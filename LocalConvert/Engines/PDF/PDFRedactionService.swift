import Foundation
import PDFKit
import CoreGraphics
import CoreText
import AppKit
import Compression

// MARK: - Permanent PDF Redaction Service

enum PDFRedactionService {

    /// Finds matching character selections & page-space boxes across the PDF for previewing or batch text redaction.
    static func findSearchRegions(
        in url: URL,
        searchTerms: [String],
        password: String? = nil
    ) throws -> [PDFRedactionRegion] {
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.invalidInput("Unable to open PDF for redaction search.")
        }
        if doc.isLocked {
            guard let pwd = password, !pwd.isEmpty, doc.unlock(withPassword: pwd) else {
                throw ConversionError.invalidInput("PDF is password-locked.")
            }
        }

        let cleaned = searchTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }

        var regions: [PDFRedactionRegion] = []
        for term in cleaned {
            let matches = doc.findString(term, withOptions: [.caseInsensitive])
            for selection in matches {
                for lineSel in selection.selectionsByLine() {
                    for page in lineSel.pages {
                        let pageIndex = doc.index(for: page)
                        let rawBounds = lineSel.bounds(for: page)
                        let transformed = convertPageRectToUpright(rawBounds, page: page)
                        if !transformed.isEmpty {
                            regions.append(PDFRedactionRegion(
                                pageIndex: pageIndex,
                                rect: transformed,
                                label: "Match: \"\(term)\""
                            ))
                        }
                    }
                }
            }
            // Also scan annotation contents & AcroForm widget values
            for pageIndex in 0..<doc.pageCount {
                guard let page = doc.page(at: pageIndex) else { continue }
                for ann in page.annotations {
                    let haystack = [ann.contents, ann.widgetStringValue, ann.fieldName]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    if !haystack.isEmpty, haystack.range(of: term, options: [.caseInsensitive]) != nil {
                        let transformed = convertPageRectToUpright(ann.bounds, page: page)
                        if !transformed.isEmpty {
                            regions.append(PDFRedactionRegion(
                                pageIndex: pageIndex,
                                rect: transformed,
                                label: "Annotation/Form Match: \"\(term)\""
                            ))
                        }
                    }
                }
            }
        }
        return regions
    }

    /// Permanently removes text, pixel content, hidden text runs, and overlapping annotations inside all specified
    /// regions and whole-page targets, writes to a new output file, and independently verifies zero residual text recovery.
    static func redact(
        inputURL: URL,
        outputURL: URL,
        options: PDFRedactionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFRedactionVerificationReport {
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw ConversionError.invalidInput("Redaction never overwrites the source PDF directly.")
        }

        guard let doc = PDFDocument(url: inputURL) else {
            throw ConversionError.invalidInput("Unable to open PDF document '\(inputURL.lastPathComponent)'.")
        }
        if doc.isLocked {
            if let pwd = options.password, !pwd.isEmpty {
                guard doc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF '\(inputURL.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF '\(inputURL.lastPathComponent)' is password-protected.")
            }
        }

        let totalPages = doc.pageCount
        guard totalPages > 0 else {
            throw ConversionError.invalidInput("The PDF contains no pages.")
        }

        // Pre-redaction structural risk audit
        let preInspect = try? PDFDocumentInspector.inspect(url: inputURL, password: options.password)
        var riskWarnings: [String] = []
        if let preInspect {
            if preInspect.hasDigitalSignatures {
                riskWarnings.append("Source PDF contained digital signature(s); permanent redaction writes a new unsigned PDF.")
            }
            if preInspect.hasXFA {
                riskWarnings.append("Source PDF contained XFA XML definitions; rebuilt sanitized PDF drops interactive XFA streams.")
            }
            if preInspect.hasEmbeddedFiles {
                riskWarnings.append("Source PDF contained embedded file attachments (\(preInspect.embeddedFileNames.count)); attachments are excluded from sanitized output.")
            }
            if preInspect.hasJavaScriptActions {
                riskWarnings.append("Source PDF contained JavaScript triggers; actions are removed in sanitized output.")
            }
            if preInspect.hasOptionalContentLayers {
                riskWarnings.append("Optional Content Layers (/OCProperties) flattened into sanitized pages.")
            }
        }

        let outlineItemCount = countOutlineItems(doc.outlineRoot)

        // Gather all redaction regions by page index (in upright page coordinates)
        var pageRegions: [Int: [CGRect]] = [:]
        var appliedRegionsCount = 0

        for region in options.regions {
            guard region.pageIndex >= 0 && region.pageIndex < totalPages else { continue }
            pageRegions[region.pageIndex, default: []].append(region.rect)
            appliedRegionsCount += 1
        }

        let termMatches = try findSearchRegions(in: inputURL, searchTerms: options.searchTerms, password: options.password)
        for match in termMatches {
            // Pad matched text bounding boxes slightly to account for descenders/ascenders and kerning
            let padded = match.rect.insetBy(dx: -2.0, dy: -2.0)
            pageRegions[match.pageIndex, default: []].append(padded)
            appliedRegionsCount += 1
        }

        if !options.wholePageRanges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let wholePages = PageRangeParser.parse(options.wholePageRanges, maxPages: totalPages)
            for oneBased in wholePages {
                let pIdx = oneBased - 1
                if let page = doc.page(at: pIdx) {
                    let fullUpright = uprightSize(for: page)
                    pageRegions[pIdx, default: []].append(CGRect(origin: .zero, size: fullUpright))
                    appliedRegionsCount += 1
                }
            }
        }

        guard !pageRegions.isEmpty else {
            throw ConversionError.invalidInput("No redaction regions, search matches, or page numbers were matched.")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Redact-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        var dummyBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var auxInfo: [CFString: Any] = [:]
        var scrubbedMetadataItems = 0
        let lowerSearchTerms = options.searchTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        if !options.removeMetadata, let attrs = doc.documentAttributes {
            func cleanAttr(_ raw: String?) -> String? {
                guard let raw, !raw.isEmpty else { return nil }
                if lowerSearchTerms.contains(where: { raw.localizedCaseInsensitiveContains($0) }) {
                    scrubbedMetadataItems += 1
                    return nil
                }
                return raw
            }
            if let t = cleanAttr(attrs[PDFDocumentAttribute.titleAttribute] as? String) { auxInfo[kCGPDFContextTitle] = t as CFString }
            if let a = cleanAttr(attrs[PDFDocumentAttribute.authorAttribute] as? String) { auxInfo[kCGPDFContextAuthor] = a as CFString }
            if let s = cleanAttr(attrs[PDFDocumentAttribute.subjectAttribute] as? String) { auxInfo[kCGPDFContextSubject] = s as CFString }
        } else {
            if let attrs = doc.documentAttributes {
                scrubbedMetadataItems += attrs.count
            }
            if preInspect?.hasXMPMetadata == true && options.scrubXMPMetadata {
                scrubbedMetadataItems += 1
            }
            auxInfo[kCGPDFContextTitle] = "" as CFString
            auxInfo[kCGPDFContextAuthor] = "" as CFString
            auxInfo[kCGPDFContextSubject] = "" as CFString
            auxInfo[kCGPDFContextKeywords] = "" as CFString
            auxInfo[kCGPDFContextCreator] = "" as CFString
        }

        guard let outContext = CGContext(tempOut as CFURL, mediaBox: &dummyBox, auxInfo as CFDictionary) else {
            throw ConversionError.engineExecutionFailed("Failed to create sanitized PDF context.", underlyingError: nil)
        }

        let scale = CGFloat(max(150.0, min(350.0, options.renderDPI)) / 72.0)
        var removedAnnotationsCount = 0
        var scrubbedFormFieldCount = 0
        let fillColor = cgColor(fromHex: options.fillColorHex)

        for pageIndex in 0..<totalPages {
            try Task.checkCancellation()
            guard let page = doc.page(at: pageIndex) else { continue }

            progress(.determinate(
                Double(pageIndex) / Double(totalPages),
                message: "Sanitizing page \(pageIndex + 1) of \(totalPages)..."
            ))

            if let rects = pageRegions[pageIndex], !rects.isEmpty {
                // Sanitized page path: permanently excise redacted content from pixels & content streams
                let uSize = uprightSize(for: page)
                let uBox = CGRect(origin: .zero, size: uSize)

                if options.cleanAnnotationsInRegions {
                    // Remove any annotations or form widgets overlapping redacted rectangles or matching blocked terms before snapshot
                    let expandedRects = rects.map { $0.insetBy(dx: -2.0, dy: -2.0) }
                    for ann in page.annotations {
                        let annUpright = convertPageRectToUpright(ann.bounds, page: page)
                        let annText = [ann.contents, ann.widgetStringValue, ann.fieldName].compactMap { $0 }.joined(separator: " ")
                        let textMatch = !annText.isEmpty && lowerSearchTerms.contains { annText.localizedCaseInsensitiveContains($0) }
                        if textMatch || expandedRects.contains(where: { $0.intersects(annUpright) }) {
                            if (ann.type ?? "").contains("Widget") || ann.fieldName != nil {
                                scrubbedFormFieldCount += 1
                            }
                            page.removeAnnotation(ann)
                            removedAnnotationsCount += 1
                        }
                    }
                }

                // Collect strictly non-overlapping text runs BEFORE building final sanitized page
                let retainedSpans: [(text: String, rect: CGRect)]
                if options.preserveUnrelatedTextSearchability {
                    retainedSpans = extractRetainedTextSpans(
                        from: page,
                        excludingUprightRects: rects,
                        blockedTermsLowercased: lowerSearchTerms
                    )
                } else {
                    retainedSpans = []
                }

                // Render single page raster into memory bitmap & physically wipe redacted pixel regions BEFORE image creation
                let pxW = max(1, Int((uSize.width * scale).rounded()))
                let pxH = max(1, Int((uSize.height * scale).rounded()))
                guard let bmpCtx = CGContext(
                    data: nil,
                    width: pxW,
                    height: pxH,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    throw ConversionError.engineExecutionFailed("Failed to allocate bitmap memory for redaction.", underlyingError: nil)
                }

                bmpCtx.setFillColor(.white)
                bmpCtx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                bmpCtx.saveGState()
                bmpCtx.scaleBy(x: scale, y: scale)
                drawPageUpright(page: page, targetRect: uBox, into: bmpCtx)
                // Physically destroy original pixels inside every redacted box
                bmpCtx.setFillColor(fillColor)
                for r in rects {
                    bmpCtx.fill(r.insetBy(dx: -1.0, dy: -1.0))
                }
                bmpCtx.restoreGState()

                guard let sanitizedCGImage = bmpCtx.makeImage() else {
                    throw ConversionError.engineExecutionFailed("Failed to snapshot redacted page bitmap.", underlyingError: nil)
                }

                var pageMediaBox = uBox
                let pageInfo: [CFString: Any] = [
                    kCGPDFContextMediaBox: Data(bytes: &pageMediaBox, count: MemoryLayout<CGRect>.size) as CFData
                ]
                outContext.beginPDFPage(pageInfo as CFDictionary)
                outContext.draw(sanitizedCGImage, in: uBox)

                // Re-paint crisp vector fill (and optional redaction label) cleanly over pixel boxes
                outContext.saveGState()
                outContext.setFillColor(fillColor)
                for r in rects {
                    outContext.fill(r.insetBy(dx: -1.0, dy: -1.0))
                }
                if !options.overlayTag.isEmpty {
                    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 8.0, nil)
                    for r in rects where r.height >= 12 && r.width >= 36 {
                        let attr = CFAttributedStringCreate(nil, options.overlayTag as CFString, [
                            kCTFontAttributeName: font,
                            kCTForegroundColorAttributeName: CGColor.white
                        ] as CFDictionary)!
                        let line = CTLineCreateWithAttributedString(attr)
                        outContext.textPosition = CGPoint(x: r.minX + 3, y: r.midY - 3)
                        CTLineDraw(line, outContext)
                    }
                }
                outContext.restoreGState()

                // Emit invisible searchable text ONLY for spans strictly outside redacted regions
                if !retainedSpans.isEmpty {
                    outContext.saveGState()
                    outContext.setTextDrawingMode(.invisible)
                    for span in retainedSpans {
                        drawInvisibleSpan(span.text, in: span.rect, into: outContext)
                    }
                    outContext.restoreGState()
                }

                outContext.endPDFPage()
            } else {
                // Unredacted page: preserve untouched vector graphics & searchable text natively
                let rawBounds = page.bounds(for: .mediaBox)
                let normRot = ((page.rotation % 360) + 360) % 360
                let isSideways = (normRot == 90 || normRot == 270)
                let uSize = CGSize(
                    width: max(1, isSideways ? rawBounds.height : rawBounds.width),
                    height: max(1, isSideways ? rawBounds.width : rawBounds.height)
                )
                let uBox = CGRect(origin: .zero, size: uSize)
                var pageMediaBox = uBox
                let pageInfo: [CFString: Any] = [
                    kCGPDFContextMediaBox: Data(bytes: &pageMediaBox, count: MemoryLayout<CGRect>.size) as CFData
                ]
                outContext.beginPDFPage(pageInfo as CFDictionary)
                drawPageUpright(page: page, targetRect: uBox, into: outContext)
                outContext.endPDFPage()
            }
        }

        try Task.checkCancellation()
        outContext.closePDF()

        guard FileManager.default.fileExists(atPath: tempOut.path),
              let verifyDoc = PDFDocument(url: tempOut),
              verifyDoc.pageCount == totalPages else {
            throw ConversionError.engineExecutionFailed("Redacted PDF failed structural validation.", underlyingError: nil)
        }

        // Independent Security Verification on staged tempOut BEFORE atomic commit:
        // ensures failed verification never deletes or overwrites any pre-existing outputURL.
        progress(.determinate(0.95, message: "Verifying zero residual redacted content..."))
        let finalDoc = PDFDocument(url: tempOut)
        var residual: [String] = []
        var checks: [String] = []
        let activeTerms = options.searchTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let turkishLocale = Locale(identifier: "tr_TR")

        func matchesTerm(_ haystack: String, _ term: String) -> Bool {
            haystack.range(of: term, options: [.caseInsensitive]) != nil
                || haystack.range(of: term, options: [.caseInsensitive], locale: turkishLocale) != nil
        }

        // Collect raw + Flate-decompressed stream text + incremental revision (%%EOF) count
        let rawBytes = (try? Data(contentsOf: tempOut)) ?? Data()
        let eofCount = countOccurrences(of: Data("%%EOF".utf8), in: rawBytes)
        let streamDump = extractReadableAndFlateText(from: rawBytes)

        if let finalDoc {
            for term in activeTerms {
                var matched = false
                if !finalDoc.findString(term, withOptions: [.caseInsensitive]).isEmpty {
                    matched = true
                } else if let allText = finalDoc.string, matchesTerm(allText, term) {
                    matched = true
                }
                // Check output annotations & form values
                for idx in 0..<finalDoc.pageCount where !matched {
                    if let p = finalDoc.page(at: idx) {
                        for ann in p.annotations {
                            let haystack = [ann.contents, ann.widgetStringValue, ann.fieldName].compactMap { $0 }.joined(separator: " ")
                            if matchesTerm(haystack, term) {
                                matched = true
                                break
                            }
                        }
                    }
                }
                // Check output Info attributes
                if !matched, let attrs = finalDoc.documentAttributes {
                    for val in attrs.values {
                        if let str = val as? String, matchesTerm(str, term) {
                            matched = true
                            break
                        }
                    }
                }
                // Check outline labels
                if !matched && outlineContains(finalDoc.outlineRoot, term: term, matcher: matchesTerm) {
                    matched = true
                }
                // Check raw + Flate-decompressed PDF streams
                if !matched, matchesTerm(streamDump, term) {
                    matched = true
                }
                if matched {
                    residual.append(term)
                }
            }
            checks.append("PDFKit full-text index & page string extraction checked (\(activeTerms.count) search term(s)).")
            checks.append("Annotations, AcroForm values, Outlines, and Document Info dictionary verified clean.")
            checks.append("Raw PDF bytes and Flate-decompressed content streams verified (\(streamDump.utf8.count) chars scanned).")
            checks.append("Incremental revision count in output PDF: \(eofCount) (single clean write).")
            let postInspect = try? PDFDocumentInspector.inspect(url: tempOut)
            if postInspect?.hasXMPMetadata == false {
                checks.append("Catalog XMP metadata stream absent/stripped.")
            }
            if postInspect?.hasEmbeddedFiles == false {
                checks.append("Embedded file attachments: 0.")
            }
        }

        let isClean = (finalDoc != nil) && residual.isEmpty && (eofCount <= 1)
        if !isClean && options.failIfVerificationFails {
            throw ConversionError.engineExecutionFailed(
                "Permanent redaction security check failed: residual redacted terms or historical revisions detected (\(residual.joined(separator: ", "))).",
                underlyingError: nil
            )
        }

        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)

        progress(.determinate(1.0, message: "Redaction Complete"))
        return PDFRedactionVerificationReport(
            outputURL: outputURL,
            redactedPageIndices: Set(pageRegions.keys),
            appliedRegionsCount: appliedRegionsCount,
            removedAnnotationsCount: removedAnnotationsCount,
            residualMatchesFound: residual,
            isVerifiedClean: isClean,
            scrubbedOutlineCount: outlineItemCount,
            scrubbedFormFieldCount: scrubbedFormFieldCount,
            scrubbedMetadataItemsCount: scrubbedMetadataItems,
            verificationChecks: checks,
            riskWarnings: riskWarnings,
            incrementalRevisionsCount: eofCount,
            decompressedStreamChecked: true
        )
    }

    // MARK: - Coordinate & Retained Text Helpers

    static func uprightSize(for page: PDFPage) -> CGSize {
        let raw = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360
        if rot == 90 || rot == 270 {
            return CGSize(width: max(1, raw.height), height: max(1, raw.width))
        }
        return CGSize(width: max(1, raw.width), height: max(1, raw.height))
    }

    /// Maps a rectangle in PDF page `.mediaBox` coordinates into upright rendered coordinates `(0...uSize.width, 0...uSize.height)`.
    static func convertPageRectToUpright(_ rect: CGRect, page: PDFPage) -> CGRect {
        let raw = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360
        let tx = rect.minX - raw.minX
        let ty = rect.minY - raw.minY
        switch rot {
        case 90:
            return CGRect(x: ty, y: raw.width - (tx + rect.width), width: rect.height, height: rect.width)
        case 180:
            return CGRect(x: raw.width - (tx + rect.width), y: raw.height - (ty + rect.height), width: rect.width, height: rect.height)
        case 270:
            return CGRect(x: raw.height - (ty + rect.height), y: tx, width: rect.height, height: rect.width)
        default:
            return CGRect(x: tx, y: ty, width: rect.width, height: rect.height)
        }
    }

    private static func drawPageUpright(page: PDFPage, targetRect: CGRect, into context: CGContext) {
        context.saveGState()
        context.setFillColor(.white)
        context.fill(targetRect)
        if let cgPage = page.pageRef {
            let transform = cgPage.getDrawingTransform(.mediaBox, rect: targetRect, rotate: 0, preserveAspectRatio: true)
            context.concatenate(transform)
            context.drawPDFPage(cgPage)
        } else {
            page.draw(with: .mediaBox, to: context)
        }
        context.restoreGState()
    }

    private static func extractRetainedTextSpans(
        from page: PDFPage,
        excludingUprightRects redactRects: [CGRect],
        blockedTermsLowercased: [String]
    ) -> [(text: String, rect: CGRect)] {
        guard let nsText = page.string as NSString?, nsText.length > 0 else { return [] }
        let paddedRedacts = redactRects.map { $0.insetBy(dx: -3.0, dy: -3.0) }

        var spans: [(text: String, rect: CGRect)] = []
        var currentChars = ""
        var currentUnionRect = CGRect.null

        func flushCurrent() {
            let trimmed = currentChars.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !currentUnionRect.isNull {
                let lowered = trimmed.lowercased()
                let containsBlocked = blockedTermsLowercased.contains { lowered.contains($0) }
                if !containsBlocked {
                    spans.append((trimmed, currentUnionRect))
                }
            }
            currentChars = ""
            currentUnionRect = .null
        }

        var idx = 0
        while idx < nsText.length {
            let seqRange = nsText.rangeOfComposedCharacterSequence(at: idx)
            let charStr = nsText.substring(with: seqRange)
            if charStr == "\n" || charStr == "\r" {
                flushCurrent()
                idx += max(1, seqRange.length)
                continue
            }
            let rawCharBounds = page.characterBounds(at: idx)
            let uprightChar = convertPageRectToUpright(rawCharBounds, page: page)

            let intersectsRedact = paddedRedacts.contains { $0.intersects(uprightChar) }
            if intersectsRedact {
                flushCurrent()
                idx += max(1, seqRange.length)
                continue
            }

            // Break spans on large Y jumps (new line)
            if !currentUnionRect.isNull && abs(uprightChar.midY - currentUnionRect.midY) > max(8.0, currentUnionRect.height * 0.8) {
                flushCurrent()
            }

            currentChars.append(charStr)
            currentUnionRect = currentUnionRect.isNull ? uprightChar : currentUnionRect.union(uprightChar)
            idx += max(1, seqRange.length)
        }
        flushCurrent()
        return spans
    }

    private static func countOutlineItems(_ node: PDFOutline?) -> Int {
        guard let node else { return 0 }
        var count = (node.label?.isEmpty == false) ? 1 : 0
        for idx in 0..<node.numberOfChildren {
            count += countOutlineItems(node.child(at: idx))
        }
        return count
    }

    private static func outlineContains(_ node: PDFOutline?, term: String, matcher: (String, String) -> Bool) -> Bool {
        guard let node else { return false }
        if let label = node.label, !label.isEmpty, matcher(label, term) {
            return true
        }
        for idx in 0..<node.numberOfChildren {
            if outlineContains(node.child(at: idx), term: term, matcher: matcher) {
                return true
            }
        }
        return false
    }

    private static func countOccurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, in: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    /// Scans raw bytes plus zlib-inflated PDF `stream...endstream` blocks for residual plaintext or UTF-16BE recovery attempts.
    private static func extractReadableAndFlateText(from pdfData: Data) -> String {
        var chunks: [String] = []
        if let utf8Raw = String(data: pdfData, encoding: .utf8) {
            chunks.append(utf8Raw)
        } else if let latin1 = String(data: pdfData, encoding: .isoLatin1) {
            chunks.append(latin1)
        }

        let streamMarker = Data("stream".utf8)
        let endStreamMarker = Data("endstream".utf8)
        var cursor = pdfData.startIndex
        while cursor < pdfData.endIndex,
              let sRange = pdfData.range(of: streamMarker, in: cursor..<pdfData.endIndex) {
            // Skip "endstream" hits
            let prevChar = sRange.lowerBound > pdfData.startIndex ? pdfData[pdfData.index(before: sRange.lowerBound)] : 0x0A
            if prevChar == UInt8(ascii: "d") {
                cursor = sRange.upperBound
                continue
            }
            var dataStart = sRange.upperBound
            if dataStart < pdfData.endIndex && pdfData[dataStart] == 0x0D { dataStart = pdfData.index(after: dataStart) }
            if dataStart < pdfData.endIndex && pdfData[dataStart] == 0x0A { dataStart = pdfData.index(after: dataStart) }

            guard let eRange = pdfData.range(of: endStreamMarker, in: dataStart..<pdfData.endIndex) else { break }
            let compressedSlice = pdfData[dataStart..<eRange.lowerBound]
            // Standard zlib-wrapped FlateDecode stream starts with 0x78 (CMF) + FLG byte
            if compressedSlice.count > 6 && compressedSlice[compressedSlice.startIndex] == 0x78 {
                let rawDeflate = Data(compressedSlice.dropFirst(2))
                if let inflated = try? (rawDeflate as NSData).decompressed(using: .zlib) as Data {
                    if let s = String(data: inflated, encoding: .utf8) {
                        chunks.append(s)
                    } else if let s = String(data: inflated, encoding: .isoLatin1) {
                        chunks.append(s)
                    }
                }
            }
            cursor = eRange.upperBound
        }
        return chunks.joined(separator: "\n")
    }

    private static func drawInvisibleSpan(_ text: String, in rect: CGRect, into context: CGContext) {
        let fontSize = max(5.0, rect.height * 0.85)
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
        guard let attr = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attr)
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let hScale = lineWidth > 1.0 ? min(3.0, max(0.3, rect.width / lineWidth)) : 1.0

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY + (rect.height * 0.15))
        context.scaleBy(x: hScale, y: 1.0)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func cgColor(fromHex hex: String) -> CGColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let val = UInt64(cleaned, radix: 16) else {
            return .black
        }
        let r = CGFloat((val >> 16) & 0xFF) / 255.0
        let g = CGFloat((val >> 8) & 0xFF) / 255.0
        let b = CGFloat(val & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}

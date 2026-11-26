import Foundation
import Vision
import PDFKit
import CoreGraphics
import CoreText
import AppKit
import Darwin

// MARK: - PDF OCR Service (Apple Vision + Invisible CoreText Layer)

enum PDFOCRService {

    /// Queries the macOS Vision framework for actual installed & supported recognition languages.
    static func supportedLanguages(for level: PDFOCRRecognitionLevel = .accurate) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (level == .accurate) ? .accurate : .fast
        let langs = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        return langs.isEmpty ? ["en-US"] : langs
    }

    static func humanLanguageName(for code: String) -> String {
        let localized = Locale.current.localizedString(forIdentifier: code)
            ?? Locale(identifier: "en").localizedString(forIdentifier: code)
        if let localized {
            return "\(localized) (\(code))"
        }
        return code
    }

    static func runOCR(
        inputURL: URL,
        outputPDFURL: URL,
        sidecarTextURL: URL? = nil,
        options: PDFOCROptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFOCRResult {
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }

        // Write atomically to a temporary PDF and move cleanly on success (never overwrite source)
        guard let pdfDoc = PDFDocument(url: inputURL) else {
            throw ConversionError.invalidInput("Unable to open PDF document at '\(inputURL.lastPathComponent)'.")
        }

        if pdfDoc.isLocked {
            if let pwd = options.password, !pwd.isEmpty {
                guard pdfDoc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF '\(inputURL.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF '\(inputURL.lastPathComponent)' is password-protected.")
            }
        }

        let totalPages = pdfDoc.pageCount
        guard totalPages > 0 else {
            throw ConversionError.invalidInput("The PDF contains no pages.")
        }

        let targetIndices: [Int]
        if options.pageRanges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetIndices = Array(0..<totalPages)
        } else {
            let parsed = PageRangeParser.parse(options.pageRanges, maxPages: totalPages)
            if parsed.isEmpty {
                throw ConversionError.invalidInput("No valid page numbers matched range '\(options.pageRanges)'.")
            }
            targetIndices = parsed.map { $0 - 1 }
        }
        let targetSet = Set(targetIndices)

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-OCR-\(UUID().uuidString).pdf")
        let ocrStreamTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-OCRStream-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: tempOut)
            try? FileManager.default.removeItem(at: ocrStreamTempURL)
        }

        enum PageSourceMapping {
            case keepOriginal(Int)
            case ocrStreamPage(Int)
        }

        var pageMappings: [PageSourceMapping] = []
        var pageSummaries: [PDFOCRPageSummary] = []
        var fullTextChunks: [String] = []
        var processedCount = 0
        var skippedCount = 0
        var warnings: [String] = []
        let supportedLangSet = Set(supportedLanguages(for: options.recognitionLevel))
        let requestedLangs = options.languageCodes.filter { supportedLangSet.contains($0) }
        let effectiveLangs = requestedLangs.isEmpty ? ["en-US"] : requestedLangs
        if requestedLangs.count < options.languageCodes.count {
            let unsupported = Set(options.languageCodes).subtracting(supportedLangSet).sorted()
            warnings.append("Unsupported OCR language(s) ignored: \(unsupported.joined(separator: ", ")).")
        }

        let scale = CGFloat(max(120.0, min(300.0, options.renderDPI)) / 72.0)
        var ocrStreamCtx: CGContext? = nil
        var ocrStreamCount = 0

        for pageIndex in 0..<totalPages {
            try Task.checkCancellation()

            guard let page = pdfDoc.page(at: pageIndex) else { continue }
            progress(.determinate(
                Double(pageIndex) / Double(totalPages),
                message: "Analyzing page \(pageIndex + 1) of \(totalPages)..."
            ))

            let uprightSize = PDFCoordinateGeometry.uprightSize(for: page)
            let uprightBox = CGRect(origin: .zero, size: uprightSize)
            var pageMediaBox = uprightBox
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &pageMediaBox, count: MemoryLayout<CGRect>.size) as CFData
            ]

            // Incremental decision: skip OCR if outside selected page range or already contains genuine text
            let existingText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !targetSet.contains(pageIndex) {
                pageMappings.append(.keepOriginal(pageIndex))
                skippedCount += 1
                pageSummaries.append(PDFOCRPageSummary(
                    pageNumber: pageIndex + 1,
                    didRunOCR: false,
                    skippedReason: "Excluded by page selection",
                    recognizedCharacters: existingText.count,
                    confidenceAverage: 1.0
                ))
                if !existingText.isEmpty { fullTextChunks.append("--- Page \(pageIndex + 1) ---\n\(existingText)") }
                continue
            }

            let hasImage = pageContainsRasterImage(page)
            let threshold = hasImage ? max(24, options.hybridTextImageThreshold) : 12
            if options.skipExistingTextPages && existingText.count >= threshold {
                pageMappings.append(.keepOriginal(pageIndex))
                skippedCount += 1
                pageSummaries.append(PDFOCRPageSummary(
                    pageNumber: pageIndex + 1,
                    didRunOCR: false,
                    skippedReason: "Page already contains searchable text (\(existingText.count) chars); original vector/links preserved",
                    recognizedCharacters: existingText.count,
                    confidenceAverage: 1.0
                ))
                fullTextChunks.append("--- Page \(pageIndex + 1) ---\n\(existingText)")
                continue
            }

            if ocrStreamCtx == nil {
                var initBox = uprightBox
                guard let ctx = CGContext(ocrStreamTempURL as CFURL, mediaBox: &initBox, nil) else {
                    throw ConversionError.engineExecutionFailed("Failed to allocate disk-backed PDF context for OCR.", underlyingError: nil)
                }
                ocrStreamCtx = ctx
            }
            guard let streamCtx = ocrStreamCtx else { continue }

            // Render, optional deskew, and OCR inside autoreleasepool so large multipage PDFs release CGImages cleanly
            let pageOutcome: (pageJoined: String, avgConf: Float) = try autoreleasepool {
                var cgImage = try renderPageImage(page: page, uprightSize: uprightSize, scale: scale)
                var wasDeskewed = false
                if options.deskewPages, let deskewed = try detectAndDeskewIfNeeded(cgImage) {
                    cgImage = deskewed
                    wasDeskewed = true
                }

                progress(.determinate(
                    (Double(pageIndex) + 0.45) / Double(totalPages),
                    message: "Recognizing text on page \(pageIndex + 1) of \(totalPages)..."
                ))

                let observations = try recognizeTextObservations(
                    in: cgImage,
                    languages: effectiveLangs,
                    level: options.recognitionLevel,
                    usesLanguageCorrection: options.usesLanguageCorrection,
                    automaticallyDetectsLanguage: options.automaticallyDetectsLanguage
                )

                streamCtx.beginPDFPage(pageInfo as CFDictionary)
                if wasDeskewed {
                    streamCtx.saveGState()
                    streamCtx.setFillColor(.white)
                    streamCtx.fill(uprightBox)
                    streamCtx.draw(cgImage, in: uprightBox)
                    streamCtx.restoreGState()
                } else {
                    drawPageUpright(page: page, targetRect: uprightBox, into: streamCtx)
                }

                var pageLines: [String] = []
                var confidenceSum: Float = 0
                var confidenceCount = 0

                let sortedObs = options.multiColumnReadingOrder
                    ? sortObservationsForReadingOrder(observations)
                    : observations.sorted {
                        if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 {
                            return $0.boundingBox.midY > $1.boundingBox.midY
                        }
                        return $0.boundingBox.minX < $1.boundingBox.minX
                    }

                streamCtx.saveGState()
                streamCtx.setTextDrawingMode(.invisible)

                for obs in sortedObs {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let rawStr = candidate.string
                    let trimmed = rawStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    pageLines.append(trimmed)
                    confidenceSum += candidate.confidence
                    confidenceCount += 1

                    let tokenRanges = whitespaceTokenRanges(in: rawStr)
                    var tokenBoxes: [(String, CGRect)] = []
                    for range in tokenRanges {
                        let token = String(rawStr[range])
                        guard !token.isEmpty else { continue }
                        if let boxObs = try? candidate.boundingBox(for: range) {
                            let norm = boxObs.boundingBox
                            let rect = CGRect(
                                x: norm.minX * uprightSize.width,
                                y: norm.minY * uprightSize.height,
                                width: max(2.0, norm.width * uprightSize.width),
                                height: max(5.0, norm.height * uprightSize.height)
                            )
                            tokenBoxes.append((token, rect))
                        }
                    }

                    if !tokenBoxes.isEmpty && tokenBoxes.count == tokenRanges.count {
                        for (tIdx, pair) in tokenBoxes.enumerated() {
                            let needsSpace = (tIdx + 1 < tokenBoxes.count)
                            drawInvisibleLine(pair.0, in: pair.1, appendTrailingSpace: needsSpace, into: streamCtx)
                        }
                    } else {
                        let norm = obs.boundingBox
                        let rect = CGRect(
                            x: norm.minX * uprightSize.width,
                            y: norm.minY * uprightSize.height,
                            width: max(4.0, norm.width * uprightSize.width),
                            height: max(6.0, norm.height * uprightSize.height)
                        )
                        drawInvisibleLine(trimmed, in: rect, appendTrailingSpace: false, into: streamCtx)
                    }
                }

                streamCtx.restoreGState()
                streamCtx.endPDFPage()

                let joined = pageLines.joined(separator: "\n")
                let avgConf = confidenceCount > 0 ? (confidenceSum / Float(confidenceCount)) : 0
                return (joined, avgConf)
            }

            pageMappings.append(.ocrStreamPage(ocrStreamCount))
            ocrStreamCount += 1

            if pageOutcome.pageJoined.isEmpty {
                warnings.append("Page \(pageIndex + 1): No recognizable text detected by Vision OCR.")
            }

            processedCount += 1
            pageSummaries.append(PDFOCRPageSummary(
                pageNumber: pageIndex + 1,
                didRunOCR: true,
                skippedReason: nil,
                recognizedCharacters: pageOutcome.pageJoined.count,
                confidenceAverage: pageOutcome.avgConf
            ))
            if !pageOutcome.pageJoined.isEmpty {
                fullTextChunks.append("--- Page \(pageIndex + 1) ---\n\(pageOutcome.pageJoined)")
            }

            if (pageIndex + 1) % 8 == 0 {
                malloc_zone_pressure_relief(nil, 0)
            }
        }

        ocrStreamCtx?.closePDF()
        ocrStreamCtx = nil
        try Task.checkCancellation()

        // Assemble final PDF preserving untouched skipped vector pages, OCR pages, outlines, and non-widget annotations
        let outputDoc = PDFDocument()
        if let attrs = pdfDoc.documentAttributes {
            var mutableAttrs = attrs
            mutableAttrs[PDFDocumentAttribute.creatorAttribute] = "LocalConvert Audio & PDF Toolbox (Apple Vision OCR)"
            outputDoc.documentAttributes = mutableAttrs
        }

        let streamedOCRDoc: PDFDocument? = ocrStreamCount > 0 ? PDFDocument(url: ocrStreamTempURL) : nil
        var targetPageLookup: [PDFOutlineRemapper.RemapKey: PDFPage] = [:]
        var copiedPagesByIndex: [Int: PDFPage] = [:]

        for (srcIndex, mapping) in pageMappings.enumerated() {
            switch mapping {
            case .keepOriginal(let origIdx):
                if let pageCopy = pdfDoc.page(at: origIdx)?.copy() as? PDFPage {
                    outputDoc.insert(pageCopy, at: outputDoc.pageCount)
                    if let inserted = outputDoc.page(at: outputDoc.pageCount - 1) {
                        targetPageLookup[PDFOutlineRemapper.RemapKey(url: inputURL, pageIndex: srcIndex)] = inserted
                        copiedPagesByIndex[srcIndex] = inserted
                    }
                }
            case .ocrStreamPage(let streamIdx):
                if let ocrPage = streamedOCRDoc?.page(at: streamIdx)?.copy() as? PDFPage {
                    outputDoc.insert(ocrPage, at: outputDoc.pageCount)
                    if let inserted = outputDoc.page(at: outputDoc.pageCount - 1) {
                        targetPageLookup[PDFOutlineRemapper.RemapKey(url: inputURL, pageIndex: srcIndex)] = inserted
                        copiedPagesByIndex[srcIndex] = inserted
                    }
                } else if let fallback = pdfDoc.page(at: srcIndex)?.copy() as? PDFPage {
                    outputDoc.insert(fallback, at: outputDoc.pageCount)
                    if let inserted = outputDoc.page(at: outputDoc.pageCount - 1) {
                        targetPageLookup[PDFOutlineRemapper.RemapKey(url: inputURL, pageIndex: srcIndex)] = inserted
                        copiedPagesByIndex[srcIndex] = inserted
                    }
                }
            }
        }

        // Preserve links & non-widget annotations on newly OCR'd pages
        for (srcIndex, mapping) in pageMappings.enumerated() {
            guard case .ocrStreamPage = mapping,
                  let srcPage = pdfDoc.page(at: srcIndex),
                  let dstPage = copiedPagesByIndex[srcIndex] else { continue }
            let dstSize = PDFCoordinateGeometry.uprightSize(for: dstPage)
            for ann in srcPage.annotations {
                let rawType = (ann.type ?? "").replacingOccurrences(of: "/", with: "")
                guard rawType != "Widget" && rawType != "Popup" else { continue }

                var targetBounds = ann.bounds
                if PDFCoordinateGeometry.normalizedRotation(srcPage.rotation) != 0 ||
                    PDFCoordinateGeometry.effectiveDisplayBox(for: srcPage).origin != .zero {
                    let n1 = PDFCoordinateGeometry.rawPagePointToUprightNormalized(CGPoint(x: ann.bounds.minX, y: ann.bounds.minY), on: srcPage)
                    let n2 = PDFCoordinateGeometry.rawPagePointToUprightNormalized(CGPoint(x: ann.bounds.maxX, y: ann.bounds.maxY), on: srcPage)
                    let vx1 = min(n1.x, n2.x) * dstSize.width
                    let vx2 = max(n1.x, n2.x) * dstSize.width
                    let vy1 = (1.0 - max(n1.y, n2.y)) * dstSize.height
                    let vy2 = (1.0 - min(n1.y, n2.y)) * dstSize.height
                    targetBounds = CGRect(x: vx1, y: vy1, width: max(4, vx2 - vx1), height: max(4, vy2 - vy1))
                }

                if rawType == "Link" {
                    let link = PDFAnnotation(bounds: targetBounds, forType: .link, withProperties: nil)
                    if let url = ann.url {
                        link.url = url
                    } else if let dest = ann.destination, let destPage = dest.page {
                        let destIdx = pdfDoc.index(for: destPage)
                        if destIdx >= 0, let mappedDest = copiedPagesByIndex[destIdx] {
                            link.destination = PDFDestination(page: mappedDest, at: dest.point)
                        }
                    } else if let act = ann.action {
                        link.action = act
                    }
                    dstPage.addAnnotation(link)
                } else if let cloned = ann.copy() as? PDFAnnotation {
                    cloned.bounds = targetBounds
                    dstPage.addAnnotation(cloned)
                }
            }
        }

        let outlineRes = PDFOutlineRemapper.remapOutlines(
            sources: [(url: inputURL, document: pdfDoc)],
            targetPageLookup: targetPageLookup,
            into: outputDoc
        )
        if let root = outlineRes.outlineRoot {
            outputDoc.outlineRoot = root
        }

        try Task.checkCancellation()
        guard outputDoc.write(to: tempOut) else {
            throw ConversionError.engineExecutionFailed("Failed to write OCR output PDF.", underlyingError: nil)
        }

        guard FileManager.default.fileExists(atPath: tempOut.path),
              let verifyDoc = PDFDocument(url: tempOut),
              verifyDoc.pageCount == totalPages else {
            throw ConversionError.engineExecutionFailed("OCR output PDF failed structural verification.", underlyingError: nil)
        }

        try Task.checkCancellation()
        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputPDFURL, policy: .overwrite)

        let combinedText = sanitizeBidiControls(fullTextChunks.joined(separator: "\n\n"))
        var createdSidecar: URL? = nil
        if options.exportExtractedTextSidecar, let sidecarTextURL {
            try combinedText.write(to: sidecarTextURL, atomically: true, encoding: .utf8)
            createdSidecar = sidecarTextURL
        }

        progress(.determinate(1.0, message: "OCR Complete"))
        return PDFOCRResult(
            outputPDFURL: outputPDFURL,
            sidecarTextURL: createdSidecar,
            extractedText: combinedText,
            processedPages: processedCount,
            skippedPages: skippedCount,
            pageSummaries: pageSummaries,
            warnings: warnings
        )
    }

    // MARK: - Helpers

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

    private static func renderPageImage(page: PDFPage, uprightSize: CGSize, scale: CGFloat) throws -> CGImage {
        let pxW = max(1, Int((uprightSize.width * scale).rounded()))
        let pxH = max(1, Int((uprightSize.height * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed("Unable to allocate bitmap buffer for OCR rendering.", underlyingError: nil)
        }

        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        drawPageUpright(page: page, targetRect: CGRect(origin: .zero, size: uprightSize), into: ctx)
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to snapshot page raster for Vision OCR.", underlyingError: nil)
        }
        return cgImage
    }

    private static func recognizeTextObservations(
        in image: CGImage,
        languages: [String],
        level: PDFOCRRecognitionLevel,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (level == .accurate) ? .accurate : .fast
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage || languages.count > 1

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    private static func pageContainsRasterImage(_ page: PDFPage) -> Bool {
        guard let pageDict = page.pageRef?.dictionary else { return false }
        var resDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resDict), let resDict else { return false }
        var xobjDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resDict, "XObject", &xobjDict), let xobjDict else { return false }
        return CGPDFDictionaryGetCount(xobjDict) > 0
    }

    /// Groups multi-column text blocks left-column-then-right-column when observations cleanly bisect around a central gutter.
    private static func sortObservationsForReadingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        guard observations.count >= 4 else {
            return observations.sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
        }

        let leftCol = observations.filter { $0.boundingBox.maxX <= 0.50 }
        let rightCol = observations.filter { $0.boundingBox.minX >= 0.48 }
        let spanning = observations.filter { $0.boundingBox.maxX > 0.50 && $0.boundingBox.minX < 0.48 }

        // Only engage column mode if substantial disjoint blocks sit in both left & right halves
        guard leftCol.count >= 2 && rightCol.count >= 2 else {
            return observations.sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
        }

        let colTopY = max(
            leftCol.map(\.boundingBox.maxY).max() ?? 1.0,
            rightCol.map(\.boundingBox.maxY).max() ?? 1.0
        )
        let colBotY = min(
            leftCol.map(\.boundingBox.minY).min() ?? 0.0,
            rightCol.map(\.boundingBox.minY).min() ?? 0.0
        )

        func ySort(_ list: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
            list.sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.015 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
        }

        let topHeaders = spanning.filter { $0.boundingBox.midY >= colTopY - 0.01 }
        let bottomFooters = spanning.filter { $0.boundingBox.midY <= colBotY + 0.01 }
        let middleSpanning = spanning.filter { $0.boundingBox.midY < colTopY - 0.01 && $0.boundingBox.midY > colBotY + 0.01 }

        // Keep middle-spanning lines interleaved into left if few; otherwise order Header -> Left Col -> Middle -> Right Col -> Footer
        return ySort(topHeaders) + ySort(leftCol + middleSpanning) + ySort(rightCol) + ySort(bottomFooters)
    }

    private static func drawInvisibleLine(_ text: String, in rect: CGRect, appendTrailingSpace: Bool = false, into context: CGContext) {
        let fontSize = max(4.0, rect.height * 0.85)
        let baseFont = CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
        let drawnText = appendTrailingSpace ? (text + " ") : text
        let utf16Len = drawnText.utf16.count
        let resolvedFont = utf16Len > 0
            ? CTFontCreateForString(baseFont, drawnText as CFString, CFRange(location: 0, length: utf16Len))
            : baseFont
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: resolvedFont
        ]
        guard let measureAttr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary),
              let drawAttr = CFAttributedStringCreate(kCFAllocatorDefault, drawnText as CFString, attrs as CFDictionary) else {
            return
        }
        let measureLine = CTLineCreateWithAttributedString(measureAttr)
        let lineWidth = CTLineGetTypographicBounds(measureLine, nil, nil, nil)
        let drawLine = CTLineCreateWithAttributedString(drawAttr)
        let hScale = lineWidth > 1.0 ? min(4.0, max(0.25, rect.width / lineWidth)) : 1.0

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY + (rect.height * 0.15))
        context.scaleBy(x: hScale, y: 1.0)
        CTLineDraw(drawLine, context)
        context.restoreGState()
    }

    private static func whitespaceTokenRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var tokenStart: String.Index? = nil
        var idx = text.startIndex
        while idx < text.endIndex {
            let isSpace = text[idx].isWhitespace || text[idx].isNewline
            if !isSpace && tokenStart == nil {
                tokenStart = idx
            } else if isSpace, let start = tokenStart {
                ranges.append(start..<idx)
                tokenStart = nil
            }
            idx = text.index(after: idx)
        }
        if let start = tokenStart {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }

    private static func detectAndDeskewIfNeeded(_ image: CGImage) throws -> CGImage? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        guard let angle = request.results?.first?.angle else { return nil }
        let absAngle = abs(angle)
        // Only correct subtle scan tilt between ~0.5° and ~15° so intentional portrait/landscape isn't spun
        guard absAngle >= 0.008 && absAngle <= 0.26 else { return nil }

        let w = image.width
        let h = image.height
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: CGFloat(w) * 0.5, y: CGFloat(h) * 0.5)
        ctx.rotate(by: -angle)
        ctx.translateBy(x: -CGFloat(w) * 0.5, y: -CGFloat(h) * 0.5)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func sanitizeBidiControls(_ text: String) -> String {
        let forbidden: Set<UInt32> = [
            0x200E, 0x200F, 0x061C,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069
        ]
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars where !forbidden.contains(scalar.value) {
            out.append(scalar)
        }
        return String(out)
    }
}

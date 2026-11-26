import Foundation
import Testing
import AppKit
import CoreGraphics
import CoreText
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@Suite("Phase 34 — PDF Toolbox Pro Tests")
struct Phase34Tests {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase34-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeVectorPDF(at url: URL, pages: [String], size: CGSize = CGSize(width: 612, height: 792), title: String? = nil, author: String? = nil) throws {
        var box = CGRect(origin: .zero, size: size)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title as CFString }
        if let author { info[kCGPDFContextAuthor] = author as CFString }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info.isEmpty ? nil : (info as CFDictionary)) else {
            throw ConversionError.engineExecutionFailed("Could not allocate vector PDF context", underlyingError: nil)
        }
        for pageText in pages {
            var pBox = box
            let pData = Data(bytes: &pBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: pData] as CFDictionary)
            ctx.setFillColor(.white)
            ctx.fill(box)

            let attr = NSAttributedString(
                string: pageText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 22),
                    .foregroundColor: NSColor.black
                ]
            )
            let setter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 60, y: 120, width: size.width - 120, height: size.height - 180))
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func makeRasterScannedPDF(at url: URL, linesPerPage: [[String]], pageSize: CGSize = CGSize(width: 612, height: 792)) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let pdfCtx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.engineExecutionFailed("Could not allocate scanned PDF context", underlyingError: nil)
        }
        let scale: CGFloat = 2.5
        let pxW = Int(pageSize.width * scale)
        let pxH = Int(pageSize.height * scale)

        for lines in linesPerPage {
            guard let bmp = CGContext(
                data: nil,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                throw ConversionError.engineExecutionFailed("Could not allocate bitmap context", underlyingError: nil)
            }
            bmp.setFillColor(.white)
            bmp.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
            bmp.saveGState()
            bmp.scaleBy(x: scale, y: scale)

            let text = lines.joined(separator: "\n\n")
            let attr = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                    .foregroundColor: NSColor.black
                ]
            )
            let setter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 50, y: 100, width: pageSize.width - 100, height: pageSize.height - 160))
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, bmp)
            bmp.restoreGState()

            guard let cgImage = bmp.makeImage() else { continue }
            var pBox = box
            let pData = Data(bytes: &pBox, count: MemoryLayout<CGRect>.size) as CFData
            pdfCtx.beginPDFPage([kCGPDFContextMediaBox: pData] as CFDictionary)
            pdfCtx.draw(cgImage, in: box)
            pdfCtx.endPDFPage()
        }
        pdfCtx.closePDF()
    }

    // MARK: - 1. OCR & Searchable PDF

    @Test("OCR turns pure raster PDF into genuinely searchable PDF + sidecar TXT")
    func ocrScannedPDFProducesSearchableTextAndSidecar() async throws {
        let dir = try makeTempDir("ocr-basic")
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputURL = dir.appendingPathComponent("scan.pdf")
        let outputURL = dir.appendingPathComponent("scan_ocr.pdf")
        let sidecarURL = dir.appendingPathComponent("scan_ocr.txt")

        try makeRasterScannedPDF(at: inputURL, linesPerPage: [
            ["INVOICE NUMBER 94821", "LOCALCONVERT DOCUMENT ARCHIVE"],
            ["SECOND PAGE CONFIDENTIAL RECORD", "AMOUNT DUE 1250 USD"]
        ])

        // Confirm baseline raster PDF has NO searchable text
        let preDoc = try #require(PDFDocument(url: inputURL))
        #expect(preDoc.pageCount == 2)
        #expect((preDoc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        var options = PDFOCROptions()
        options.languageCodes = ["en-US"]
        options.recognitionLevel = .accurate
        options.usesLanguageCorrection = true
        options.exportExtractedTextSidecar = true

        let result = try await PDFOCRService.runOCR(
            inputURL: inputURL,
            outputPDFURL: outputURL,
            sidecarTextURL: sidecarURL,
            options: options
        ) { _ in }

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        #expect(result.processedPages == 2)
        #expect(result.skippedPages == 0)

        let postDoc = try #require(PDFDocument(url: outputURL))
        #expect(postDoc.pageCount == 2)
        let matches = postDoc.findString("INVOICE", withOptions: .caseInsensitive)
        #expect(!matches.isEmpty)
        let page2Matches = postDoc.findString("CONFIDENTIAL", withOptions: .caseInsensitive)
        #expect(!page2Matches.isEmpty)

        let sidecarText = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(sidecarText.localizedCaseInsensitiveContains("INVOICE"))
        #expect(sidecarText.localizedCaseInsensitiveContains("LOCALCONVERT"))
    }

    @Test("OCR skips already-searchable pages when configured and warns on unknown language")
    func ocrSkipExistingTextAndPageRanges() async throws {
        let dir = try makeTempDir("ocr-skip")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build mixed PDF: Page 1 is vector searchable, Page 2 is raster image
        let vectorURL = dir.appendingPathComponent("vec.pdf")
        let rasterURL = dir.appendingPathComponent("ras.pdf")
        let mixedURL = dir.appendingPathComponent("mixed.pdf")
        let outputURL = dir.appendingPathComponent("mixed_ocr.pdf")

        try makeVectorPDF(at: vectorURL, pages: ["This page already contains crisp native vector text for skipping."])
        try makeRasterScannedPDF(at: rasterURL, linesPerPage: [["RASTER PAGE TWO HELLO WORLD"]])

        let merged = PDFDocument()
        merged.insert(try #require(PDFDocument(url: vectorURL)?.page(at: 0)), at: 0)
        merged.insert(try #require(PDFDocument(url: rasterURL)?.page(at: 0)), at: 1)
        #expect(merged.write(to: mixedURL))

        var opts = PDFOCROptions()
        opts.languageCodes = ["en-US", "xx-INVALID"]
        opts.skipExistingTextPages = true
        opts.recognitionLevel = .accurate

        let res = try await PDFOCRService.runOCR(
            inputURL: mixedURL,
            outputPDFURL: outputURL,
            sidecarTextURL: nil,
            options: opts
        ) { _ in }

        #expect(res.skippedPages == 1)
        #expect(res.processedPages == 1)
        #expect(res.warnings.contains(where: { $0.contains("xx-INVALID") }))
        #expect(!PDFOCRService.supportedLanguages(for: .accurate).isEmpty)

        let post = try #require(PDFDocument(url: outputURL))
        #expect(!post.findString("vector text", withOptions: .caseInsensitive).isEmpty)
        #expect(!post.findString("RASTER", withOptions: .caseInsensitive).isEmpty)
    }

    // MARK: - 2. PDF/A & Archiving

    @Test("PDF/A archival generation succeeds for 1b, 2b, 3b, 4 and rejects unsupported 2u")
    func pdfaArchivalConversionAndValidation() async throws {
        let dir = try makeTempDir("pdfa")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("source.pdf")
        try makeVectorPDF(at: srcURL, pages: ["LocalConvert Archival Test Document — Page 1"])

        // Plain CoreGraphics PDF is NOT PDF/A compliant
        let baselineReport = try PDFDocumentInspector.validatePDFA(url: srcURL, expectedProfile: .pdfa2b)
        #expect(!baselineReport.isCompliant)
        #expect(!baselineReport.failedRequirements.isEmpty)

        // Unsupported PDF/A-2u must cleanly reject
        #expect(PDFAProfile.pdfa2u.isGenerationSupported == false)
        await #expect(throws: ConversionError.self) {
            _ = try await PDFArchivalService.convertToPDFA(
                inputURL: srcURL,
                outputURL: dir.appendingPathComponent("fail_2u.pdf"),
                profile: .pdfa2u
            ) { _ in }
        }

        // Real bundled LibreOffice generation + validation for 1b, 2b, 3b, 4
        for profile in [PDFAProfile.pdfa1b, .pdfa2b, .pdfa3b, .pdfa4] {
            let outURL = dir.appendingPathComponent("archival_\(profile.libreOfficeVersionValue ?? 0).pdf")
            let conv = try await PDFArchivalService.convertToPDFA(
                inputURL: srcURL,
                outputURL: outURL,
                profile: profile
            ) { _ in }
            #expect(FileManager.default.fileExists(atPath: outURL.path))
            #expect(conv.validationReport.isCompliant, "Expected \(profile.rawValue) to pass validation: \(conv.validationReport.failedRequirements)")
        }
    }

    // MARK: - 3. Permanent Redaction

    @Test("Permanent redaction destroys text-layer and pixel data while keeping unrelated text searchable")
    func permanentRedactionZeroResidualVerification() async throws {
        let dir = try makeTempDir("redact")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("contract.pdf")
        let outURL = dir.appendingPathComponent("contract_redacted.pdf")

        try makeVectorPDF(
            at: srcURL,
            pages: [
                "Public Header Agreement\n\nSecret Codeword: TOP-SECRET-OMEGA-991\n\nPublic Footer Reference",
                "Page Two Entirely Redacted Content DO-NOT-LEAK"
            ],
            title: "Sensitive Contract",
            author: "Secret Author"
        )

        // Add an overlapping comment annotation over page 1
        let preDoc = try #require(PDFDocument(url: srcURL))
        let page0 = try #require(preDoc.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 60, y: 500, width: 250, height: 120), forType: .text, withProperties: nil)
        note.contents = "TOP-SECRET-OMEGA-991 annotation note"
        page0.addAnnotation(note)
        #expect(preDoc.write(to: srcURL))

        var options = PDFRedactionOptions()
        options.searchTerms = ["TOP-SECRET-OMEGA-991"]
        options.wholePageRanges = "2"
        options.removeMetadata = true
        options.cleanAnnotationsInRegions = true
        options.preserveUnrelatedTextSearchability = true
        options.renderDPI = 200.0

        let report = try await PDFRedactionService.redact(
            inputURL: srcURL,
            outputURL: outURL,
            options: options
        ) { _ in }

        #expect(report.isVerifiedClean)
        #expect(report.residualMatchesFound.isEmpty)
        #expect(report.redactedPageIndices.contains(0))
        #expect(report.redactedPageIndices.contains(1))

        // 1. Source PDF untouched
        let checkSrc = try #require(PDFDocument(url: srcURL))
        #expect(!checkSrc.findString("TOP-SECRET-OMEGA-991").isEmpty)

        // 2. Output PDF has ZERO matches via PDFKit text extraction or binary ASCII scan
        let checkOut = try #require(PDFDocument(url: outURL))
        #expect(checkOut.findString("TOP-SECRET-OMEGA-991", withOptions: .caseInsensitive).isEmpty)
        #expect(!(checkOut.string ?? "").contains("TOP-SECRET-OMEGA-991"))
        #expect(!(checkOut.string ?? "").contains("DO-NOT-LEAK"))

        let rawBytes = try Data(contentsOf: outURL)
        #expect(rawBytes.range(of: Data("TOP-SECRET-OMEGA-991".utf8)) == nil)
        #expect(rawBytes.range(of: Data("DO-NOT-LEAK".utf8)) == nil)

        // 3. Unrelated text on page 1 remains searchable
        #expect(!checkOut.findString("Public Header", withOptions: .caseInsensitive).isEmpty)

        // 4. Metadata was scrubbed
        let info = try PDFDocumentInspector.inspect(url: outURL)
        #expect((info.title ?? "").isEmpty)
        #expect((info.author ?? "").isEmpty)
    }

    // MARK: - 4. PDF Comparison

    @Test("PDF comparison detects identical documents, text deltas, visual pixel diffs, and page additions/removals")
    func pdfComparisonDiffsTextVisualAndPageCounts() async throws {
        let dir = try makeTempDir("compare")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfA = dir.appendingPathComponent("v1.pdf")
        let pdfB = dir.appendingPathComponent("v2.pdf")

        try makeVectorPDF(at: pdfA, pages: [
            "Section 1: Revenue\nTotal: 1000 USD\nStatus: Draft",
            "Section 2: Unchanged Page"
        ])
        try makeVectorPDF(at: pdfB, pages: [
            "Section 1: Revenue\nTotal: 2500 USD\nStatus: Final",
            "Section 2: Unchanged Page",
            "Section 3: Newly Appended Addendum"
        ])

        // Identical comparison
        let identicalReport = try await PDFComparisonService.compare(leftURL: pdfA, rightURL: pdfA, renderWidthPixels: 300)
        #expect(identicalReport.identicalPagesCount == 2)
        #expect(identicalReport.modifiedPagesCount == 0)
        #expect(identicalReport.addedPagesCount == 0)
        #expect(identicalReport.removedPagesCount == 0)

        // Modified + Added comparison
        let diffReport = try await PDFComparisonService.compare(leftURL: pdfA, rightURL: pdfB, renderWidthPixels: 360)
        #expect(diffReport.leftPageCount == 2)
        #expect(diffReport.rightPageCount == 3)
        #expect(diffReport.identicalPagesCount >= 1)
        #expect(diffReport.modifiedPagesCount >= 1)
        #expect(diffReport.addedPagesCount == 1)
        #expect(diffReport.totalAddedLines >= 1)
        #expect(diffReport.totalRemovedLines >= 1)

        let p1 = try #require(diffReport.pageDiffs.first(where: { $0.pageNumber == 1 }))
        #expect((p1.visualDifferenceRatio ?? 0) > 0.0)
        #expect(p1.visualDiffImageData != nil)
    }

    // MARK: - 5. Compression

    @Test("PDF compression profiles work cleanly with integrity validation and lossless vs lossy distinction")
    func pdfCompressionProfilesAndValidation() async throws {
        let dir = try makeTempDir("compress")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create high-res image-heavy PDF
        let heavyURL = dir.appendingPathComponent("heavy.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(heavyURL as CFURL, mediaBox: &box, nil) else {
            Issue.record("Failed CGContext creation")
            return
        }
        // Build noisy 1200x1200 bitmap so JPEG downsampling visibly shrinks it
        let w = 1200, h = 1200
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8((i * 17) % 251)
            pixels[i + 1] = UInt8((i * 31) % 241)
            pixels[i + 2] = UInt8((i * 47) % 233)
            pixels[i + 3] = 255
        }
        let img = pixels.withUnsafeMutableBytes { ptr -> CGImage? in
            let bmp = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return bmp?.makeImage()
        }
        var pBox = box
        let pData = Data(bytes: &pBox, count: MemoryLayout<CGRect>.size) as CFData
        ctx.beginPDFPage([kCGPDFContextMediaBox: pData] as CFDictionary)
        if let cg = img {
            ctx.draw(cg, in: box)
        }
        ctx.endPDFPage()
        ctx.closePDF()

        let origSize = try #require(FileManager.default.attributesOfItem(atPath: heavyURL.path)[.size] as? Int64)
        #expect(PDFCompressionService.estimateSizeRange(originalBytes: origSize, options: .forProfile(.smallFile)) != nil)

        // Lossless Maximum Quality
        let losslessOut = dir.appendingPathComponent("lossless.pdf")
        let losslessInfo = try await PDFCompressionService.compress(
            inputURL: heavyURL,
            outputURL: losslessOut,
            options: .forProfile(.maximumQuality)
        ) { _ in }
        #expect(!losslessInfo.wasLossyApplied)
        #expect(losslessInfo.validatedReadable)
        #expect(losslessInfo.pageCount == 1)

        // Small File (110 DPI JPEG 60%)
        let smallOut = dir.appendingPathComponent("small.pdf")
        let smallInfo = try await PDFCompressionService.compress(
            inputURL: heavyURL,
            outputURL: smallOut,
            options: .forProfile(.smallFile)
        ) { _ in }
        #expect(smallInfo.wasLossyApplied)
        #expect(smallInfo.validatedReadable)
        #expect(smallInfo.compressedBytes < origSize)

        // Corrupt input rejection
        let badURL = dir.appendingPathComponent("corrupt.pdf")
        try Data("NOT A PDF".utf8).write(to: badURL)
        await #expect(throws: ConversionError.self) {
            _ = try await PDFCompressionService.compress(
                inputURL: badURL,
                outputURL: dir.appendingPathComponent("bad_out.pdf"),
                options: .forProfile(.balanced)
            ) { _ in }
        }
    }

    // MARK: - 6. Forms (AcroForm + Flattening + XFA Detection)

    @Test("AcroForm inspect, edit, JSON round-trip, burn-in flatten, and XFA detection work end-to-end")
    func pdfFormsEditFlattenAndXFA() async throws {
        let dir = try makeTempDir("forms")
        defer { try? FileManager.default.removeItem(at: dir) }

        let formURL = dir.appendingPathComponent("form.pdf")
        try makeVectorPDF(at: formURL, pages: ["Registration Form"])

        let doc = try #require(PDFDocument(url: formURL))
        let page = try #require(doc.page(at: 0))

        let nameField = PDFAnnotation(bounds: CGRect(x: 60, y: 500, width: 240, height: 28), forType: .widget, withProperties: nil)
        nameField.widgetFieldType = .text
        nameField.fieldName = "ApplicantName"
        nameField.widgetStringValue = "Initial"

        let agreeBox = PDFAnnotation(bounds: CGRect(x: 60, y: 450, width: 22, height: 22), forType: .widget, withProperties: nil)
        agreeBox.widgetFieldType = .button
        agreeBox.widgetControlType = .checkBoxControl
        agreeBox.fieldName = "AcceptTerms"
        agreeBox.buttonWidgetState = .offState

        let tierChoice = PDFAnnotation(bounds: CGRect(x: 60, y: 400, width: 160, height: 26), forType: .widget, withProperties: nil)
        tierChoice.widgetFieldType = .choice
        tierChoice.fieldName = "PlanTier"
        tierChoice.choices = ["Standard", "Pro", "Enterprise"]
        tierChoice.widgetStringValue = "Standard"

        page.addAnnotation(nameField)
        page.addAnnotation(agreeBox)
        page.addAnnotation(tierChoice)
        #expect(doc.write(to: formURL))

        // Inspect
        let inspected = try PDFFormService.inspectForms(url: formURL)
        #expect(inspected.hasAcroForm)
        #expect(!inspected.hasXFA)
        #expect(inspected.fields.count == 3)

        // JSON export/import round-trip check
        let encoded = try JSONEncoder().encode(inspected.fields)
        var decoded = try JSONDecoder().decode([PDFFormFieldItem].self, from: encoded)
        for i in decoded.indices {
            if decoded[i].fieldName == "ApplicantName" { decoded[i].stringValue = "Ada Lovelace" }
            if decoded[i].fieldName == "AcceptTerms" { decoded[i].boolValue = true }
            if decoded[i].fieldName == "PlanTier" { decoded[i].stringValue = "Pro" }
        }

        // Save edited non-flattened form
        let editedURL = dir.appendingPathComponent("form_edited.pdf")
        let saveRes = try PDFFormService.applyAndSave(
            inputURL: formURL,
            outputURL: editedURL,
            editedFields: decoded,
            flatten: false
        )
        #expect(saveRes.updatedFieldCount == 3)
        #expect(!saveRes.flattened)

        let reinspect = try PDFFormService.inspectForms(url: editedURL)
        #expect(reinspect.fields.first(where: { $0.fieldName == "ApplicantName" })?.stringValue == "Ada Lovelace")
        #expect(reinspect.fields.first(where: { $0.fieldName == "AcceptTerms" })?.boolValue == true)
        #expect(reinspect.fields.first(where: { $0.fieldName == "PlanTier" })?.stringValue == "Pro")

        // Flatten form
        let flatURL = dir.appendingPathComponent("form_flattened.pdf")
        let flatRes = try PDFFormService.applyAndSave(
            inputURL: editedURL,
            outputURL: flatURL,
            editedFields: reinspect.fields,
            flatten: true
        )
        #expect(flatRes.flattened)
        let flatCheck = try PDFFormService.inspectForms(url: flatURL)
        #expect(flatCheck.fields.isEmpty)

        // Synthetic /XFA dictionary detection
        let xfaURL = dir.appendingPathComponent("synthetic_xfa.pdf")
        let xfaRaw = """
        %PDF-1.7
        1 0 obj
        << /Type /Catalog /Pages 2 0 R /AcroForm 4 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
        endobj
        4 0 obj
        << /XFA 5 0 R /Fields [] >>
        endobj
        5 0 obj
        << /Length 12 >>
        stream
        <xdp:xdp/>
        endstream
        endobj
        xref
        0 6
        0000000000 65535 f 
        0000000009 00000 n 
        0000000074 00000 n 
        0000000131 00000 n 
        0000000201 00000 n 
        0000000246 00000 n 
        trailer
        << /Size 6 /Root 1 0 R >>
        startxref
        311
        %%EOF
        """
        try Data(xfaRaw.utf8).write(to: xfaURL)
        let xfaInspect = try PDFFormService.inspectForms(url: xfaURL)
        #expect(xfaInspect.hasAcroForm)
        #expect(xfaInspect.hasXFA)
        #expect(xfaInspect.xfaNote != nil)
    }

    // MARK: - 7. Inspector & Security

    @Test("Inspector reads deep structure/signatures and Security encrypts, enforces permissions, and decrypts")
    func pdfInspectorAndSecurityRoundTrip() async throws {
        let dir = try makeTempDir("security")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("plain.pdf")
        try makeVectorPDF(at: srcURL, pages: ["Confidential Security Test Page"], title: "Audit Doc", author: "QA")

        // Add signature widget to verify signature inspection
        let sigDoc = try #require(PDFDocument(url: srcURL))
        let sigPage = try #require(sigDoc.page(at: 0))
        let sigWidget = PDFAnnotation(bounds: CGRect(x: 60, y: 120, width: 180, height: 48), forType: .widget, withProperties: nil)
        sigWidget.widgetFieldType = .signature
        sigWidget.fieldName = "ApprovalSig1"
        sigPage.addAnnotation(sigWidget)
        #expect(sigDoc.write(to: srcURL))

        let baseReport = try PDFDocumentInspector.inspect(url: srcURL)
        #expect(baseReport.pageCount == 1)
        #expect(baseReport.title == "Audit Doc")
        #expect(baseReport.hasDigitalSignatures)
        #expect(baseReport.signatureFieldNames.contains("ApprovalSig1"))
        #expect(!baseReport.isEncrypted)
        #expect(!baseReport.fonts.isEmpty)

        // Encrypt with strict passwords & disabled printing/copying
        let encURL = dir.appendingPathComponent("encrypted.pdf")
        var encOpts = PDFSecurityOptions()
        encOpts.mode = .encrypt
        encOpts.ownerPassword = "OwnerSecret!42"
        encOpts.userPassword = "UserOpen!42"
        encOpts.allowPrinting = false
        encOpts.allowHighQualityPrinting = false
        encOpts.allowCopying = false

        let encRes = try PDFSecurityService.applySecurity(inputURL: srcURL, outputURL: encURL, options: encOpts)
        #expect(encRes.isEncrypted)
        #expect(encRes.signaturesInvalidated)

        // Wrong / missing password must fail inspection
        #expect(throws: ConversionError.self) {
            _ = try PDFDocumentInspector.inspect(url: encURL, password: "wrong")
        }

        // User password unlocks viewing while enforcing owner restrictions
        let encUserReport = try PDFDocumentInspector.inspect(url: encURL, password: "UserOpen!42")
        #expect(encUserReport.isEncrypted)
        #expect(!encUserReport.allowsPrinting)
        #expect(!encUserReport.allowsCopying)

        // User password alone cannot strip owner restrictions
        var userDecryptFail = PDFSecurityOptions()
        userDecryptFail.mode = .decrypt
        userDecryptFail.currentPassword = "UserOpen!42"
        #expect(throws: ConversionError.self) {
            _ = try PDFSecurityService.applySecurity(
                inputURL: encURL,
                outputURL: dir.appendingPathComponent("should_fail.pdf"),
                options: userDecryptFail
            )
        }

        // Owner password decrypts back cleanly
        let decURL = dir.appendingPathComponent("decrypted.pdf")
        var decOpts = PDFSecurityOptions()
        decOpts.mode = .decrypt
        decOpts.currentPassword = "OwnerSecret!42"

        let decRes = try PDFSecurityService.applySecurity(inputURL: encURL, outputURL: decURL, options: decOpts)
        #expect(!decRes.isEncrypted)
        let decReport = try PDFDocumentInspector.inspect(url: decURL)
        #expect(!decReport.isEncrypted)
    }
}

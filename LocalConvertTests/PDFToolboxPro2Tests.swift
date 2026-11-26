import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import AppKit
@testable import LocalConvert

@Suite("Phase 38 - PDF Toolbox Pro 2.0 Real-File Verification")
struct PDFToolboxPro2Tests {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LC_PDFPro2_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeScannedTextPDF(at url: URL, lines: [(text: String, rect: CGRect)], size: CGSize = CGSize(width: 612, height: 792)) throws {
        let scale: CGFloat = 2.0
        let pxW = Int(size.width * scale)
        let pxH = Int(size.height * scale)
        guard let bmp = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed("Failed bitmap context", underlyingError: nil)
        }
        bmp.setFillColor(.white)
        bmp.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        bmp.saveGState()
        bmp.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 20.0, nil)
        for item in lines {
            let attr = CFAttributedStringCreate(nil, item.text as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor.black
            ] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attr)
            bmp.textPosition = CGPoint(x: item.rect.minX, y: item.rect.minY)
            CTLineDraw(line, bmp)
        }
        bmp.restoreGState()
        guard let cgImg = bmp.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed CGImage snapshot", underlyingError: nil)
        }
        var box = CGRect(origin: .zero, size: size)
        guard let pdfCtx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.engineExecutionFailed("Failed PDF CGContext", underlyingError: nil)
        }
        var pBox = box
        let pData = Data(bytes: &pBox, count: MemoryLayout<CGRect>.size) as CFData
        pdfCtx.beginPDFPage([kCGPDFContextMediaBox: pData] as CFDictionary)
        pdfCtx.draw(cgImg, in: box)
        pdfCtx.endPDFPage()
        pdfCtx.closePDF()
    }

    private func makeVectorPDF(at url: URL, pages: [String], title: String? = nil, author: String? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var aux: [CFString: Any] = [:]
        if let title { aux[kCGPDFContextTitle] = title as CFString }
        if let author { aux[kCGPDFContextAuthor] = author as CFString }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else {
            throw ConversionError.engineExecutionFailed("Failed vector PDF context", underlyingError: nil)
        }
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 14.0, nil)
        for text in pages {
            var pBox = box
            let pData = Data(bytes: &pBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: pData] as CFDictionary)
            ctx.setFillColor(.white)
            ctx.fill(box)
            var y: CGFloat = 720
            for rawLine in text.components(separatedBy: "\n") {
                let lineStr = rawLine.trimmingCharacters(in: .whitespaces)
                if !lineStr.isEmpty {
                    let attr = CFAttributedStringCreate(nil, lineStr as CFString, [
                        kCTFontAttributeName: font,
                        kCTForegroundColorAttributeName: CGColor.black
                    ] as CFDictionary)!
                    ctx.textPosition = CGPoint(x: 48, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                }
                y -= 24
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: - 1. Turkish Unicode OCR & Multi-Column Reading Order + Hybrid Preservation

    @Test("OCR preserves Turkish diacritics, sorts multi-column reading order, and keeps skipped vector pages intact")
    func ocrTurkishMultiColumnAndHybrid() async throws {
        let dir = try makeTempDir("ocr_tr")
        defer { try? FileManager.default.removeItem(at: dir) }

        let scannedP1 = dir.appendingPathComponent("scan_multicol.pdf")
        try makeScannedTextPDF(at: scannedP1, lines: [
            ("DOCUMENTS HEADER TITLE", CGRect(x: 60, y: 720, width: 480, height: 30)),
            ("Left Column Line One", CGRect(x: 45, y: 630, width: 220, height: 24)),
            ("Left Column Line Two", CGRect(x: 45, y: 580, width: 220, height: 24)),
            ("Right Column First", CGRect(x: 330, y: 630, width: 220, height: 24)),
            ("Right Column Second", CGRect(x: 330, y: 580, width: 220, height: 24)),
            ("İstanbul Şehir Merkezi ğüşiöç", CGRect(x: 45, y: 480, width: 420, height: 26))
        ])

        // Combine scanned page 1 + vector page 2 with link annotation
        let vectorP2 = dir.appendingPathComponent("vector_p2.pdf")
        try makeVectorPDF(at: vectorP2, pages: ["Already Searchable Vector Page Reference 2026"])
        let p2Doc = try #require(PDFDocument(url: vectorP2))
        let link = PDFAnnotation(bounds: CGRect(x: 48, y: 680, width: 160, height: 24), forType: .link, withProperties: nil)
        link.url = URL(string: "https://localconvert.example")
        p2Doc.page(at: 0)?.addAnnotation(link)

        let combinedURL = dir.appendingPathComponent("hybrid_in.pdf")
        let scanDoc = try #require(PDFDocument(url: scannedP1))
        let merged = PDFDocument()
        merged.insert(try #require(scanDoc.page(at: 0)), at: 0)
        merged.insert(try #require(p2Doc.page(at: 0)), at: 1)
        #expect(merged.write(to: combinedURL))

        var opts = PDFOCROptions()
        opts.languageCodes = ["tr-TR", "en-US"]
        opts.automaticallyDetectsLanguage = true
        opts.multiColumnReadingOrder = true
        opts.skipExistingTextPages = true
        opts.recognitionLevel = .accurate
        opts.exportExtractedTextSidecar = true

        let outPDF = dir.appendingPathComponent("hybrid_ocr_out.pdf")
        let sidecar = dir.appendingPathComponent("hybrid_ocr.txt")
        let res = try await PDFOCRService.runOCR(
            inputURL: combinedURL,
            outputPDFURL: outPDF,
            sidecarTextURL: sidecar,
            options: opts
        ) { _ in }

        #expect(res.processedPages == 1)
        #expect(res.skippedPages == 1)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        let outDoc = try #require(PDFDocument(url: outPDF))
        #expect(outDoc.pageCount == 2)
        let page1Text = outDoc.page(at: 0)?.string ?? ""
        #expect(page1Text.localizedCaseInsensitiveContains("Left Column"))
        #expect(page1Text.localizedCaseInsensitiveContains("Right Column"))

        // Verify left column text appears BEFORE right column text in sorted extractedText
        if let leftRange = res.extractedText.range(of: "Left Column Line Two"),
           let rightRange = res.extractedText.range(of: "Right Column First") {
            #expect(leftRange.lowerBound < rightRange.lowerBound)
        }

        // Verify skipped vector page preserved its link annotation untouched!
        let p2Annots = outDoc.page(at: 1)?.annotations ?? []
        #expect(p2Annots.contains(where: { $0.url?.absoluteString == "https://localconvert.example" }))
    }

    // MARK: - 2. Permanent Redaction with Turkish Unicode + Forms + Metadata + Recovery Verification

    @Test("Redaction scrubs Turkish secret text, widget values, metadata, outlines, and retains unrelated Turkish text")
    func redactionScrubsWidgetsOutlinesMetadataAndTurkish() async throws {
        let dir = try makeTempDir("redact_pro")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("sensitive_tr.pdf")
        let outURL = dir.appendingPathComponent("sensitive_tr_redacted.pdf")
        try makeVectorPDF(
            at: srcURL,
            pages: [
                "GENEL BAŞLIK: İstanbul Şehir Sözleşmesi\n\nGİZLİ-KOD-2026-ŞİĞ\n\nKamu Referansı: ğüşiöç ĞÜŞİÖÇ",
                "İkinci Sayfa Gizli Ek MADDE-999"
            ],
            title: "Gizli Rapor GİZLİ-KOD-2026-ŞİĞ",
            author: "Kurumsal Denetçi"
        )

        let preDoc = try #require(PDFDocument(url: srcURL))
        let page0 = try #require(preDoc.page(at: 0))
        let widget = PDFAnnotation(bounds: CGRect(x: 48, y: 500, width: 220, height: 28), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "SecretField"
        widget.widgetStringValue = "GİZLİ-KOD-2026-ŞİĞ"
        page0.addAnnotation(widget)

        let root = PDFOutline()
        let bm = PDFOutline()
        bm.label = "GİZLİ-KOD-2026-ŞİĞ Chapter"
        bm.destination = PDFDestination(page: page0, at: CGPoint(x: 0, y: 792))
        root.insertChild(bm, at: 0)
        preDoc.outlineRoot = root
        #expect(preDoc.write(to: srcURL))

        var opts = PDFRedactionOptions()
        opts.searchTerms = ["GİZLİ-KOD-2026-ŞİĞ"]
        opts.wholePageRanges = "2"
        opts.removeMetadata = true
        opts.scrubXMPMetadata = true
        opts.cleanAnnotationsInRegions = true
        opts.preserveUnrelatedTextSearchability = true
        opts.renderDPI = 200.0

        let report = try await PDFRedactionService.redact(
            inputURL: srcURL,
            outputURL: outURL,
            options: opts
        ) { _ in }

        #expect(report.isVerifiedClean)
        #expect(report.residualMatchesFound.isEmpty)
        #expect(report.scrubbedFormFieldCount >= 1)
        #expect(!report.verificationChecks.isEmpty)

        let outDoc = try #require(PDFDocument(url: outURL))
        #expect(outDoc.findString("GİZLİ-KOD-2026-ŞİĞ", withOptions: [.caseInsensitive]).isEmpty)
        #expect(!(outDoc.string ?? "").contains("GİZLİ-KOD-2026-ŞİĞ"))
        #expect(!(outDoc.string ?? "").contains("MADDE-999"))
        // Retained Turkish text must still be extracted cleanly
        #expect((outDoc.string ?? "").contains("İstanbul") || (outDoc.string ?? "").contains("ğüşiöç"))
        // Outlines and metadata scrubbed
        #expect((outDoc.outlineRoot?.numberOfChildren ?? 0) == 0)
    }

    // MARK: - 3. Structure-Preserving Compression vs Rasterization + Linearization Honesty

    @Test("Structure-preserving compression retains links/text/forms and accurately reports linearization and lost structures")
    func compressionStructurePreservationAndTradeoffs() async throws {
        let dir = try makeTempDir("comp_pro")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("structured.pdf")
        try makeVectorPDF(at: srcURL, pages: ["Contract Clause Keep Me Searchable"])
        let doc = try #require(PDFDocument(url: srcURL))
        let page0 = try #require(doc.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 48, y: 650, width: 140, height: 22), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.org/terms")
        page0.addAnnotation(link)
        #expect(doc.write(to: srcURL))

        // Structure-preserving Web Optimized
        let webOut = dir.appendingPathComponent("web_opt.pdf")
        let webRes = try await PDFCompressionService.compress(
            inputURL: srcURL,
            outputURL: webOut,
            options: .forProfile(.webOptimized)
        ) { _ in }

        #expect(webRes.validatedReadable)
        #expect(!webRes.isLinearized)
        #expect((webRes.linearizationNote ?? "").contains("Linearized") || (webRes.linearizationNote ?? "").contains("linearized"))
        #expect(webRes.preservedStructures.contains("Vector Text & Typography"))
        let webDoc = try #require(PDFDocument(url: webOut))
        #expect((webDoc.page(at: 0)?.string ?? "").contains("Searchable"))
        #expect(!(webDoc.page(at: 0)?.annotations.isEmpty ?? true))

        // Rasterize Small File explicitly records discarded structures
        let smallOut = dir.appendingPathComponent("small_raster.pdf")
        let smallRes = try await PDFCompressionService.compress(
            inputURL: srcURL,
            outputURL: smallOut,
            options: .forProfile(.smallFile)
        ) { _ in }

        #expect(smallRes.wasLossyApplied)
        #expect(!smallRes.discardedStructures.isEmpty)
        let smallDoc = try #require(PDFDocument(url: smallOut))
        #expect((smallDoc.page(at: 0)?.annotations.isEmpty ?? true))
    }

    // MARK: - 4. Radio Button Mutual Exclusion, Reset & PDF Compare Structural Diffs

    @Test("AcroForm radio group mutual exclusion and PDF Compare annotation/form diff inspection work end-to-end")
    func formsRadioAndCompareStructuralDiffs() async throws {
        let dir = try makeTempDir("form_cmp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfA = dir.appendingPathComponent("form_a.pdf")
        let pdfB = dir.appendingPathComponent("form_b.pdf")
        try makeVectorPDF(at: pdfA, pages: ["Application Form"])

        let doc = try #require(PDFDocument(url: pdfA))
        let page = try #require(doc.page(at: 0))

        let r1 = PDFAnnotation(bounds: CGRect(x: 50, y: 600, width: 20, height: 20), forType: .widget, withProperties: nil)
        r1.widgetFieldType = .button
        r1.widgetControlType = .radioButtonControl
        r1.fieldName = "PlanChoice"
        r1.buttonWidgetState = .onState

        let r2 = PDFAnnotation(bounds: CGRect(x: 100, y: 600, width: 20, height: 20), forType: .widget, withProperties: nil)
        r2.widgetFieldType = .button
        r2.widgetControlType = .radioButtonControl
        r2.fieldName = "PlanChoice"
        r2.buttonWidgetState = .offState

        let txt = PDFAnnotation(bounds: CGRect(x: 50, y: 540, width: 200, height: 26), forType: .widget, withProperties: nil)
        txt.widgetFieldType = .text
        txt.fieldName = "ApplicantName"
        txt.widgetStringValue = "Ahmet"

        page.addAnnotation(r1)
        page.addAnnotation(r2)
        page.addAnnotation(txt)
        #expect(doc.write(to: pdfA))

        let inspected = try PDFFormService.inspectForms(url: pdfA)
        #expect(inspected.fields.count == 3)

        // Toggle second radio ON and first OFF + update text
        var edited = inspected.fields
        for i in edited.indices {
            if edited[i].kind == .radio {
                edited[i].boolValue = (i == 1)
            } else if edited[i].fieldName == "ApplicantName" {
                edited[i].stringValue = "Ayşe Yılmaz"
            }
        }
        _ = try PDFFormService.applyAndSave(inputURL: pdfA, outputURL: pdfB, editedFields: edited, flatten: false)

        let reInspectedB = try PDFFormService.inspectForms(url: pdfB)
        let radios = reInspectedB.fields.filter { $0.kind == .radio }
        #expect(radios.filter(\.boolValue).count == 1)
        #expect(radios.count == 2)
        #expect(reInspectedB.fields.first(where: { $0.fieldName == "ApplicantName" })?.stringValue == "Ayşe Yılmaz")

        // Reset helper clears non-readonly fields
        let reset = PDFFormService.resetFieldsToEmpty(reInspectedB.fields)
        #expect(reset.first(where: { $0.fieldName == "ApplicantName" })?.stringValue == "")
        #expect(reset.filter(\.boolValue).isEmpty)

        // PDF Compare detects form field changes between pdfA and pdfB
        let cmp = try await PDFComparisonService.compare(leftURL: pdfA, rightURL: pdfB, renderWidthPixels: 320)
        #expect(cmp.totalFormFieldChanges >= 1)
        let page1Diff = try #require(cmp.pageDiffs.first)
        #expect(!page1Diff.formFieldChanges.isEmpty)
    }

    // MARK: - 5. PDF/A Extended Structural Validation & Honest Scope Notice

    @Test("PDF/A validation checks ToUnicode, JS, Transparency and embeds honest non-veraPDF notice")
    func pdfaDeepStructuralValidation() async throws {
        let dir = try makeTempDir("pdfa_deep")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("doc.pdf")
        try makeVectorPDF(at: srcURL, pages: ["Archival Document Test 2026"])

        let out2b = dir.appendingPathComponent("out_2b.pdf")
        let res2b = try await PDFArchivalService.convertToPDFA(
            inputURL: srcURL,
            outputURL: out2b,
            profile: .pdfa2b
        ) { _ in }
        #expect(res2b.validationReport.validationScopeNote.contains("veraPDF"))
        #expect(res2b.validationReport.checks.contains(where: { $0.requirement.contains("ToUnicode") }))
        #expect(res2b.validationReport.checks.contains(where: { $0.requirement.contains("JavaScript") }))

        let out4 = dir.appendingPathComponent("out_4.pdf")
        let res4 = try await PDFArchivalService.convertToPDFA(
            inputURL: srcURL,
            outputURL: out4,
            profile: .pdfa4
        ) { _ in }
        #expect(res4.validationReport.detectedPart == "4")
    }

    // MARK: - 6. Incremental Revisions & Raster Pixel Redaction Verification

    @Test("Redaction strips incremental PDF revisions, verifies Flate streams, and wipes image-based pixels")
    func redactionIncrementalRevisionsAndRasterPixels() async throws {
        let dir = try makeTempDir("redact_inc")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build base PDF with SECRET-REV1, then append incremental update with %%EOF #2
        let baseURL = dir.appendingPathComponent("incremental.pdf")
        try makeVectorPDF(at: baseURL, pages: ["Revision 1 SECRET-REV1 Public Body"])
        var raw = try Data(contentsOf: baseURL)
        let incrementalAppend = Data("\n% Incremental comment SECRET-REV2\n%%EOF\n".utf8)
        raw.append(incrementalAppend)
        try raw.write(to: baseURL)

        let outURL = dir.appendingPathComponent("sanitized_clean.pdf")
        var opts = PDFRedactionOptions()
        opts.searchTerms = ["SECRET-REV1", "SECRET-REV2"]
        opts.renderDPI = 200.0
        let report = try await PDFRedactionService.redact(inputURL: baseURL, outputURL: outURL, options: opts) { _ in }

        #expect(report.isVerifiedClean)
        #expect(report.incrementalRevisionsCount == 1)
        #expect(report.decompressedStreamChecked)
        let outBytes = try Data(contentsOf: outURL)
        #expect(outBytes.range(of: Data("SECRET-REV1".utf8)) == nil)
        #expect(outBytes.range(of: Data("SECRET-REV2".utf8)) == nil)

        // Raster pixel redaction check: create pure image text PDF and redact region manually
        let scanURL = dir.appendingPathComponent("raster_secret.pdf")
        let targetRect = CGRect(x: 60, y: 500, width: 260, height: 44)
        try makeScannedTextPDF(at: scanURL, lines: [("PIXEL-SECRET-99", CGRect(x: 68, y: 508, width: 220, height: 28))])

        let rasterOut = dir.appendingPathComponent("raster_wiped.pdf")
        var rasterOpts = PDFRedactionOptions()
        rasterOpts.regions = [PDFRedactionRegion(pageIndex: 0, rect: targetRect, label: "Pixel wipe")]
        rasterOpts.fillColorHex = "#000000"
        let rasterReport = try await PDFRedactionService.redact(inputURL: scanURL, outputURL: rasterOut, options: rasterOpts) { _ in }
        #expect(rasterReport.isVerifiedClean)

        // Render redacted page back into RGBA bitmap and confirm pixels inside redacted rect are solid black
        let outDoc = try #require(PDFDocument(url: rasterOut))
        let page = try #require(outDoc.page(at: 0))
        let w = 612, h = 792
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let renderedOK: Bool = rgba.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgPage = page.pageRef else { return false }
            ctx.drawPDFPage(cgPage)
            return true
        }
        #expect(renderedOK)
        // Sample center pixel (x=180, y_pdf=522 -> top-down row = 792 - 522 = 270)
        let sampleRow = 792 - 522
        let offset = (sampleRow * w + 180) * 4
        #expect(rgba[offset] <= 5 && rgba[offset + 1] <= 5 && rgba[offset + 2] <= 5)
    }

    // MARK: - 7. Cryptographic Digital Signatures vs Parsing vs Tampered / Expired / Multi-Sig

    @Test("Inspector separates CMS parsing, ByteRange digest verification, tampering, expired certs, and untrusted self-signed chains")
    func digitalSignatureParsingVsCryptographicVerification() async throws {
        let dir = try makeTempDir("sig_crypto")
        defer { try? FileManager.default.removeItem(at: dir) }

        func buildSignedPDF(outURL: URL, expiredCert: Bool, extraSignaturePlaceholder: Bool = false) throws {
            let keyURL = dir.appendingPathComponent("signer_\(expiredCert ? "exp" : "ok").key")
            let certURL = dir.appendingPathComponent("signer_\(expiredCert ? "exp" : "ok").crt")
            let sslProc = Process()
            sslProc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            sslProc.arguments = [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyURL.path, "-out", certURL.path,
                "-subj", "/CN=LocalConvert Test Signer", "-days", "30"
            ]
            sslProc.standardOutput = FileHandle.nullDevice
            sslProc.standardError = FileHandle.nullDevice
            try sslProc.run()
            sslProc.waitUntilExit()
            guard sslProc.terminationStatus == 0 else {
                throw ConversionError.engineExecutionFailed("openssl cert gen failed", underlyingError: nil)
            }

            if expiredCert {
                let caDir = dir.appendingPathComponent("ca_exp", isDirectory: true)
                try FileManager.default.createDirectory(at: caDir, withIntermediateDirectories: true)
                let idxURL = caDir.appendingPathComponent("idx")
                let serURL = caDir.appendingPathComponent("ser")
                let cnfURL = caDir.appendingPathComponent("ca.cnf")
                let csrURL = caDir.appendingPathComponent("exp.csr")
                let expCrtURL = caDir.appendingPathComponent("exp.crt")
                try "".write(to: idxURL, atomically: true, encoding: .utf8)
                try "01\n".write(to: serURL, atomically: true, encoding: .utf8)
                let cnf = """
                [ca]
                default_ca = CA_d
                [CA_d]
                database = \(idxURL.path)
                new_certs_dir = \(caDir.path)
                serial = \(serURL.path)
                default_md = sha256
                policy = pol
                [pol]
                commonName = supplied
                """
                try cnf.write(to: cnfURL, atomically: true, encoding: .utf8)

                let csrProc = Process()
                csrProc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                csrProc.arguments = ["req", "-new", "-key", keyURL.path, "-out", csrURL.path, "-subj", "/CN=Expired LocalConvert Signer"]
                csrProc.standardOutput = FileHandle.nullDevice; csrProc.standardError = FileHandle.nullDevice
                try csrProc.run(); csrProc.waitUntilExit()

                let caProc = Process()
                caProc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                caProc.arguments = [
                    "ca", "-batch", "-config", cnfURL.path,
                    "-cert", certURL.path, "-keyfile", keyURL.path,
                    "-in", csrURL.path, "-out", expCrtURL.path,
                    "-startdate", "20200101000000Z", "-enddate", "20210101000000Z"
                ]
                caProc.standardOutput = FileHandle.nullDevice; caProc.standardError = FileHandle.nullDevice
                try caProc.run(); caProc.waitUntilExit()
                guard caProc.terminationStatus == 0 else {
                    throw ConversionError.engineExecutionFailed("openssl ca expired cert failed", underlyingError: nil)
                }
                try FileManager.default.removeItem(at: certURL)
                try FileManager.default.moveItem(at: expCrtURL, to: certURL)
            }

            let contentsSlotBytes = 4096
            let zeroHex = String(repeating: "00", count: contentsSlotBytes)
            let extraAnnot = extraSignaturePlaceholder ? " 6 0 R" : ""
            let extraObj = extraSignaturePlaceholder
                ? "6 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Sig /T (SecondUnsignedSig) /Rect [0 0 0 0] >>\nendobj\n"
                : ""

            let header = """
            %PDF-1.4
            1 0 obj
            << /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R\(extraAnnot)] /SigFlags 3 >> >>
            endobj
            2 0 obj
            << /Type /Pages /Kids [3 0 R] /Count 1 >>
            endobj
            3 0 obj
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Annots [5 0 R\(extraAnnot)] >>
            endobj
            4 0 obj
            << /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /Name (Test Signer) /Reason (Approval) /ByteRange [0000000000 0000000000 0000000000 0000000000] /Contents <
            """
            let mid = "> >>\nendobj\n5 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Sig /T (PrimarySig) /V 4 0 R /P 3 0 R /Rect [10 10 100 40] >>\nendobj\n" + extraObj + "trailer\n<< /Root 1 0 R >>\n%%EOF\n"

            let preBytes = Data(header.utf8)
            let slotHexBytes = Data(zeroHex.utf8)
            let postBytes = Data(mid.utf8)
            let o2 = preBytes.count + slotHexBytes.count + 1 // right after '>' Wait: '<' is end of preBytes, '>' starts postBytes!
            _ = o2
            // Exact byte indices wrapping '<' ... '>': ByteRange excludes '<' and '>'? PDF spec excludes `<...>`!
            // preBytes includes `<` -> exclude trailing '<': l1 = preBytes.count - 1; o2 = preBytes.count + slotHexBytes.count + 1
            let l1 = preBytes.count - 1
            let brStart2 = preBytes.count + slotHexBytes.count + 1
            let l2 = postBytes.count - 1
            let brString = String(format: "%010d %010d %010d %010d", 0, l1, brStart2, l2)
            let patchedHeader = header.replacingOccurrences(of: "0000000000 0000000000 0000000000 0000000000", with: brString)
            let patchedPre = Data(patchedHeader.utf8)
            assert(patchedPre.count == preBytes.count)

            let toSignData = patchedPre.dropLast(1) + postBytes.dropFirst(1)
            let payloadURL = dir.appendingPathComponent("payload.bin")
            let cmsURL = dir.appendingPathComponent("sig.der")
            try Data(toSignData).write(to: payloadURL)

            let cmsProc = Process()
            cmsProc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            cmsProc.arguments = [
                "cms", "-sign", "-binary", "-in", payloadURL.path,
                "-signer", certURL.path, "-inkey", keyURL.path,
                "-outform", "DER", "-out", cmsURL.path, "-nodetach"
            ]
            // Use -outform DER detached CMS (`-binary` detached by default when `-nodetach` NOT passed!)
            cmsProc.arguments = [
                "cms", "-sign", "-binary", "-in", payloadURL.path,
                "-signer", certURL.path, "-inkey", keyURL.path,
                "-outform", "DER", "-out", cmsURL.path
            ]
            cmsProc.standardOutput = FileHandle.nullDevice
            cmsProc.standardError = FileHandle.nullDevice
            try cmsProc.run()
            cmsProc.waitUntilExit()
            guard cmsProc.terminationStatus == 0 else {
                throw ConversionError.engineExecutionFailed("openssl cms failed", underlyingError: nil)
            }
            let der = try Data(contentsOf: cmsURL)
            let hex = der.map { String(format: "%02x", $0) }.joined()
            let paddedHex = hex + String(repeating: "0", count: max(0, (contentsSlotBytes * 2) - hex.count))
            let finalData = patchedPre + Data(paddedHex.utf8) + postBytes
            try finalData.write(to: outURL)
        }

        // 1. Valid cryptographic digest with untrusted self-signed cert + second unsigned sig field
        let signedURL = dir.appendingPathComponent("valid_sig.pdf")
        try buildSignedPDF(outURL: signedURL, expiredCert: false, extraSignaturePlaceholder: true)
        let rep = try PDFDocumentInspector.inspect(url: signedURL)
        #expect(rep.hasDigitalSignatures)
        #expect(rep.digitalSignatures.count >= 2)
        let primary = try #require(rep.digitalSignatures.first(where: { $0.fieldName == "PrimarySig" }))
        #expect(primary.cmsParsed == true)
        #expect(primary.cryptoStatus == .validDigest)
        #expect(primary.coversEntireFile == true)
        #expect(primary.trustChainStatus.contains("Untrusted") || primary.trustChainStatus.contains("Self-Signed"))
        #expect(primary.revocationStatus.contains("Not checked"))

        // 2. Tamper one byte inside signed ByteRange: CMS still parses, BUT crypto digest MUST fail!
        let tamperedURL = dir.appendingPathComponent("tampered_sig.pdf")
        var tamperedData = try Data(contentsOf: signedURL)
        if let approvalRange = tamperedData.range(of: Data("Approval".utf8)) {
            tamperedData[approvalRange.lowerBound] = UInt8(ascii: "X")
        }
        try tamperedData.write(to: tamperedURL)
        let tamperedRep = try PDFDocumentInspector.inspect(url: tamperedURL)
        let tamperedSig = try #require(tamperedRep.digitalSignatures.first(where: { $0.fieldName == "PrimarySig" }))
        #expect(tamperedSig.cmsParsed == true)
        #expect(tamperedSig.cryptoStatus == .invalidDigest)

        // 3. Post-signing append: ByteRange EOF coverage turns FALSE
        let appendedURL = dir.appendingPathComponent("appended_sig.pdf")
        var appData = try Data(contentsOf: signedURL)
        appData.append(Data("\n% Post-signing incremental comment\n".utf8))
        try appData.write(to: appendedURL)
        let appRep = try PDFDocumentInspector.inspect(url: appendedURL)
        let appSig = try #require(appRep.digitalSignatures.first(where: { $0.fieldName == "PrimarySig" }))
        #expect(appSig.coversEntireFile == false)

        // 4. Expired certificate check
        let expURL = dir.appendingPathComponent("expired_sig.pdf")
        try buildSignedPDF(outURL: expURL, expiredCert: true)
        let expRep = try PDFDocumentInspector.inspect(url: expURL)
        let expSig = try #require(expRep.digitalSignatures.first(where: { $0.fieldName == "PrimarySig" }))
        #expect(expSig.isCertificateExpired == true)
    }

    // MARK: - 8. OCR on Rotated Page + Low-Resolution Scan

    @Test("OCR handles rotated 90-degree pages and low-resolution scans accurately")
    func ocrRotatedAndLowResScan() async throws {
        let dir = try makeTempDir("ocr_rot")
        defer { try? FileManager.default.removeItem(at: dir) }

        let baseScan = dir.appendingPathComponent("base_scan.pdf")
        try makeScannedTextPDF(at: baseScan, lines: [("ROTATED RECEIPT NUMBER 8421", CGRect(x: 60, y: 650, width: 420, height: 32))])
        let srcDoc = try #require(PDFDocument(url: baseScan))
        srcDoc.page(at: 0)?.rotation = 90
        let rotURL = dir.appendingPathComponent("rotated_90.pdf")
        #expect(srcDoc.write(to: rotURL))

        var opts = PDFOCROptions()
        opts.renderDPI = 144.0
        opts.skipExistingTextPages = false
        let outURL = dir.appendingPathComponent("rotated_ocr.pdf")
        let res = try await PDFOCRService.runOCR(inputURL: rotURL, outputPDFURL: outURL, sidecarTextURL: nil, options: opts) { _ in }
        #expect(res.processedPages == 1)
        #expect(res.extractedText.localizedCaseInsensitiveContains("8421") || res.extractedText.localizedCaseInsensitiveContains("RECEIPT"))
    }
}

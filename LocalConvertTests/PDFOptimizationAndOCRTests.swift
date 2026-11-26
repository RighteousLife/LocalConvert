import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
@testable import LocalConvert

@Suite("Phase 44.3 & 44.4 — PDF Optimization & OCR", .serialized)
struct PDFOptimizationAndOCRTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P44_OptOCR_\(name)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePhotoAndTextPDF(at url: URL) throws {
        // High-entropy raster image + crisp vector text + outline + link annotation + metadata
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let aux: [CFString: Any] = [
            kCGPDFContextTitle: "Confidential Draft Report" as CFString,
            kCGPDFContextAuthor: "Secret Author" as CFString
        ]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else {
            throw ConversionError.engineExecutionFailed("Failed PDF context", underlyingError: nil)
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(.white)
        ctx.fill(box)

        // Generate 1600x1600 noisy image with deterministic LCG PRNG so Flate is huge while JPEG shrinks dramatically
        let w = 1600, h = 1600
        if let bmp = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let ptr = bmp.data {
            let p = ptr.bindMemory(to: UInt8.self, capacity: w * h * 4)
            var state: UInt32 = 0x12345678
            for i in 0..<(w * h) {
                state = state &* 1664525 &+ 1013904223
                p[i * 4] = UInt8((state >> 24) & 0xFF)
                p[i * 4 + 1] = UInt8((state >> 16) & 0xFF)
                p[i * 4 + 2] = UInt8((state >> 8) & 0xFF)
                p[i * 4 + 3] = 255
            }
            if let img = bmp.makeImage() {
                ctx.draw(img, in: CGRect(x: 72, y: 120, width: 420, height: 420))
            }
        }

        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, "VECTOR_HEADLINE_PRESERVED" as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor.black
            ] as CFDictionary)!
        )
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw ConversionError.invalidInput("Reload failed")
        }
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 695, width: 220, height: 26), forType: .link, withProperties: nil)
        link.url = URL(string: "https://localconvert.invalid/test")
        let fresh = PDFDocument()
        fresh.insert(page.copy() as! PDFPage, at: 0)
        fresh.page(at: 0)?.addAnnotation(link)
        fresh.documentAttributes = doc.documentAttributes
        let root = PDFOutline()
        let bm = PDFOutline()
        bm.label = "Chapter 1"
        bm.destination = PDFDestination(page: fresh.page(at: 0)!, at: CGPoint(x: 0, y: 792))
        root.insertChild(bm, at: 0)
        fresh.outlineRoot = root
        fresh.write(to: url)
    }

    @Test("44.3 Optimization tiers: Quartz preserves vectors/outlines/links, Rasterize shrinks & grayscale works, Metadata strip verifies cleanup")
    func multiTierOptimizationAndMetadataVerification() async throws {
        let dir = try makeTempDir("OptTiers")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputURL = dir.appendingPathComponent("heavy_photo.pdf")
        try makePhotoAndTextPDF(at: inputURL)
        let origSize = try #require(FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64)

        // 1. Quartz Vector-Preserving Optimization (Balanced) + Metadata Strip
        let quartzOut = dir.appendingPathComponent("quartz_opt.pdf")
        var quartzOpts = PDFCompressionOptions.forProfile(.balanced)
        quartzOpts.targetDPI = 96
        quartzOpts.imageQuality = 0.55
        quartzOpts.stripMetadata = true
        let qRes = try await PDFCompressionService.compress(inputURL: inputURL, outputURL: quartzOut, options: quartzOpts) { _ in }

        #expect(qRes.validatedReadable)
        #expect(qRes.wasLossyApplied)
        #expect(qRes.compressedBytes < origSize)
        #expect(qRes.preservedStructures.contains("Vector Text & Typography"))
        #expect(qRes.preservedStructures.contains("Bookmarks / Outlines"))
        #expect(qRes.fontNote?.contains("subsetting") == true)
        #expect(qRes.metadataStrippedVerified == true)

        let qDoc = try #require(PDFDocument(url: quartzOut))
        #expect((qDoc.page(at: 0)?.string ?? "").contains("VECTOR_HEADLINE_PRESERVED"))
        #expect((qDoc.outlineRoot?.numberOfChildren ?? 0) == 1)
        let qLinks = qDoc.page(at: 0)?.annotations.filter { ($0.type ?? "").contains("Link") } ?? []
        #expect(qLinks.count == 1)
        let qAuthor = qDoc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        #expect(qAuthor == nil || qAuthor?.isEmpty == true)

        // 2. Grayscale Explicit Rasterization Tier
        let grayOut = dir.appendingPathComponent("gray_raster.pdf")
        let grayOpts = PDFCompressionOptions(
            profile: .custom,
            strategy: .rasterizePages,
            targetDPI: 96,
            imageQuality: 0.50,
            imageCodec: .jpeg,
            stripMetadata: true,
            grayscale: true
        )
        let gRes = try await PDFCompressionService.compress(inputURL: inputURL, outputURL: grayOut, options: grayOpts) { _ in }
        #expect(gRes.validatedReadable)
        #expect(gRes.compressedBytes < origSize)
        #expect(!gRes.discardedStructures.isEmpty)
        #expect(gRes.tradeOffNote.contains("Grayscale"))

        // 3. Lossless Cleanup preserves vectors, outlines, and has wasLossyApplied == false
        let losslessOut = dir.appendingPathComponent("lossless_cleanup.pdf")
        let losslessRes = try await PDFCompressionService.compress(
            inputURL: inputURL,
            outputURL: losslessOut,
            options: .forProfile(.maximumQuality)
        ) { _ in }
        #expect(!losslessRes.wasLossyApplied)
        #expect(losslessRes.preservedStructures.contains("Bookmarks / Outlines"))
    }

    private func makeRasterScannedPDF(
        at url: URL,
        pages: [(text: String, tiltRadians: CGFloat)],
        bookmarks: [(title: String, pageIndex: Int)] = []
    ) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdfCtx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.engineExecutionFailed("Failed PDF ctx", underlyingError: nil)
        }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 26, nil)

        for entry in pages {
            let pxW = 1224, pxH = 1584
            guard let bmp = CGContext(
                data: nil,
                width: pxW,
                height: pxH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            bmp.setFillColor(.white)
            bmp.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
            bmp.saveGState()
            bmp.scaleBy(x: 2.0, y: 2.0)
            if abs(entry.tiltRadians) > 0.001 {
                bmp.translateBy(x: 306, y: 396)
                bmp.rotate(by: entry.tiltRadians)
                bmp.translateBy(x: -306, y: -396)
            }
            // Add horizon baseline rule for horizon detection
            bmp.setStrokeColor(CGColor.black)
            bmp.setLineWidth(2.0)
            bmp.move(to: CGPoint(x: 60, y: 580))
            bmp.addLine(to: CGPoint(x: 540, y: 580))
            bmp.strokePath()

            let attr = CFAttributedStringCreate(nil, entry.text as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor.black
            ] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attr)
            bmp.textPosition = CGPoint(x: 72, y: 620)
            CTLineDraw(line, bmp)
            bmp.restoreGState()

            if let img = bmp.makeImage() {
                pdfCtx.beginPDFPage(nil)
                pdfCtx.draw(img, in: box)
                pdfCtx.endPDFPage()
            }
        }
        pdfCtx.closePDF()

        if !bookmarks.isEmpty, let doc = PDFDocument(url: url) {
            let fresh = PDFDocument()
            for idx in 0..<doc.pageCount {
                if let copy = doc.page(at: idx)?.copy() as? PDFPage {
                    fresh.insert(copy, at: idx)
                }
            }
            let root = PDFOutline()
            for (bIdx, bm) in bookmarks.enumerated() {
                if let p = fresh.page(at: bm.pageIndex) {
                    let node = PDFOutline()
                    node.label = bm.title
                    node.destination = PDFDestination(page: p, at: CGPoint(x: 0, y: 792))
                    root.insertChild(node, at: bIdx)
                }
            }
            fresh.outlineRoot = root
            fresh.write(to: url)
        }
    }

    @Test("44.4 OCR word-level search, Unicode fallback, outline preservation, tilted deskew, and cancellation")
    func ocrWordBoundsUnicodeOutlinesDeskewAndCancellation() async throws {
        let dir = try makeTempDir("OCRSuite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let scanURL = dir.appendingPathComponent("scan_tilted.pdf")
        try makeRasterScannedPDF(
            at: scanURL,
            pages: [
                (text: "Quarterly Financial Invoice Approved", tiltRadians: 0.0),
                (text: "Türkiye İstanbul Şirket Özeti", tiltRadians: 0.09)
            ],
            bookmarks: [
                (title: "Invoice Page", pageIndex: 0),
                (title: "Turkish Summary", pageIndex: 1)
            ]
        )

        let outPDF = dir.appendingPathComponent("searchable.pdf")
        let sidecar = dir.appendingPathComponent("searchable.txt")
        let ocrOpts = PDFOCROptions(
            languageCodes: ["en-US", "tr-TR"],
            automaticallyDetectsLanguage: true,
            multiColumnReadingOrder: true,
            recognitionLevel: .accurate,
            usesLanguageCorrection: true,
            deskewPages: true,
            pageRanges: "",
            skipExistingTextPages: false,
            renderDPI: 200.0,
            exportExtractedTextSidecar: true,
            password: nil
        )

        let res = try await PDFOCRService.runOCR(
            inputURL: scanURL,
            outputPDFURL: outPDF,
            sidecarTextURL: sidecar,
            options: ocrOpts
        ) { _ in }

        #expect(res.processedPages == 2)
        #expect(res.sidecarTextURL == sidecar)
        let txt = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(!txt.contains("\u{202E}"))

        let outDoc = try #require(PDFDocument(url: outPDF))
        #expect(outDoc.pageCount == 2)
        #expect((outDoc.outlineRoot?.numberOfChildren ?? 0) == 2)

        // Word-level search check: individual word hit bounds should be compact width (much narrower than page width)
        let invoiceHits = outDoc.findString("Invoice", withOptions: .caseInsensitive)
        #expect(!invoiceHits.isEmpty)
        if let firstHit = invoiceHits.first, let page0 = outDoc.page(at: 0) {
            let hitBounds = firstHit.bounds(for: page0)
            #expect(hitBounds.width > 10 && hitBounds.width < 220)
        }
        #expect(!outDoc.findString("Financial", withOptions: .caseInsensitive).isEmpty)

        // Multi-page (16 pages) streaming OCR & immediate cancellation cleanup check
        let multiURL = dir.appendingPathComponent("multi_16p.pdf")
        let multiPages = (0..<16).map { i in (text: "ARCHIVE PAGE NUMBER \(i + 1)", tiltRadians: CGFloat(0.0)) }
        try makeRasterScannedPDF(at: multiURL, pages: multiPages)
        let cancelOut = dir.appendingPathComponent("cancelled.pdf")
        let task = Task {
            try await PDFOCRService.runOCR(
                inputURL: multiURL,
                outputPDFURL: cancelOut,
                options: PDFOCROptions(recognitionLevel: .fast, skipExistingTextPages: false, renderDPI: 140.0)
            ) { _ in }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Expected cancellation path
        }
        #expect(!FileManager.default.fileExists(atPath: cancelOut.path))
    }
}

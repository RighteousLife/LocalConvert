import XCTest
import SwiftUI
import AppKit
import Combine
import CryptoKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import LocalConvert

// MARK: - Deterministic Mock Video Runner (Headless, Zero Subprocess)

private final class MockTargetSizeVideoRunner: TargetSizeVideoCompressionRunner, @unchecked Sendable {
    private let lock = NSLock()
    let durationSeconds: Double
    /// Returns file size (in bytes) to write for a given pass index (1-based) and bitrate.
    let bytesForPass: @Sendable (_ passIndex: Int, _ videoBitrateBps: Int, _ audioBitrateBps: Int) -> Int
    private(set) var recordedBitrates: [(video: Int, audio: Int, scaleWidth: Int?)] = []

    init(
        durationSeconds: Double = 20.0,
        bytesForPass: @escaping @Sendable (_ passIndex: Int, _ videoBitrateBps: Int, _ audioBitrateBps: Int) -> Int
    ) {
        self.durationSeconds = durationSeconds
        self.bytesForPass = bytesForPass
    }

    func probeDurationSeconds(url: URL) async throws -> Double {
        durationSeconds
    }

    func transcode(
        inputURL: URL,
        tempOutputURL: URL,
        outputFormat: FileFormat,
        videoBitrateBps: Int,
        audioBitrateBps: Int,
        scaleMaxWidth: Int?,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let passIndex = lock.withLock {
            recordedBitrates.append((video: videoBitrateBps, audio: audioBitrateBps, scaleWidth: scaleMaxWidth))
            return recordedBitrates.count
        }
        let byteCount = max(128, bytesForPass(passIndex, videoBitrateBps, audioBitrateBps))
        let payload = Data(repeating: 0x4D, count: byteCount)
        try payload.write(to: tempOutputURL, options: .atomic)
        progress(1.0)
    }
}

// MARK: - Milestone 13 Compression, Stitcher, Checksum & PDF Power Tools Tests

@MainActor
final class Milestone13CompressionAndPDFTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M13CompPDF-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        OutputReservationCoordinator.clearReservedOutputURLs()
    }

    override func tearDown() async throws {
        OutputReservationCoordinator.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        AppState.shared = previousAppState
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
        previousAppState = nil
    }

    // MARK: - Test Fixture Helpers

    private func makeIsolatedAppState() -> AppState {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        let undo = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: artifacts
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return AppState(
            undoCoordinator: undo,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history,
            uitestingOutputDirectory: sandbox.outputsURL
        )
    }

    private func writeSolidPNG(
        to url: URL,
        width: Int,
        height: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = r
            pixels[i + 1] = g
            pixels[i + 2] = b
            pixels[i + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let img = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone13Tests", code: 1)
        }
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func writeNoisyJPEGOrPNG(to url: URL, width: Int, height: Int, utType: UTType) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8((state >> 16) & 0xFF)
            pixels[i + 1] = UInt8((state >> 24) & 0xFF)
            pixels[i + 2] = UInt8((state >> 32) & 0xFF)
            pixels[i + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let img = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone13Tests", code: 2)
        }
        let props: [CFString: Any] = (utType == .jpeg) ? [kCGImageDestinationLossyCompressionQuality: 0.98] : [:]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func writeVectorPDF(to url: URL, pageTexts: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "Milestone13Tests", code: 3)
        }
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 16.0, nil)
        for text in pageTexts {
            var pageBox = box
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.setFillColor(.white)
            ctx.fill(box)
            var y: CGFloat = 720
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let attr = CFAttributedStringCreate(nil, trimmed as CFString, [
                        kCTFontAttributeName: font,
                        kCTForegroundColorAttributeName: CGColor.black
                    ] as CFDictionary)!
                    ctx.textPosition = CGPoint(x: 48, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
                }
                y -= 28
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func writeHeavyRasterPDF(to url: URL, pageCount: Int = 2) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdfCtx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "Milestone13Tests", code: 4)
        }
        let imgW = 900, imgH = 1200
        var pixels = [UInt8](repeating: 255, count: imgW * imgH * 4)
        var state: UInt64 = 0xCAFE_BABE_1234_5678
        for i in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8((state >> 16) & 0xFF)
            pixels[i + 1] = UInt8((state >> 24) & 0xFF)
            pixels[i + 2] = UInt8((state >> 32) & 0xFF)
            pixels[i + 3] = 255
        }
        guard let bmpCtx = CGContext(
            data: &pixels,
            width: imgW,
            height: imgH,
            bitsPerComponent: 8,
            bytesPerRow: imgW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let raster = bmpCtx.makeImage() else {
            throw NSError(domain: "Milestone13Tests", code: 5)
        }

        for _ in 0..<pageCount {
            var pBox = box
            let pData = Data(bytes: &pBox, count: MemoryLayout<CGRect>.size) as CFData
            pdfCtx.beginPDFPage([kCGPDFContextMediaBox: pData] as CFDictionary)
            pdfCtx.draw(raster, in: box)
            pdfCtx.endPDFPage()
        }
        pdfCtx.closePDF()
    }

    private func samplePixelRGBA(atURL url: URL, x: Int, yFromTop: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8, width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "Milestone13Tests", code: 6)
        }
        let w = img.width
        let h = img.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(ok)
        let offset = (yFromTop * w + x) * 4
        return (rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3], w, h)
    }

    // MARK: - 1. Target File-Size Auto-Compression Tests

    func testImageTargetSizeCompressionConvergesWithinMax4Iterations() async throws {
        let srcURL = sandbox.documentsURL.appendingPathComponent("noisy_photo.jpg")
        try writeNoisyJPEGOrPNG(to: srcURL, width: 640, height: 480, utType: .jpeg)
        let originalData = try Data(contentsOf: srcURL)
        let targetBytes: Int64 = 45_000

        let result = try await TargetSizeCompressionCoordinator.compress(
            inputURL: srcURL,
            targetBytes: targetBytes,
            outputDirectory: sandbox.outputsURL,
            preferredOutputFormat: .jpg
        )

        XCTAssertLessThanOrEqual(result.iterationsUsed, TargetSizeCompressionCoordinator.maxIterations)
        XCTAssertGreaterThanOrEqual(result.iterationsUsed, 1)
        XCTAssertTrue(result.targetReached)
        XCTAssertLessThanOrEqual(result.finalBytes, targetBytes)
        XCTAssertNotEqual(result.outputURL.standardizedFileURL, srcURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertEqual(try Data(contentsOf: srcURL), originalData, "Source image must remain untouched")
    }

    func testImageTargetSizeCompressionEnforcesMax4IterationBoundWhenUnreachable() async throws {
        let srcURL = sandbox.documentsURL.appendingPathComponent("tiny_bound.png")
        try writeNoisyJPEGOrPNG(to: srcURL, width: 512, height: 512, utType: .png)

        let result = try await TargetSizeCompressionCoordinator.compressImage(
            inputURL: srcURL,
            targetFormat: .png,
            targetBytes: 150, // Physically unreachable PNG byte cap
            outputDirectory: sandbox.outputsURL
        )

        XCTAssertLessThanOrEqual(result.iterationsUsed, 4)
        XCTAssertFalse(result.targetReached)
        XCTAssertNotNil(result.note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
    }

    func testPDFTargetSizeCompressionConvergesWithinMax4Iterations() async throws {
        let srcPDF = sandbox.documentsURL.appendingPathComponent("heavy_scan.pdf")
        try writeHeavyRasterPDF(to: srcPDF, pageCount: 2)
        let origBytes = (try FileManager.default.attributesOfItem(atPath: srcPDF.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(origBytes, 500_000)

        let targetBytes = max(120_000, origBytes / 4)
        let result = try await TargetSizeCompressionCoordinator.compress(
            inputURL: srcPDF,
            targetBytes: targetBytes,
            outputDirectory: sandbox.outputsURL
        )

        XCTAssertEqual(result.outputFormat, .pdf)
        XCTAssertLessThanOrEqual(result.iterationsUsed, 4)
        XCTAssertTrue(result.targetReached)
        XCTAssertLessThanOrEqual(result.finalBytes, targetBytes)
        let outDoc = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertEqual(outDoc.pageCount, 2)
    }

    func testVideoBitrateBudgetCalculationAndBounded4IterationRetry() async throws {
        let budget = TargetSizeCompressionCoordinator.computeVideoBitrateBudget(
            targetBytes: 10_000_000,
            durationSeconds: 40.0
        )
        // 10 MB = 80_000_000 bits * 0.92 / 40s = 1_840_000 bps total
        XCTAssertEqual(budget.totalBitrateBps, 1_840_000, accuracy: 2_000)
        XCTAssertGreaterThan(budget.videoBitrateBps, 1_000_000)
        XCTAssertEqual(budget.audioBitrateBps, 128_000)

        let dummyVideo = sandbox.documentsURL.appendingPathComponent("clip.mp4")
        try Data("synthetic-mp4".utf8).write(to: dummyVideo)

        // Mock runner overshoots on pass 1, converges on pass 2
        let runnerConverge = MockTargetSizeVideoRunner(durationSeconds: 20.0) { pass, _, _ in
            pass == 1 ? 12_000_000 : 8_800_000
        }
        let convergeRes = try await TargetSizeCompressionCoordinator.compressVideo(
            inputURL: dummyVideo,
            outputFormat: .mp4,
            targetBytes: 10_000_000,
            outputDirectory: sandbox.outputsURL,
            runner: runnerConverge
        )
        XCTAssertEqual(convergeRes.iterationsUsed, 2)
        XCTAssertTrue(convergeRes.targetReached)
        XCTAssertEqual(convergeRes.finalBytes, 8_800_000)

        // Mock runner always overshoots: must stop strictly at 4 iterations
        let runnerOvershoot = MockTargetSizeVideoRunner(durationSeconds: 20.0) { pass, _, _ in
            20_000_000 - (pass * 1_000_000)
        }
        let boundedRes = try await TargetSizeCompressionCoordinator.compressVideo(
            inputURL: dummyVideo,
            outputFormat: .mp4,
            targetBytes: 5_000_000,
            outputDirectory: sandbox.outputsURL,
            runner: runnerOvershoot
        )
        XCTAssertEqual(boundedRes.iterationsUsed, 4)
        XCTAssertFalse(boundedRes.targetReached)
        XCTAssertEqual(runnerOvershoot.recordedBitrates.count, 4)
        XCTAssertLessThan(runnerOvershoot.recordedBitrates[1].video, runnerOvershoot.recordedBitrates[0].video)
    }

    // MARK: - 2. Multi-Image Stitcher Tests

    func testImageStitcherVerticalAndHorizontalDimensionsGapAndBackground() async throws {
        let img1 = sandbox.documentsURL.appendingPathComponent("top.png")
        let img2 = sandbox.documentsURL.appendingPathComponent("bottom.png")
        try writeSolidPNG(to: img1, width: 100, height: 60, r: 0, g: 255, b: 0)   // Green
        try writeSolidPNG(to: img2, width: 140, height: 80, r: 0, g: 0, b: 255)   // Blue

        // Vertical stitch with 12px red gap
        let vertRes = try await ImageStitcherEngine.stitch(
            inputURLs: [img1, img2],
            outputDirectory: sandbox.outputsURL,
            options: ImageStitchOptions(
                direction: .vertical,
                spacing: 12,
                alignment: .center,
                nsBackgroundColor: .red,
                outputFormat: .png
            )
        )
        XCTAssertEqual(vertRes.width, 140)
        XCTAssertEqual(vertRes.height, 152) // 60 + 12 + 80
        XCTAssertEqual(vertRes.stitchedCount, 2)

        // Verify top image pixel (center), gap pixel (red), and bottom image pixel (blue)
        let topPx = try samplePixelRGBA(atURL: vertRes.outputURL, x: 70, yFromTop: 30)
        XCTAssertEqual(topPx.width, 140)
        XCTAssertEqual(topPx.height, 152)
        XCTAssertGreaterThan(topPx.g, 200)
        XCTAssertLessThan(topPx.r, 30)

        let gapPx = try samplePixelRGBA(atURL: vertRes.outputURL, x: 70, yFromTop: 66)
        XCTAssertGreaterThan(gapPx.r, 200)
        XCTAssertLessThan(gapPx.g, 30)

        let botPx = try samplePixelRGBA(atURL: vertRes.outputURL, x: 70, yFromTop: 110)
        XCTAssertGreaterThan(botPx.b, 200)

        // Horizontal stitch with 10px red gap
        let horizRes = try await ImageStitcherEngine.stitch(
            inputURLs: [img1, img2],
            outputDirectory: sandbox.outputsURL,
            options: ImageStitchOptions(
                direction: .horizontal,
                spacing: 10,
                alignment: .center,
                nsBackgroundColor: .red,
                outputFormat: .png
            )
        )
        XCTAssertEqual(horizRes.width, 250) // 100 + 10 + 140
        XCTAssertEqual(horizRes.height, 80)

        let hGapPx = try samplePixelRGBA(atURL: horizRes.outputURL, x: 105, yFromTop: 40)
        XCTAssertEqual(hGapPx.width, 250)
        XCTAssertEqual(hGapPx.height, 80)
        XCTAssertGreaterThan(hGapPx.r, 200)
        XCTAssertLessThan(hGapPx.b, 30)
    }

    func testSmartSuggestionEngineIncludesStitchImagesOnlyWhenTwoOrMoreImagesQueued() throws {
        let img1 = sandbox.documentsURL.appendingPathComponent("a.png")
        let img2 = sandbox.documentsURL.appendingPathComponent("b.png")
        try writeSolidPNG(to: img1, width: 16, height: 16, r: 255, g: 0, b: 0)
        try writeSolidPNG(to: img2, width: 16, height: 16, r: 0, g: 255, b: 0)

        let det1 = FileDetectionResult(url: img1, detectedFormat: .png, extensionFormat: .png, utTypeFormat: .png, magicBytesFormat: .png, confidence: .high)
        let det2 = FileDetectionResult(url: img2, detectedFormat: .png, extensionFormat: .png, utTypeFormat: .png, magicBytesFormat: .png, confidence: .high)
        let f1 = DroppedFile(url: img1, detectionResult: det1)
        let f2 = DroppedFile(url: img2, detectionResult: det2)

        let oneFilePlan = SmartSuggestionEngine.suggest(for: [f1])
        XCTAssertFalse(oneFilePlan.actions.contains(where: { $0.id == .stitchImages }))

        let twoFilePlan = SmartSuggestionEngine.suggest(for: [f1, f2])
        XCTAssertTrue(twoFilePlan.actions.contains(where: { $0.id == .stitchImages && $0.title == "Stitch Images" }))
    }

    // MARK: - 3. Offline CryptoKit Checksums Tests

    func testCryptoKitStreamingChecksumsMatchKnownVectorsAndMultiChunkFiles() throws {
        // Known NIST vector for "abc"
        let abcURL = sandbox.documentsURL.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: abcURL)
        let abcChecksums = try FileChecksumCalculator.computeChecksums(for: abcURL)
        XCTAssertEqual(abcChecksums.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(abcChecksums.md5, "900150983cd24fb0d6963f7d28e17f72")

        // Multi-chunk streaming verification (25,000 bytes with 4,096 byte chunks)
        let largeURL = sandbox.documentsURL.appendingPathComponent("stream_payload.bin")
        let payload = Data((0..<25_000).map { UInt8($0 % 251) })
        try payload.write(to: largeURL)

        let streamed = try FileChecksumCalculator.computeChecksums(for: largeURL, chunkSize: 4096)
        let expectedSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let expectedMD5 = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamed.sha256, expectedSHA)
        XCTAssertEqual(streamed.md5, expectedMD5)
    }

    // MARK: - 4. Advanced PDF Power Tools Tests

    func testPDFPowerToolsOrganizerReorderDeleteRotateAndExtract() async throws {
        let srcURL = sandbox.documentsURL.appendingPathComponent("three_pages.pdf")
        try writeVectorPDF(to: srcURL, pageTexts: ["PAGE-ALPHA", "PAGE-BETA", "PAGE-GAMMA"])

        // Thumbnails
        let thumbs = try await PDFPowerToolsEngine.renderThumbnails(url: srcURL, maxDimension: 120)
        XCTAssertEqual(thumbs.count, 3)
        XCTAssertGreaterThan(thumbs[0].cgImage.width, 0)

        // Reorder [2, 0] (drops PAGE-BETA) and rotate page 0 by +90, page 1 by 270
        let organizedURL = sandbox.outputsURL.appendingPathComponent("organized.pdf")
        let orgSummary = try await PDFPowerToolsEngine.organizePages(
            inputURL: srcURL,
            outputURL: organizedURL,
            specs: [
                PDFPowerPageSpec(sourcePageIndex: 2, rotationDeltaDegrees: 90),
                PDFPowerPageSpec(sourcePageIndex: 0, rotationDeltaDegrees: 270)
            ]
        )
        XCTAssertEqual(orgSummary.pageCount, 2)
        let orgDoc = try XCTUnwrap(PDFDocument(url: organizedURL))
        XCTAssertEqual(orgDoc.pageCount, 2)
        XCTAssertTrue((orgDoc.page(at: 0)?.string ?? "").contains("PAGE-GAMMA"))
        XCTAssertTrue((orgDoc.page(at: 1)?.string ?? "").contains("PAGE-ALPHA"))
        XCTAssertFalse((orgDoc.string ?? "").contains("PAGE-BETA"))
        XCTAssertEqual(orgDoc.page(at: 0)?.rotation, 90)
        XCTAssertEqual(orgDoc.page(at: 1)?.rotation, 270)

        // Extract selected page [1] ("PAGE-BETA")
        let extractedURL = sandbox.outputsURL.appendingPathComponent("extracted.pdf")
        let extSummary = try await PDFPowerToolsEngine.extractPages(
            inputURL: srcURL,
            zeroBasedIndices: [1],
            outputURL: extractedURL
        )
        XCTAssertEqual(extSummary.pageCount, 1)
        let extDoc = try XCTUnwrap(PDFDocument(url: extractedURL))
        XCTAssertTrue((extDoc.page(at: 0)?.string ?? "").contains("PAGE-BETA"))
    }

    func testPDFPowerToolsTrueDestructiveRedactionRemovesTextFromDocumentString() async throws {
        let srcURL = sandbox.documentsURL.appendingPathComponent("secret_contract.pdf")
        // Top line is around y=720 in 792pt page (top ~9% of page)
        try writeVectorPDF(to: srcURL, pageTexts: ["TOP-SECRET-TOKEN-991\n\nSecond Line"])

        let outURL = sandbox.outputsURL.appendingPathComponent("redacted_contract.pdf")
        // Normalized top-left rect covering the top portion of page 0
        let region = PDFPowerRedactionRegion(
            pageIndex: 0,
            normalizedTopLeftRect: CGRect(x: 0.04, y: 0.04, width: 0.70, height: 0.14)
        )

        let summary = try await PDFPowerToolsEngine.applyTrueDestructiveRedaction(
            inputURL: srcURL,
            outputURL: outURL,
            regions: [region],
            searchTerms: ["TOP-SECRET-TOKEN-991"],
            renderDPI: 180.0
        )

        XCTAssertEqual(summary.pageCount, 1)
        XCTAssertEqual(summary.redactedPageIndices, [0])

        let redactedDoc = try XCTUnwrap(PDFDocument(url: outURL))
        let extractedText = redactedDoc.string ?? ""
        XCTAssertFalse(extractedText.contains("TOP-SECRET-TOKEN-991"), "Redacted text must be completely absent from PDFDocument.string")
        XCTAssertTrue(redactedDoc.findString("TOP-SECRET-TOKEN-991", withOptions: [.caseInsensitive]).isEmpty)

        // Raw PDF bytes must also contain zero occurrences of the redacted token
        let rawBytes = try Data(contentsOf: outURL)
        XCTAssertNil(rawBytes.range(of: Data("TOP-SECRET-TOKEN-991".utf8)))
    }

    func testPDFPowerToolsSignatureStampAndFlattenPDF() async throws {
        let srcURL = sandbox.documentsURL.appendingPathComponent("form_and_sign.pdf")
        try writeVectorPDF(to: srcURL, pageTexts: ["Agreement Document"])

        // Add interactive annotation + AcroForm text widget to srcURL
        let preDoc = try XCTUnwrap(PDFDocument(url: srcURL))
        let page0 = try XCTUnwrap(preDoc.page(at: 0))

        let widget = PDFAnnotation(bounds: CGRect(x: 60, y: 500, width: 220, height: 28), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "SignerName"
        widget.widgetStringValue = "Alice Example"
        page0.addAnnotation(widget)

        let square = PDFAnnotation(bounds: CGRect(x: 60, y: 420, width: 120, height: 40), forType: .square, withProperties: nil)
        square.color = .red
        page0.addAnnotation(square)
        XCTAssertTrue(preDoc.write(to: srcURL))
        XCTAssertEqual(PDFDocument(url: srcURL)?.page(at: 0)?.annotations.count, 2)

        // 1. Stamp Signature
        let signedURL = sandbox.outputsURL.appendingPathComponent("signed.pdf")
        let strokes: [[CGPoint]] = [
            [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.4, y: 0.2), CGPoint(x: 0.85, y: 0.6)]
        ]
        let signRes = try await PDFPowerToolsEngine.stampSignature(
            inputURL: srcURL,
            outputURL: signedURL,
            request: PDFSignatureStampRequest(
                pageIndex: 0,
                normalizedTopLeftRect: CGRect(x: 0.55, y: 0.70, width: 0.35, height: 0.15),
                strokes: strokes,
                strokeColorHex: "#0A2463",
                lineWidth: 3.0
            )
        )
        XCTAssertEqual(signRes.pageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: signedURL.path))

        // 2. Flatten PDF (bakes annotations & widgets so remainingAnnotationCount == 0)
        let flattenedURL = sandbox.outputsURL.appendingPathComponent("flattened.pdf")
        let flatRes = try await PDFPowerToolsEngine.flattenPDF(
            inputURL: srcURL,
            outputURL: flattenedURL
        )
        XCTAssertEqual(flatRes.pageCount, 1)
        XCTAssertEqual(flatRes.flattenedAnnotationCount, 2)
        XCTAssertEqual(flatRes.remainingAnnotationCount, 0)

        let flatDoc = try XCTUnwrap(PDFDocument(url: flattenedURL))
        XCTAssertTrue(flatDoc.page(at: 0)?.annotations.isEmpty ?? false, "Flattened PDF must have no remaining editable annotations/widgets")
    }

    func testPDFPowerToolsPageNumberingWatermarkAndEncryptDecryptRoundTrip() async throws {
        let srcURL = sandbox.documentsURL.appendingPathComponent("multi_page_doc.pdf")
        try writeVectorPDF(to: srcURL, pageTexts: ["Body One", "Body Two", "Body Three"])

        // 1. Automatic Page Numbering (1 / N)
        let numberedURL = sandbox.outputsURL.appendingPathComponent("numbered.pdf")
        let numRes = try await PDFPowerToolsEngine.addPageNumbers(
            inputURL: srcURL,
            outputURL: numberedURL,
            options: PDFPageNumberingOptions(position: .bottomCenter, format: .pageOfTotal)
        )
        XCTAssertEqual(numRes.pageCount, 3)
        let numDoc = try XCTUnwrap(PDFDocument(url: numberedURL))
        XCTAssertTrue((numDoc.page(at: 0)?.string ?? "").contains("1 / 3"))
        XCTAssertTrue((numDoc.page(at: 1)?.string ?? "").contains("2 / 3"))
        XCTAssertTrue((numDoc.page(at: 2)?.string ?? "").contains("3 / 3"))

        // 2. Diagonal Translucent Watermark
        let watermarkedURL = sandbox.outputsURL.appendingPathComponent("watermarked.pdf")
        let wmRes = try await PDFPowerToolsEngine.addDiagonalWatermark(
            inputURL: srcURL,
            outputURL: watermarkedURL,
            options: PDFWatermarkOptions(text: "DRAFT-M13", opacity: 0.25, angleDegrees: -45.0)
        )
        XCTAssertEqual(wmRes.pageCount, 3)
        let wmDoc = try XCTUnwrap(PDFDocument(url: watermarkedURL))
        XCTAssertTrue((wmDoc.page(at: 0)?.string ?? "").contains("DRAFT-M13"))
        XCTAssertTrue((wmDoc.page(at: 2)?.string ?? "").contains("DRAFT-M13"))

        // 3. Password Encrypt & Decrypt Round-Trip
        let encryptedURL = sandbox.outputsURL.appendingPathComponent("locked.pdf")
        let encRes = try await PDFPowerToolsEngine.encryptPDF(
            inputURL: srcURL,
            outputURL: encryptedURL,
            userPassword: "user-pass-123",
            ownerPassword: "owner-pass-456"
        )
        XCTAssertTrue(encRes.isEncrypted)
        XCTAssertTrue(encRes.isLocked)

        let lockedDoc = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(lockedDoc.isEncrypted)
        XCTAssertTrue(lockedDoc.isLocked)
        XCTAssertFalse(lockedDoc.unlock(withPassword: "wrong-password"))
        XCTAssertTrue(lockedDoc.unlock(withPassword: "user-pass-123"))

        let decryptedURL = sandbox.outputsURL.appendingPathComponent("unlocked.pdf")
        let decRes = try await PDFPowerToolsEngine.decryptPDF(
            inputURL: encryptedURL,
            outputURL: decryptedURL,
            password: "owner-pass-456"
        )
        XCTAssertFalse(decRes.isEncrypted)
        XCTAssertFalse(decRes.isLocked)
        XCTAssertEqual(decRes.pageCount, 3)

        let unlockedDoc = try XCTUnwrap(PDFDocument(url: decryptedURL))
        XCTAssertFalse(unlockedDoc.isEncrypted)
        XCTAssertFalse(unlockedDoc.isLocked)
        XCTAssertTrue((unlockedDoc.page(at: 0)?.string ?? "").contains("Body One"))
    }

    // MARK: - 5. Headless UI Hosting Layout Checks (820x580, Zero Re-Entrant State Publish)

    func testNewAndEditedViewsLayoutWithin820x580WithoutPublishingAppState() throws {
        let appState = makeIsolatedAppState()
        let samplePDF = sandbox.documentsURL.appendingPathComponent("ui_sample.pdf")
        try writeVectorPDF(to: samplePDF, pageTexts: ["Sample Page 1"])
        let pdfDet = FileDetector().detect(url: samplePDF)
        let pdfFile = DroppedFile(url: samplePDF, detectionResult: pdfDet)
        appState.droppedFiles = [pdfFile]

        var publishCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let views: [(String, AnyView)] = [
            ("PDFPageOrganizerAndSecurityView", AnyView(
                PDFPageOrganizerAndSecurityView(selectedFiles: [pdfFile], password: .constant(""))
                    .environmentObject(appState)
            )),
            ("ContextualSmartBarView", AnyView(
                ContextualSmartBarView().environmentObject(appState)
            )),
            ("FileRowView", AnyView(
                FileRowView(file: pdfFile).environmentObject(appState)
            )),
            ("FileOptionsView", AnyView(
                FileOptionsView(
                    options: .constant(.default),
                    descriptors: [],
                    fileName: pdfFile.fileName,
                    inputFormat: .pdf,
                    outputFormat: .png
                )
            )),
            ("MetadataView", AnyView(
                MetadataView(metadataManager: MetadataManager.shared)
            ))
        ]

        for (name, view) in views {
            let before = publishCount
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(publishCount, before, "\(name) must not publish AppState during layout")
            XCTAssertLessThanOrEqual(host.fittingSize.width, 820, "\(name) fitting width must stay within LC-019 820pt bound")
        }
    }
}

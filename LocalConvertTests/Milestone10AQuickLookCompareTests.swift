import XCTest
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import AppKit
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone10AQuickLookCompareTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M10AQuickLookCompare-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
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

    // MARK: - Helpers

    private func makeDroppedFile(url: URL, format: FileFormat?) -> DroppedFile {
        let result = FileDetectionResult(
            url: url,
            detectedFormat: format,
            extensionFormat: format,
            utTypeFormat: format,
            magicBytesFormat: format,
            confidence: format == nil ? .unknown : .high
        )
        return DroppedFile(url: url, detectionResult: result)
    }

    private func writeSyntheticPNG(to url: URL, width: Int = 32, height: Int = 24) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 180, count: width * height * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) { pixels[idx] = 255 }
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone10AQuickLookCompareTests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Milestone10AQuickLookCompareTests", code: 2)
        }
    }

    private func writeSyntheticPDF(to url: URL, pageCount: Int = 2) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc = PDFDocument()
        for index in 0..<pageCount {
            let pageRect = CGRect(x: 0, y: 0, width: 200, height: 260)
            let data = NSMutableData()
            var mediaBox = pageRect
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                throw NSError(domain: "Milestone10AQuickLookCompareTests", code: 3)
            }
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
            ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 220))
            ctx.endPDFPage()
            ctx.closePDF()

            if let singleDoc = PDFDocument(data: data as Data),
               let page = singleDoc.page(at: 0) {
                doc.insert(page, at: index)
            }
        }
        guard doc.pageCount == pageCount, doc.write(to: url) else {
            throw NSError(domain: "Milestone10AQuickLookCompareTests", code: 4)
        }
    }

    private func writeDummyFile(to url: URL, byteCount: Int = 128) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: byteCount)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Preview Item URL Resolution Tests

    func testResolvePreviewURLPrefersExistingConvertedOutputWhenCompleted() throws {
        let inputURL = sandbox.documentsURL.appendingPathComponent("photo.png")
        let outputURL = sandbox.outputsURL.appendingPathComponent("photo.webp")
        try writeSyntheticPNG(to: inputURL)
        try writeDummyFile(to: outputURL, byteCount: 64)

        let file = makeDroppedFile(url: inputURL, format: .png)
        let result = ConversionResult(outputURL: outputURL, outputFormat: .webp, fileSize: 64)

        let resolved = QueueQuickLookResolver.resolvePreviewURL(
            for: file,
            status: .completed(result)
        )
        XCTAssertEqual(resolved, outputURL)
    }

    func testResolvePreviewURLFallsBackToInputWhenCompletedOutputIsMissing() throws {
        let inputURL = sandbox.documentsURL.appendingPathComponent("photo.png")
        let missingOutputURL = sandbox.outputsURL.appendingPathComponent("deleted_output.webp")
        try writeSyntheticPNG(to: inputURL)

        let file = makeDroppedFile(url: inputURL, format: .png)
        let result = ConversionResult(outputURL: missingOutputURL, outputFormat: .webp, fileSize: 64)

        let resolved = QueueQuickLookResolver.resolvePreviewURL(
            for: file,
            status: .completed(result)
        )
        XCTAssertEqual(resolved, inputURL)
    }

    func testResolvePreviewURLUsesInputForNonCompletedStatuses() throws {
        let inputURL = sandbox.documentsURL.appendingPathComponent("input.png")
        let outputURL = sandbox.outputsURL.appendingPathComponent("output.jpg")
        try writeSyntheticPNG(to: inputURL)
        try writeDummyFile(to: outputURL, byteCount: 32)

        let file = makeDroppedFile(url: inputURL, format: .png)
        let statuses: [ConversionJobStatus?] = [
            nil,
            .waiting,
            .converting(.determinate(0.5)),
            .failed(.invalidInput("bad")),
            .cancelled
        ]

        for status in statuses {
            let resolved = QueueQuickLookResolver.resolvePreviewURL(for: file, status: status)
            XCTAssertEqual(resolved, inputURL)
        }
    }

    func testResolvePreviewURLReturnsNilWhenFilesMissingOrDirectory() throws {
        let missingInput = sandbox.documentsURL.appendingPathComponent("does_not_exist.png")
        let missingOutput = sandbox.outputsURL.appendingPathComponent("missing.webp")
        let missingFile = makeDroppedFile(url: missingInput, format: .png)
        let missingResult = ConversionResult(outputURL: missingOutput, outputFormat: .webp, fileSize: 0)

        XCTAssertNil(QueueQuickLookResolver.resolvePreviewURL(for: missingFile, status: nil))
        XCTAssertNil(QueueQuickLookResolver.resolvePreviewURL(for: missingFile, status: .completed(missingResult)))

        // Directories must not resolve as regular preview files
        let dirFile = makeDroppedFile(url: sandbox.documentsURL, format: nil)
        XCTAssertNil(QueueQuickLookResolver.resolvePreviewURL(for: dirFile, status: nil))
    }

    func testResolveQueueItemsTracksSelectionAndSkipsMissingFiles() throws {
        let missingURL = sandbox.documentsURL.appendingPathComponent("gone.png")
        let firstValidInput = sandbox.documentsURL.appendingPathComponent("first.png")
        let secondValidInput = sandbox.documentsURL.appendingPathComponent("second.pdf")
        let secondConvertedOutput = sandbox.outputsURL.appendingPathComponent("second_compressed.pdf")

        try writeSyntheticPNG(to: firstValidInput)
        try writeSyntheticPDF(to: secondValidInput, pageCount: 1)
        try writeSyntheticPDF(to: secondConvertedOutput, pageCount: 1)

        let missingFile = makeDroppedFile(url: missingURL, format: .png)
        let firstFile = makeDroppedFile(url: firstValidInput, format: .png)
        let secondFile = makeDroppedFile(url: secondValidInput, format: .pdf)

        let statuses: [UUID: ConversionJobStatus] = [
            secondFile.id: .completed(ConversionResult(outputURL: secondConvertedOutput, outputFormat: .pdf, fileSize: 512))
        ]

        let resolved = QueueQuickLookResolver.resolveQueueItems(
            files: [missingFile, firstFile, secondFile],
            statusesByFileID: statuses,
            selectedFileID: secondFile.id
        )

        XCTAssertEqual(resolved.urls, [firstValidInput, secondConvertedOutput])
        XCTAssertEqual(resolved.selectedIndex, 1)
    }

    // MARK: - Before/After Comparison Eligibility Tests

    func testComparisonEligibilityAcceptsCompletedImageAndPDFFiles() throws {
        let pngIn = sandbox.documentsURL.appendingPathComponent("a.png")
        let jpgOut = sandbox.outputsURL.appendingPathComponent("a.jpg")
        try writeSyntheticPNG(to: pngIn)
        try writeSyntheticPNG(to: jpgOut)

        let pdfIn = sandbox.documentsURL.appendingPathComponent("b.pdf")
        let pdfOut = sandbox.outputsURL.appendingPathComponent("b_out.pdf")
        try writeSyntheticPDF(to: pdfIn, pageCount: 2)
        try writeSyntheticPDF(to: pdfOut, pageCount: 2)

        let pngOutFromPDF = sandbox.outputsURL.appendingPathComponent("b_page1.png")
        try writeSyntheticPNG(to: pngOutFromPDF)

        let imageFile = makeDroppedFile(url: pngIn, format: .png)
        let imageStatus = ConversionJobStatus.completed(
            ConversionResult(outputURL: jpgOut, outputFormat: .jpg, fileSize: 120)
        )
        XCTAssertTrue(BeforeAfterComparisonSupport.isEligibleForComparison(file: imageFile, status: imageStatus))

        let pdfFile = makeDroppedFile(url: pdfIn, format: .pdf)
        let pdfStatus = ConversionJobStatus.completed(
            ConversionResult(outputURL: pdfOut, outputFormat: .pdf, fileSize: 300)
        )
        XCTAssertTrue(BeforeAfterComparisonSupport.isEligibleForComparison(file: pdfFile, status: pdfStatus))

        let pdfToImageStatus = ConversionJobStatus.completed(
            ConversionResult(outputURL: pngOutFromPDF, outputFormat: .png, fileSize: 200)
        )
        XCTAssertTrue(BeforeAfterComparisonSupport.isEligibleForComparison(file: pdfFile, status: pdfToImageStatus))
    }

    func testComparisonEligibilityRejectsNonCompletedMissingAndUnsupportedFormats() throws {
        let pngIn = sandbox.documentsURL.appendingPathComponent("photo.png")
        let pngOut = sandbox.outputsURL.appendingPathComponent("photo_out.png")
        try writeSyntheticPNG(to: pngIn)
        try writeSyntheticPNG(to: pngOut)

        let imageFile = makeDroppedFile(url: pngIn, format: .png)
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: imageFile, status: nil))
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: imageFile, status: .waiting))
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: imageFile, status: .converting(.determinate(0.4))))
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: imageFile, status: .failed(.cancelled)))
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: imageFile, status: .cancelled))

        // Missing output file
        let missingOut = sandbox.outputsURL.appendingPathComponent("missing_out.png")
        let missingOutStatus = ConversionJobStatus.completed(
            ConversionResult(outputURL: missingOut, outputFormat: .png, fileSize: 100)
        )
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: imageFile, status: missingOutStatus))

        // Missing input file
        let missingInFile = makeDroppedFile(url: sandbox.documentsURL.appendingPathComponent("missing_in.png"), format: .png)
        let validOutStatus = ConversionJobStatus.completed(
            ConversionResult(outputURL: pngOut, outputFormat: .png, fileSize: 100)
        )
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: missingInFile, status: validOutStatus))

        // Non-image / non-PDF formats (audio, video, office doc -> pdf, text -> json)
        let audioIn = sandbox.documentsURL.appendingPathComponent("clip.wav")
        let audioOut = sandbox.outputsURL.appendingPathComponent("clip.mp3")
        try writeDummyFile(to: audioIn)
        try writeDummyFile(to: audioOut)
        let audioFile = makeDroppedFile(url: audioIn, format: .wav)
        let audioStatus = ConversionJobStatus.completed(ConversionResult(outputURL: audioOut, outputFormat: .mp3, fileSize: 64))
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: audioFile, status: audioStatus))

        let docxIn = sandbox.documentsURL.appendingPathComponent("notes.docx")
        let docxPDFOut = sandbox.outputsURL.appendingPathComponent("notes.pdf")
        try writeDummyFile(to: docxIn)
        try writeSyntheticPDF(to: docxPDFOut, pageCount: 1)
        let docxFile = makeDroppedFile(url: docxIn, format: .docx)
        let docxStatus = ConversionJobStatus.completed(ConversionResult(outputURL: docxPDFOut, outputFormat: .pdf, fileSize: 256))
        XCTAssertFalse(BeforeAfterComparisonSupport.isEligibleForComparison(file: docxFile, status: docxStatus))
    }

    // MARK: - Split-Ratio Clamping & Size Delta Tests

    func testSplitRatioClampingBoundsAndNonFiniteHandling() {
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(-0.001), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(-42.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(0.37), 0.37, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(1.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(1.25), 1.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(999.0), 1.0, accuracy: 0.0001)

        let nanResult = BeforeAfterComparisonMath.clampSplitRatio(Double.nan)
        XCTAssertTrue(nanResult.isFinite)
        XCTAssertEqual(nanResult, 0.5, accuracy: 0.0001)

        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(-Double.infinity), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(Double.infinity), 1.0, accuracy: 0.0001)

        // CGFloat overload
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(CGFloat(-0.5)), 0.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(CGFloat(1.8)), 1.0, accuracy: 0.0001)
        XCTAssertEqual(BeforeAfterComparisonMath.clampSplitRatio(CGFloat.nan), 0.5, accuracy: 0.0001)
    }

    func testSizeDeltaCalculationsAndDiskFallback() throws {
        let smaller = try XCTUnwrap(BeforeAfterComparisonMath.computeSizeDelta(inputBytes: 10_000, outputBytes: 2_500))
        XCTAssertEqual(smaller.byteDelta, -7_500)
        XCTAssertEqual(try XCTUnwrap(smaller.percentDelta), -75.0, accuracy: 0.01)
        XCTAssertEqual(smaller.savingsSummary?.direction, .smaller(percent: 75))

        let larger = try XCTUnwrap(BeforeAfterComparisonMath.computeSizeDelta(inputBytes: 1_000, outputBytes: 1_250))
        XCTAssertEqual(larger.byteDelta, 250)
        XCTAssertEqual(try XCTUnwrap(larger.percentDelta), 25.0, accuracy: 0.01)
        XCTAssertEqual(larger.savingsSummary?.direction, .larger(percent: 25))

        let same = try XCTUnwrap(BeforeAfterComparisonMath.computeSizeDelta(inputBytes: 4_096, outputBytes: 4_096))
        XCTAssertEqual(same.byteDelta, 0)
        XCTAssertEqual(try XCTUnwrap(same.percentDelta), 0.0, accuracy: 0.01)
        XCTAssertEqual(same.savingsSummary?.direction, .same)

        XCTAssertNil(BeforeAfterComparisonMath.computeSizeDelta(inputBytes: 0, outputBytes: 100))
        XCTAssertNil(BeforeAfterComparisonMath.computeSizeDelta(inputBytes: 100, outputBytes: 0))
        XCTAssertNil(BeforeAfterComparisonMath.computeSizeDelta(inputBytes: nil, outputBytes: 100))

        // Disk-size fallback when ConversionResult.fileSize == 0
        let inURL = sandbox.documentsURL.appendingPathComponent("disk_in.png")
        let outURL = sandbox.outputsURL.appendingPathComponent("disk_out.png")
        try writeSyntheticPNG(to: inURL, width: 64, height: 64)
        try writeSyntheticPNG(to: outURL, width: 16, height: 16)

        let file = makeDroppedFile(url: inURL, format: .png)
        let result = ConversionResult(outputURL: outURL, outputFormat: .png, fileSize: 0)
        let item = try XCTUnwrap(BeforeAfterComparisonSupport.makeComparisonItem(for: file, status: .completed(result)))
        XCTAssertGreaterThan(item.inputBytes, 0)
        XCTAssertGreaterThan(item.outputBytes, 0)
        XCTAssertNotNil(item.sizeDelta)
    }

    // MARK: - Visual Asset Loader Tests (Image & Multi-Page PDF)

    func testVisualLoaderRendersImageAndMultiPagePDFSafely() async throws {
        let pngURL = sandbox.documentsURL.appendingPathComponent("render_sample.png")
        try writeSyntheticPNG(to: pngURL, width: 48, height: 32)
        let pngAsset = await BeforeAfterVisualLoader.loadVisualAsset(url: pngURL, format: .png, pageIndex: 0)
        XCTAssertNotNil(pngAsset.cgImage)
        XCTAssertEqual(pngAsset.pageCount, 1)
        XCTAssertEqual(pngAsset.pixelWidth, 48)
        XCTAssertEqual(pngAsset.pixelHeight, 32)

        let pdfURL = sandbox.documentsURL.appendingPathComponent("multipage.pdf")
        try writeSyntheticPDF(to: pdfURL, pageCount: 3)
        let pdfPage0 = await BeforeAfterVisualLoader.loadVisualAsset(url: pdfURL, format: .pdf, pageIndex: 0)
        XCTAssertNotNil(pdfPage0.cgImage)
        XCTAssertEqual(pdfPage0.pageCount, 3)

        // Out-of-bounds page index clamps safely to last page
        let pdfOutOfRange = await BeforeAfterVisualLoader.loadVisualAsset(url: pdfURL, format: .pdf, pageIndex: 99)
        XCTAssertNotNil(pdfOutOfRange.cgImage)
        XCTAssertEqual(pdfOutOfRange.pageCount, 3)

        // Missing file fails gracefully without throwing or crashing
        let missingAsset = await BeforeAfterVisualLoader.loadVisualAsset(
            url: sandbox.documentsURL.appendingPathComponent("missing.pdf"),
            format: .pdf,
            pageIndex: 0
        )
        XCTAssertNil(missingAsset.cgImage)
        XCTAssertEqual(missingAsset.pageCount, 0)
    }
}

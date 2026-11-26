import XCTest
import Foundation
import AppKit
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import LocalConvert

final class Milestone1BPDFImageSafetyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConversionManager.clearReservedOutputURLs()
    }

    override func tearDown() {
        ConversionManager.clearReservedOutputURLs()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String = "M1B") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeVectorPDF(at url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "M1BTests", code: 1)
        }
        for text in pages {
            var pageBox = box
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.setFillColor(.white)
            ctx.fill(box)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (text as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func writeTinyPNG(to url: URL, width: Int = 24, height: Int = 24) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 180, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 40
            pixels[i + 1] = 120
            pixels[i + 2] = 220
            pixels[i + 3] = 255
        }
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "M1BTests", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func writeJPEGWithGPSAndCameraEXIF(to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 140, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i + 3] = 255
        }
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "M1BTests", code: 3)
        }

        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "PrivacyTestCam",
                kCGImagePropertyTIFFModel: "Model X1"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "50mm f/1.8",
                kCGImagePropertyExifDateTimeOriginal: "2026:11:25 12:00:00"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSLongitude: 122.4194
            ]
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - LC-001: Zero Delete-Before-Move & Atomic Commit Spy

    func testAtomicPublishNeverDeletesExistingDestinationBeforeMoveOrReplace() throws {
        let dir = try makeTempDir(prefix: "M1B-Spy")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tempFile = dir.appendingPathComponent("staged.pdf")
        let destFile = dir.appendingPathComponent("existing.pdf")
        try Data("new-staged-pdf".utf8).write(to: tempFile)
        try Data("original-existing-pdf".utf8).write(to: destFile)

        final class SpyLog: @unchecked Sendable {
            private let lock = NSLock()
            var removedURLs: [URL] = []
            var replacedPairs: [(URL, URL)] = []

            func recordRemove(_ url: URL) {
                lock.lock()
                removedURLs.append(url)
                lock.unlock()
            }

            func recordReplace(_ dst: URL, _ src: URL) {
                lock.lock()
                replacedPairs.append((dst, src))
                lock.unlock()
            }
        }

        let spy = SpyLog()
        let ops = OutputReservationCoordinator.AtomicPublishFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            isSameVolume: { _, _ in true },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            replaceItemAt: { dst, src in
                spy.recordReplace(dst, src)
                return (try FileManager.default.replaceItemAt(dst, withItemAt: src)) ?? dst
            },
            removeItem: { url in
                spy.recordRemove(url)
                try FileManager.default.removeItem(at: url)
            }
        )

        let committed = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempFile,
            to: destFile,
            policy: .overwrite,
            operations: ops
        )

        XCTAssertEqual(committed.standardizedFileURL, destFile.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: destFile, encoding: .utf8), "new-staged-pdf")
        XCTAssertEqual(spy.replacedPairs.count, 1)
        XCTAssertFalse(
            spy.removedURLs.contains { $0.standardizedFileURL == destFile.standardizedFileURL },
            "Destination URL must never be deleted via removeItem prior to atomic replace"
        )
    }

    // MARK: - LC-001: PDF Services Atomic Overwrite & Failure Preservation

    func testPDFServicesCommitAtomicallyAndPreserveExistingDestinationOnFailure() async throws {
        let dir = try makeTempDir(prefix: "M1B-PDFServices")
        defer { try? FileManager.default.removeItem(at: dir) }

        let validPDF = dir.appendingPathComponent("valid.pdf")
        try writeVectorPDF(at: validPDF, pages: ["Page 1 Confidential Token", "Page 2 Public Content"])
        let corruptPDF = dir.appendingPathComponent("corrupt.pdf")
        try Data("NOT-A-VALID-PDF".utf8).write(to: corruptPDF)

        // 1) PDFSecurityService: encrypt over existing file succeeds; failed decrypt preserves existing destination
        let secDest = dir.appendingPathComponent("sec_dest.pdf")
        try Data("SENTINEL-SECURITY-DEST".utf8).write(to: secDest)

        var encOpts = PDFSecurityOptions()
        encOpts.mode = .encrypt
        encOpts.ownerPassword = "Owner!123"
        encOpts.userPassword = "User!123"
        _ = try PDFSecurityService.applySecurity(inputURL: validPDF, outputURL: secDest, options: encOpts)
        XCTAssertTrue(try PDFDocumentInspector.inspect(url: secDest, password: "Owner!123").isEncrypted)

        let secBeforeFailHash = try sha256Hex(of: secDest)
        var badDecOpts = PDFSecurityOptions()
        badDecOpts.mode = .decrypt
        badDecOpts.currentPassword = "WrongPassword"
        XCTAssertThrowsError(try PDFSecurityService.applySecurity(inputURL: secDest, outputURL: secDest, options: badDecOpts))
        XCTAssertEqual(try sha256Hex(of: secDest), secBeforeFailHash)

        let otherDest = dir.appendingPathComponent("other_sentinel.pdf")
        try Data("KEEP-OTHER-SENTINEL".utf8).write(to: otherDest)
        let otherHash = try sha256Hex(of: otherDest)
        XCTAssertThrowsError(try PDFSecurityService.applySecurity(inputURL: secDest, outputURL: otherDest, options: badDecOpts))
        XCTAssertEqual(try sha256Hex(of: otherDest), otherHash, "Failed security operation must preserve existing destination")

        // 2) PDFPageManagementService: writeAtomicallyAndVerify & split failure preserve existing destination
        let pageDest = dir.appendingPathComponent("page_dest.pdf")
        try Data("SENTINEL-PAGE-DEST".utf8).write(to: pageDest)
        let pageDoc = try XCTUnwrap(PDFDocument(url: validPDF))
        try PDFPageManagementService.writeAtomicallyAndVerify(document: pageDoc, to: pageDest, expectedPageCount: 2)
        XCTAssertEqual(PDFDocument(url: pageDest)?.pageCount, 2)

        let splitOutDir = dir.appendingPathComponent("split_out", isDirectory: true)
        try FileManager.default.createDirectory(at: splitOutDir, withIntermediateDirectories: true)
        let existingSplit1 = splitOutDir.appendingPathComponent("doc_part1.pdf")
        try Data("SENTINEL-SPLIT-1".utf8).write(to: existingSplit1)
        let split1Hash = try sha256Hex(of: existingSplit1)
        do {
            _ = try await PDFPageManagementService.split(
                input: corruptPDF,
                strategy: .everyPage,
                outputDirectory: splitOutDir,
                baseName: "doc",
                existingFileHandling: .overwrite,
                progress: { _ in }
            )
            XCTFail("Expected split on corrupt PDF to fail")
        } catch {
            XCTAssertEqual(try sha256Hex(of: existingSplit1), split1Hash)
        }

        // 3) PDFAnnotationService: atomic overwrite & failure preservation
        let annotDest = dir.appendingPathComponent("annot_dest.pdf")
        try Data("SENTINEL-ANNOT-DEST".utf8).write(to: annotDest)
        _ = try await PDFAnnotationService.applyAndSave(
            inputURL: validPDF,
            outputURL: annotDest,
            options: PDFAnnotationSaveOptions(),
            progress: { _ in }
        )
        XCTAssertEqual(PDFDocument(url: annotDest)?.pageCount, 2)

        let annotHash = try sha256Hex(of: annotDest)
        do {
            _ = try await PDFAnnotationService.applyAndSave(
                inputURL: corruptPDF,
                outputURL: annotDest,
                options: PDFAnnotationSaveOptions(),
                progress: { _ in }
            )
            XCTFail("Expected annotation save on corrupt PDF to fail")
        } catch {
            XCTAssertEqual(try sha256Hex(of: annotDest), annotHash)
        }

        // 4) PDFFormService: atomic overwrite & failure preservation
        let formDest = dir.appendingPathComponent("form_dest.pdf")
        try Data("SENTINEL-FORM-DEST".utf8).write(to: formDest)
        _ = try PDFFormService.applyAndSave(inputURL: validPDF, outputURL: formDest, editedFields: [], flatten: false)
        XCTAssertEqual(PDFDocument(url: formDest)?.pageCount, 2)

        let formHash = try sha256Hex(of: formDest)
        XCTAssertThrowsError(try PDFFormService.applyAndSave(inputURL: corruptPDF, outputURL: formDest, editedFields: [], flatten: false))
        XCTAssertEqual(try sha256Hex(of: formDest), formHash)

        // 5) PDFCompressionService: atomic overwrite & failure preservation
        let compDest = dir.appendingPathComponent("comp_dest.pdf")
        try Data("SENTINEL-COMP-DEST".utf8).write(to: compDest)
        let compRes = try await PDFCompressionService.compress(
            inputURL: validPDF,
            outputURL: compDest,
            options: .forProfile(.maximumQuality),
            progress: { _ in }
        )
        XCTAssertEqual(compRes.pageCount, 2)

        let compHash = try sha256Hex(of: compDest)
        do {
            _ = try await PDFCompressionService.compress(
                inputURL: corruptPDF,
                outputURL: compDest,
                options: .forProfile(.balanced),
                progress: { _ in }
            )
            XCTFail("Expected compression on corrupt PDF to fail")
        } catch {
            XCTAssertEqual(try sha256Hex(of: compDest), compHash)
        }

        // 6) PDFRedactionService: atomic overwrite & failure preservation
        let redactDest = dir.appendingPathComponent("redact_dest.pdf")
        try Data("SENTINEL-REDACT-DEST".utf8).write(to: redactDest)
        var redactOpts = PDFRedactionOptions()
        redactOpts.searchTerms = ["Confidential"]
        redactOpts.renderDPI = 150.0
        let redactRes = try await PDFRedactionService.redact(
            inputURL: validPDF,
            outputURL: redactDest,
            options: redactOpts,
            progress: { _ in }
        )
        XCTAssertTrue(redactRes.isVerifiedClean)

        let redactHash = try sha256Hex(of: redactDest)
        do {
            _ = try await PDFRedactionService.redact(
                inputURL: corruptPDF,
                outputURL: redactDest,
                options: redactOpts,
                progress: { _ in }
            )
            XCTFail("Expected redaction on corrupt PDF to fail")
        } catch {
            XCTAssertEqual(try sha256Hex(of: redactDest), redactHash)
        }
    }

    // MARK: - LC-001: PDFConversionEngine Temp Staging & Atomic Commit

    func testPDFConversionEngineStagesAndCommitsAtomicallyUnderOverwrite() async throws {
        let dir = try makeTempDir(prefix: "M1B-PDFEngine-Overwrite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("sample.pdf")
        try writeVectorPDF(at: pdfURL, pages: ["Alpha", "Beta"])

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let prePage1 = outDir.appendingPathComponent("sample-1.png")
        let prePage2 = outDir.appendingPathComponent("sample-2.png")
        try Data("OLD-PAGE-1".utf8).write(to: prePage1)
        try Data("OLD-PAGE-2".utf8).write(to: prePage2)

        let engine = PDFConversionEngine()
        var opts = ConversionOptions.default
        opts.overwriteExisting = true
        opts.pdfDPI = 72.0

        let result = try await engine.convert(
            inputs: [pdfURL],
            to: .png,
            outputDirectory: outDir,
            options: opts,
            progress: { _ in }
        )

        XCTAssertEqual(result.outputURL.standardizedFileURL, prePage1.standardizedFileURL)
        XCTAssertEqual(result.additionalOutputURLs.map(\.standardizedFileURL), [prePage2.standardizedFileURL])
        XCTAssertNotNil(CGImageSourceCreateWithURL(prePage1 as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateWithURL(prePage2 as CFURL, nil))
    }

    func testPDFConversionEnginePreservesExistingDestinationOnCancellationAndSkipPolicy() async throws {
        let dir = try makeTempDir(prefix: "M1B-PDFEngine-Cancel")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("sample.pdf")
        try writeVectorPDF(at: pdfURL, pages: ["Page One", "Page Two"])

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let prePage1 = outDir.appendingPathComponent("sample-1.png")
        let prePage2 = outDir.appendingPathComponent("sample-2.png")
        try Data("KEEP-PAGE-1-SENTINEL".utf8).write(to: prePage1)
        try Data("KEEP-PAGE-2-SENTINEL".utf8).write(to: prePage2)
        let hash1 = try sha256Hex(of: prePage1)
        let hash2 = try sha256Hex(of: prePage2)

        let engine = PDFConversionEngine()
        var overwriteOpts = ConversionOptions.default
        overwriteOpts.overwriteExisting = true
        overwriteOpts.pdfDPI = 72.0

        let cancelledTask = Task {
            try await engine.convert(
                inputs: [pdfURL],
                to: .png,
                outputDirectory: outDir,
                options: overwriteOpts,
                progress: { _ in }
            )
        }
        cancelledTask.cancel()

        do {
            _ = try await cancelledTask.value
            XCTFail("Expected pre-cancelled PDF conversion task to throw")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertEqual(try sha256Hex(of: prePage1), hash1, "Pre-existing page 1 must survive cancelled overwrite conversion")
        XCTAssertEqual(try sha256Hex(of: prePage2), hash2, "Pre-existing page 2 must survive cancelled overwrite conversion")

        // Verify .skip policy also preserves pre-existing single-page output
        let singlePDF = dir.appendingPathComponent("single.pdf")
        try writeVectorPDF(at: singlePDF, pages: ["Single Page"])
        let existingSingle = outDir.appendingPathComponent("single.png")
        try Data("SKIP-SENTINEL".utf8).write(to: existingSingle)
        let singleHash = try sha256Hex(of: existingSingle)

        var skipOpts = ConversionOptions.default
        skipOpts.customOptions["existing_file_handling"] = ExistingFileHandling.skip.rawValue
        do {
            _ = try await engine.convert(
                inputs: [singlePDF],
                to: .png,
                outputDirectory: outDir,
                options: skipOpts,
                progress: { _ in }
            )
            XCTFail("Expected ConversionError.outputFileAlreadyExists")
        } catch let err as ConversionError {
            XCTAssertEqual(err, .outputFileAlreadyExists(existingSingle))
        }
        XCTAssertEqual(try sha256Hex(of: existingSingle), singleHash)
    }

    // MARK: - LC-001: ImageConversionEngine & ImageMetadataInspectorService Atomic Commit

    func testImageConversionEngineAndMetadataServicePreserveExistingDestinationOnFailureOrCancellation() async throws {
        let dir = try makeTempDir(prefix: "M1B-ImageEngine")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcPNG = dir.appendingPathComponent("photo.png")
        try writeTinyPNG(to: srcPNG)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let existingJPG = outDir.appendingPathComponent("photo.jpg")
        try Data("KEEP-IMAGE-SENTINEL".utf8).write(to: existingJPG)
        let sentinelHash = try sha256Hex(of: existingJPG)

        let engine = ImageConversionEngine()
        var overwriteOpts = ConversionOptions.default
        overwriteOpts.overwriteExisting = true

        // Cancelled conversion under .overwrite must not delete or corrupt existingJPG
        let cancelledTask = Task {
            try await engine.convert(
                inputs: [srcPNG],
                to: .jpg,
                outputDirectory: outDir,
                options: overwriteOpts,
                progress: { _ in }
            )
        }
        cancelledTask.cancel()

        do {
            _ = try await cancelledTask.value
            XCTFail("Expected pre-cancelled image conversion task to throw")
        } catch is CancellationError {
            // Expected
        }
        XCTAssertEqual(try sha256Hex(of: existingJPG), sentinelHash)

        // Successful .overwrite commits atomically
        let okResult = try await engine.convert(
            inputs: [srcPNG],
            to: .jpg,
            outputDirectory: outDir,
            options: overwriteOpts,
            progress: { _ in }
        )
        XCTAssertEqual(okResult.outputURL.standardizedFileURL, existingJPG.standardizedFileURL)
        XCTAssertNotNil(CGImageSourceCreateWithURL(existingJPG as CFURL, nil))

        // ImageMetadataInspectorService atomic metadata strip & failure preservation
        let gpsJPG = dir.appendingPathComponent("gps_src.jpg")
        try writeJPEGWithGPSAndCameraEXIF(to: gpsJPG)

        let metaDest = dir.appendingPathComponent("meta_dest.jpg")
        try Data("SENTINEL-META-DEST".utf8).write(to: metaDest)
        var stripAll = ImageMetadataEditPayload()
        stripAll.policy = .stripAll

        let metaRes = try await ImageMetadataInspectorService.writeMetadataAndDPINonDestructively(
            from: gpsJPG,
            to: metaDest,
            payload: stripAll
        )
        XCTAssertTrue(metaRes.wasLosslessPixelCopy)
        let afterSnap = ImageMetadataInspectorService.inspectDetailed(url: metaDest)
        XCTAssertNil(afterSnap.gpsLatitude)
        XCTAssertNil(afterSnap.cameraMake)

        let metaDestHash = try sha256Hex(of: metaDest)
        let missingSrc = dir.appendingPathComponent("does_not_exist.jpg")
        do {
            _ = try await ImageMetadataInspectorService.writeMetadataAndDPINonDestructively(
                from: missingSrc,
                to: metaDest,
                payload: stripAll
            )
            XCTFail("Expected missing source metadata write to throw")
        } catch {
            XCTAssertEqual(try sha256Hex(of: metaDest), metaDestHash, "Failed metadata write must preserve destination")
        }
    }

    // MARK: - LC-009: JXL Reconstruction Privacy Enforcement

    func testJXLReconstructJPEGStripsMetadataWhenPreserveMetadataFalse() async throws {
        let dir = try makeTempDir(prefix: "M1B-LC009-Strip")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gpsJPG = dir.appendingPathComponent("sensitive.jpg")
        try writeJPEGWithGPSAndCameraEXIF(to: gpsJPG)

        let beforeSnap = ImageMetadataInspectorService.inspectDetailed(url: gpsJPG)
        XCTAssertNotNil(beforeSnap.gpsLatitude)
        XCTAssertEqual(beforeSnap.cameraMake, "PrivacyTestCam")

        let jpegBytes = try Data(contentsOf: gpsJPG)
        let jxlBytes = try JPEGXLCodec.transcodeJPEG(jpegData: jpegBytes, effort: 5, storeJPEGMetadata: true)
        let jxlURL = dir.appendingPathComponent("sensitive.jxl")
        try jxlBytes.write(to: jxlURL)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let engine = ImageConversionEngine()
        var opts = ConversionOptions.default
        opts.preserveMetadata = false
        opts.customOptions["jxl_reconstruct_jpeg"] = "true"

        let res = try await engine.convert(
            inputs: [jxlURL],
            to: .jpg,
            outputDirectory: outDir,
            options: opts,
            progress: { _ in }
        )

        let afterSnap = ImageMetadataInspectorService.inspectDetailed(url: res.outputURL)
        XCTAssertNil(afterSnap.gpsLatitude, "GPS latitude must be stripped when preserveMetadata is false")
        XCTAssertNil(afterSnap.gpsLongitude, "GPS longitude must be stripped when preserveMetadata is false")
        XCTAssertNil(afterSnap.cameraMake, "EXIF/TIFF camera make must be stripped when preserveMetadata is false")
        XCTAssertNil(afterSnap.cameraModel, "EXIF/TIFF camera model must be stripped when preserveMetadata is false")
    }

    func testJXLReconstructJPEGNeverFallsBackToUnstrippedBytesOnDecodeFailure() throws {
        let unstrippedSecretPayload = Data("FAKE-JPEG-WITH-SENSITIVE-GPS-EXIF-DATA".utf8)

        // preserveMetadata == true returns original reconstructed bitstream untouched
        let preserved = try ImageConversionEngine.finalizeReconstructedJPEGData(
            unstrippedSecretPayload,
            preserveMetadata: true,
            quality: 0.9
        )
        XCTAssertEqual(preserved, unstrippedSecretPayload)

        // preserveMetadata == false MUST throw ConversionError instead of falling back to unstripped bytes
        XCTAssertThrowsError(
            try ImageConversionEngine.finalizeReconstructedJPEGData(
                unstrippedSecretPayload,
                preserveMetadata: false,
                quality: 0.9
            )
        ) { error in
            guard case ConversionError.engineExecutionFailed = error else {
                XCTFail("Expected ConversionError.engineExecutionFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - LC-001 Remediation: PDFGridPageSplitter, PDFOCRService, PDFToolboxEngine

    private func writeTwoByTwoMultiUpPDF(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 800, height: 600)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "M1BTests", code: 4)
        }
        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
        ]
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.setFillColor(.white)
        ctx.fill(mediaBox)

        let cells = PDFGridLayout.twoByTwo.cellRects(for: mediaBox)
        for (idx, rect) in cells.enumerated() {
            let inset = rect.insetBy(dx: 24, dy: 24)
            ctx.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 0.25))
            ctx.fill(inset)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 20),
                .foregroundColor: NSColor.black
            ]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("Cell \(idx + 1)" as NSString).draw(at: NSPoint(x: rect.minX + 32, y: rect.midY), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    func testPDFGridPageSplitterCommitsAtomicallyAndPreservesExistingDestinationOnFailure() async throws {
        let dir = try makeTempDir(prefix: "M1B-GridSplit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let multiUpPDF = dir.appendingPathComponent("multiup.pdf")
        try writeTwoByTwoMultiUpPDF(at: multiUpPDF)
        let corruptPDF = dir.appendingPathComponent("corrupt.pdf")
        try Data("NOT-A-VALID-PDF".utf8).write(to: corruptPDF)

        let gridDest = dir.appendingPathComponent("grid_dest.pdf")
        try Data("SENTINEL-GRID-DEST".utf8).write(to: gridDest)
        let sentinelHash = try sha256Hex(of: gridDest)

        // Failure on corrupt input must preserve existing destination (no defer removeItem)
        do {
            _ = try await PDFGridPageSplitter.split(
                input: corruptPDF,
                outputURL: gridDest,
                layout: .twoByTwo,
                progress: { _ in }
            )
            XCTFail("Expected grid split on corrupt PDF to fail")
        } catch {
            XCTAssertEqual(try sha256Hex(of: gridDest), sentinelHash, "Failed grid split must preserve existing destination")
        }

        // Cancelled task must also preserve existing destination
        let cancelledTask = Task {
            try await PDFGridPageSplitter.split(
                input: multiUpPDF,
                outputURL: gridDest,
                layout: .twoByTwo,
                progress: { _ in }
            )
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected cancelled grid split to throw")
        } catch is CancellationError {
            // Expected
        }
        XCTAssertEqual(try sha256Hex(of: gridDest), sentinelHash, "Cancelled grid split must preserve existing destination")

        // Valid split commits atomically over existing destination
        let result = try await PDFGridPageSplitter.split(
            input: multiUpPDF,
            outputURL: gridDest,
            layout: .twoByTwo,
            progress: { _ in }
        )
        XCTAssertEqual(result.outputURL.standardizedFileURL, gridDest.standardizedFileURL)
        XCTAssertEqual(result.extractedPagesCount, 4)
        XCTAssertEqual(PDFDocument(url: gridDest)?.pageCount, 4)
    }

    func testPDFOCRServiceCommitsAtomicallyAndPreservesExistingDestinationOnFailure() async throws {
        let dir = try makeTempDir(prefix: "M1B-PDFOCR")
        defer { try? FileManager.default.removeItem(at: dir) }

        let validPDF = dir.appendingPathComponent("searchable.pdf")
        try writeVectorPDF(
            at: validPDF,
            pages: [
                "Searchable vector page one with sufficient existing text",
                "Searchable vector page two with sufficient existing text"
            ]
        )
        let corruptPDF = dir.appendingPathComponent("corrupt.pdf")
        try Data("NOT-A-VALID-PDF".utf8).write(to: corruptPDF)

        let ocrDest = dir.appendingPathComponent("ocr_dest.pdf")
        try Data("SENTINEL-OCR-DEST".utf8).write(to: ocrDest)
        let sentinelHash = try sha256Hex(of: ocrDest)

        var ocrOpts = PDFOCROptions()
        ocrOpts.skipExistingTextPages = true

        // Failure on corrupt input must preserve existing destination
        do {
            _ = try await PDFOCRService.runOCR(
                inputURL: corruptPDF,
                outputPDFURL: ocrDest,
                options: ocrOpts,
                progress: { _ in }
            )
            XCTFail("Expected OCR on corrupt PDF to fail")
        } catch {
            XCTAssertEqual(try sha256Hex(of: ocrDest), sentinelHash, "Failed OCR must preserve existing destination")
        }

        // Cancelled task must preserve existing destination
        let cancelledTask = Task {
            try await PDFOCRService.runOCR(
                inputURL: validPDF,
                outputPDFURL: ocrDest,
                options: ocrOpts,
                progress: { _ in }
            )
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected cancelled OCR task to throw")
        } catch is CancellationError {
            // Expected
        }
        XCTAssertEqual(try sha256Hex(of: ocrDest), sentinelHash, "Cancelled OCR must preserve existing destination")

        // Valid runOCR commits atomically via OutputReservationCoordinator
        let ocrResult = try await PDFOCRService.runOCR(
            inputURL: validPDF,
            outputPDFURL: ocrDest,
            options: ocrOpts,
            progress: { _ in }
        )
        XCTAssertEqual(ocrResult.outputPDFURL.standardizedFileURL, ocrDest.standardizedFileURL)
        XCTAssertEqual(PDFDocument(url: ocrDest)?.pageCount, 2)
    }

    func testPDFToolboxEnginePDFToImagesStagesAndPreservesExistingDestinationsOnCancelAndSkip() async throws {
        let dir = try makeTempDir(prefix: "M1B-ToolboxImages")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("sample.pdf")
        try writeVectorPDF(at: pdfURL, pages: ["Toolbox Page 1", "Toolbox Page 2"])

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let prePage1 = outDir.appendingPathComponent("sample_page_1.png")
        let prePage2 = outDir.appendingPathComponent("sample_page_2.png")
        try Data("KEEP-TOOLBOX-PAGE-1".utf8).write(to: prePage1)
        try Data("KEEP-TOOLBOX-PAGE-2".utf8).write(to: prePage2)
        let hash1 = try sha256Hex(of: prePage1)
        let hash2 = try sha256Hex(of: prePage2)

        let engine = PDFToolboxEngine()
        var overwriteOpts = ConversionOptions.default
        overwriteOpts.overwriteExisting = true
        overwriteOpts.pdfDPI = 72.0
        overwriteOpts.customOptions["pdf_operation"] = "pdfToImages"

        // Cancelled task under .overwrite must preserve pre-existing destinations
        let cancelledTask = Task { [overwriteOpts] in
            try await engine.convert(
                inputs: [pdfURL],
                to: .png,
                outputDirectory: outDir,
                options: overwriteOpts,
                progress: { _ in }
            )
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected cancelled PDFToolboxEngine pdfToImages task to throw")
        } catch is CancellationError {
            // Expected
        }
        XCTAssertEqual(try sha256Hex(of: prePage1), hash1, "Pre-existing page 1 must survive cancelled overwrite")
        XCTAssertEqual(try sha256Hex(of: prePage2), hash2, "Pre-existing page 2 must survive cancelled overwrite")

        // .skip policy must preserve pre-existing page
        let singlePDF = dir.appendingPathComponent("single.pdf")
        try writeVectorPDF(at: singlePDF, pages: ["Single Toolbox Page"])
        let existingSingle = outDir.appendingPathComponent("single_page_1.png")
        try Data("SKIP-TOOLBOX-SENTINEL".utf8).write(to: existingSingle)
        let singleHash = try sha256Hex(of: existingSingle)

        var skipOpts = ConversionOptions.default
        skipOpts.pdfDPI = 72.0
        skipOpts.customOptions["pdf_operation"] = "pdfToImages"
        skipOpts.customOptions["existing_file_handling"] = ExistingFileHandling.skip.rawValue
        do {
            _ = try await engine.convert(
                inputs: [singlePDF],
                to: .png,
                outputDirectory: outDir,
                options: skipOpts,
                progress: { _ in }
            )
            XCTFail("Expected ConversionError.outputFileAlreadyExists")
        } catch let err as ConversionError {
            XCTAssertEqual(err, .outputFileAlreadyExists(existingSingle))
        }
        XCTAssertEqual(try sha256Hex(of: existingSingle), singleHash)

        // Successful .overwrite commits staged pages atomically
        let result = try await engine.convert(
            inputs: [pdfURL],
            to: .png,
            outputDirectory: outDir,
            options: overwriteOpts,
            progress: { _ in }
        )
        XCTAssertEqual(result.outputURL.standardizedFileURL, prePage1.standardizedFileURL)
        XCTAssertEqual(result.additionalOutputURLs.map(\.standardizedFileURL), [prePage2.standardizedFileURL])
        XCTAssertNotNil(CGImageSourceCreateWithURL(prePage1 as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateWithURL(prePage2 as CFURL, nil))
    }
}

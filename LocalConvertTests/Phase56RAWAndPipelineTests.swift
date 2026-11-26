import XCTest
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Phase56RAWAndPipelineTests: XCTestCase {

    private func makeSandbox(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P56-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeRichOrientation6JPEG(to url: URL) throws {
        // Draw asymmetric 40x20 image so EXIF Orientation 6 (90 deg CW) produces 20x40 upright pixels
        let width = 40
        let height = 20
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Phase56Tests", code: 1, userInfo: nil)
        }
        ctx.setFillColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.95, green: 0.25, blue: 0.20, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: height))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Phase56Tests", code: 2, userInfo: nil)
        }
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyDPIWidth: 300.0,
            kCGImagePropertyDPIHeight: 300.0,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "TestCam",
                kCGImagePropertyTIFFModel: "Model Z9",
                kCGImagePropertyTIFFSoftware: "LocalConvertTestFirmware",
                kCGImagePropertyTIFFArtist: "Phase 56 Auditor",
                kCGImagePropertyTIFFCopyright: "2026 Test Notice",
                kCGImagePropertyTIFFOrientation: 6
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:22 10:00:00",
                kCGImagePropertyExifLensModel: "35mm f/1.4",
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifExposureTime: 0.008
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCHeadline: "Phase 56 Headline",
                kCGImagePropertyIPTCCaptionAbstract: "Phase 56 Caption",
                kCGImagePropertyIPTCByline: "Phase 56 Byline",
                kCGImagePropertyIPTCCopyrightNotice: "IPTC Notice",
                kCGImagePropertyIPTCKeywords: ["raw", "pipeline"]
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.8688,
                kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 74.0060,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 42.5
            ] as [CFString: Any]
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - 1. Genuine Camera RAW Verification (Gated on LOCALCONVERT_RAW_SAMPLES_DIR)

    func testGenuineCameraRAWSamplesMatrixIfProvided() async throws {
        guard let samplesPath = ProcessInfo.processInfo.environment["LOCALCONVERT_RAW_SAMPLES_DIR"],
              !samplesPath.isEmpty else {
            throw XCTSkip("BLOCKED / UNVERIFIED: Genuine camera RAW sample directory not configured via LOCALCONVERT_RAW_SAMPLES_DIR.")
        }

        let samplesDir = URL(fileURLWithPath: samplesPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: samplesDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCTSkip("BLOCKED / UNVERIFIED: LOCALCONVERT_RAW_SAMPLES_DIR is not an existing directory: \(samplesPath)")
        }

        let rawExtensions = Set(FileFormat.allCases.filter(\.isRawImage).map { $0.fileExtension.lowercased() }
            + ["raw", "rwl", "3fr", "fff", "iiq", "dcr", "mrw", "sr2", "srf", "erf", "crw", "mos"])

        let contents = try FileManager.default.contentsOfDirectory(at: samplesDir, includingPropertiesForKeys: nil)
        let rawFiles = contents
            .filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !rawFiles.isEmpty else {
            throw XCTSkip("BLOCKED / UNVERIFIED: No genuine camera RAW files found in LOCALCONVERT_RAW_SAMPLES_DIR (\(samplesPath)).")
        }

        let sandbox = try makeSandbox(name: "GenuineRAW")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let detector = FileDetector()
        let provider = ImageMetadataProvider()
        let engine = ImageConversionEngine()

        for sourceURL in rawFiles {
            let hashBefore = try sha256Hex(of: sourceURL)
            let detected = detector.detect(url: sourceURL).bestFormat
            let inspected = ImageSourcePipeline.inspectProperties(url: sourceURL, isRAWHint: true)
            let imageIORecognized = (inspected != nil)
            let ciRAWResult = ImageSourcePipeline.renderWithCIRAWFilter(url: sourceURL)
            let thumb = inspected.flatMap { ImageSourcePipeline.extractThumbnail(from: $0.source, maxPixelSize: 320) }
            let doc = try? await provider.readMetadata(from: sourceURL)
            let detail = ImageMetadataInspectorService.inspectDetailed(url: sourceURL)

            let perOut = sandbox.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: perOut, withIntermediateDirectories: true)

            var convertedOK = 0
            for target in [FileFormat.jpg, .png, .tiff] {
                if let res = try? await engine.convert(inputs: [sourceURL], to: target, outputDirectory: perOut, options: .default, progress: { _ in }),
                   let reopened = ImageSourcePipeline.inspectProperties(url: res.outputURL, isRAWHint: false),
                   let dims = ImageSourcePipeline.orientedDimensions(from: reopened.properties),
                   dims.width > 0 && dims.height > 0 {
                    convertedOK += 1
                }
            }

            let classification: String
            if convertedOK == 3 && (ciRAWResult != nil || imageIORecognized) {
                classification = "SUPPORTED AND VERIFIED"
            } else if convertedOK > 0 || thumb != nil {
                classification = "PARTIALLY SUPPORTED"
            } else if imageIORecognized || !(doc?.technical["dimensions"] ?? "").isEmpty || detail.pixelWidth > 0 {
                classification = "RECOGNIZED BUT NOT RENDERABLE"
            } else {
                classification = "UNSUPPORTED"
            }
            print("[Phase56-RAW] file=\(sourceURL.lastPathComponent) detected=\(detected?.fileExtension ?? "nil") imageIO=\(imageIORecognized) ciRAW=\(ciRAWResult != nil) thumb=\(thumb != nil) metaDims=\(detail.pixelWidth)x\(detail.pixelHeight) conv=\(convertedOK)/3 status=\(classification)")

            XCTAssertEqual(try sha256Hex(of: sourceURL), hashBefore, "Read-only original RAW file must never be mutated")
        }
    }

    // MARK: - 2. Corrupt & Unsupported RAW Handling

    func testCorruptAndUnsupportedRAWFailSafelyAcrossPipeline() async throws {
        let sandbox = try makeSandbox(name: "CorruptRAW")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let inDir = sandbox.appendingPathComponent("in", isDirectory: true)
        let outDir = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let engine = ImageConversionEngine()
        let samples: [(String, Data)] = [
            ("bad.cr3", Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x63, 0x72, 0x78, 0x20])),
            ("bad.nef", Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])),
            ("bad.arw", Data([0x49, 0x49, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00])),
            ("bad.dng", Data([0x49, 0x49, 0x2A, 0x00, 0xFF, 0xFF, 0x00, 0x00]))
        ]

        for (name, bytes) in samples {
            let fileURL = inDir.appendingPathComponent(name)
            try bytes.write(to: fileURL)
            let beforeHash = try sha256Hex(of: fileURL)

            XCTAssertNil(ImageSourcePipeline.renderWithCIRAWFilter(url: fileURL))

            do {
                _ = try await engine.convert(inputs: [fileURL], to: .jpg, outputDirectory: outDir, options: .default) { _ in }
                XCTFail("Expected ConversionError for corrupt \(name)")
            } catch ConversionError.invalidInput {
                // expected safe failure
            }

            XCTAssertEqual(try sha256Hex(of: fileURL), beforeHash)
        }

        let leftovers = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: - 3. Unified Metadata Extraction Parity (Provider vs Inspector)

    func testUnifiedMetadataExtractionConsistencyBetweenProviderAndInspector() async throws {
        let sandbox = try makeSandbox(name: "MetadataParity")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let jpgURL = sandbox.appendingPathComponent("rich_orient6.jpg")
        try writeRichOrientation6JPEG(to: jpgURL)

        let provider = ImageMetadataProvider()
        let doc = try await provider.readMetadata(from: jpgURL)
        let snap = ImageMetadataInspectorService.inspectDetailed(url: jpgURL)
        let dims = ImageProcessingService.inspectSourceDimensions(url: jpgURL)

        // Orientation 6 swaps 40x20 -> 20x40 across both services
        XCTAssertEqual(dims?.width, 20)
        XCTAssertEqual(dims?.height, 40)
        XCTAssertEqual(snap.pixelWidth, 20)
        XCTAssertEqual(snap.pixelHeight, 40)
        XCTAssertEqual(doc.technical["dimensions"], "20 × 40 px")

        // Camera & EXIF parity
        XCTAssertEqual(doc.common.cameraMake, snap.cameraMake)
        XCTAssertEqual(doc.common.cameraModel, snap.cameraModel)
        XCTAssertEqual(doc.common.lensModel, snap.lensModel)
        XCTAssertEqual(doc.common.cameraMake, "TestCam")
        XCTAssertEqual(doc.common.cameraModel, "Model Z9")
        XCTAssertEqual(doc.common.lensModel, "35mm f/1.4")
        XCTAssertEqual(doc.common.iso, 200)
        XCTAssertEqual(doc.common.yearString, "2026")
        XCTAssertEqual(snap.dateTaken, "2026:11:22 10:00:00")
        XCTAssertEqual(snap.software, "LocalConvertTestFirmware")

        // Signed GPS parity (S -> negative, W -> negative)
        let gps = try XCTUnwrap(doc.gps)
        let snapLat = try XCTUnwrap(snap.gpsLatitude)
        let snapLon = try XCTUnwrap(snap.gpsLongitude)
        XCTAssertEqual(gps.latitude, snapLat, accuracy: 0.0001)
        XCTAssertEqual(gps.longitude, snapLon, accuracy: 0.0001)
        XCTAssertEqual(gps.latitude, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(gps.longitude, -74.0060, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snap.gpsAltitude), 42.5, accuracy: 0.01)
    }

    // MARK: - 4. Orientation & Metadata Preservation Across Conversion and Toolbox

    func testOrientationAndMetadataPreservationConsistencyAcrossConversionAndToolbox() async throws {
        let sandbox = try makeSandbox(name: "OrientConvert")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let srcURL = sandbox.appendingPathComponent("orient6.jpg")
        try writeRichOrientation6JPEG(to: srcURL)

        let engine = ImageConversionEngine()

        // 1) Engine convert with preserveMetadata: true
        let keepDir = sandbox.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: keepDir, withIntermediateDirectories: true)
        var keepOpts = ConversionOptions.default
        keepOpts.preserveMetadata = true
        let keepRes = try await engine.convert(inputs: [srcURL], to: .png, outputDirectory: keepDir, options: keepOpts) { _ in }
        let keepSnap = ImageMetadataInspectorService.inspectDetailed(url: keepRes.outputURL)
        XCTAssertEqual(keepSnap.pixelWidth, 20)
        XCTAssertEqual(keepSnap.pixelHeight, 40)
        XCTAssertEqual(keepSnap.cameraMake, "TestCam")
        XCTAssertNotNil(keepSnap.gpsLatitude)
        if let inspected = ImageSourcePipeline.inspectProperties(url: keepRes.outputURL, isRAWHint: false) {
            XCTAssertEqual(ImageSourcePipeline.orientation(from: inspected.properties), .up)
        } else {
            XCTFail("Failed to reopen converted output")
        }

        // 2) Engine convert with preserveMetadata: false strips GPS/EXIF cleanly while keeping upright dimensions
        let stripDir = sandbox.appendingPathComponent("strip", isDirectory: true)
        try FileManager.default.createDirectory(at: stripDir, withIntermediateDirectories: true)
        var stripOpts = ConversionOptions.default
        stripOpts.preserveMetadata = false
        let stripRes = try await engine.convert(inputs: [srcURL], to: .png, outputDirectory: stripDir, options: stripOpts) { _ in }
        let stripSnap = ImageMetadataInspectorService.inspectDetailed(url: stripRes.outputURL)
        XCTAssertEqual(stripSnap.pixelWidth, 20)
        XCTAssertEqual(stripSnap.pixelHeight, 40)
        XCTAssertNil(stripSnap.gpsLatitude)
        XCTAssertNil(stripSnap.cameraMake)

        // 3) Image Toolbox processToFile matches oriented pixel geometry
        let toolboxDir = sandbox.appendingPathComponent("toolbox", isDirectory: true)
        try FileManager.default.createDirectory(at: toolboxDir, withIntermediateDirectories: true)
        let toolboxRes = try await ImageProcessingService.processToFile(
            inputURL: srcURL,
            outputFormat: .png,
            outputDirectory: toolboxDir,
            config: ImageToolboxConfig()
        )
        let tbDims = ImageProcessingService.inspectSourceDimensions(url: toolboxRes.outputURL)
        XCTAssertEqual(tbDims?.width, 20)
        XCTAssertEqual(tbDims?.height, 40)
    }

    // MARK: - 5. MetadataManager Save Copy & Undo Safety Unchanged

    func testMetadataManagerSaveCopyAndUndoSafetyUnchanged() async throws {
        let sandbox = try makeSandbox(name: "MetaSaveCopy")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let srcURL = sandbox.appendingPathComponent("source.jpg")
        try writeRichOrientation6JPEG(to: srcURL)
        let beforeHash = try sha256Hex(of: srcURL)

        let registry = MetadataRegistry.shared
        if registry.provider(for: .jpg) == nil {
            registry.register(provider: ImageMetadataProvider())
        }
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.appendingPathComponent("journal", isDirectory: true),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.appendingPathComponent("artifacts", isDirectory: true))
        )
        let history = HistoryManager(fileURL: sandbox.appendingPathComponent("history.json"))
        let manager = MetadataManager(
            undoCoordinator: undoCoord,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.appendingPathComponent("meta_artifacts", isDirectory: true)),
            historyManager: history
        )

        await manager.load(url: srcURL)
        manager.updateField(id: "title", value: .string("Updated Phase 56 Copy"))

        let copyURL = sandbox.appendingPathComponent("saved_copy.jpg")
        let resultURL = await manager.saveCopy(to: copyURL)
        XCTAssertNotNil(resultURL)
        XCTAssertEqual(try sha256Hex(of: srcURL), beforeHash, "Save Copy must never alter original image")
        XCTAssertEqual(history.items.count, 1)

        let copyDoc = try await ImageMetadataProvider().readMetadata(from: copyURL)
        XCTAssertEqual(copyDoc.common.title, "Updated Phase 56 Copy")
    }
}

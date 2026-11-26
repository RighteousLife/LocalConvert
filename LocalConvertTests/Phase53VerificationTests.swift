import XCTest
import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Phase53VerificationTests: XCTestCase {

    // MARK: - Helpers

    private func makeSandbox(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P53Verify-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isNonBlankCGImage(_ cgImage: CGImage) -> Bool {
        let sampleW = min(cgImage.width, 16)
        let sampleH = min(cgImage.height, 16)
        guard sampleW > 0, sampleH > 0 else { return false }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return false
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        var hasVariation = false
        let firstR = pixels[0]
        let firstG = pixels[1]
        let firstB = pixels[2]
        var nonZeroAlpha = false
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i + 3] > 0 { nonZeroAlpha = true }
            if pixels[i] != firstR || pixels[i + 1] != firstG || pixels[i + 2] != firstB {
                hasVariation = true
                break
            }
        }
        return nonZeroAlpha && (hasVariation || firstR != 0 || firstG != 0 || firstB != 0)
    }

    // MARK: - 1. RAW Format Registration & Read-Only Enforcement

    func testRAWFormatRegistrationAndReadOnlyEnforcement() {
        let rawFormats: [FileFormat] = [.dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw]
        let capabilityRegistry = FormatCapabilityRegistry.shared
        let imageEngine = ImageConversionEngine()
        let metadataProvider = ImageMetadataProvider()

        let dngAliases = ["raw", "rwl", "3fr", "fff", "iiq", "dcr", "mrw", "sr2", "srf", "erf", "crw", "mos"]
        XCTAssertEqual(Set(capabilityRegistry.capability(for: .dng).aliases), Set(dngAliases))

        for format in rawFormats {
            XCTAssertTrue(format.isRawImage, "\(format) should report isRawImage == true")

            let cap = capabilityRegistry.capability(for: format)
            XCTAssertTrue(cap.canRead, "\(format) must be readable")
            XCTAssertFalse(cap.canWrite, "\(format) must be read-only")

            XCTAssertTrue(imageEngine.supportedInputFormats.contains(format), "ImageEngine must accept \(format) input")
            XCTAssertFalse(imageEngine.supportedOutputFormats.contains(format), "ImageEngine must not advertise \(format) output")
            XCTAssertTrue(imageEngine.canConvert(from: format, to: .jpg))
            XCTAssertTrue(imageEngine.canConvert(from: format, to: .png))
            XCTAssertTrue(imageEngine.canConvert(from: format, to: .tiff))

            let metaCaps = metadataProvider.capabilities(for: format)
            XCTAssertTrue(metaCaps.canRead, "MetadataProvider must read \(format)")
            XCTAssertFalse(metaCaps.canWrite, "MetadataProvider must enforce read-only for \(format)")
        }
    }

    // MARK: - 2. ImageIO Host RAW UTI Capability Probe

    func testImageIOHostRAWUTISupportProbe() {
        let supportedIdentifiers = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        let supportedSet = Set(supportedIdentifiers)

        let rawFormats: [FileFormat] = [.dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw]
        for format in rawFormats {
            let uti = format.utType?.identifier ?? "nil"
            let advertised = format.utType.map { supportedSet.contains($0.identifier) } ?? false
            print("[Phase53-RAW-UTI] format=\(format.fileExtension) uti=\(uti) imageIOAdvertised=\(advertised)")
        }

        // Standard DNG UTI is expected to be registered by macOS ImageIO
        XCTAssertTrue(supportedSet.contains("com.adobe.raw-image"))
    }

    // MARK: - 3. Corrupt / Truncated RAW Inputs Fail Safely Without Source Mutation

    func testCorruptAndTruncatedRAWFilesFailSafelyWithoutModifyingSource() async throws {
        let sandbox = try makeSandbox(name: "CorruptRAW")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let inDir = sandbox.appendingPathComponent("in", isDirectory: true)
        let outDir = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let engine = ImageConversionEngine()

        let truncatedFixtures: [(String, Data)] = [
            ("corrupt.dng", Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])),
            ("corrupt.cr2", Data([0x49, 0x49, 0x2A, 0x00, 0x10, 0x00, 0x00, 0x00, 0x43, 0x52, 0x02, 0x00])),
            ("corrupt.cr3", Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x63, 0x72, 0x78, 0x20])),
            ("corrupt.nef", Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])),
            ("corrupt.nrw", Data([0x49, 0x49, 0x2A, 0x00, 0xFF, 0xFF, 0x00, 0x00])),
            ("corrupt.arw", Data([0x49, 0x49, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00])),
            ("corrupt.raf", Data("FUJIFILMCCD-RAW 0201".utf8)),
            ("corrupt.rw2", Data([0x49, 0x49, 0x55, 0x00, 0x08, 0x00, 0x00, 0x00])),
            ("corrupt.orf", Data([0x49, 0x49, 0x52, 0x4F, 0x08, 0x00, 0x00, 0x00])),
            ("corrupt.pef", Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x10])),
            ("corrupt.srw", Data("CORRUPT_SRW_DATA".utf8))
        ]

        for (fileName, payload) in truncatedFixtures {
            let inputURL = inDir.appendingPathComponent(fileName)
            try payload.write(to: inputURL)
            let beforeHash = try sha256Hex(of: inputURL)

            do {
                _ = try await engine.convert(
                    inputs: [inputURL],
                    to: .jpg,
                    outputDirectory: outDir,
                    options: .default
                ) { _ in }
                XCTFail("Truncated/corrupt RAW fixture \(fileName) unexpectedly succeeded conversion")
            } catch let error as ConversionError {
                if case .invalidInput = error {
                    // expected
                } else if case .engineExecutionFailed = error {
                    // also acceptable safe failure
                } else {
                    XCTFail("Unexpected ConversionError for \(fileName): \(error)")
                }
            } catch {
                XCTFail("Expected ConversionError for \(fileName), got \(error)")
            }

            let afterHash = try sha256Hex(of: inputURL)
            XCTAssertEqual(afterHash, beforeHash, "Source file \(fileName) must remain unmodified")
        }

        let remainingOutputs = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(remainingOutputs.isEmpty, "Failed RAW conversions must leave no output files behind")
    }

    // MARK: - 4. Genuine Camera RAW Verification (Gated on Real User-Provided Samples)

    func testGenuineCameraRAWSamplesIfProvided() async throws {
        guard let samplesPath = ProcessInfo.processInfo.environment["LOCALCONVERT_RAW_SAMPLES_DIR"],
              !samplesPath.isEmpty else {
            throw XCTSkip("BLOCKED: Genuine camera RAW sample directory not configured via LOCALCONVERT_RAW_SAMPLES_DIR.")
        }

        let samplesDir = URL(fileURLWithPath: samplesPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: samplesDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCTSkip("BLOCKED: LOCALCONVERT_RAW_SAMPLES_DIR does not point to an existing directory: \(samplesPath)")
        }

        let rawExtensions = Set(FileFormat.allCases.filter(\.isRawImage).map { $0.fileExtension.lowercased() }
            + ["raw", "rwl", "3fr", "fff", "iiq", "dcr", "mrw", "sr2", "srf", "erf", "crw", "mos"])

        let contents = try FileManager.default.contentsOfDirectory(at: samplesDir, includingPropertiesForKeys: nil)
        let rawFiles = contents.filter { rawExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !rawFiles.isEmpty else {
            throw XCTSkip("BLOCKED: No camera RAW files found inside LOCALCONVERT_RAW_SAMPLES_DIR (\(samplesPath)).")
        }

        let sandbox = try makeSandbox(name: "GenuineRAW")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let detector = FileDetector()
        let metadataProvider = ImageMetadataProvider()
        let engine = ImageConversionEngine()

        for sourceURL in rawFiles {
            let sourceHashBefore = try sha256Hex(of: sourceURL)
            let detection = detector.detect(url: sourceURL)
            XCTAssertNotNil(detection.bestFormat, "Expected detected format for \(sourceURL.lastPathComponent)")
            XCTAssertTrue(detection.bestFormat?.isRawImage == true, "Expected RAW format for \(sourceURL.lastPathComponent)")

            let metadata = try await metadataProvider.readMetadata(from: sourceURL)
            XCTAssertFalse(metadata.technical["dimensions"]?.isEmpty ?? true)

            let perFileOutDir = sandbox.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent, isDirectory: true)
            try FileManager.default.createDirectory(at: perFileOutDir, withIntermediateDirectories: true)

            for target in [FileFormat.jpg, .png, .tiff] {
                let result = try await engine.convert(
                    inputs: [sourceURL],
                    to: target,
                    outputDirectory: perFileOutDir,
                    options: .default
                ) { _ in }

                let outSource = try XCTUnwrap(CGImageSourceCreateWithURL(result.outputURL as CFURL, nil))
                let decodedOut = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outSource, 0, nil))
                XCTAssertGreaterThan(decodedOut.width, 0)
                XCTAssertGreaterThan(decodedOut.height, 0)
                XCTAssertTrue(isNonBlankCGImage(decodedOut), "Decoded output for \(sourceURL.lastPathComponent) -> \(target.fileExtension) appears blank")
            }

            let sourceHashAfter = try sha256Hex(of: sourceURL)
            XCTAssertEqual(sourceHashAfter, sourceHashBefore, "Genuine RAW source must not be modified")
        }
    }

    // MARK: - 5. Cross-Phase Safety & Architecture Boundaries (Phases 49-52)

    func testCrossPhaseDataSafetyAndUndoBoundaries() async throws {
        let sandbox = try makeSandbox(name: "CrossPhaseSafety")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Phase 50/51 boundary: AppSettings.sanitizeOptionsForRemembering clears videoTrim and destructive overwrite
        var rawOptions = ConversionOptions(preset: .custom, preserveMetadata: true, imageQuality: 0.9)
        rawOptions.overwriteExisting = true
        rawOptions.videoTrim = VideoTrimRange(startMilliseconds: 1000, endMilliseconds: 4000, mode: .streamCopy)
        let sanitized = AppSettings.sanitizeOptionsForRemembering(rawOptions)
        XCTAssertFalse(sanitized.overwriteExisting)
        XCTAssertNil(sanitized.videoTrim)
        XCTAssertNil(sanitized.preset)

        // Phase 52 loop prevention: WatchFolderValidator rejects input == output
        let preset = SavedPreset(name: "P53 Safety", targetFormat: .jpg)
        let rule = WatchFolderRule(
            name: "Same Folder Loop",
            inputDirectoryPath: sandbox.path,
            presetID: preset.id,
            outputDestination: .customDirectory(path: sandbox.path, bookmarkData: nil)
        )
        let validation = WatchFolderValidator.validate(rule: rule, existingRules: [], availablePresets: [preset])
        XCTAssertFalse(validation.isValid)

        // Phase 49 protected source boundary: OutputCreationUndoCommand never stages protected sources
        let protectedSource = sandbox.appendingPathComponent("source.png")
        let generatedOutput = sandbox.appendingPathComponent("output.jpg")
        try Data("SRC".utf8).write(to: protectedSource)
        try Data("OUT".utf8).write(to: generatedOutput)

        let artifactsDir = sandbox.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        let artifactManager = RecoveryArtifactManager(baseDirectoryURL: artifactsDir)

        let undoCmd = OutputCreationUndoCommand(
            title: "Phase 53 Output Test",
            context: .convert,
            outputURLs: [protectedSource, generatedOutput, generatedOutput],
            protectedSourceURLs: [protectedSource],
            artifactManager: artifactManager
        )
        XCTAssertEqual(undoCmd.affectedURLs.map(\.lastPathComponent), ["output.jpg"])
        try await undoCmd.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: generatedOutput.path))
        try await undoCmd.redo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: generatedOutput.path))
    }
}

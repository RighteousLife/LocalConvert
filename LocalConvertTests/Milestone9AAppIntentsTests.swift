import XCTest
import AppIntents
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import Darwin
@testable import LocalConvert

final class Milestone9AAppIntentsTests: XCTestCase {

    // MARK: - Sandbox & Fixture Helpers

    private func makeSandbox(suffix: String) throws -> TestSandbox {
        let sandbox = try TestSandbox(runID: "M9A-AppIntents-\(suffix)-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        return sandbox
    }

    private func cleanupSandbox(_ sandbox: TestSandbox) {
        AppStoragePaths.clearTestOverrides()
        _ = sandbox.cleanup()
    }

    @MainActor
    private func makeIsolatedConversionManager(sandbox: TestSandbox) -> ConversionManager {
        LocalConvertIntentSupport.ensureEnginesRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return ConversionManager(registry: .shared, historyManager: history)
    }

    private func writeTinyPNG(to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 140, count: 16 * 16 * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone9AAppIntentsTests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func makePNGData() throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 200, count: 12 * 12 * 4)
        let mutableData = NSMutableData()
        guard let ctx = CGContext(
            data: &pixels,
            width: 12,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 12 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone9AAppIntentsTests", code: 2)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return mutableData as Data
    }

    private func assertValidImage(at url: URL) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            XCTFail("Expected decodable output image at \(url.path)")
            return
        }
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    // MARK: - 1. SavedPresetEntityQuery Resolution

    @MainActor
    func testSavedPresetEntityQueryResolution() async throws {
        let sandbox = try makeSandbox(suffix: "PresetQuery")
        defer { cleanupSandbox(sandbox) }

        let customPreset = SavedPreset(
            id: UUID(),
            name: "Archive JSON to PLIST",
            description: "Converts JSON payloads to Apple Property List.",
            targetFormat: .plist,
            sourceConstraint: .json,
            options: .default,
            outputDestinationPolicy: .defaultLocation,
            outputNamingPolicy: .standard,
            isBuiltIn: false
        )

        let store = PresetStore(fileURL: sandbox.presetsFileURL)
        store.save(customPreset)
        let storedPresets = store.getAll()

        let query = SavedPresetEntityQuery {
            storedPresets
        }

        // 1. suggestedEntities()
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.count, storedPresets.count)
        XCTAssertTrue(suggested.contains(where: { $0.id == customPreset.id && $0.name == "Archive JSON to PLIST" }))

        // 2. entities(for:) preserves requested order and omits unknown UUIDs
        let firstDefault = try XCTUnwrap(SavedPreset.defaultTemplates.first)
        let unknownID = UUID()
        let resolvedByIDs = try await query.entities(for: [customPreset.id, unknownID, firstDefault.id])
        XCTAssertEqual(resolvedByIDs.map(\.id), [customPreset.id, firstDefault.id])
        XCTAssertEqual(resolvedByIDs.first?.targetFormatRawValue, FileFormat.plist.rawValue)

        // 3. entities(matching:) filters by name, description, and format; blank query returns all
        let byName = try await query.entities(matching: "archive json")
        XCTAssertEqual(byName.map(\.id), [customPreset.id])

        let byDescription = try await query.entities(matching: "property list")
        XCTAssertEqual(byDescription.map(\.id), [customPreset.id])

        let byFormat = try await query.entities(matching: "webp")
        XCTAssertTrue(byFormat.contains(where: { $0.targetFormatRawValue == FileFormat.webp.rawValue }))

        let allOnBlank = try await query.entities(matching: "   ")
        XCTAssertEqual(allOnBlank.count, storedPresets.count)
    }

    // MARK: - 2. ConvertFilesIntent Parameter Mapping & Conversion

    func testIntentEnumMappingsCoverTargetFormatsAndQuality() {
        for quality in IntentQualityPreset.allCases {
            XCTAssertNotNil(IntentQualityPreset.caseDisplayRepresentations[quality])
        }
        XCTAssertEqual(IntentQualityPreset.low.qualityPreset, .low)
        XCTAssertEqual(IntentQualityPreset.medium.qualityPreset, .medium)
        XCTAssertEqual(IntentQualityPreset.high.qualityPreset, .high)
        XCTAssertEqual(IntentQualityPreset.maximum.qualityPreset, .maximum)

        for target in IntentTargetFormat.allCases {
            XCTAssertNotNil(IntentTargetFormat.caseDisplayRepresentations[target])
            XCTAssertEqual(IntentTargetFormat(fileFormat: target.fileFormat), target)
            XCTAssertFalse(target.fileFormat.isReadOnly, "IntentTargetFormat must only expose writable formats: \(target.rawValue)")
        }
    }

    @MainActor
    func testConvertFilesIntentConvertsPNGToJPEGWithoutMutatingSource() async throws {
        let sandbox = try makeSandbox(suffix: "ConvertPNGtoJPG")
        defer { cleanupSandbox(sandbox) }

        let inputURL = sandbox.documentsURL.appendingPathComponent("photo_source.png")
        try writeTinyPNG(to: inputURL)
        let originalBytes = try Data(contentsOf: inputURL)

        let manager = makeIsolatedConversionManager(sandbox: sandbox)
        let intent = ConvertFilesIntent(
            files: [IntentFile(fileURL: inputURL)],
            targetFormat: .jpg,
            quality: .medium
        )

        let outputs = try await intent.execute(
            destinationOverride: sandbox.outputsURL,
            conversionManager: manager
        )

        XCTAssertEqual(outputs.count, 1)
        let outputFile = try XCTUnwrap(outputs.first)
        let outputURL = try XCTUnwrap(outputFile.fileURL)
        XCTAssertEqual(outputURL.pathExtension.lowercased(), "jpg")
        XCTAssertEqual(outputURL.deletingLastPathComponent().standardizedFileURL, sandbox.outputsURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        assertValidImage(at: outputURL)

        // Source file must remain untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputURL.path))
        XCTAssertEqual(try Data(contentsOf: inputURL), originalBytes)
    }

    @MainActor
    func testConvertFilesIntentPerformSupportsDataOnlyIntentFile() async throws {
        let sandbox = try makeSandbox(suffix: "DataOnlyPerform")
        defer { cleanupSandbox(sandbox) }

        LocalConvertIntentSupport.ensureEnginesRegistered()
        let originalLocation = AppSettings.shared.defaultOutputLocation
        let originalCustomDir = AppSettings.shared.customOutputDirectory
        defer {
            AppSettings.shared.defaultOutputLocation = originalLocation
            AppSettings.shared.customOutputDirectory = originalCustomDir
        }
        AppSettings.shared.defaultOutputLocation = .custom
        AppSettings.shared.customOutputDirectory = sandbox.outputsURL

        let pngData = try makePNGData()
        let intentFile = IntentFile(data: pngData, filename: "in_memory_sample.png", type: .png)
        let intent = ConvertFilesIntent(
            files: [intentFile],
            targetFormat: .jpg,
            quality: .high
        )

        let result = try await intent.perform()
        let container = result as? IntentResultContainer<[IntentFile], Never, Never, Never>
        let outputs = try XCTUnwrap(container?.value)

        XCTAssertEqual(outputs.count, 1)
        let outputURL = try XCTUnwrap(outputs.first?.fileURL)
        XCTAssertEqual(outputURL.pathExtension.lowercased(), "jpg")
        assertValidImage(at: outputURL)
    }

    @MainActor
    func testConvertFilesIntentRejectsEmptyAndUnsupportedConversions() async throws {
        let sandbox = try makeSandbox(suffix: "UnsupportedConvert")
        defer { cleanupSandbox(sandbox) }

        let manager = makeIsolatedConversionManager(sandbox: sandbox)

        // Empty input
        let emptyIntent = ConvertFilesIntent(files: [], targetFormat: .jpg, quality: .high)
        do {
            _ = try await emptyIntent.execute(destinationOverride: sandbox.outputsURL, conversionManager: manager)
            XCTFail("Expected noInputFiles error")
        } catch let error as LocalConvertIntentError {
            XCTAssertEqual(error, .noInputFiles)
        }

        // Unsupported conversion: .png -> .mp3
        let inputPNG = sandbox.documentsURL.appendingPathComponent("cannot_be_audio.png")
        try writeTinyPNG(to: inputPNG)

        let badRouteIntent = ConvertFilesIntent(
            files: [IntentFile(fileURL: inputPNG)],
            targetFormat: .mp3,
            quality: .high
        )
        do {
            _ = try await badRouteIntent.execute(destinationOverride: sandbox.outputsURL, conversionManager: manager)
            XCTFail("Expected unsupportedConversion error")
        } catch let error as LocalConvertIntentError {
            XCTAssertEqual(error, .unsupportedConversion(from: .png, to: .mp3))
        }
    }

    // MARK: - 3. RunSavedPresetIntent Execution & Validation

    @MainActor
    func testRunSavedPresetIntentExecutesPresetAndPreservesSource() async throws {
        let sandbox = try makeSandbox(suffix: "RunPreset")
        defer { cleanupSandbox(sandbox) }

        let inputURL = sandbox.documentsURL.appendingPathComponent("preset_input.png")
        try writeTinyPNG(to: inputURL)
        let originalBytes = try Data(contentsOf: inputURL)

        let preset = SavedPreset(
            id: UUID(),
            name: "Export JPEG Copy",
            description: "Converts image to JPEG with _export suffix.",
            targetFormat: .jpg,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(preset: .maximumQuality, preserveMetadata: true, imageQuality: 0.92),
            outputDestinationPolicy: .customDirectory(path: sandbox.outputsURL.path),
            outputNamingPolicy: .addSuffix(suffix: "_export"),
            isBuiltIn: false
        )

        let manager = makeIsolatedConversionManager(sandbox: sandbox)
        let intent = RunSavedPresetIntent(
            files: [IntentFile(fileURL: inputURL)],
            preset: SavedPresetEntity(preset: preset)
        )

        let outputs = try await intent.execute(
            presetsOverride: [preset],
            conversionManager: manager
        )

        XCTAssertEqual(outputs.count, 1)
        let outputURL = try XCTUnwrap(outputs.first?.fileURL)
        XCTAssertEqual(outputURL.lastPathComponent, "preset_input_export.jpg")
        XCTAssertEqual(outputURL.deletingLastPathComponent().standardizedFileURL, sandbox.outputsURL.standardizedFileURL)
        assertValidImage(at: outputURL)
        XCTAssertEqual(try Data(contentsOf: inputURL), originalBytes)
    }

    @MainActor
    func testRunSavedPresetIntentRejectsUnknownPresetAndIncompatibleInput() async throws {
        let sandbox = try makeSandbox(suffix: "PresetErrors")
        defer { cleanupSandbox(sandbox) }

        let jsonURL = sandbox.documentsURL.appendingPathComponent("sample.json")
        try Data("{\"hello\":\"world\"}".utf8).write(to: jsonURL)

        let imagePreset = SavedPreset(
            id: UUID(),
            name: "Images Only JPEG",
            targetFormat: .jpg,
            sourceCategoryConstraint: .image
        )
        let unknownPreset = SavedPreset(
            id: UUID(),
            name: "Ghost Preset",
            targetFormat: .jpg
        )

        let manager = makeIsolatedConversionManager(sandbox: sandbox)

        // Unknown preset ID
        let missingIntent = RunSavedPresetIntent(
            files: [IntentFile(fileURL: jsonURL)],
            preset: SavedPresetEntity(preset: unknownPreset)
        )
        do {
            _ = try await missingIntent.execute(
                presetsOverride: [imagePreset],
                destinationOverride: sandbox.outputsURL,
                conversionManager: manager
            )
            XCTFail("Expected presetNotFound")
        } catch let error as LocalConvertIntentError {
            XCTAssertEqual(error, .presetNotFound("Ghost Preset"))
        }

        // Incompatible file category (.json for image-only preset)
        let incompatibleIntent = RunSavedPresetIntent(
            files: [IntentFile(fileURL: jsonURL)],
            preset: SavedPresetEntity(preset: imagePreset)
        )
        do {
            _ = try await incompatibleIntent.execute(
                presetsOverride: [imagePreset],
                destinationOverride: sandbox.outputsURL,
                conversionManager: manager
            )
            XCTFail("Expected incompatiblePreset")
        } catch let error as LocalConvertIntentError {
            if case .incompatiblePreset(let name, _) = error {
                XCTAssertEqual(name, "Images Only JPEG")
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - 4. Shared Safe File Validation (FinderIntegration + Quick Actions + AppIntents)

    @MainActor
    func testSharedSafeFileValidationRejectsInvalidInputsAcrossFinderAndAppIntents() async throws {
        let sandbox = try makeSandbox(suffix: "SharedSecurity")
        defer { cleanupSandbox(sandbox) }

        let realFile = sandbox.documentsURL.appendingPathComponent("real.png")
        try writeTinyPNG(to: realFile)

        // 1. Directory
        let folder = sandbox.documentsURL.appendingPathComponent("FolderInput", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 2. Direct symlink
        let directSymlink = sandbox.documentsURL.appendingPathComponent("direct_link.png")
        try FileManager.default.createSymbolicLink(at: directSymlink, withDestinationURL: realFile)

        // 3. Dangling symlink
        let danglingSymlink = sandbox.documentsURL.appendingPathComponent("dangling_link.png")
        try FileManager.default.createSymbolicLink(
            at: danglingSymlink,
            withDestinationURL: sandbox.documentsURL.appendingPathComponent("missing_target.png")
        )

        // 4. Ancestor symlink
        let realSubdir = sandbox.documentsURL.appendingPathComponent("real_subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: realSubdir, withIntermediateDirectories: true)
        let innerFile = realSubdir.appendingPathComponent("inside.png")
        try writeTinyPNG(to: innerFile)
        let linkedDir = sandbox.documentsURL.appendingPathComponent("linked_subdir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: realSubdir)
        let viaLinkedDir = linkedDir.appendingPathComponent("inside.png")

        // 5. FIFO non-regular file
        let fifoURL = sandbox.documentsURL.appendingPathComponent("fifo_pipe.png")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, 0o600), 0)

        // 6. Missing file
        let missingURL = sandbox.documentsURL.appendingPathComponent("does_not_exist.png")

        // 7. Unreadable file (when non-root)
        let unreadableURL = sandbox.documentsURL.appendingPathComponent("unreadable.png")
        try writeTinyPNG(to: unreadableURL)
        let checkUnreadable = Darwin.geteuid() != 0
        if checkUnreadable {
            XCTAssertEqual(Darwin.chmod(unreadableURL.path, 0o000), 0)
        }
        defer {
            if checkUnreadable {
                _ = Darwin.chmod(unreadableURL.path, 0o644)
            }
        }

        // Verify FinderHandoffHandler.validateInputFileURL exact error classifications
        XCTAssertEqual(
            FinderHandoffHandler.validateInputFileURL(folder),
            .failure(.folderRejected(folder.standardizedFileURL.path))
        )
        XCTAssertEqual(
            FinderHandoffHandler.validateInputFileURL(directSymlink),
            .failure(.symlinkRejected(directSymlink.standardizedFileURL.path))
        )
        XCTAssertEqual(
            FinderHandoffHandler.validateInputFileURL(danglingSymlink),
            .failure(.symlinkRejected(danglingSymlink.standardizedFileURL.path))
        )
        XCTAssertEqual(
            FinderHandoffHandler.validateInputFileURL(viaLinkedDir),
            .failure(.symlinkRejected(viaLinkedDir.standardizedFileURL.path))
        )
        XCTAssertEqual(
            FinderHandoffHandler.validateInputFileURL(fifoURL),
            .failure(.notRegularFile(fifoURL.standardizedFileURL.path))
        )
        XCTAssertEqual(
            FinderHandoffHandler.validateInputFileURL(missingURL),
            .failure(.fileNotFound(missingURL.standardizedFileURL.path))
        )
        if checkUnreadable {
            XCTAssertEqual(
                FinderHandoffHandler.validateInputFileURL(unreadableURL),
                .failure(.fileNotReadable(unreadableURL.standardizedFileURL.path))
            )
        }
        if case .failure(.malformedURL) = FinderHandoffHandler.validateInputFileURL(URL(string: "https://example.com/test.png")!) {
            // Expected
        } else {
            XCTFail("Expected malformedURL for non-file URL")
        }
        if let traversalURL = URL(string: "file://\(realSubdir.path)/../real.png") {
            if case .failure(.pathTraversalRejected) = FinderHandoffHandler.validateInputFileURL(traversalURL) {
                // Expected
            } else {
                XCTFail("Expected pathTraversalRejected for traversal file:// URL")
            }
        }

        // Verify FinderHandoffHandler.validateAndSanitize shares the same restrictions
        var badURLs: [URL] = [folder, directSymlink, danglingSymlink, viaLinkedDir, fifoURL, missingURL]
        if checkUnreadable {
            badURLs.append(unreadableURL)
        }
        let sanitized = FinderHandoffHandler.validateAndSanitize(urls: badURLs + [realFile])
        XCTAssertEqual(sanitized.validURLs.map(\.standardizedFileURL), [realFile.standardizedFileURL])
        XCTAssertEqual(sanitized.rejectedFolders.map(\.standardizedFileURL), [folder.standardizedFileURL])
        XCTAssertEqual(sanitized.inaccessibleURLs.count, badURLs.count - 1)

        // Verify ServicesProvider Quick Action validation rejects all unsafe URLs and forwards only valid regular files
        let serviceProvider = ServicesProvider()
        var forwardedURLs: [URL] = []
        serviceProvider.onFilesReceivedWithAction = { urls, _ in
            forwardedURLs = urls
        }
        let serviceOutcome = serviceProvider.handleQuickActionURLs(
            badURLs + [realFile],
            action: "convert",
            activateApplication: false
        )
        XCTAssertEqual(serviceOutcome.accepted.map(\.standardizedFileURL), [realFile.standardizedFileURL])
        XCTAssertEqual(serviceOutcome.rejected.count, badURLs.count)
        XCTAssertEqual(forwardedURLs.map(\.standardizedFileURL), [realFile.standardizedFileURL])

        // Verify all-invalid Quick Action batch triggers no callback
        forwardedURLs = []
        let allRejectedOutcome = serviceProvider.handleQuickActionURLs(
            badURLs,
            action: "webp",
            activateApplication: false
        )
        XCTAssertTrue(allRejectedOutcome.accepted.isEmpty)
        XCTAssertTrue(forwardedURLs.isEmpty)

        // Verify ConvertFilesIntent and RunSavedPresetIntent reject every invalid file type
        let manager = makeIsolatedConversionManager(sandbox: sandbox)
        let jpegPreset = SavedPreset(
            id: UUID(),
            name: "To JPEG",
            targetFormat: .jpg,
            sourceCategoryConstraint: .image
        )
        let presetEntity = SavedPresetEntity(preset: jpegPreset)

        for invalidURL in badURLs {
            let convertIntent = ConvertFilesIntent(
                files: [IntentFile(fileURL: invalidURL)],
                targetFormat: .jpg,
                quality: .high
            )
            do {
                _ = try await convertIntent.execute(destinationOverride: sandbox.outputsURL, conversionManager: manager)
                XCTFail("ConvertFilesIntent should have rejected \(invalidURL.lastPathComponent)")
            } catch let error as LocalConvertIntentError {
                guard case .invalidInputFile = error else {
                    XCTFail("Expected invalidInputFile for \(invalidURL.lastPathComponent), got \(error)")
                    continue
                }
            }

            let presetIntent = RunSavedPresetIntent(
                files: [IntentFile(fileURL: invalidURL)],
                preset: presetEntity
            )
            do {
                _ = try await presetIntent.execute(
                    presetsOverride: [jpegPreset],
                    destinationOverride: sandbox.outputsURL,
                    conversionManager: manager
                )
                XCTFail("RunSavedPresetIntent should have rejected \(invalidURL.lastPathComponent)")
            } catch let error as LocalConvertIntentError {
                guard case .invalidInputFile = error else {
                    XCTFail("Expected invalidInputFile for \(invalidURL.lastPathComponent), got \(error)")
                    continue
                }
            }
        }
    }
}

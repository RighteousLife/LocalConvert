import XCTest
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Phase55VerificationTests: XCTestCase {

    private func makeSandbox(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P55-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func writeSyntheticPNG(to url: URL) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: 16 * 16 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 40
            pixels[i + 1] = 150
            pixels[i + 2] = 210
            pixels[i + 3] = 255
        }
        let ctx = CGContext(
            data: &pixels,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: colorSpaceOrDefault(cs),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func colorSpaceOrDefault(_ cs: CGColorSpace) -> CGColorSpace { cs }

    // MARK: - 1. P1 HistoryManager Test Isolation & Backward Compatibility

    func testHistoryManagerSharedUsesTemporaryStorageUnderXCTestNeverUserAppSupport() {
        XCTAssertTrue(HistoryManager.isRunningUnderXCTest)
        let sharedURL = HistoryManager.shared.fileURL.standardizedFileURL.path
        let prodURL = HistoryManager.productionStoreFileURL().standardizedFileURL.path
        XCTAssertNotEqual(sharedURL, prodURL)
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(sharedURL.hasPrefix(tempRoot), "Expected XCTest HistoryManager.shared path under temp directory, got: \(sharedURL)")
    }

    func testHistoryManagerInjectedStorePersistsAndPreservesBackwardCompatibleJSONFormat() throws {
        let sandbox = try makeSandbox(name: "HistoryInject")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let historyFile = sandbox.appendingPathComponent("nested/history.json")
        let mgr = HistoryManager(fileURL: historyFile)
        XCTAssertTrue(mgr.items.isEmpty)

        let item = ConversionHistoryItem(
            id: UUID(),
            inputFilename: "photo.png",
            inputFormatName: "PNG",
            outputFilename: "photo.jpg",
            outputFormatName: "JPEG",
            date: Date(),
            status: .completed,
            inputSizeBytes: 1024,
            outputSizeBytes: 512,
            presetName: nil,
            outputURLPath: sandbox.appendingPathComponent("photo.jpg").path,
            inputURLPath: sandbox.appendingPathComponent("photo.png").path,
            duration: 0.25,
            errorMessage: nil
        )
        mgr.addEntry(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFile.path))

        // Reload via fresh instance using exact JSON format
        let reloaded = HistoryManager(fileURL: historyFile)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertEqual(reloaded.items.first?.id, item.id)
        XCTAssertEqual(reloaded.items.first?.outputFilename, "photo.jpg")
    }

    func testHistoryManagerCorruptFileBacksUpSafely() throws {
        let sandbox = try makeSandbox(name: "HistoryCorrupt")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let historyFile = sandbox.appendingPathComponent("history.json")
        try Data("{corrupt-json".utf8).write(to: historyFile)

        let mgr = HistoryManager(fileURL: historyFile)
        XCTAssertTrue(mgr.items.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
        let quarantinePattern = #"^history\.corrupted\.\d{8}-\d{6}(?:-\d+)?\.json$"#
        let quarantined = files.filter { $0.range(of: quarantinePattern, options: .regularExpression) != nil }
        XCTAssertEqual(quarantined.count, 1, "Expected 1 timestamped quarantined corrupt history file, found: \(files)")
        XCTAssertNotNil(mgr.lastPersistenceError)
    }

    func testConversionManagerAndMetadataManagerUseInjectedHistoryWithoutPollutingProductionStore() async throws {
        let sandbox = try makeSandbox(name: "HistoryManagers")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let inDir = sandbox.appendingPathComponent("in", isDirectory: true)
        let outDir = sandbox.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: ImageConversionEngine())
        }
        let metaRegistry = MetadataRegistry.shared
        if metaRegistry.provider(for: .png) == nil {
            metaRegistry.register(provider: ImageMetadataProvider())
        }

        let convHistoryURL = sandbox.appendingPathComponent("conv_history.json")
        let convHistory = HistoryManager(fileURL: convHistoryURL)
        let convManager = ConversionManager(registry: registry, historyManager: convHistory)

        let pngURL = try writeSyntheticPNG(to: inDir.appendingPathComponent("sample.png"))
        let job = ConversionJob(
            inputURLs: [pngURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: outDir
        )
        let status: ConversionJobStatus = await withCheckedContinuation { continuation in
            convManager.submit(job: job) { finalStatus in
                continuation.resume(returning: finalStatus)
            }
        }
        guard case .completed(let res) = status else {
            XCTFail("Expected ConversionManager job to complete, got \(status)")
            return
        }
        XCTAssertEqual(convHistory.items.count, 1)
        XCTAssertEqual(convHistory.items.first?.outputFilename, res.outputURL.lastPathComponent)

        // MetadataManager isolated Save Copy
        let metaHistoryURL = sandbox.appendingPathComponent("meta_history.json")
        let metaHistory = HistoryManager(fileURL: metaHistoryURL)
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.appendingPathComponent("journal", isDirectory: true),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.appendingPathComponent("artifacts", isDirectory: true))
        )
        let metaManager = MetadataManager(
            undoCoordinator: undoCoord,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.appendingPathComponent("meta_artifacts", isDirectory: true)),
            historyManager: metaHistory
        )
        await metaManager.load(url: res.outputURL)
        metaManager.updateField(id: "title", value: .string("Phase 55 Test Title"))
        let savedCopy = await metaManager.saveCopy(to: sandbox.appendingPathComponent("tagged.jpg"))
        XCTAssertNotNil(savedCopy)
        XCTAssertEqual(metaHistory.items.count, 1)
        XCTAssertEqual(metaHistory.items.first?.presetName, "Metadata Save Copy")
    }

    // MARK: - 2. P1 Sustainable RAW Handling Policy & Honest Claims

    func testRAWCapabilityNotesDoNotClaimUnconditionalVerificationAndUnsupportedRAWFailsSafelyInWatchFolder() async throws {
        let caps = FormatCapabilityRegistry.shared.capability(for: .cr3)
        XCTAssertTrue(caps.isReadOnly)
        XCTAssertTrue(caps.limitationNote?.contains("depends on macOS camera support") == true)

        let sandbox = try makeSandbox(name: "WatchRAWFail")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let inboxDir = sandbox.appendingPathComponent("Inbox", isDirectory: true)
        let storeDir = sandbox.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: ImageConversionEngine())
        }
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.appendingPathComponent("journal", isDirectory: true),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.appendingPathComponent("artifacts", isDirectory: true))
        )
        let presetStore = PresetStore(fileURL: storeDir.appendingPathComponent("presets.json"))
        let presetManager = PresetManager(store: presetStore, undoCoordinator: undoCoord)
        let preset = SavedPreset(
            name: "RAW to JPG",
            targetFormat: .jpg,
            sourceCategoryConstraint: .image,
            options: .default,
            outputDestinationPolicy: .defaultLocation,
            outputNamingPolicy: .standard
        )
        presetManager.save(preset: preset)

        let watchHistory = HistoryManager(fileURL: storeDir.appendingPathComponent("watch_history.json"))
        let convManager = ConversionManager(registry: registry, historyManager: watchHistory)
        let convQueue = ConversionQueue(conversionManager: convManager, undoCoordinator: undoCoord)
        let watchStore = WatchFolderStore(fileURL: storeDir.appendingPathComponent("watch.json"))
        let watchManager = WatchFolderManager(
            store: watchStore,
            presetManager: presetManager,
            conversionManager: convManager,
            conversionQueue: convQueue,
            defaultOutputLocationProvider: { (.sameFolder, nil) }
        )
        defer { watchManager.stopAll() }

        let rule = WatchFolderRule(
            name: "RAW Watch",
            inputDirectoryPath: inboxDir.path,
            presetID: preset.id,
            isEnabled: true,
            outputDestination: .subfolder(name: "Converted"),
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 0.8
        )
        XCTAssertTrue(watchManager.addRule(rule).isValid)

        let badRAW = inboxDir.appendingPathComponent("unsupported.cr3")
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x63, 0x72, 0x78, 0x20]).write(to: badRAW)
        let hashBefore = try sha256Hex(of: badRAW)

        watchManager.handleDetectedFiles([badRAW], for: rule.id)

        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            if watchManager.records.first(where: { $0.fileName == "unsupported.cr3" })?.state == .failed {
                break
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        let rec = try XCTUnwrap(watchManager.records.first { $0.fileName == "unsupported.cr3" })
        XCTAssertEqual(rec.state, .failed)
        XCTAssertTrue(rec.reason?.contains("Camera RAW") == true || rec.reason?.contains("decoded") == true)
        XCTAssertEqual(try sha256Hex(of: badRAW), hashBefore)
        XCTAssertEqual(watchManager.records.filter { $0.fileName == "unsupported.cr3" }.count, 1)

        let convertedDir = inboxDir.appendingPathComponent("Converted", isDirectory: true)
        if FileManager.default.fileExists(atPath: convertedDir.path) {
            let leftover = try FileManager.default.contentsOfDirectory(at: convertedDir, includingPropertiesForKeys: nil)
            XCTAssertTrue(leftover.isEmpty, "Failed RAW job must leave no output file")
        }
    }
}

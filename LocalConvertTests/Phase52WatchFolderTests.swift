import XCTest
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import LocalConvert

@MainActor
final class Phase52WatchFolderTests: XCTestCase {

    // MARK: - Sandbox & Fixture Helpers

    private struct Sandbox {
        let root: URL
        let inboxDir: URL
        let subDir: URL
        let secondInboxDir: URL
        let customOutputDir: URL
        let storeDir: URL
        let journalDir: URL
        let artifactsDir: URL
    }

    private func makeSandbox(name: String) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P52Watch-\(name)-\(UUID().uuidString)", isDirectory: true)
        let inboxDir = root.appendingPathComponent("Inbox", isDirectory: true)
        let subDir = inboxDir.appendingPathComponent("Subfolder", isDirectory: true)
        let secondInboxDir = root.appendingPathComponent("SecondInbox", isDirectory: true)
        let customOutputDir = root.appendingPathComponent("CustomOutput", isDirectory: true)
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        let journalDir = root.appendingPathComponent("Journal", isDirectory: true)
        let artifactsDir = root.appendingPathComponent("Artifacts", isDirectory: true)

        for dir in [inboxDir, subDir, secondInboxDir, customOutputDir, storeDir, journalDir, artifactsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return Sandbox(
            root: root,
            inboxDir: inboxDir,
            subDir: subDir,
            secondInboxDir: secondInboxDir,
            customOutputDir: customOutputDir,
            storeDir: storeDir,
            journalDir: journalDir,
            artifactsDir: artifactsDir
        )
    }

    private struct Harness {
        let store: WatchFolderStore
        let presetStore: PresetStore
        let presetManager: PresetManager
        let undoCoordinator: UndoRedoCoordinator
        let conversionManager: ConversionManager
        let conversionQueue: ConversionQueue
        let manager: WatchFolderManager
        let jpegPreset: SavedPreset
    }

    private func makeHarness(
        sandbox: Sandbox,
        targetFormat: FileFormat = .jpg,
        outputDestinationPolicy: OutputDestinationPolicy = .defaultLocation
    ) -> Harness {
        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: ImageConversionEngine())
            registry.register(engine: TextConversionEngine())
            registry.register(engine: PDFConversionEngine())
            registry.register(engine: MediaConversionEngine())
            registry.register(engine: SubtitleConversionEngine())
            registry.register(engine: ArchiveConversionEngine())
            registry.register(engine: OfficeConversionEngine())
            registry.register(engine: PDFToolboxEngine())
        }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let undoCoordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 100 },
            storageBudgetBytesProvider: { 64_000_000 }
        )

        let presetStore = PresetStore(fileURL: sandbox.storeDir.appendingPathComponent("presets.json"))
        let presetManager = PresetManager(store: presetStore, undoCoordinator: undoCoordinator)

        let jpegPreset = SavedPreset(
            id: UUID(),
            name: "Watch Test \(targetFormat.displayName)",
            targetFormat: targetFormat,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(preset: .web, preserveMetadata: false, imageQuality: 0.85),
            outputDestinationPolicy: outputDestinationPolicy,
            outputNamingPolicy: .standard
        )
        presetManager.save(preset: jpegPreset)

        let watchStore = WatchFolderStore(fileURL: sandbox.storeDir.appendingPathComponent("watch_folders.json"))
        let conversionManager = ConversionManager(registry: registry)
        let conversionQueue = ConversionQueue(conversionManager: conversionManager, undoCoordinator: undoCoordinator)

        let manager = WatchFolderManager(
            store: watchStore,
            presetManager: presetManager,
            conversionManager: conversionManager,
            conversionQueue: conversionQueue,
            defaultOutputLocationProvider: { (.sameFolder, nil) }
        )
        manager.monitorDebounceInterval = 0.05

        return Harness(
            store: watchStore,
            presetStore: presetStore,
            presetManager: presetManager,
            undoCoordinator: undoCoordinator,
            conversionManager: conversionManager,
            conversionQueue: conversionQueue,
            manager: manager,
            jpegPreset: jpegPreset
        )
    }

    @discardableResult
    private func writeSyntheticPNG(
        to url: URL,
        width: Int = 32,
        height: Int = 32,
        red: UInt8 = 64,
        green: UInt8 = 160,
        blue: UInt8 = 220
    ) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = 255
        }
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 8.0,
        pollIntervalNs: UInt64 = 30_000_000,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        return condition()
    }

    // MARK: - 1. CRUD, Persistence, Corruption Recovery & Crash Reconciliation

    func testRuleCRUDPersistenceAndToggles() throws {
        let sandbox = try makeSandbox(name: "CRUD")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let harness = makeHarness(sandbox: sandbox)
        defer { harness.manager.stopAll() }

        let rule = WatchFolderRule(
            name: "Drop Photos",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: true,
            includeSubdirectories: false,
            outputDestination: .defaultSubfolder,
            collisionPolicy: .createUnique,
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 0.6
        )

        let addResult = harness.manager.addRule(rule)
        XCTAssertTrue(addResult.isValid)
        XCTAssertEqual(harness.manager.rules.count, 1)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .active)

        // Update rule
        var updated = harness.manager.rules[0]
        updated.name = "Renamed Drop"
        updated.includeSubdirectories = true
        let updateResult = harness.manager.updateRule(updated)
        XCTAssertTrue(updateResult.isValid)
        XCTAssertEqual(harness.manager.rules.first?.name, "Renamed Drop")
        XCTAssertTrue(harness.manager.rules.first?.includeSubdirectories ?? false)

        // Pause & Resume rule
        harness.manager.setPaused(true, for: rule.id)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .paused)
        harness.manager.setPaused(false, for: rule.id)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .active)

        // Disable & Re-enable
        _ = harness.manager.setEnabled(false, for: rule.id)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .disabled)
        _ = harness.manager.setEnabled(true, for: rule.id)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .active)

        // Global Pause / Resume
        harness.manager.pauseAll()
        XCTAssertTrue(harness.manager.isGloballyPaused)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .paused)
        harness.manager.resumeAll()
        XCTAssertFalse(harness.manager.isGloballyPaused)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .active)

        // Persistence reload round-trip
        harness.manager.stopAll()
        let reloadedStore = WatchFolderStore(fileURL: harness.store.fileURL)
        XCTAssertEqual(reloadedStore.snapshot.rules.count, 1)
        XCTAssertEqual(reloadedStore.snapshot.rules.first?.name, "Renamed Drop")

        // Delete rule
        let manager2 = WatchFolderManager(
            store: reloadedStore,
            presetManager: harness.presetManager,
            conversionManager: harness.conversionManager,
            conversionQueue: harness.conversionQueue
        )
        defer { manager2.stopAll() }
        manager2.removeRule(id: rule.id)
        XCTAssertTrue(manager2.rules.isEmpty)
    }

    func testCorruptStoreRecoveryCreatesBackupAndCleanSnapshot() throws {
        let sandbox = try makeSandbox(name: "CorruptStore")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let storeURL = sandbox.storeDir.appendingPathComponent("watch_folders.json")
        try Data("{not-valid-json".utf8).write(to: storeURL)

        let recoveredStore = WatchFolderStore(fileURL: storeURL)
        XCTAssertTrue(recoveredStore.snapshot.rules.isEmpty)
        XCTAssertTrue(recoveredStore.snapshot.recentRecords.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(at: sandbox.storeDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.contains("corrupted") })
    }

    func testUncleanShutdownStaleRecordsReconcileToFailedOnStartup() throws {
        let sandbox = try makeSandbox(name: "CrashReconcile")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let harness = makeHarness(sandbox: sandbox)
        defer { harness.manager.stopAll() }

        let ruleID = UUID()
        let rule = WatchFolderRule(
            id: ruleID,
            name: "Reconcile Rule",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: false
        )
        harness.store.update { snap in
            snap.rules.append(rule)
            snap.recentRecords = [
                WatchFolderFileRecord(ruleID: ruleID, filePath: "/tmp/a.png", fileName: "a.png", state: .processing),
                WatchFolderFileRecord(ruleID: ruleID, filePath: "/tmp/b.png", fileName: "b.png", state: .queued),
                WatchFolderFileRecord(ruleID: ruleID, filePath: "/tmp/c.png", fileName: "c.png", state: .stabilizing),
                WatchFolderFileRecord(ruleID: ruleID, filePath: "/tmp/d.png", fileName: "d.png", state: .completed)
            ]
        }

        let reloaded = WatchFolderStore(fileURL: harness.store.fileURL)
        let restartedManager = WatchFolderManager(
            store: reloaded,
            presetManager: harness.presetManager,
            conversionManager: harness.conversionManager,
            conversionQueue: harness.conversionQueue
        )
        defer { restartedManager.stopAll() }

        restartedManager.reconcileAndStartEnabledRules()

        let states = Dictionary(uniqueKeysWithValues: restartedManager.records.map { ($0.fileName, $0.state) })
        XCTAssertEqual(states["a.png"], .failed)
        XCTAssertEqual(states["b.png"], .failed)
        XCTAssertEqual(states["c.png"], .failed)
        XCTAssertEqual(states["d.png"], .completed)
        XCTAssertTrue(restartedManager.records.first { $0.fileName == "a.png" }?.canRetry ?? false)
    }

    // MARK: - 2. Configuration Validation & Safety

    func testValidationRejectsInvalidConfigurations() throws {
        let sandbox = try makeSandbox(name: "Validation")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let harness = makeHarness(sandbox: sandbox)
        defer { harness.manager.stopAll() }

        // Empty name
        let emptyName = WatchFolderRule(name: "   ", inputDirectoryPath: sandbox.inboxDir.path, presetID: harness.jpegPreset.id)
        XCTAssertFalse(WatchFolderValidator.validate(rule: emptyName, existingRules: [], availablePresets: [harness.jpegPreset]).isValid)

        // Missing folder / unmounted volume
        let missingDir = WatchFolderRule(
            name: "Missing",
            inputDirectoryPath: sandbox.root.appendingPathComponent("DoesNotExist").path,
            presetID: harness.jpegPreset.id
        )
        XCTAssertFalse(WatchFolderValidator.validate(rule: missingDir, existingRules: [], availablePresets: [harness.jpegPreset]).isValid)

        // Missing preset
        let badPreset = WatchFolderRule(name: "No Preset", inputDirectoryPath: sandbox.inboxDir.path, presetID: UUID())
        XCTAssertFalse(WatchFolderValidator.validate(rule: badPreset, existingRules: [], availablePresets: [harness.jpegPreset]).isValid)

        // Unreadable folder permission check
        let unreadableDir = sandbox.root.appendingPathComponent("UnreadableDir", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableDir.path) }
        if !FileManager.default.isReadableFile(atPath: unreadableDir.path) {
            let unreadableRule = WatchFolderRule(name: "Locked", inputDirectoryPath: unreadableDir.path, presetID: harness.jpegPreset.id)
            XCTAssertFalse(WatchFolderValidator.validate(rule: unreadableRule, existingRules: [], availablePresets: [harness.jpegPreset]).isValid)
        }

        // input == output (via presetDefault with sameFolder or customDirectory equal to inbox)
        let loopSameDir = WatchFolderRule(
            name: "Loop Same Dir",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            outputDestination: .presetDefault
        )
        let sameDirRes = WatchFolderValidator.validate(
            rule: loopSameDir,
            existingRules: [],
            availablePresets: [harness.jpegPreset],
            defaultOutputLocation: .sameFolder
        )
        XCTAssertFalse(sameDirRes.isValid)

        // input inside output
        let loopNestedInOutput = WatchFolderRule(
            name: "Input Inside Output",
            inputDirectoryPath: sandbox.subDir.path,
            presetID: harness.jpegPreset.id,
            outputDestination: .customDirectory(path: sandbox.inboxDir.path, bookmarkData: nil)
        )
        XCTAssertFalse(WatchFolderValidator.validate(rule: loopNestedInOutput, existingRules: [], availablePresets: [harness.jpegPreset]).isValid)

        // Output path pointing to a regular file
        let existingFile = try writeSyntheticPNG(to: sandbox.root.appendingPathComponent("not_a_dir.png"))
        let fileAsOutput = WatchFolderRule(
            name: "File Output",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            outputDestination: .customDirectory(path: existingFile.path, bookmarkData: nil)
        )
        XCTAssertFalse(WatchFolderValidator.validate(rule: fileAsOutput, existingRules: [], availablePresets: [harness.jpegPreset]).isValid)

        // Duplicate directory & overlapping recursive rules
        let parentRule = WatchFolderRule(
            name: "Parent Recursive",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: true,
            includeSubdirectories: true,
            outputDestination: .defaultSubfolder
        )
        let duplicateRule = WatchFolderRule(
            name: "Dup",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            outputDestination: .defaultSubfolder
        )
        XCTAssertFalse(WatchFolderValidator.validate(rule: duplicateRule, existingRules: [parentRule], availablePresets: [harness.jpegPreset]).isValid)

        let childOverlapRule = WatchFolderRule(
            name: "Child Overlap",
            inputDirectoryPath: sandbox.subDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: true,
            outputDestination: .defaultSubfolder
        )
        XCTAssertFalse(WatchFolderValidator.validate(rule: childOverlapRule, existingRules: [parentRule], availablePresets: [harness.jpegPreset]).isValid)

        // Valid subfolder produces non-nil informational loop-exclusion warning
        let validSubfolder = WatchFolderRule(
            name: "Valid Subfolder",
            inputDirectoryPath: sandbox.secondInboxDir.path,
            presetID: harness.jpegPreset.id,
            outputDestination: .defaultSubfolder
        )
        let validRes = WatchFolderValidator.validate(rule: validSubfolder, existingRules: [parentRule], availablePresets: [harness.jpegPreset])
        XCTAssertTrue(validRes.isValid)
        XCTAssertNotNil(validRes.warningMessage)
    }

    // MARK: - 3. FileStabilityDetector

    func testFileStabilityDetectorCases() async throws {
        let sandbox = try makeSandbox(name: "Stability")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let detector = FileStabilityDetector(settleDelaySeconds: 0.04, maxWaitSeconds: 0.5, requiredStableObservations: 2)

        // 1. Stable regular file
        let stableURL = try writeSyntheticPNG(to: sandbox.inboxDir.appendingPathComponent("stable.png"))
        let stableOutcome = await detector.waitForStability(of: stableURL)
        if case .stable(let fp) = stableOutcome {
            XCTAssertGreaterThan(fp.fileSize, 0)
        } else {
            XCTFail("Expected .stable outcome, got \(stableOutcome)")
        }

        // 2. Temporary / hidden files ignored
        let tempNames = [".DS_Store", "partial.part", "download.crdownload", "draft.tmp", "~$word.docx", "LocalConvert-scratch.png"]
        for name in tempNames {
            let tempFile = sandbox.inboxDir.appendingPathComponent(name)
            try Data("abc".utf8).write(to: tempFile)
            let outcome = await detector.waitForStability(of: tempFile)
            if case .ignored = outcome {
                // expected
            } else {
                XCTFail("Expected .ignored for temp file \(name), got \(outcome)")
            }
        }

        // 3. Symlink ignored
        let linkURL = sandbox.inboxDir.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: stableURL)
        let linkOutcome = await detector.waitForStability(of: linkURL)
        if case .ignored = linkOutcome {
            // expected
        } else {
            XCTFail("Expected .ignored for symlink, got \(linkOutcome)")
        }

        // 4. Zero-byte file times out
        let zeroURL = sandbox.inboxDir.appendingPathComponent("empty.png")
        try Data().write(to: zeroURL)
        let fastTimeoutDetector = FileStabilityDetector(settleDelaySeconds: 0.03, maxWaitSeconds: 0.16, requiredStableObservations: 2)
        let zeroOutcome = await fastTimeoutDetector.waitForStability(of: zeroURL)
        if case .timedOut = zeroOutcome {
            // expected
        } else {
            XCTFail("Expected .timedOut for empty file, got \(zeroOutcome)")
        }

        // 5. File deleted before completion
        let deletedURL = sandbox.inboxDir.appendingPathComponent("vanishing.png")
        let deletedOutcome = await detector.waitForStability(of: deletedURL)
        if case .ignored = deletedOutcome {
            // expected
        } else {
            XCTFail("Expected .ignored for missing file, got \(deletedOutcome)")
        }

        // 6. Growing file waits until writes finish then stabilizes
        let growingURL = sandbox.inboxDir.appendingPathComponent("growing.bin")
        try Data(repeating: 1, count: 64).write(to: growingURL)
        let writeTask = Task.detached {
            for chunk in 0..<4 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if let handle = try? FileHandle(forWritingTo: growingURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(repeating: UInt8(chunk + 2), count: 128))
                }
            }
        }
        let growingDetector = FileStabilityDetector(settleDelaySeconds: 0.06, maxWaitSeconds: 2.0, requiredStableObservations: 2)
        let growingOutcome = await growingDetector.waitForStability(of: growingURL)
        await writeTask.value
        if case .stable(let finalFP) = growingOutcome {
            XCTAssertEqual(finalFP.fileSize, 64 + 4 * 128)
        } else {
            XCTFail("Expected growing file to become .stable once writes finished, got \(growingOutcome)")
        }

        // 7. Continuous growth past maxWait times out
        let endlessURL = sandbox.inboxDir.appendingPathComponent("endless.bin")
        try Data(repeating: 9, count: 32).write(to: endlessURL)
        let endlessTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000)
                if Task.isCancelled { break }
                if let handle = try? FileHandle(forWritingTo: endlessURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(repeating: 7, count: 32))
                }
            }
        }
        let shortMaxDetector = FileStabilityDetector(settleDelaySeconds: 0.08, maxWaitSeconds: 0.24, requiredStableObservations: 2)
        let endlessOutcome = await shortMaxDetector.waitForStability(of: endlessURL)
        endlessTask.cancel()
        _ = await endlessTask.value
        if case .timedOut = endlessOutcome {
            // expected
        } else {
            XCTFail("Expected .timedOut for continuously modified file, got \(endlessOutcome)")
        }
    }

    // MARK: - 4. WatchFolderMonitor (Real FSEvents)

    private final class FSEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[URL]] = []
        private var names = Set<String>()

        func append(_ urls: [URL]) {
            lock.withLock {
                batches.append(urls)
                for u in urls { names.insert(u.lastPathComponent) }
            }
        }

        func snapshotNames() -> Set<String> {
            lock.withLock { names }
        }

        func count() -> Int {
            lock.withLock { names.count }
        }
    }

    func testFSEventsDetectsNewFilesExcludesOutputSubfolderAndDebouncesBursts() async throws {
        let sandbox = try makeSandbox(name: "FSEvents")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let convertedDir = sandbox.inboxDir.appendingPathComponent("Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)
        let excludedPrefix = WatchFolderPathSafety.canonicalPath(for: convertedDir)

        let recorder = FSEventRecorder()

        let monitor = WatchFolderMonitor(
            directoryURL: sandbox.inboxDir,
            includeSubdirectories: false,
            excludedCanonicalPrefixes: [excludedPrefix],
            debounceInterval: 0.12,
            onFilesChanged: { urls in
                recorder.append(urls)
            },
            onError: { _ in }
        )

        XCTAssertTrue(monitor.start())
        defer { monitor.stop() }

        // Give FSEventStream a brief settle window
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Create burst of valid files, plus one in Converted (excluded), plus one in Subfolder (non-recursive excluded)
        for i in 1...3 {
            _ = try writeSyntheticPNG(to: sandbox.inboxDir.appendingPathComponent("burst_\(i).png"))
        }
        _ = try writeSyntheticPNG(to: convertedDir.appendingPathComponent("already_out.png"))
        _ = try writeSyntheticPNG(to: sandbox.subDir.appendingPathComponent("nested.png"))

        let gotAllBurst = await waitUntil(timeoutSeconds: 6.0) {
            let names = recorder.snapshotNames()
            return names.contains("burst_1.png")
                && names.contains("burst_2.png")
                && names.contains("burst_3.png")
        }
        let deliveredNames = recorder.snapshotNames()
        XCTAssertTrue(gotAllBurst, "Expected FSEvents to deliver all burst files, got: \(deliveredNames)")
        XCTAssertFalse(deliveredNames.contains("already_out.png"), "Excluded output subfolder file must not trigger events")
        XCTAssertFalse(deliveredNames.contains("nested.png"), "Non-recursive rule must ignore nested subfolder file")

        // Clean stop -> subsequent write should not deliver to this stopped monitor
        let countBeforeStop = recorder.count()
        monitor.stop()
        _ = try writeSyntheticPNG(to: sandbox.inboxDir.appendingPathComponent("after_stop.png"))
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(recorder.count(), countBeforeStop)

        // Recursive monitor picks up files in Subfolder while still excluding Converted output directory
        let recursiveRecorder = FSEventRecorder()
        let recursiveMonitor = WatchFolderMonitor(
            directoryURL: sandbox.inboxDir,
            includeSubdirectories: true,
            excludedCanonicalPrefixes: [excludedPrefix],
            debounceInterval: 0.1,
            onFilesChanged: { urls in
                recursiveRecorder.append(urls)
            },
            onError: { _ in }
        )
        XCTAssertTrue(recursiveMonitor.start())
        defer { recursiveMonitor.stop() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = try writeSyntheticPNG(to: sandbox.subDir.appendingPathComponent("deep_new.png"))
        _ = try writeSyntheticPNG(to: convertedDir.appendingPathComponent("converted_ignored.png"))
        let gotDeep = await waitUntil(timeoutSeconds: 6.0) {
            recursiveRecorder.snapshotNames().contains("deep_new.png")
        }
        let recursiveNames = recursiveRecorder.snapshotNames()
        XCTAssertTrue(gotDeep, "Recursive monitor should detect nested file, got: \(recursiveNames)")
        XCTAssertFalse(recursiveNames.contains("converted_ignored.png"))
    }

    // MARK: - 5. End-to-End Watch Folder -> PresetExecutor -> ConversionQueue + Loop/Idempotency/Undo

    func testEndToEndFSEventsConversionIdempotencyLoopProvenanceAndUndo() async throws {
        let sandbox = try makeSandbox(name: "E2E")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let harness = makeHarness(sandbox: sandbox, targetFormat: .jpg)
        defer { harness.manager.stopAll() }

        let rule = WatchFolderRule(
            name: "E2E PNG to JPEG",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: true,
            includeSubdirectories: false,
            outputDestination: .subfolder(name: "Converted"),
            collisionPolicy: .createUnique,
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 2.0
        )
        XCTAssertTrue(harness.manager.addRule(rule).isValid)

        try? await Task.sleep(nanoseconds: 250_000_000)

        let sourceURL = sandbox.inboxDir.appendingPathComponent("photo.png")
        try writeSyntheticPNG(to: sourceURL, width: 48, height: 32, red: 200, green: 80, blue: 40)
        let sourceHashBefore = try sha256Hex(of: sourceURL)

        let completed = await waitUntil(timeoutSeconds: 10.0) {
            harness.manager.records.first(where: { $0.fileName == "photo.png" })?.state == .completed
        }
        XCTAssertTrue(completed, "Expected Watch Folder conversion of photo.png to complete; records: \(harness.manager.records)")

        let record = try XCTUnwrap(harness.manager.records.first { $0.fileName == "photo.png" })
        XCTAssertEqual(record.outputPaths.count, 1)
        let outputURL = URL(fileURLWithPath: try XCTUnwrap(record.outputPaths.first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(outputURL.deletingLastPathComponent().lastPathComponent, "Converted")
        XCTAssertEqual(outputURL.pathExtension.lowercased(), "jpg")

        // Verify source file untouched
        XCTAssertEqual(try sha256Hex(of: sourceURL), sourceHashBefore)

        // 1. Idempotency: rescanning must NOT re-queue unchanged file
        let outputsBeforeRescan = try FileManager.default.contentsOfDirectory(at: outputURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        harness.manager.handleDetectedFiles([sourceURL], for: rule.id)
        try? await Task.sleep(nanoseconds: 250_000_000)
        let outputsAfterRescan = try FileManager.default.contentsOfDirectory(at: outputURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(outputsBeforeRescan.count, outputsAfterRescan.count, "Unchanged source must be suppressed by idempotency check")

        // 2. Provenance loop prevention: copying converted output back into watched inbox must be ignored
        let copiedBackURL = sandbox.inboxDir.appendingPathComponent("reimported_output.jpg")
        try FileManager.default.copyItem(at: outputURL, to: copiedBackURL)
        let ignoredCopiedBack = await waitUntil(timeoutSeconds: 4.0) {
            harness.manager.records.first(where: { $0.fileName == "reimported_output.jpg" })?.state == .ignored
        }
        XCTAssertTrue(ignoredCopiedBack, "Generated output copied back into watched root must be ignored by provenance tracking")

        // 3. Modified content -> new fingerprint triggers reprocessing
        try writeSyntheticPNG(to: sourceURL, width: 64, height: 48, red: 20, green: 210, blue: 90)
        harness.manager.handleDetectedFiles([sourceURL], for: rule.id)
        let reprocessed = await waitUntil(timeoutSeconds: 10.0) {
            let count = (try? FileManager.default.contentsOfDirectory(at: outputURL.deletingLastPathComponent(), includingPropertiesForKeys: nil).count) ?? 0
            return count >= 2
        }
        XCTAssertTrue(reprocessed, "Modified source file should be reprocessed with unique filename")

        // 4. Global Undo removes generated output while preserving source
        XCTAssertTrue(harness.undoCoordinator.canUndo)
        _ = await harness.undoCoordinator.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testCollisionPoliciesSkipOverwriteCreateUniqueAndIncompatibleRetry() async throws {
        let sandbox = try makeSandbox(name: "CollisionAndRetry")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let harness = makeHarness(sandbox: sandbox, targetFormat: .jpg)
        defer { harness.manager.stopAll() }

        let convertedDir = sandbox.inboxDir.appendingPathComponent("Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: convertedDir, withIntermediateDirectories: true)

        // Pre-seed collision file
        let existingTarget = convertedDir.appendingPathComponent("collide.jpg")
        let sentinelData = Data("PREEXISTING_SENTINEL".utf8)
        try sentinelData.write(to: existingTarget)

        // Case A: .skip keeps sentinel untouched
        let skipRule = WatchFolderRule(
            name: "Skip Collision",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: true,
            outputDestination: .subfolder(name: "Converted"),
            collisionPolicy: .skip,
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 1.0
        )
        XCTAssertTrue(harness.manager.addRule(skipRule).isValid)

        let src = try writeSyntheticPNG(to: sandbox.inboxDir.appendingPathComponent("collide.png"))
        harness.manager.handleDetectedFiles([src], for: skipRule.id)

        // Incompatible text file -> cleanly ignored
        let textFile = sandbox.inboxDir.appendingPathComponent("notes.txt")
        try Data("hello watch folder".utf8).write(to: textFile)
        harness.manager.handleDetectedFiles([textFile], for: skipRule.id)

        let incompatibleIgnored = await waitUntil(timeoutSeconds: 6.0) {
            harness.manager.records.first(where: { $0.fileName == "notes.txt" })?.state == .ignored
        }
        XCTAssertTrue(incompatibleIgnored)

        let skipFinished = await waitUntil(timeoutSeconds: 8.0) {
            let state = harness.manager.records.first(where: { $0.fileName == "collide.png" })?.state
            return state == .completed || state == .failed || state == .ignored
        }
        XCTAssertTrue(skipFinished)
        XCTAssertEqual(try Data(contentsOf: existingTarget), sentinelData, ".skip collision policy must preserve preexisting output")

        // Case B: .overwrite replaces preexisting target
        var overwriteRule = skipRule
        overwriteRule.collisionPolicy = .overwrite
        XCTAssertTrue(harness.manager.updateRule(overwriteRule).isValid)
        harness.manager.handleDetectedFiles([src], for: overwriteRule.id, forceReprocess: true)

        let overwriteCompleted = await waitUntil(timeoutSeconds: 8.0) {
            harness.manager.records.first(where: { $0.fileName == "collide.png" })?.state == .completed
        }
        XCTAssertTrue(overwriteCompleted)
        XCTAssertNotEqual(try Data(contentsOf: existingTarget), sentinelData, ".overwrite should replace existing output file")

        // Case C: Failure & Retry recovery
        let brokenSource = sandbox.inboxDir.appendingPathComponent("corrupt_retry.png")
        try Data("not-a-valid-png".utf8).write(to: brokenSource)
        harness.manager.handleDetectedFiles([brokenSource], for: overwriteRule.id)

        let failedRecord = await waitUntil(timeoutSeconds: 8.0) {
            harness.manager.records.first(where: { $0.fileName == "corrupt_retry.png" })?.state == .failed
        }
        XCTAssertTrue(failedRecord, "Corrupt input image should transition WatchFolderFileRecord to .failed")

        let rec = try XCTUnwrap(harness.manager.records.first { $0.fileName == "corrupt_retry.png" })
        XCTAssertTrue(rec.canRetry)

        // Repair source file and retry
        try writeSyntheticPNG(to: brokenSource)
        harness.manager.retryRecord(id: rec.id)

        let retriedSuccess = await waitUntil(timeoutSeconds: 8.0) {
            harness.manager.records.first(where: { $0.fileName == "corrupt_retry.png" })?.state == .completed
        }
        XCTAssertTrue(retriedSuccess, "Retry after fixing file should complete conversion")
    }

    func testConcurrentBurstRespectsQueueExecutionWithoutDroppingFiles() async throws {
        let sandbox = try makeSandbox(name: "ConcurrentBurst")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let harness = makeHarness(sandbox: sandbox, targetFormat: .webp)
        defer { harness.manager.stopAll() }

        let rule = WatchFolderRule(
            name: "WebP Batch",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: true,
            outputDestination: .subfolder(name: "Converted"),
            collisionPolicy: .createUnique,
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 1.5
        )
        XCTAssertTrue(harness.manager.addRule(rule).isValid)

        var inputs: [URL] = []
        for idx in 1...6 {
            let url = try writeSyntheticPNG(
                to: sandbox.inboxDir.appendingPathComponent("batch_\(idx).png"),
                red: UInt8(idx * 30),
                green: 120,
                blue: 200
            )
            inputs.append(url)
        }

        harness.manager.handleDetectedFiles(inputs, for: rule.id)

        let allDone = await waitUntil(timeoutSeconds: 15.0) {
            let completedCount = harness.manager.records.filter { $0.ruleID == rule.id && $0.state == .completed }.count
            return completedCount == 6
        }
        XCTAssertTrue(allDone, "All 6 burst files should convert via ConversionQueue, got: \(harness.manager.records)")

        let outDir = sandbox.inboxDir.appendingPathComponent("Converted", isDirectory: true)
        let webps = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "webp" }
        XCTAssertEqual(webps.count, 6)
    }

    // MARK: - 6. Lifecycle, Wake/Volume Unmount, Preset Deletion, Bookmarks & UI State

    func testLifecyclePresetDeletionVolumeUnmountBookmarksAndMenuBarSummary() async throws {
        let sandbox = try makeSandbox(name: "Lifecycle")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let harness = makeHarness(sandbox: sandbox)
        defer { harness.manager.stopAll() }

        // Bookmark create & resolve round-trip
        if let bookmark = WatchFolderBookmarkManager.createBookmark(for: sandbox.inboxDir) {
            let resolved = WatchFolderBookmarkManager.resolveBookmark(bookmark)
            XCTAssertNotNil(resolved)
            XCTAssertEqual(
                WatchFolderPathSafety.canonicalPath(for: resolved!.url),
                WatchFolderPathSafety.canonicalPath(for: sandbox.inboxDir)
            )
        }

        let rule = WatchFolderRule(
            name: "Volume Watch",
            inputDirectoryPath: sandbox.inboxDir.path,
            presetID: harness.jpegPreset.id,
            isEnabled: true,
            outputDestination: .defaultSubfolder,
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 0.8
        )
        XCTAssertTrue(harness.manager.addRule(rule).isValid)
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .active)

        // Volume unmount / missing folder -> error state, then restore -> active
        let tempMovedPath = sandbox.root.appendingPathComponent("TemporarilyDetached", isDirectory: true)
        try FileManager.default.moveItem(at: sandbox.inboxDir, to: tempMovedPath)
        harness.manager.handleSystemWakeOrVolumeChange()
        XCTAssertTrue(harness.manager.rules.first?.lastStatus.isError ?? false)

        try FileManager.default.moveItem(at: tempMovedPath, to: sandbox.inboxDir)
        harness.manager.handleSystemWakeOrVolumeChange()
        XCTAssertEqual(harness.manager.rules.first?.lastStatus, .active)

        // Deleted preset invalidates active rule safely
        harness.presetManager.delete(id: harness.jpegPreset.id)
        harness.manager.validateActivePresetsAfterChange()
        XCTAssertTrue(harness.manager.rules.first?.lastStatus.isError ?? false)
        XCTAssertTrue(harness.manager.rules.first?.isPaused ?? false)

        // State machine transition invariants
        XCTAssertTrue(WatchFolderFileState.pending.canTransition(to: .stabilizing))
        XCTAssertTrue(WatchFolderFileState.processing.canTransition(to: .completed))
        XCTAssertFalse(WatchFolderFileState.processing.canTransition(to: .stabilizing))

        // AppState + MenuBar summary integration check (isolated store path)
        let appSandbox = try makeSandbox(name: "MenuSummary")
        defer { try? FileManager.default.removeItem(at: appSandbox.root) }
        let appState = AppState(
            undoCoordinator: harness.undoCoordinator,
            watchFolderStoreURL: appSandbox.storeDir.appendingPathComponent("app_watch_folders.json")
        )
        defer { appState.watchFolderManager.stopAll() }

        if let builtInPreset = PresetManager.shared.presets.first {
            let menuRule = WatchFolderRule(
                name: "Menu Test",
                inputDirectoryPath: appSandbox.inboxDir.path,
                presetID: builtInPreset.id,
                isEnabled: true,
                outputDestination: .defaultSubfolder
            )
            let res = appState.watchFolderManager.addRule(menuRule)
            XCTAssertTrue(res.isValid)
            let activeSummary = MenuBarManager.watchFolderStatusSummary(for: appState)
            XCTAssertTrue(activeSummary.contains("Watch Folders:"))
            appState.watchFolderManager.pauseAll()
            let pausedSummary = MenuBarManager.watchFolderStatusSummary(for: appState)
            XCTAssertTrue(pausedSummary.contains("Paused"))
            appState.watchFolderManager.removeRule(id: menuRule.id)
        }

        // Termination cleanup stops monitoring cleanly without crashing
        AppLifecycleManager.shared.prepareForTermination(appState: appState)
    }
}

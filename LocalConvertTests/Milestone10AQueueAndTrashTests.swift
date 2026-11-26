import XCTest
import SwiftUI
import AppKit
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone10AQueueAndTrashTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M10A-QueueTrash-\(UUID().uuidString)")
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

    private func ensureImageRegistryRegistered() -> ConversionRegistry {
        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: ImageConversionEngine())
        } else if registry.findEngine(from: .png, to: .jpg, options: .default) == nil {
            registry.register(engine: ImageConversionEngine())
        }
        return registry
    }

    @discardableResult
    private func writeSyntheticPNG(to url: URL, width: Int = 32, height: Int = 32) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 180, count: width * height * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) {
            pixels[idx] = 255
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
        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeIsolatedSettings() -> AppSettings {
        AppSettings(defaults: sandbox.makeUserDefaults())
    }

    private func makeQueueStore(filename: String = "pending_queue.json") -> PersistentQueueStore {
        PersistentQueueStore(directoryURL: sandbox.applicationSupportURL, filename: filename)
    }

    // MARK: - 1. PersistentQueueStore Tests

    func testPersistentQueueStoreAtomicSaveLoadAndClear() throws {
        let store = makeQueueStore()
        let src1 = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("alpha.png"))
        let src2 = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("beta.png"))

        let batchID = UUID()
        let ruleID = UUID()
        var opts = ConversionOptions.default
        opts.imageQuality = 0.72
        opts.preserveMetadata = false

        let job1 = ConversionJob(
            id: UUID(),
            inputURLs: [src1],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: sandbox.outputsURL,
            options: opts,
            batchID: batchID,
            presetName: "Web Optimized",
            source: .manual
        )
        let job2 = ConversionJob(
            id: UUID(),
            inputURLs: [src2],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: sandbox.outputsURL,
            options: .default,
            batchID: batchID,
            presetName: "WF Rule",
            source: .watchFolder,
            watchFolderRuleID: ruleID,
            watchFolderRuleName: "Inbox"
        )

        XCTAssertTrue(store.save(jobs: [job1, job2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        // Verify no leftover atomic temp files
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: sandbox.applicationSupportURL.path)
        XCTAssertFalse(dirContents.contains { $0.contains(".tmp.") })

        let loaded = store.load()
        XCTAssertFalse(loaded.wasCorrupted)
        XCTAssertEqual(loaded.droppedMissingOrInvalidCount, 0)
        XCTAssertEqual(loaded.droppedDuplicateCount, 0)
        XCTAssertEqual(loaded.recoveredJobs.count, 2)

        XCTAssertEqual(loaded.recoveredJobs[0].id, job1.id)
        XCTAssertEqual(loaded.recoveredJobs[0].inputURLs.first?.standardizedFileURL, src1.standardizedFileURL)
        XCTAssertEqual(loaded.recoveredJobs[0].outputFormat, .jpg)
        XCTAssertEqual(loaded.recoveredJobs[0].options.imageQuality, 0.72)
        XCTAssertEqual(loaded.recoveredJobs[0].options.preserveMetadata, false)
        XCTAssertEqual(loaded.recoveredJobs[0].batchID, batchID)
        XCTAssertEqual(loaded.recoveredJobs[0].presetName, "Web Optimized")
        XCTAssertEqual(loaded.recoveredJobs[0].source, .manual)

        XCTAssertEqual(loaded.recoveredJobs[1].id, job2.id)
        XCTAssertEqual(loaded.recoveredJobs[1].source, .watchFolder)
        XCTAssertEqual(loaded.recoveredJobs[1].watchFolderRuleID, ruleID)
        XCTAssertEqual(loaded.recoveredJobs[1].watchFolderRuleName, "Inbox")

        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let afterClear = store.load()
        XCTAssertTrue(afterClear.recoveredJobs.isEmpty)
        XCTAssertFalse(afterClear.wasCorrupted)
    }

    func testPersistentQueueStoreFiltersMissingDeletedSymlinkAndDirectoryInputs() throws {
        let store = makeQueueStore()
        let validFile = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("valid.png"))
        let deletedFile = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("deleted.png"))
        let symlinkURL = sandbox.documentsURL.appendingPathComponent("symlink.png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: validFile)
        let folderURL = sandbox.documentsURL.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let validJob = ConversionJob(inputURLs: [validFile], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let deletedJob = ConversionJob(inputURLs: [deletedFile], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let symlinkJob = ConversionJob(inputURLs: [symlinkURL], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let dirJob = ConversionJob(inputURLs: [folderURL], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)

        XCTAssertTrue(store.save(jobs: [validJob, deletedJob, symlinkJob, dirJob]))

        // Delete one source file before relaunch recovery
        try FileManager.default.removeItem(at: deletedFile)

        let loaded = store.load()
        XCTAssertFalse(loaded.wasCorrupted)
        XCTAssertEqual(loaded.recoveredJobs.map(\.id), [validJob.id])
        XCTAssertEqual(loaded.droppedMissingOrInvalidCount, 3)
    }

    func testPersistentQueueStoreDeduplicatesDuplicateEntries() throws {
        let store = makeQueueStore()
        let validFile = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("dup.png"))

        let jobA = ConversionJob(id: UUID(), inputURLs: [validFile], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let jobB = ConversionJob(id: UUID(), inputURLs: [validFile], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)

        // Write snapshot manually with both duplicate ID and duplicate canonical signature
        let entryA = try XCTUnwrap(PersistedQueueEntry(job: jobA))
        let entryB = try XCTUnwrap(PersistedQueueEntry(job: jobB))
        let snapshot = PersistedQueueSnapshot(schemaVersion: 1, updatedAt: Date(), entries: [entryA, entryA, entryB])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: sandbox.applicationSupportURL, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: store.fileURL, options: .atomic)

        let loaded = store.load()
        XCTAssertEqual(loaded.recoveredJobs.count, 1)
        XCTAssertEqual(loaded.recoveredJobs.first?.id, jobA.id)
        XCTAssertEqual(loaded.droppedDuplicateCount, 2)
    }

    func testPersistentQueueStoreQuarantinesCorruptedAndEmptyJSONWithoutCrashing() throws {
        let store = makeQueueStore()
        try FileManager.default.createDirectory(at: sandbox.applicationSupportURL, withIntermediateDirectories: true)

        // 1. Corrupt JSON bytes
        try Data("{not valid json!!!".utf8).write(to: store.fileURL, options: .atomic)
        let corruptResult = store.load()
        XCTAssertTrue(corruptResult.wasCorrupted)
        XCTAssertTrue(corruptResult.recoveredJobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        let dirItems = try FileManager.default.contentsOfDirectory(atPath: sandbox.applicationSupportURL.path)
        XCTAssertTrue(dirItems.contains { $0.hasPrefix("pending_queue.corrupted.") && $0.hasSuffix(".json") })

        // 2. Empty 0-byte file
        try Data().write(to: store.fileURL, options: .atomic)
        let emptyResult = store.load()
        XCTAssertTrue(emptyResult.wasCorrupted)
        XCTAssertTrue(emptyResult.recoveredJobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testPersistentQueueStoreDefaultFileURLUsesTestSandboxNeverHostAppSupport() {
        let defaultURL = PersistentQueueStore.defaultFileURL.standardizedFileURL
        XCTAssertTrue(defaultURL.path.hasPrefix(sandbox.rootURL.standardizedFileURL.path))
        let hostAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .standardizedFileURL.path
        XCTAssertFalse(defaultURL.path.hasPrefix(hostAppSupport))
    }

    // MARK: - 2. AppSettings Tests

    func testAppSettingsNewDefaultsAndUserDefaultsIsolation() {
        let isolatedDefaults = sandbox.makeUserDefaults()
        let settings = makeIsolatedSettings()
        XCTAssertFalse(settings.defaults === UserDefaults.standard)
        XCTAssertFalse(isolatedDefaults === UserDefaults.standard)

        let stdTrashBefore = UserDefaults.standard.object(forKey: "settings.moveOriginalsToTrashAfterSuccess")
        let stdRestoreBefore = UserDefaults.standard.object(forKey: "settings.restoreUnfinishedQueueOnLaunch")

        XCTAssertFalse(settings.moveOriginalsToTrashAfterSuccess)
        XCTAssertTrue(settings.restoreUnfinishedQueueOnLaunch)

        settings.moveOriginalsToTrashAfterSuccess = true
        settings.restoreUnfinishedQueueOnLaunch = false

        XCTAssertTrue(settings.defaults.bool(forKey: "settings.moveOriginalsToTrashAfterSuccess"))
        XCTAssertFalse(settings.defaults.bool(forKey: "settings.restoreUnfinishedQueueOnLaunch"))

        // Host UserDefaults.standard must remain untouched
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "settings.moveOriginalsToTrashAfterSuccess") as? Bool,
            stdTrashBefore as? Bool
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "settings.restoreUnfinishedQueueOnLaunch") as? Bool,
            stdRestoreBefore as? Bool
        )
    }

    func testAppSettingsResetToDefaultsRestoresNewM10ASettings() {
        let settings = makeIsolatedSettings()
        settings.moveOriginalsToTrashAfterSuccess = true
        settings.restoreUnfinishedQueueOnLaunch = false

        XCTAssertTrue(settings.moveOriginalsToTrashAfterSuccess)
        XCTAssertFalse(settings.restoreUnfinishedQueueOnLaunch)

        settings.resetToDefaults()

        XCTAssertFalse(settings.moveOriginalsToTrashAfterSuccess)
        XCTAssertTrue(settings.restoreUnfinishedQueueOnLaunch)
    }

    // MARK: - 3. ConversionManager Queue Persistence & Recovery

    func testConversionManagerPersistsPendingAndClearsOnCompletionAndCancellation() async throws {
        let registry = ensureImageRegistryRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let store = makeQueueStore()
        let settings = makeIsolatedSettings()

        let manager = ConversionManager(
            registry: registry,
            historyManager: history,
            settings: settings,
            queueStore: store,
            restoreQueueOnInit: false
        )

        let src1 = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("q1.png"))
        let job1 = ConversionJob(inputURLs: [src1], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)

        manager.registerPending(job: job1)
        XCTAssertEqual(store.load().recoveredJobs.map(\.id), [job1.id])

        let doneExpectation = expectation(description: "Job completes and clears store")
        manager.submit(job: job1) { status in
            if case .completed = status {
                doneExpectation.fulfill()
            }
        }
        await fulfillment(of: [doneExpectation], timeout: 5.0)
        XCTAssertTrue(store.load().recoveredJobs.isEmpty, "Completed job must be cleared from pending queue store")

        let src2 = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("q2.png"))
        let job2 = ConversionJob(inputURLs: [src2], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        manager.registerPending(job: job2)
        XCTAssertEqual(store.load().recoveredJobs.map(\.id), [job2.id])

        manager.cancel(jobId: job2.id)
        XCTAssertTrue(store.load().recoveredJobs.isEmpty, "Cancelled job must be cleared from pending queue store")
    }

    func testConversionManagerRestoresUnfinishedQueueOnRelaunchWhenEnabled() throws {
        let registry = ensureImageRegistryRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let store = makeQueueStore()
        let settings = makeIsolatedSettings()
        settings.restoreUnfinishedQueueOnLaunch = true

        let srcKeep = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("keep.png"))
        let srcDrop = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("drop.png"))
        let keepJob = ConversionJob(inputURLs: [srcKeep], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let dropJob = ConversionJob(inputURLs: [srcDrop], inputFormat: .png, outputFormat: .webp, outputDirectory: sandbox.outputsURL)

        XCTAssertTrue(store.save(jobs: [keepJob, dropJob]))
        try FileManager.default.removeItem(at: srcDrop)

        let relaunched = ConversionManager(
            registry: registry,
            historyManager: history,
            settings: settings,
            queueStore: store,
            restoreQueueOnInit: true
        )

        XCTAssertTrue(relaunched.hasRestoredQueueBanner)
        XCTAssertEqual(relaunched.restoredQueueCount, 1)
        XCTAssertEqual(relaunched.restoredSkippedMissingCount, 1)
        XCTAssertEqual(relaunched.activeJobs.map(\.id), [keepJob.id])
        XCTAssertEqual(relaunched.status(for: keepJob.id), .waiting)

        // Disk snapshot should also have pruned the missing entry
        XCTAssertEqual(store.load().recoveredJobs.map(\.id), [keepJob.id])

        let consumed = relaunched.consumeRestoredJobsForConvertTab()
        XCTAssertEqual(consumed.map(\.id), [keepJob.id])
        XCTAssertFalse(relaunched.hasRestoredQueueBanner)
        XCTAssertTrue(relaunched.activeJobs.isEmpty)
        XCTAssertTrue(store.load().recoveredJobs.isEmpty)
    }

    func testConversionManagerSkipsQueueRecoveryWhenSettingDisabled() throws {
        let registry = ensureImageRegistryRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let store = makeQueueStore()
        let settings = makeIsolatedSettings()
        settings.restoreUnfinishedQueueOnLaunch = false

        let src = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("ignored.png"))
        let job = ConversionJob(inputURLs: [src], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        XCTAssertTrue(store.save(jobs: [job]))

        let manager = ConversionManager(
            registry: registry,
            historyManager: history,
            settings: settings,
            queueStore: store,
            restoreQueueOnInit: true
        )

        XCTAssertFalse(manager.hasRestoredQueueBanner)
        XCTAssertEqual(manager.restoredQueueCount, 0)
        XCTAssertTrue(manager.activeJobs.isEmpty)
    }

    func testConversionManagerDismissRestoredQueueBannerClearsPlaceholderAndStore() throws {
        let registry = ensureImageRegistryRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let store = makeQueueStore()
        let settings = makeIsolatedSettings()

        let src = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("dismiss.png"))
        let job = ConversionJob(inputURLs: [src], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        XCTAssertTrue(store.save(jobs: [job]))

        let manager = ConversionManager(
            registry: registry,
            historyManager: history,
            settings: settings,
            queueStore: store,
            restoreQueueOnInit: true
        )
        XCTAssertTrue(manager.hasRestoredQueueBanner)

        manager.dismissRestoredQueueBanner(clearRestoredJobs: true)
        XCTAssertFalse(manager.hasRestoredQueueBanner)
        XCTAssertEqual(manager.restoredQueueCount, 0)
        XCTAssertTrue(manager.activeJobs.isEmpty)
        XCTAssertTrue(store.load().recoveredJobs.isEmpty)
    }

    // MARK: - 4. Move-Originals-to-Trash Safety Guard Tests

    func testTrashEligibilityDisabledByDefaultDoesNotTrash() throws {
        let src = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("in.png"))
        let out = sandbox.outputsURL.appendingPathComponent("out.jpg")
        try Data("non-empty".utf8).write(to: out)

        let job = ConversionJob(inputURLs: [src], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let result = ConversionResult(outputURL: out, outputFormat: .jpg, fileSize: 9, duration: 0.1, engineName: "Test")

        let eligibility = ConversionManager.evaluateTrashEligibility(
            job: job,
            status: .completed(result),
            moveOriginalsToTrashEnabled: false
        )
        guard case .skipped = eligibility else {
            return XCTFail("Expected .skipped when moveOriginalsToTrashEnabled is false")
        }
    }

    func testTrashEligibilityBlockedOnFailureCancellationMissingOrZeroByteOutput() throws {
        let src = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("source.png"))
        let job = ConversionJob(inputURLs: [src], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)

        let missingOut = sandbox.outputsURL.appendingPathComponent("missing.jpg")
        let missingResult = ConversionResult(outputURL: missingOut, outputFormat: .jpg, fileSize: 100, duration: 0.1, engineName: "Test")
        if case .eligible = ConversionManager.evaluateTrashEligibility(job: job, status: .completed(missingResult), moveOriginalsToTrashEnabled: true) {
            XCTFail("Must block trashing when output file is missing")
        }

        let zeroOut = sandbox.outputsURL.appendingPathComponent("zero.jpg")
        try Data().write(to: zeroOut)
        let zeroResult = ConversionResult(outputURL: zeroOut, outputFormat: .jpg, fileSize: 0, duration: 0.1, engineName: "Test")
        if case .eligible = ConversionManager.evaluateTrashEligibility(job: job, status: .completed(zeroResult), moveOriginalsToTrashEnabled: true) {
            XCTFail("Must block trashing when output file is 0 bytes")
        }

        let validOut = sandbox.outputsURL.appendingPathComponent("valid.jpg")
        try Data("valid-output-bytes".utf8).write(to: validOut)
        let validResult = ConversionResult(outputURL: validOut, outputFormat: .jpg, fileSize: 18, duration: 0.1, engineName: "Test")

        // Blocked on failure
        if case .eligible = ConversionManager.evaluateTrashEligibility(job: job, status: .failed(.unknown("boom")), moveOriginalsToTrashEnabled: true) {
            XCTFail("Must block trashing on failed status")
        }
        // Blocked on cancelled status
        if case .eligible = ConversionManager.evaluateTrashEligibility(job: job, status: .cancelled, moveOriginalsToTrashEnabled: true) {
            XCTFail("Must block trashing on cancelled status")
        }
        // Blocked when task cancellation flag is set
        if case .eligible = ConversionManager.evaluateTrashEligibility(job: job, status: .completed(validResult), moveOriginalsToTrashEnabled: true, isCancelled: true) {
            XCTFail("Must block trashing when task is cancelled")
        }
        // Blocked if additionalOutputURL is missing
        let missingExtra = sandbox.outputsURL.appendingPathComponent("missing_page2.jpg")
        let multiResult = ConversionResult(outputURL: validOut, additionalOutputURLs: [missingExtra], outputFormat: .jpg, fileSize: 18, duration: 0.1, engineName: "Test")
        if case .eligible = ConversionManager.evaluateTrashEligibility(job: job, status: .completed(multiResult), moveOriginalsToTrashEnabled: true) {
            XCTFail("Must block trashing when any additionalOutputURL is missing")
        }
    }

    func testTrashEligibilityBlockedWhenInputEqualsOutputPathIncludingSymlinkAlias() throws {
        let sameFile = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("inplace.png"))
        let jobSame = ConversionJob(inputURLs: [sameFile], inputFormat: .png, outputFormat: .png, outputDirectory: sandbox.documentsURL)
        let resultSame = ConversionResult(outputURL: sameFile, outputFormat: .png, fileSize: 128, duration: 0.1, engineName: "Test")

        if case .eligible = ConversionManager.evaluateTrashEligibility(job: jobSame, status: .completed(resultSame), moveOriginalsToTrashEnabled: true) {
            XCTFail("Must NEVER trash when input == output standardized path")
        }

        // Symlink alias pointing to same directory
        let aliasDir = sandbox.temporaryURL.appendingPathComponent("alias_docs", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasDir, withDestinationURL: sandbox.documentsURL)
        let aliasOutput = aliasDir.appendingPathComponent("inplace.png")
        let resultAlias = ConversionResult(outputURL: aliasOutput, outputFormat: .png, fileSize: 128, duration: 0.1, engineName: "Test")

        if case .eligible = ConversionManager.evaluateTrashEligibility(job: jobSame, status: .completed(resultAlias), moveOriginalsToTrashEnabled: true) {
            XCTFail("Must NEVER trash when input and output resolve to the same file via symlink")
        }
    }

    func testConversionManagerTrashesOriginalOnlyAfterVerifiedSuccessAndNeverDeletesOnFailureOrCancel() async throws {
        let registry = ensureImageRegistryRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let store = makeQueueStore()
        let settings = makeIsolatedSettings()
        let simulatedTrashDir = sandbox.temporaryURL.appendingPathComponent("SimulatedTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: simulatedTrashDir, withIntermediateDirectories: true)

        final class TrashRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [URL] = []
            var shouldThrow = false
            let trashDir: URL

            init(trashDir: URL) {
                self.trashDir = trashDir
            }

            func record(_ url: URL) throws -> URL? {
                lock.lock()
                defer { lock.unlock() }
                if shouldThrow {
                    throw CocoaError(.fileWriteNoPermission)
                }
                urls.append(url)
                let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }

            var recordedURLs: [URL] {
                lock.lock()
                defer { lock.unlock() }
                return urls
            }
        }

        let recorder = TrashRecorder(trashDir: simulatedTrashDir)
        let manager = ConversionManager(
            registry: registry,
            historyManager: history,
            settings: settings,
            queueStore: store,
            trashHandler: { url in try recorder.record(url) },
            restoreQueueOnInit: false
        )

        // Case A: Disabled by default -> original remains untouched
        settings.moveOriginalsToTrashAfterSuccess = false
        let srcA = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("keep_default.png"))
        let jobA = ConversionJob(inputURLs: [srcA], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let expA = expectation(description: "Job A complete")
        manager.submit(job: jobA) { status in
            if case .completed = status { expA.fulfill() }
        }
        await fulfillment(of: [expA], timeout: 5.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcA.path))
        XCTAssertTrue(recorder.recordedURLs.isEmpty)

        // Case B: Enabled -> trashes original only after verified non-empty JPG output
        settings.moveOriginalsToTrashAfterSuccess = true
        let srcB = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("trash_on_success.png"))
        let jobB = ConversionJob(inputURLs: [srcB], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let expB = expectation(description: "Job B complete")
        var jobBResult: ConversionResult?
        manager.submit(job: jobB) { status in
            if case .completed(let res) = status {
                jobBResult = res
                expB.fulfill()
            }
        }
        await fulfillment(of: [expB], timeout: 5.0)

        let outB = try XCTUnwrap(jobBResult?.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outB.path))
        let outSize = (try? FileManager.default.attributesOfItem(atPath: outB.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(outSize, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcB.path), "Original should have been moved to Trash")
        XCTAssertEqual(recorder.recordedURLs.map(\.standardizedFileURL), [srcB.standardizedFileURL])
        XCTAssertEqual(manager.lastTrashedInputURLs.map(\.standardizedFileURL), [srcB.standardizedFileURL])

        // Case C: Failure (corrupt input) -> must NEVER trash original
        let srcCorrupt = sandbox.documentsURL.appendingPathComponent("corrupt.png")
        try Data("not-a-real-png".utf8).write(to: srcCorrupt)
        let jobC = ConversionJob(inputURLs: [srcCorrupt], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let expC = expectation(description: "Job C failed")
        manager.submit(job: jobC) { status in
            if case .failed = status { expC.fulfill() }
        }
        await fulfillment(of: [expC], timeout: 5.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcCorrupt.path), "Failed conversion must preserve original")
        XCTAssertEqual(recorder.recordedURLs.count, 1)

        // Case D: Cancelled -> must NEVER trash original
        let srcCancel = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("cancelled.png"))
        let jobD = ConversionJob(inputURLs: [srcCancel], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let expD = expectation(description: "Job D cancelled")
        manager.submit(job: jobD) { status in
            if case .cancelled = status { expD.fulfill() }
        }
        manager.cancel(jobId: jobD.id)
        await fulfillment(of: [expD], timeout: 5.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcCancel.path), "Cancelled conversion must preserve original")
        XCTAssertEqual(recorder.recordedURLs.count, 1)

        // Case E: trashItem throws -> must NEVER fall back to permanent delete
        recorder.shouldThrow = true
        let srcE = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("trash_throws.png"))
        let jobE = ConversionJob(inputURLs: [srcE], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let expE = expectation(description: "Job E complete")
        manager.submit(job: jobE) { status in
            if case .completed = status { expE.fulfill() }
        }
        await fulfillment(of: [expE], timeout: 5.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcE.path), "Original must remain intact if trashItem throws")
    }

    // MARK: - 5. ContentView Banner & Layout Integrity

    func testContentViewRestoredBannerRendersWithin820x580WithoutReentrantPublish() throws {
        // Keep teardown/ARC deterministic around NSHostingView if any layout assertion fails.
        continueAfterFailure = true

        let artifactManager = RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: artifactManager
        )
        let undoMenu = UndoMenuController(coordinator: coordinator)
        let commandPalette = CommandPaletteController()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let metadataManager = MetadataManager(
            undoCoordinator: coordinator,
            artifactManager: artifactManager,
            historyManager: history
        )
        let appState = AppState(
            undoCoordinator: coordinator,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history
        )

        var publishCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let contentView = ContentView(
            undoCoordinator: coordinator,
            undoMenu: undoMenu,
            commandPalette: commandPalette,
            metadataManager: metadataManager
        )
        .environmentObject(appState)

        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(publishCount, 0, "Initial ContentView layout must not trigger reentrant AppState.objectWillChange")

        // Seed persistent queue (including a missing file to exercise the longer banner copy) and restore.
        let src = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("banner.png"))
        let missing = try writeSyntheticPNG(to: sandbox.documentsURL.appendingPathComponent("missing_banner.png"))
        let restoredJob = ConversionJob(inputURLs: [src], inputFormat: .png, outputFormat: .jpg, outputDirectory: sandbox.outputsURL)
        let missingJob = ConversionJob(inputURLs: [missing], inputFormat: .png, outputFormat: .webp, outputDirectory: sandbox.outputsURL)
        let store = PersistentQueueStore(directoryURL: sandbox.applicationSupportURL)
        XCTAssertTrue(store.save(jobs: [restoredJob, missingJob]))
        try FileManager.default.removeItem(at: missing)

        appState.conversionManager.restoreUnfinishedQueueIfEnabled()
        XCTAssertTrue(appState.conversionManager.hasRestoredQueueBanner)
        XCTAssertEqual(appState.conversionManager.restoredQueueCount, 1)
        XCTAssertEqual(appState.conversionManager.restoredSkippedMissingCount, 1)

        // Reset after intentional restoreUnfinishedQueueIfEnabled() publish, then verify layout itself emits 0 publishes.
        publishCount = 0
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(publishCount, 0, "Laying out ContentView with restored queue banner must not trigger reentrant AppState.objectWillChange")

        let fittingSize = hosting.fittingSize
        XCTAssertGreaterThan(fittingSize.width, 0)
        XCTAssertLessThanOrEqual(fittingSize.width, 820)
        XCTAssertGreaterThan(fittingSize.height, 0)
        XCTAssertLessThanOrEqual(fittingSize.height, 580)
        XCTAssertEqual(hosting.bounds.size, NSSize(width: 820, height: 580))

        appState.conversionManager.dismissRestoredQueueBanner(clearRestoredJobs: true)
        XCTAssertFalse(appState.conversionManager.hasRestoredQueueBanner)

        publishCount = 0
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(publishCount, 0, "Dismissing restored queue banner and re-laying out must not trigger reentrant AppState.objectWillChange")
    }
}

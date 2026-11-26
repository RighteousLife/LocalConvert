import XCTest
import Foundation
@testable import LocalConvert

final class Phase58TestIsolationTests: XCTestCase {

    private var userAppSupportPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.localconvert.app", isDirectory: true)
            .standardizedFileURL.path
    }

    private var userCachesPath: String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.localconvert.app", isDirectory: true)
            .standardizedFileURL.path
    }

    private var userLogsPath: String {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/LocalConvert", isDirectory: true)
            .standardizedFileURL.path
    }

    // MARK: - 1. Sandbox Creation & Deterministic Cleanup

    func testSandboxCreationAndDeterministicCleanup() throws {
        let sandbox = try TestSandbox(runID: "CreateCleanup-\(UUID().uuidString)")
        let fm = FileManager.default

        for dir in sandbox.allSubdirectories {
            var isDir: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue, "Missing sandbox directory: \(dir.path)")
            XCTAssertFalse(dir.standardizedFileURL.path.hasPrefix(userAppSupportPath))
        }

        let marker = sandbox.outputsURL.appendingPathComponent("marker.txt")
        try Data("ok".utf8).write(to: marker)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))

        let defaults = sandbox.makeUserDefaults()
        defaults.set("isolated_value", forKey: "phase58.cleanupCheck")
        XCTAssertEqual(defaults.string(forKey: "phase58.cleanupCheck"), "isolated_value")

        let cleanupResult = sandbox.cleanup()
        if case .failure(let error) = cleanupResult {
            XCTFail("Sandbox cleanup failed: \(error.localizedDescription)")
        }
        XCTAssertFalse(fm.fileExists(atPath: sandbox.rootURL.path), "Sandbox root must be removed after cleanup()")
        XCTAssertNil(UserDefaults.standard.string(forKey: "phase58.cleanupCheck"))
    }

    // MARK: - 2. Parallel Test Sandbox Isolation

    func testParallelTestSandboxIsolation() async throws {
        let count = 8
        let roots = try await withThrowingTaskGroup(of: String.self) { group in
            for idx in 0..<count {
                group.addTask {
                    let sb = try TestSandbox(runID: "Parallel-\(idx)-\(UUID().uuidString)")
                    defer {
                        let res = sb.cleanup()
                        if case .failure(let err) = res {
                            XCTFail("Parallel sandbox \(sb.rootURL.path) cleanup failed: \(err.localizedDescription)")
                        }
                    }

                    let fileURL = sb.applicationSupportURL.appendingPathComponent("worker.txt")
                    let payload = "worker-\(idx)-\(sb.runID)"
                    try Data(payload.utf8).write(to: fileURL)

                    let defaults = sb.makeUserDefaults()
                    defaults.set(idx, forKey: "phase58.workerIndex")

                    try await Task.sleep(nanoseconds: 25_000_000)

                    let readBack = try String(contentsOf: fileURL, encoding: .utf8)
                    XCTAssertEqual(readBack, payload)
                    XCTAssertEqual(defaults.integer(forKey: "phase58.workerIndex"), idx)
                    XCTAssertNil(UserDefaults.standard.object(forKey: "phase58.workerIndex"))
                    return sb.rootURL.standardizedFileURL.path
                }
            }

            var collected: [String] = []
            for try await root in group {
                collected.append(root)
            }
            return collected
        }

        XCTAssertEqual(Set(roots).count, count, "Every parallel sandbox must own a unique directory")
        for path in roots {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Parallel sandbox must be cleaned up: \(path)")
        }
    }

    // MARK: - 3. UserDefaults Isolation Protects UserDefaults.standard

    func testUserDefaultsIsolationProtectsStandardDefaults() throws {
        let sandbox = try TestSandbox(runID: "Defaults-\(UUID().uuidString)")
        defer {
            AppStoragePaths.clearTestOverrides()
            _ = sandbox.cleanup()
        }

        AppStoragePaths.setTestOverrides(sandboxRoot: sandbox.rootURL, defaultsSuiteName: sandbox.userDefaultsSuiteName)

        XCTAssertTrue(AppStoragePaths.isRunningUnderTests)
        XCTAssertFalse(AppStoragePaths.userDefaults === UserDefaults.standard, "Test runtime must never return UserDefaults.standard")

        let canaryDir = sandbox.outputsURL.appendingPathComponent("CanaryDest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: canaryDir, withIntermediateDirectories: true)

        let stdLastBefore = UserDefaults.standard.string(forKey: "com.localconvert.lastUsedOutputDir")
        let stdLocBefore = UserDefaults.standard.string(forKey: "com.localconvert.outputLocation")
        let stdCustomBefore = UserDefaults.standard.string(forKey: "com.localconvert.customOutputDir")

        OutputManager.lastUsedDirectory = canaryDir
        OutputManager.savePreferences(location: .customFolder, customDirectory: canaryDir)

        XCTAssertEqual(OutputManager.lastUsedDirectory?.standardizedFileURL, canaryDir.standardizedFileURL)
        let loaded = OutputManager.loadSavedPreferences()
        XCTAssertEqual(loaded.location, .customFolder)
        XCTAssertEqual(loaded.customDirectory?.standardizedFileURL, canaryDir.standardizedFileURL)

        XCTAssertEqual(UserDefaults.standard.string(forKey: "com.localconvert.lastUsedOutputDir"), stdLastBefore)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "com.localconvert.outputLocation"), stdLocBefore)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "com.localconvert.customOutputDir"), stdCustomBefore)
    }

    // MARK: - 4. Recovery / Undo / History / AudioEditor Storage Isolation

    @MainActor
    func testRecoveryUndoHistoryAndAudioEditorIsolation() async throws {
        let sandbox = try TestSandbox(runID: "RecoveryUndo-\(UUID().uuidString)")
        defer {
            AppStoragePaths.clearTestOverrides()
            _ = sandbox.cleanup()
        }

        AppStoragePaths.setTestOverrides(sandboxRoot: sandbox.rootURL, defaultsSuiteName: sandbox.userDefaultsSuiteName)

        let historyMgr = HistoryManager()
        let artifactMgr = RecoveryArtifactManager()
        let coordinator = UndoRedoCoordinator(artifactManager: artifactMgr)
        let presetStore = PresetStore()
        let audioRecoveryDir = ProjectPersistenceService.recoveryDirectoryURL
        let _ = ClipProxyCache()
        let audioPresetStore = AudioEffectPresetStore()

        let pathsToVerify = [
            historyMgr.fileURL.standardizedFileURL.path,
            await artifactMgr.baseDirectoryURL.standardizedFileURL.path,
            coordinator.journalDirectoryURL.standardizedFileURL.path,
            presetStore.fileURL.standardizedFileURL.path,
            audioRecoveryDir.standardizedFileURL.path,
            AppStoragePaths.audioEditorProxiesDirectory.standardizedFileURL.path
        ]

        let rootPrefix = sandbox.rootURL.standardizedFileURL.path + "/"
        for path in pathsToVerify {
            XCTAssertTrue(path.hasPrefix(rootPrefix), "Expected path inside sandbox \(rootPrefix), got: \(path)")
            XCTAssertFalse(path.hasPrefix(userAppSupportPath), "Must never target user Application Support: \(path)")
            XCTAssertFalse(path.hasPrefix(userCachesPath), "Must never target user Caches: \(path)")
        }

        let audioPresetsPath = AppStoragePaths.audioEditorPresetsFileURL.standardizedFileURL.path
        XCTAssertTrue(audioPresetsPath.hasPrefix(rootPrefix))
        XCTAssertFalse(audioPresetsPath.hasPrefix(userAppSupportPath))
        XCTAssertGreaterThanOrEqual(audioPresetStore.presets.count, 0)

        let source = sandbox.temporaryURL.appendingPathComponent("artifact_src.bin")
        try Data("recovery-blob".utf8).write(to: source)
        _ = try await artifactMgr.stageFileByCopying(from: source)
        let manifestURL = await artifactMgr.baseDirectoryURL.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    // MARK: - 5. Watch Folder Storage Isolation

    @MainActor
    func testWatchFolderStorageIsolation() throws {
        let sandbox = try TestSandbox(runID: "WatchFolder-\(UUID().uuidString)")
        defer {
            AppStoragePaths.clearTestOverrides()
            _ = sandbox.cleanup()
        }

        AppStoragePaths.setTestOverrides(sandboxRoot: sandbox.rootURL, defaultsSuiteName: sandbox.userDefaultsSuiteName)

        let store = WatchFolderStore()
        let rootPrefix = sandbox.rootURL.standardizedFileURL.path + "/"
        XCTAssertTrue(store.fileURL.standardizedFileURL.path.hasPrefix(rootPrefix))
        XCTAssertFalse(store.fileURL.standardizedFileURL.path.hasPrefix(userAppSupportPath))

        let watchedInput = sandbox.documentsURL.appendingPathComponent("watched-in", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedInput, withIntermediateDirectories: true)
        let rule = WatchFolderRule(
            name: "Phase58 Isolation Rule",
            inputDirectoryPath: watchedInput.path,
            presetID: UUID(),
            isEnabled: false
        )
        store.update { $0.rules.append(rule) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.snapshot.rules.count, 1)
    }

    // MARK: - 6. Diagnostic Log Isolation

    func testDiagnosticLogIsolation() throws {
        let sandbox = try TestSandbox(runID: "DiagLog-\(UUID().uuidString)")
        defer {
            AppStoragePaths.clearTestOverrides()
            _ = sandbox.cleanup()
        }

        AppStoragePaths.setTestOverrides(sandboxRoot: sandbox.rootURL, defaultsSuiteName: sandbox.userDefaultsSuiteName)

        let logDir = DiagnosticLogManager.logDirectoryURL.standardizedFileURL.path
        let rootPrefix = sandbox.rootURL.standardizedFileURL.path + "/"
        XCTAssertTrue(logDir.hasPrefix(rootPrefix), "Expected diagnostic logs inside sandbox, got: \(logDir)")
        XCTAssertFalse(logDir.hasPrefix(userLogsPath), "Must never write diagnostic logs to user Library/Logs: \(logDir)")

        AppStoragePaths.userDefaults.set(true, forKey: "settings.verboseLogging")
        XCTAssertTrue(DiagnosticLogManager.isVerboseLoggingEnabled())
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "settings.verboseLogging") && sandbox.makeUserDefaults() === UserDefaults.standard)

        DiagnosticLogManager.logVerbose(category: "Phase58", message: "Isolated log event from /Users/tester/secret.png")
        let contents = DiagnosticLogManager.readDiagnosticLogContents()
        XCTAssertTrue(contents.contains("Isolated log event from ~/secret.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DiagnosticLogManager.logFileURL.path))
    }
}

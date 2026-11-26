import Foundation
import os

/// Single source of truth for LocalConvert's persistent directories and `UserDefaults` domain.
/// In normal app launches this resolves to standard user Library directories (`Application Support`,
/// `Caches`, `Logs`) and `UserDefaults.standard`. Under XCTest / XCUITest, all paths automatically
/// resolve into an isolated temporary test sandbox unless explicitly overridden.
enum AppStoragePaths {

    private struct ThreadSafeUserDefaults: @unchecked Sendable {
        // Foundation's UserDefaults is thread-safe per Apple documentation.
        let value: UserDefaults
    }

    private struct SandboxState: Sendable {
        var overrideRoot: URL?
        var lazyProcessRoot: URL?
        var overrideDefaultsSuiteName: String?
        var lazyProcessDefaultsSuiteName: String?
        var cachedDefaultsBySuite: [String: ThreadSafeUserDefaults] = [:]
    }

    private static let lock = OSAllocatedUnfairLock<SandboxState>(initialState: SandboxState())

    static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil
            || env["XCTestConfigurationFilePath"] != nil
            || env["LOCALCONVERT_UITEST"] == "1"
            || (env["LOCALCONVERT_TEST_SANDBOX"].map { !$0.isEmpty } ?? false)
            || (env["LOCALCONVERT_UITEST_SANDBOX"].map { !$0.isEmpty } ?? false)
    }

    static func setTestOverrides(sandboxRoot: URL?, defaultsSuiteName: String?) {
        lock.withLock { state in
            state.overrideRoot = sandboxRoot?.standardizedFileURL
            state.overrideDefaultsSuiteName = defaultsSuiteName
        }
    }

    static func clearTestOverrides() {
        setTestOverrides(sandboxRoot: nil, defaultsSuiteName: nil)
    }

    static var activeTestSandboxRoot: URL? {
        let env = ProcessInfo.processInfo.environment
        if let envRoot = nonEmptyEnv("LOCALCONVERT_TEST_SANDBOX", in: env)
            ?? nonEmptyEnv("LOCALCONVERT_UITEST_SANDBOX", in: env) {
            let root = URL(fileURLWithPath: envRoot, isDirectory: true).standardizedFileURL
            ensureSandboxSubdirectories(under: root)
            return root
        }

        if let overridden = lock.withLock({ $0.overrideRoot }) {
            ensureSandboxSubdirectories(under: overridden)
            return overridden
        }

        guard isRunningUnderTests else {
            return nil
        }

        let lazyRoot: URL = lock.withLock { state in
            if let existing = state.lazyProcessRoot {
                return existing
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let runID = "process-\(pid)-\(UUID().uuidString.prefix(8))"
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalConvertTests", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
                .standardizedFileURL
            state.lazyProcessRoot = root
            return root
        }
        ensureSandboxSubdirectories(under: lazyRoot)
        return lazyRoot
    }

    static var userDefaults: UserDefaults {
        let env = ProcessInfo.processInfo.environment
        let overrideSuite = lock.withLock { $0.overrideDefaultsSuiteName }
        return resolveUserDefaults(
            isTesting: isRunningUnderTests,
            environment: env,
            overrideSuite: overrideSuite
        )
    }

    static func resolveUserDefaults(
        isTesting: Bool,
        environment: [String: String],
        overrideSuite: String?
    ) -> UserDefaults {
        guard isTesting else {
            return UserDefaults.standard
        }

        if let suite = nonEmptyEnv("LOCALCONVERT_TEST_DEFAULTS_SUITE", in: environment) ?? overrideSuite {
            return cachedIsolatedDefaults(forSuite: suite)
        }

        let lazySuite: String = lock.withLock { state in
            if let existing = state.lazyProcessDefaultsSuiteName {
                return existing
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let name = "com.localconvert.tests.process.\(pid).\(UUID().uuidString)"
            state.lazyProcessDefaultsSuiteName = name
            return name
        }
        return cachedIsolatedDefaults(forSuite: lazySuite)
    }

    private static func cachedIsolatedDefaults(forSuite suite: String) -> UserDefaults {
        let entry = lock.withLock { state -> ThreadSafeUserDefaults in
            if let cached = state.cachedDefaultsBySuite[suite] {
                return cached
            }
            guard let isolated = UserDefaults(suiteName: suite) else {
                fatalError("Refusing to fall back to UserDefaults.standard under tests for suite: \(suite)")
            }
            let wrapped = ThreadSafeUserDefaults(value: isolated)
            state.cachedDefaultsBySuite[suite] = wrapped
            return wrapped
        }
        return entry.value
    }

    // MARK: - Application Storage Directories

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.localconvert.app"
    }

    static var applicationSupportDirectory: URL {
        if let sandbox = activeTestSandboxRoot {
            let dir = sandbox.appendingPathComponent("ApplicationSupport", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var cachesDirectory: URL {
        if let sandbox = activeTestSandboxRoot {
            let dir = sandbox.appendingPathComponent("Caches", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var logsDirectory: URL {
        if let sandbox = activeTestSandboxRoot {
            let dir = sandbox.appendingPathComponent("Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return lib
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LocalConvert", isDirectory: true)
    }

    static var historyFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("history.json", isDirectory: false)
    }

    static var presetsFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("presets.json", isDirectory: false)
    }

    static var watchFoldersFileURL: URL {
        if let sandbox = activeTestSandboxRoot {
            let dir = sandbox.appendingPathComponent("WatchFolders", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("watch_folders.json", isDirectory: false)
        }
        return applicationSupportDirectory.appendingPathComponent("watch_folders.json", isDirectory: false)
    }

    static var recoveryArtifactsDirectory: URL {
        if let sandbox = activeTestSandboxRoot {
            let dir = sandbox
                .appendingPathComponent("Recovery", isDirectory: true)
                .appendingPathComponent("RecoveryArtifacts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return applicationSupportDirectory.appendingPathComponent("RecoveryArtifacts", isDirectory: true)
    }

    static var undoHistoryDirectory: URL {
        if let sandbox = activeTestSandboxRoot {
            let dir = sandbox.appendingPathComponent("UndoHistory", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return applicationSupportDirectory.appendingPathComponent("UndoHistory", isDirectory: true)
    }

    static var audioEditorRecoveryDirectory: URL {
        if let sandbox = activeTestSandboxRoot {
            let dir = sandbox
                .appendingPathComponent("Recovery", isDirectory: true)
                .appendingPathComponent("AudioEditorRecovery", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return applicationSupportDirectory.appendingPathComponent("AudioEditorRecovery", isDirectory: true)
    }

    static var audioEditorProxiesDirectory: URL {
        cachesDirectory.appendingPathComponent("AudioEditorProxies", isDirectory: true)
    }

    struct AudioWorkspaceStoragePaths: Sendable, Equatable {
        let libraryDatabaseURL: URL
        let waveformCacheDirectory: URL
        let artworkCacheDirectory: URL
        let playerStateURL: URL
        let exportStagingDirectory: URL
    }

    static var audioEditorPresetsFileURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("AudioEditorPresets", isDirectory: true)
            .appendingPathComponent("effect-chain-presets.json", isDirectory: false)
    }

    // MARK: - Audio Workspace Storage Paths (Phase 62 Foundation)

    /// Pure path resolver enabling tests to verify both production and sandboxed resolution
    /// without mutating real user Application Support or Caches directories.
    static func resolveAudioWorkspacePaths(
        isTesting: Bool,
        sandboxRoot: URL?,
        applicationSupportBase: URL,
        cachesBase: URL,
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.localconvert.app"
    ) -> AudioWorkspaceStoragePaths {
        let appSupportRoot: URL
        let cachesRoot: URL
        if isTesting, let sandboxRoot {
            let std = sandboxRoot.standardizedFileURL
            appSupportRoot = std.appendingPathComponent("ApplicationSupport", isDirectory: true)
            cachesRoot = std.appendingPathComponent("Caches", isDirectory: true)
        } else {
            appSupportRoot = applicationSupportBase.appendingPathComponent(bundleID, isDirectory: true)
            cachesRoot = cachesBase.appendingPathComponent(bundleID, isDirectory: true)
        }

        let libraryDir = appSupportRoot.appendingPathComponent("AudioLibrary", isDirectory: true)
        return AudioWorkspaceStoragePaths(
            libraryDatabaseURL: libraryDir.appendingPathComponent("library.sqlite", isDirectory: false),
            waveformCacheDirectory: cachesRoot.appendingPathComponent("AudioWaveformCache", isDirectory: true),
            artworkCacheDirectory: cachesRoot.appendingPathComponent("AudioArtworkCache", isDirectory: true),
            playerStateURL: libraryDir.appendingPathComponent("player-session.json", isDirectory: false),
            exportStagingDirectory: cachesRoot.appendingPathComponent("AudioExportStaging", isDirectory: true)
        )
    }

    static var audioLibraryDatabaseURL: URL {
        let dir = applicationSupportDirectory.appendingPathComponent("AudioLibrary", isDirectory: true)
        ensureDirectoryExistsIdempotently(dir)
        return dir.appendingPathComponent("library.sqlite", isDirectory: false)
    }

    static var audioWaveformCacheDirectory: URL {
        let dir = cachesDirectory.appendingPathComponent("AudioWaveformCache", isDirectory: true)
        ensureDirectoryExistsIdempotently(dir)
        return dir
    }

    static var audioArtworkCacheDirectory: URL {
        let dir = cachesDirectory.appendingPathComponent("AudioArtworkCache", isDirectory: true)
        ensureDirectoryExistsIdempotently(dir)
        return dir
    }

    static var audioPlayerStateURL: URL {
        let dir = applicationSupportDirectory.appendingPathComponent("AudioLibrary", isDirectory: true)
        ensureDirectoryExistsIdempotently(dir)
        return dir.appendingPathComponent("player-session.json", isDirectory: false)
    }

    static var audioExportStagingDirectory: URL {
        let dir = cachesDirectory.appendingPathComponent("AudioExportStaging", isDirectory: true)
        ensureDirectoryExistsIdempotently(dir)
        return dir
    }

    // MARK: - Helpers

    private static func ensureDirectoryExistsIdempotently(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func nonEmptyEnv(_ key: String, in env: [String: String]) -> String? {
        guard let value = env[key], !value.isEmpty else { return nil }
        return value
    }

    private static func ensureSandboxSubdirectories(under root: URL) {
        let fm = FileManager.default
        for name in [
            "ApplicationSupport",
            "Caches",
            "Documents",
            "Recovery",
            "UndoHistory",
            "WatchFolders",
            "Logs",
            "Temporary",
            "Outputs"
        ] {
            let sub = root.appendingPathComponent(name, isDirectory: true)
            if !fm.fileExists(atPath: sub.path) {
                try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
            }
        }
    }
}

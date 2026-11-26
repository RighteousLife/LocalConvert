import Foundation

/// Shared, isolated sandbox for `LocalConvertTests` and `LocalConvertUITests`.
/// Directs all persistent files, caches, logs, recovery artifacts, and `UserDefaults`
/// into `<temporary-root>/LocalConvertTests/<test-run-id>/`, never touching
/// `~/Library/Application Support/com.localconvert.app/`.
struct TestSandbox: Sendable {

    static var sandboxesBaseURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvertTests", isDirectory: true)
    }

    let runID: String
    let rootURL: URL

    let applicationSupportURL: URL
    let cachesURL: URL
    let documentsURL: URL
    let recoveryURL: URL
    let undoHistoryURL: URL
    let watchFoldersURL: URL
    let logsURL: URL
    let temporaryURL: URL
    let outputsURL: URL

    let userDefaultsSuiteName: String

    init(runID: String = UUID().uuidString) throws {
        let trimmed = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeID = trimmed.isEmpty ? UUID().uuidString : trimmed
        self.runID = safeID

        let base = Self.sandboxesBaseURL.standardizedFileURL
        let root = base.appendingPathComponent(safeID, isDirectory: true).standardizedFileURL
        self.rootURL = root

        self.applicationSupportURL = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        self.cachesURL = root.appendingPathComponent("Caches", isDirectory: true)
        self.documentsURL = root.appendingPathComponent("Documents", isDirectory: true)
        self.recoveryURL = root.appendingPathComponent("Recovery", isDirectory: true)
        self.undoHistoryURL = root.appendingPathComponent("UndoHistory", isDirectory: true)
        self.watchFoldersURL = root.appendingPathComponent("WatchFolders", isDirectory: true)
        self.logsURL = root.appendingPathComponent("Logs", isDirectory: true)
        self.temporaryURL = root.appendingPathComponent("Temporary", isDirectory: true)
        self.outputsURL = root.appendingPathComponent("Outputs", isDirectory: true)

        self.userDefaultsSuiteName = "com.localconvert.tests.sandbox.\(safeID)"

        let fm = FileManager.default
        for dir in allSubdirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var allSubdirectories: [URL] {
        [
            applicationSupportURL,
            cachesURL,
            documentsURL,
            recoveryURL,
            undoHistoryURL,
            watchFoldersURL,
            logsURL,
            temporaryURL,
            outputsURL
        ]
    }

    var historyFileURL: URL {
        applicationSupportURL.appendingPathComponent("history.json", isDirectory: false)
    }

    var presetsFileURL: URL {
        applicationSupportURL.appendingPathComponent("presets.json", isDirectory: false)
    }

    var watchFoldersFileURL: URL {
        watchFoldersURL.appendingPathComponent("watch_folders.json", isDirectory: false)
    }

    var recoveryArtifactsURL: URL {
        recoveryURL.appendingPathComponent("RecoveryArtifacts", isDirectory: true)
    }

    var audioEditorRecoveryURL: URL {
        recoveryURL.appendingPathComponent("AudioEditorRecovery", isDirectory: true)
    }

    var audioEditorProxiesURL: URL {
        cachesURL.appendingPathComponent("AudioEditorProxies", isDirectory: true)
    }

    var audioEditorPresetsFileURL: URL {
        applicationSupportURL
            .appendingPathComponent("AudioEditorPresets", isDirectory: true)
            .appendingPathComponent("effect-chain-presets.json", isDirectory: false)
    }

    func makeUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: userDefaultsSuiteName) ?? UserDefaults.standard
    }

    var launchEnvironment: [String: String] {
        [
            "LOCALCONVERT_UITEST": "1",
            "LOCALCONVERT_TEST_SANDBOX": rootURL.path,
            "LOCALCONVERT_UITEST_SANDBOX": rootURL.path,
            "LOCALCONVERT_UITEST_OUTPUT": outputsURL.path,
            "LOCALCONVERT_TEST_DEFAULTS_SUITE": userDefaultsSuiteName
        ]
    }

    @discardableResult
    func cleanup() -> Result<Void, Error> {
        let basePrefix = Self.sandboxesBaseURL.standardizedFileURL.path + "/"
        let rootPath = rootURL.standardizedFileURL.path

        guard rootPath.hasPrefix(basePrefix) else {
            return .failure(NSError(
                domain: "TestSandbox",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Refused cleanup outside \(basePrefix): \(rootPath)"
                ]
            ))
        }

        if let suiteDefaults = UserDefaults(suiteName: userDefaultsSuiteName) {
            suiteDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: rootPath) {
            do {
                try fm.removeItem(at: rootURL)
            } catch {
                return .failure(NSError(
                    domain: "TestSandbox",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to remove sandbox at \(rootPath): \(error.localizedDescription)"
                    ]
                ))
            }
        }
        return .success(())
    }
}

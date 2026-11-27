import XCTest
import SwiftUI
import AppKit
import Combine
@testable import LocalConvert

@MainActor
final class Milestone14ASystemAndLocalizationTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = true
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M14A-System-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        OutputReservationCoordinator.clearReservedOutputURLs()
    }

    override func tearDown() async throws {
        DuplicateFinderSheetController.shared.dismiss()
        TextAndArchiveUtilityController.shared.dismiss()
        BatchRenamerSheetController.shared.dismiss()
        SettingsNavigationCoordinator.shared.requestedTab = nil
        SettingsNavigationCoordinator.shared.diagnosticsExportPromptRequested = false
        OutputReservationCoordinator.clearReservedOutputURLs()
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

    private func makeIsolatedAppState() -> AppState {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        let undo = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: artifacts
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return AppState(
            undoCoordinator: undo,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history,
            uitestingOutputDirectory: sandbox.outputsURL
        )
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - 1. CLIBridgeInstaller Tests

    func testCLIBridgeInstallerInstallsExecutableScriptAndRemovesCleanly() throws {
        let tempHome = sandbox.rootURL.appendingPathComponent("MockHome", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)

        let installer = CLIBridgeInstaller(
            baseDirectory: tempHome,
            appBundlePathOverride: "/Applications/LocalConvert.app"
        )

        XCTAssertFalse(installer.isInstalled)
        XCTAssertFalse(installer.status().isInstalled)

        let installedStatus = try installer.install()
        XCTAssertTrue(installedStatus.isInstalled)
        XCTAssertTrue(installedStatus.isExecutable)
        XCTAssertTrue(installer.isInstalled)
        XCTAssertEqual(installedStatus.scriptURL, tempHome.appendingPathComponent(".local/bin/localconvert"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installer.scriptURL.path))

        let attrs = try FileManager.default.attributesOfItem(atPath: installer.scriptURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o755)

        let scriptText = try String(contentsOf: installer.scriptURL, encoding: .utf8)
        XCTAssertTrue(scriptText.hasPrefix("#!/usr/bin/env bash"))
        XCTAssertTrue(scriptText.contains("open -a"))
        XCTAssertFalse(scriptText.contains("--args \"$@\""))

        // Reinstall atomically succeeds
        let reinstalledStatus = try installer.install()
        XCTAssertTrue(reinstalledStatus.isInstalled)

        // PATH detection
        let pathStatus = installer.status(environment: ["PATH": "/usr/bin:\(installer.binDirectoryURL.path)"])
        XCTAssertTrue(pathStatus.isBinDirectoryInPATH)

        // Remove cleans up and is idempotent
        let removedStatus = try installer.remove()
        XCTAssertFalse(removedStatus.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path))
        XCTAssertNoThrow(try installer.remove())
    }

    // MARK: - 2. DiagnosticBundleExporter & Path Redaction Tests

    func testDiagnosticBundleExporterRedactsUserPathsAndCreatesValidZip() throws {
        let testText = """
        Input file: /Users/alice/Documents/Private/tax-return.pdf
        Output file: /Users/bob.smith/Desktop/output.zip
        Auth: Bearer secret_token_12345 password=mysecretpass
        Location: latitude=37.7749 longitude=-122.4194
        """
        let redacted = DiagnosticBundleExporter.redact(testText, username: "alice")
        XCTAssertFalse(redacted.contains("/Users/alice"))
        XCTAssertFalse(redacted.contains("/Users/bob.smith"))
        XCTAssertTrue(redacted.contains("/Users/<redacted>/Documents/Private/tax-return.pdf"))
        XCTAssertTrue(redacted.contains("/Users/<redacted>/Desktop/output.zip"))
        XCTAssertFalse(redacted.contains("secret_token_12345"))
        XCTAssertFalse(redacted.contains("mysecretpass"))
        XCTAssertTrue(redacted.contains("[GPS_REDACTED]"))

        let logsDir = sandbox.logsURL
        let sampleLogURL = logsDir.appendingPathComponent("localconvert.log")
        try "[2026-11-27T12:00:00Z] [ERROR] [Conversion] Failed at /Users/charlie/Movies/clip.mov\n"
            .write(to: sampleLogURL, atomically: true, encoding: .utf8)

        let exporter = DiagnosticBundleExporter(
            logsDirectoryOverride: logsDir,
            stagingParentDirectory: sandbox.temporaryURL,
            currentUsernameOverride: "charlie"
        )

        let destinationZip = sandbox.outputsURL.appendingPathComponent("diag-bundle.zip")
        let result = try exporter.exportBundle(
            to: destinationZip,
            policy: .createUnique,
            additionalLogContents: "Note from /Users/charlie/Desktop/file.png"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertGreaterThan(result.fileSizeBytes, 0)
        XCTAssertTrue(result.includedFiles.contains("system-summary.txt"))
        XCTAssertTrue(result.includedFiles.contains("logs-localconvert.log"))

        // Extract exported zip to verify redacted contents via bsdtar
        let verifyDir = sandbox.temporaryURL.appendingPathComponent("VerifyDiagExtract", isDirectory: true)
        try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-xf", result.outputURL.path, "-C", verifyDir.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let extractedRoot = verifyDir.appendingPathComponent("LocalConvert-Diagnostics", isDirectory: true)
        let extractedLog = try String(
            contentsOf: extractedRoot.appendingPathComponent("logs-localconvert.log"),
            encoding: .utf8
        )
        XCTAssertFalse(extractedLog.contains("/Users/charlie"))
        XCTAssertTrue(extractedLog.contains("/Users/<redacted>/Movies/clip.mov"))

        let extractedNotes = try String(
            contentsOf: extractedRoot.appendingPathComponent("additional-notes.log"),
            encoding: .utf8
        )
        XCTAssertFalse(extractedNotes.contains("/Users/charlie"))
        XCTAssertTrue(extractedNotes.contains("/Users/<redacted>/Desktop/file.png"))

        // Second export with .createUnique avoids overwriting existing zip
        let secondResult = try exporter.exportBundle(to: destinationZip, policy: .createUnique)
        XCTAssertNotEqual(secondResult.outputURL, result.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondResult.outputURL.path))
    }

    // MARK: - 3. Opt-In UpdateCheckService Tests

    private final class MockUpdateTransport: UpdateCheckTransport, @unchecked Sendable {
        var callCount = 0
        var requestedURLs: [URL] = []
        var nextResult: Result<(Data, Int), Error>

        init(result: Result<(Data, Int), Error>) {
            self.nextResult = result
        }

        func fetchLatestReleaseData(from url: URL) async throws -> (Data, URLResponse) {
            callCount += 1
            requestedURLs.append(url)
            switch nextResult {
            case .success(let (data, statusCode)):
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                return (data, response)
            case .failure(let error):
                throw error
            }
        }
    }

    func testUpdateCheckServiceIsOptInAndComparesSemanticVersions() async throws {
        let jsonPayload = """
        {
          "tag_name": "v1.4.2",
          "name": "LocalConvert 1.4.2",
          "html_url": "https://github.com/RighteousLife/LocalConvert/releases/tag/v1.4.2",
          "published_at": "2026-11-27T10:00:00Z",
          "body": "Everyday Mac improvements"
        }
        """.data(using: .utf8)!

        let transport = MockUpdateTransport(result: .success((jsonPayload, 200)))
        let service = UpdateCheckService(
            transport: transport,
            currentVersionProvider: { "1.0.0" }
        )

        // Opt-in guarantee: constructing UpdateCheckService performs ZERO network requests
        XCTAssertEqual(transport.callCount, 0)
        XCTAssertNil(service.lastResult)

        let result = try await service.checkForUpdates()
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(result.currentVersion, "1.0.0")
        XCTAssertEqual(result.latestVersion, "1.4.2")
        XCTAssertTrue(result.isUpdateAvailable)
        XCTAssertEqual(result.releaseURL?.absoluteString, "https://github.com/RighteousLife/LocalConvert/releases/tag/v1.4.2")

        // Same version -> no update available
        let upToDateService = UpdateCheckService(
            transport: MockUpdateTransport(result: .success((jsonPayload, 200))),
            currentVersionProvider: { "1.4.2" }
        )
        let sameResult = try await upToDateService.checkForUpdates()
        XCTAssertFalse(sameResult.isUpdateAvailable)

        // Pure semver comparison checks
        XCTAssertTrue(UpdateCheckService.isVersion("1.2.0", newerThan: "1.0.9"))
        XCTAssertTrue(UpdateCheckService.isVersion("v2.0.0", newerThan: "2.0.0-beta.1"))
        XCTAssertFalse(UpdateCheckService.isVersion("1.0.0-rc.1", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateCheckService.isVersion("1.0.0", newerThan: "1.0.0"))

        // Rejects non-HTTPS release URL
        let insecurePayload = """
        {
          "tag_name": "v2.0.0",
          "html_url": "http://github.com/RighteousLife/LocalConvert/releases/tag/v2.0.0"
        }
        """.data(using: .utf8)!
        let insecureService = UpdateCheckService(
            transport: MockUpdateTransport(result: .success((insecurePayload, 200))),
            currentVersionProvider: { "1.0.0" }
        )
        do {
            _ = try await insecureService.checkForUpdates()
            XCTFail("Expected non-HTTPS release URL to be rejected")
        } catch let error as UpdateCheckError {
            XCTAssertEqual(error, .insecureReleaseURL("http://github.com/RighteousLife/LocalConvert/releases/tag/v2.0.0"))
        }
    }

    // MARK: - 4. CommandPalette & MenuBar Registration Tests

    func testCommandPaletteRegistersAndRoutesMilestone14AActionsHeadlessly() {
        let appState = makeIsolatedAppState()
        let items = CommandPaletteCatalog.buildItems(presets: [])

        let expectedTitles = [
            "Batch Rename Files",
            "Find Duplicate Files (SHA-256)",
            "Archive Inspector & Encrypted ZIP",
            "Markdown / JSON / Base64 / URL-to-PDF",
            "Capture Screen Text (OCR)",
            "Record Voice Memo",
            "Export Redacted Diagnostics"
        ]

        for title in expectedTitles {
            XCTAssertTrue(
                items.contains(where: { $0.title == title }),
                "Missing Command Palette item '\(title)'"
            )
        }

        // Batch Rename with empty queue gives non-blocking feedback on .convert
        let batchRenameItem = items.first(where: { $0.action == .batchRenameFiles })!
        CommandPaletteRouter.execute(batchRenameItem, appState: appState)
        XCTAssertEqual(appState.selectedTab, .convert)
        XCTAssertNotNil(appState.dropFeedbackText)
        XCTAssertFalse(BatchRenamerSheetController.shared.isPresented)

        // Duplicate Finder opens controller
        let dupItem = items.first(where: { $0.action == .findDuplicateFiles })!
        CommandPaletteRouter.execute(dupItem, appState: appState)
        XCTAssertTrue(DuplicateFinderSheetController.shared.isPresented)
        DuplicateFinderSheetController.shared.dismiss()

        // Archive Inspector opens .archive mode
        let archiveItem = items.first(where: { $0.action == .openArchiveInspector })!
        CommandPaletteRouter.execute(archiveItem, appState: appState)
        XCTAssertTrue(TextAndArchiveUtilityController.shared.isPresented)
        XCTAssertEqual(TextAndArchiveUtilityController.shared.selectedMode, .archive)
        TextAndArchiveUtilityController.shared.dismiss()

        // Markdown / JSON / Base64 / URL-to-PDF opens .textTools mode
        let textItem = items.first(where: { $0.action == .openTextAndURLUtility })!
        CommandPaletteRouter.execute(textItem, appState: appState)
        XCTAssertTrue(TextAndArchiveUtilityController.shared.isPresented)
        XCTAssertEqual(TextAndArchiveUtilityController.shared.selectedMode, .textTools)
        TextAndArchiveUtilityController.shared.dismiss()

        // Export Redacted Diagnostics switches to Settings -> Advanced without modal NSSavePanel
        let diagItem = items.first(where: { $0.action == .exportRedactedDiagnostics })!
        CommandPaletteRouter.execute(diagItem, appState: appState)
        XCTAssertEqual(appState.selectedTab, .settings)
        XCTAssertEqual(SettingsNavigationCoordinator.shared.requestedTab, .advanced)
    }

    func testMenuBarManagerIncludesScreenOCRAndVoiceMemoActions() {
        let idleMenu = MenuBarManager.shared.buildMenu(
            statusString: "Ready",
            watchSummary: nil,
            hasWatchRules: false,
            isWatchPaused: false,
            isRecordingVoiceMemo: false
        )
        let idleTitles = idleMenu.items.map(\.title)
        XCTAssertTrue(idleTitles.contains(String(localized: "Capture Screen Text (OCR)")))
        XCTAssertTrue(idleTitles.contains(String(localized: "Record Voice Memo")))

        let recordingMenu = MenuBarManager.shared.buildMenu(
            statusString: "Ready",
            watchSummary: nil,
            hasWatchRules: false,
            isWatchPaused: false,
            isRecordingVoiceMemo: true
        )
        let stopItem = recordingMenu.items.first(where: { $0.title == String(localized: "Stop Voice Memo Recording") })
        XCTAssertNotNil(stopItem)
        XCTAssertEqual(stopItem?.state, .on)
    }

    func testContentViewAndSettingsLayoutWithin820x580WithoutAppStatePublish() {
        let appState = makeIsolatedAppState()
        var publishCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let content = ContentView(
            undoCoordinator: appState.undoCoordinator,
            undoMenu: UndoMenuController.shared,
            commandPalette: CommandPaletteController.shared,
            metadataManager: MetadataManager.shared
        ).environmentObject(appState)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(publishCount, 0)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 820)

        let settingsHost = NSHostingView(rootView: SettingsView().environmentObject(appState))
        settingsHost.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        settingsHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(publishCount, 0)
        XCTAssertLessThanOrEqual(settingsHost.fittingSize.width, 820)
    }

    // MARK: - 5. Info.plist & project.yml Microphone Permission Check

    func testInfoPlistAndProjectYmlContainMicrophoneUsageDescription() throws {
        let root = repoRootURL()
        let plistURL = root.appendingPathComponent("LocalConvert/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plistObj = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        let dict = try XCTUnwrap(plistObj as? [String: Any])
        let micDesc = try XCTUnwrap(dict["NSMicrophoneUsageDescription"] as? String)
        XCTAssertFalse(micDesc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let projectYMLURL = root.appendingPathComponent("project.yml")
        let projectYMLText = try String(contentsOf: projectYMLURL, encoding: .utf8)
        XCTAssertTrue(projectYMLText.contains("NSMicrophoneUsageDescription:"))
    }

    // MARK: - 6. Localizable.xcstrings Worker 4 & Milestone 14A Parity

    func testLocalizableCatalogIncludesMilestone14AKeysWithEnglishAndTurkishParity() throws {
        let xcstringsURL = repoRootURL()
            .appendingPathComponent("LocalConvert", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings", isDirectory: false)

        let data = try Data(contentsOf: xcstringsURL)
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        let catalog = try XCTUnwrap(raw as? [String: Any])
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        XCTAssertEqual(catalog["version"] as? String, "1.0")

        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertFalse(strings.isEmpty)

        let placeholderRegex = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|llu|ld|d|@|f|\.\d+f)"#)

        // Verify ALL keys in Localizable.xcstrings have translated, non-empty en/tr values and placeholder parity.
        for key in strings.keys.sorted() {
            let entry = try XCTUnwrap(strings[key], "Missing entry for '\(key)'")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for '\(key)'")
            for lang in ["en", "tr"] {
                let unit = try XCTUnwrap(
                    (locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any],
                    "Missing stringUnit for '\(key)' (\(lang))"
                )
                XCTAssertEqual(unit["state"] as? String, "translated", "Untranslated '\(key)' (\(lang))")
                let val = try XCTUnwrap(unit["value"] as? String, "Missing string value for '\(key)' (\(lang))")
                XCTAssertFalse(val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty value for '\(key)' (\(lang))")
            }
            let enVal = ((locs["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            let trVal = ((locs["tr"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            let enCount = placeholderRegex.numberOfMatches(in: enVal, range: NSRange(enVal.startIndex..<enVal.endIndex, in: enVal))
            let trCount = placeholderRegex.numberOfMatches(in: trVal, range: NSRange(trVal.startIndex..<trVal.endIndex, in: trVal))
            XCTAssertEqual(enCount, trCount, "Placeholder mismatch for '\(key)'")
        }

        let requiredKeys: [String] = [
            // Milestone 14A
            "Batch Rename Files",
            "Find Duplicate Files (SHA-256)",
            "Archive Inspector & Encrypted ZIP",
            "Markdown / JSON / Base64 / URL-to-PDF",
            "Capture Screen Text (OCR)",
            "Record Voice Memo",
            "Stop Voice Memo Recording",
            "Export Redacted Diagnostics",
            "Export Redacted Diagnostics...",
            "Terminal CLI Helper",
            "Install CLI Helper",
            "Remove CLI Helper",
            "Software Updates",
            "Check for Updates",
            "Update available: v%@ (current: v%@).",
            "You are up to date (v%@).",
            "WhatsApp / Discord (<10 MB)",
            "Official Document PDF (<5 MB)",
            "Strip Privacy Metadata",
            "Duplicate File Finder",
            "Move Duplicates to Trash",
            "Hold to Compare Original",
            "Original (\\)",
            // ClipboardIntakeService (9)
            "The clipboard is empty.",
            "The clipboard does not contain supported files, images, or text.",
            "The image data on the clipboard could not be decoded.",
            "The text on the clipboard could not be encoded as UTF-8.",
            "The clipboard payload (%@) exceeds the maximum supported size.",
            "All copied file paths were rejected by safety validation.",
            "Could not stage clipboard content: %@",
            "Nothing to Paste",
            "Clipboard Paste Failed",
            // OutputManager filename tokens (9)
            "Source name",
            "Output extension",
            "Target format",
            "Date (YYYY-MM-DD)",
            "Time (HH-MM-SS)",
            "Resolution (WxH)",
            "Width x Height",
            "Preset name",
            "Item index",
            // ContentView restored queue plurals (2)
            "%lld unfinished conversions from your previous session were restored.",
            "%lld missing files were skipped.",
            // BatchRenamer
            "Find text",
            "Replace with",
            "Sequential numbering value is out of range",
            // AudioWorkspace
            "Audio Workspace",
            "Audio Output Device",
            "System Default",
            "No active output device",
            "Refresh Audio Devices",
            "Auto-pause other audio transport",
            "Library",
            "Hygiene",
            "Missing Files",
            "Duplicates",
            "Collections",
            "Add Playlist to Queue",
            "Sort by",
            "Audio Library Is Empty",
            "No Matching Tracks",
            "No Duplicate Tracks Detected",
            "Play / Pause Audio",
            // Milestone 14B Workers 1, 2, 3
            "Previous / Next Photo",
            "LocalConvert never checks for updates automatically in the background. A single network request to GitHub Releases is made only when you click Check for Updates.",
            "All file conversions run 100% locally and offline on your Mac with zero background telemetry. Optional user-triggered tools (Update Check and URL-to-PDF) connect to the network only when you explicitly invoke them.",
            "Hardware VideoToolbox H.264 encoding failed and no software H.264 encoder is available in the bundled FFmpeg build. Try WebM output or retry once GPU resources are available.",
            "Symbolic links are not allowed for local URL-to-PDF rendering: %@",
            "Page loading timed out after %lld seconds.",
            "Web content process terminated unexpectedly while loading the page.",
            "Output Filename Template"
        ]

        for key in requiredKeys {
            XCTAssertNotNil(strings[key], "Missing required key '\(key)' in Localizable.xcstrings")
        }

        let legacyPrivacyKey = "All file processing occurs 100% locally and offline on your Mac. LocalConvert never uploads or transmits your files, telemetry, or metadata to external servers."
        let legacyLocs = try XCTUnwrap(strings[legacyPrivacyKey]?["localizations"] as? [String: Any])
        let legacyEn = ((legacyLocs["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
        let legacyTr = ((legacyLocs["tr"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
        XCTAssertTrue(legacyEn.contains("zero background telemetry"))
        XCTAssertTrue(legacyTr.contains("telemetri"))
    }
}

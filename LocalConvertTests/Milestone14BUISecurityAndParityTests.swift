import XCTest
import SwiftUI
import AppKit
import Combine
import WebKit
@testable import LocalConvert

@MainActor
final class Milestone14BUISecurityAndParityTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUp() async throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "M14B-SecurityParity-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        OutputReservationCoordinator.clearReservedOutputURLs()
    }

    override func tearDown() async throws {
        DuplicateFinderSheetController.shared.dismiss()
        TextAndArchiveUtilityController.shared.dismiss()
        KeyboardShortcutsSheetController.shared.dismiss()
        QuickQRGeneratorController.shared.dismiss()
        OutputReservationCoordinator.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
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

    private func runExecutable(
        _ path: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessExecutionOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        if let environment {
            process.environment = environment
        }
        return try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 15)
    }

    // MARK: - 1. URLToPDFValidator Symlink & Confirmation Hardening

    func testURLToPDFValidatorRejectsDirectAndAncestorSymlinksAndRequiresUserInitiatedHTTP() throws {
        let realDir = sandbox.documentsURL.appendingPathComponent("real_html", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let realHTML = realDir.appendingPathComponent("page.html")
        try Data("<html><body><h1>Safe</h1></body></html>".utf8).write(to: realHTML)

        // Regular local HTML succeeds (even when sandbox sits under macOS root symlink /var)
        let validRequest = try URLToPDFValidator.validateAndNormalize(realHTML.absoluteString, userInitiated: false)
        XCTAssertEqual(validRequest.url, realHTML.standardizedFileURL)

        // Direct symlink file is rejected
        let directSymlink = sandbox.documentsURL.appendingPathComponent("direct_link.html")
        try FileManager.default.createSymbolicLink(at: directSymlink, withDestinationURL: realHTML)
        XCTAssertThrowsError(try URLToPDFValidator.validateAndNormalize(directSymlink.absoluteString, userInitiated: true)) { error in
            XCTAssertEqual(error as? URLToPDFValidationError, .symlinkNotAllowed(directSymlink))
        }

        // Ancestor symlink directory is rejected
        let linkedDir = sandbox.documentsURL.appendingPathComponent("linked_html_dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: realDir)
        let viaLinkedDir = linkedDir.appendingPathComponent("page.html")
        XCTAssertThrowsError(try URLToPDFValidator.validateAndNormalize(viaLinkedDir.absoluteString, userInitiated: true)) { error in
            XCTAssertEqual(error as? URLToPDFValidationError, .symlinkNotAllowed(viaLinkedDir))
        }

        // HTTP/HTTPS requires userInitiated == true
        XCTAssertThrowsError(try URLToPDFValidator.validateAndNormalize("https://example.com/doc", userInitiated: false)) { error in
            XCTAssertEqual(error as? URLToPDFValidationError, .userConfirmationRequired)
        }
        XCTAssertThrowsError(try URLToPDFValidator.validateAndNormalize("http://example.com/doc", userInitiated: false)) { error in
            XCTAssertEqual(error as? URLToPDFValidationError, .userConfirmationRequired)
        }
        let webRequest = try URLToPDFValidator.validateAndNormalize("https://example.com/doc", userInitiated: true)
        XCTAssertEqual(webRequest.url.absoluteString, "https://example.com/doc")
        XCTAssertTrue(webRequest.userInitiated)
    }

    // MARK: - 2. WebKitPDFRenderSession Headless Timeout / Termination / Cancellation Guard

    func testWebKitPDFRenderSessionTimeoutResumesOnceHeadlessly() async {
        let session = WebKitPDFRenderSession(timeoutSeconds: 0.05)
        do {
            try await session.waitForNavigation {
                // Intentionally never invoke navigation callbacks to trigger timeout
            }
            XCTFail("Expected URLToPDFValidationError.loadTimedOut")
        } catch let error as URLToPDFValidationError {
            XCTAssertEqual(error, .loadTimedOut(0.05))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Late callbacks must be ignored (no double-resume)
        session.finishNavigation(.success(()))
        session.finishNavigation(.failure(URLToPDFValidationError.webContentProcessTerminated))
        XCTAssertEqual(session.resumeCountForTesting, 1)
    }

    func testWebKitPDFRenderSessionWebContentProcessTerminationResumesOnce() async {
        let session = WebKitPDFRenderSession(timeoutSeconds: 5.0)
        let dummyWebView = WKWebView(frame: .zero)

        do {
            try await session.waitForNavigation {
                Task { @MainActor in
                    session.webViewWebContentProcessDidTerminate(dummyWebView)
                    session.finishNavigation(.success(()))
                    session.finishNavigation(.failure(CancellationError()))
                }
            }
            XCTFail("Expected URLToPDFValidationError.webContentProcessTerminated")
        } catch let error as URLToPDFValidationError {
            XCTAssertEqual(error, .webContentProcessTerminated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(session.resumeCountForTesting, 1)
    }

    func testWebKitPDFRenderSessionCancellationResumesOnceWithCancellationError() async {
        let session = WebKitPDFRenderSession(timeoutSeconds: 10.0)
        let task = Task { @MainActor in
            try await session.waitForNavigation {
                // Keep pending until task cancellation
            }
        }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        session.finishNavigation(.success(()))
        XCTAssertEqual(session.resumeCountForTesting, 1)
    }

    // MARK: - 3. CLIBridgeInstaller Script Sanitization & Argument Hardening

    func testCLIBridgeInstallerScriptSanitizationAndArgumentHandling() async throws {
        let mockHome = sandbox.rootURL.appendingPathComponent("CLIMockHome", isDirectory: true)
        try FileManager.default.createDirectory(at: mockHome, withIntermediateDirectories: true)

        let fakeApp = sandbox.rootURL.appendingPathComponent("FakeLocalConvert.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)

        let installer = CLIBridgeInstaller(
            baseDirectory: mockHome,
            appBundlePathOverride: fakeApp.path
        )
        _ = try installer.install()

        let scriptText = try String(contentsOf: installer.scriptURL, encoding: .utf8)
        XCTAssertFalse(scriptText.contains("--args"), "Launcher script must never forward --args \"$@\"")
        XCTAssertTrue(scriptText.contains("open -a \"$APP_TARGET\""))

        // Syntax check with bash -n
        let syntaxCheck = try await runExecutable("/bin/bash", arguments: ["-n", installer.scriptURL.path])
        XCTAssertEqual(syntaxCheck.terminationStatus, 0, "bash -n failed: \(String(decoding: syntaxCheck.stderr, as: UTF8.self))")

        // Stub `open` binary to inspect invoked arguments safely without launching GUI apps
        let stubBinDir = sandbox.temporaryURL.appendingPathComponent("StubBin", isDirectory: true)
        try FileManager.default.createDirectory(at: stubBinDir, withIntermediateDirectories: true)
        let openLogURL = sandbox.temporaryURL.appendingPathComponent("open-args.log")
        let openStubURL = stubBinDir.appendingPathComponent("open")
        let openStubScript = """
        #!/usr/bin/env bash
        printf '%s\\n' "$@" > "\(openLogURL.path)"
        """
        try openStubScript.write(to: openStubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: openStubURL.path)

        let env: [String: String] = [
            "PATH": "\(stubBinDir.path):/usr/bin:/bin",
            "HOME": mockHome.path
        ]

        // 1. Reject internal flags like --uitesting with exit code 2
        let rejected = try await runExecutable(
            installer.scriptURL.path,
            arguments: ["--uitesting"],
            currentDirectoryURL: sandbox.documentsURL,
            environment: env
        )
        XCTAssertEqual(rejected.terminationStatus, 2)
        XCTAssertFalse(rejected.stderr.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLogURL.path))

        // 2. Help flag exits 0 without calling open
        let helpOut = try await runExecutable(
            installer.scriptURL.path,
            arguments: ["--help"],
            currentDirectoryURL: sandbox.documentsURL,
            environment: env
        )
        XCTAssertEqual(helpOut.terminationStatus, 0)
        let helpStdout = String(decoding: helpOut.stdout, as: UTF8.self)
        XCTAssertTrue(helpStdout.contains("Usage: localconvert"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLogURL.path))

        // 3. End-of-options sentinel `--` resolves leading-dash filename to safe absolute path
        let dashFile = sandbox.documentsURL.appendingPathComponent("-dashfile.txt")
        try Data("dash".utf8).write(to: dashFile)
        let dashResult = try await runExecutable(
            installer.scriptURL.path,
            arguments: ["--", "-dashfile.txt"],
            currentDirectoryURL: sandbox.documentsURL,
            environment: env
        )
        XCTAssertEqual(dashResult.terminationStatus, 0, "stderr: \(String(decoding: dashResult.stderr, as: UTF8.self))")
        let recordedLines = try String(contentsOf: openLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(recordedLines.first, "-a")
        XCTAssertEqual(recordedLines.dropFirst().first, fakeApp.path)
        XCTAssertEqual(
            recordedLines.last.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path },
            dashFile.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    // MARK: - 4. LC-019 Sheet Bounds & Zero Reentrant AppState Publish

    func testAudioEditorExportAndVideoTrimSheetsFitWithin580HeightWithoutAppStatePublish() async throws {
        let appState = makeIsolatedAppState()
        var appStatePublishCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            appStatePublishCount += 1
        }
        defer { cancellable.cancel() }

        let audioStore = AudioEditorStore(undoCoordinator: appState.undoCoordinator)
        let exportHost = NSHostingView(
            rootView: AudioEditorExportSheet(store: audioStore)
                .environmentObject(appState)
        )
        exportHost.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        exportHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(exportHost.fittingSize.height, 580)
        XCTAssertLessThanOrEqual(exportHost.fittingSize.width, 820)

        let videoURL = sandbox.documentsURL.appendingPathComponent("trim_bounds.mp4")
        _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: videoURL)
        let detection = FileDetector().detect(url: videoURL)
        let videoFile = DroppedFile(url: videoURL, detectionResult: detection)
        let trimHost = NSHostingView(
            rootView: VideoTrimSheetView(file: videoFile, onApply: { _, _ in })
                .environmentObject(appState)
        )
        trimHost.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
        trimHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(trimHost.fittingSize.height, 580)
        XCTAssertLessThanOrEqual(trimHost.fittingSize.width, 820)

        XCTAssertEqual(appStatePublishCount, 0, "Laying out export and trim sheets must not publish AppState changes")
    }

    // MARK: - 5. LC-016 Keyboard Shortcuts Catalog & Escape Block Parity

    func testKeyboardShortcutsCatalogMediaViewerAndAudioWorkspaceParity() {
        let all = KeyboardShortcutsCatalog.allEntries
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        XCTAssertEqual(byID["mv_sibling_nav"]?.action, "Previous / Next Photo")
        XCTAssertEqual(byID["mv_sibling_nav"]?.shortcut, "← / →")
        XCTAssertEqual(byID["mv_sibling_nav"]?.category, "Media Viewer")
        XCTAssertFalse(all.contains { $0.action == "Rotate Image Left / Right" })

        XCTAssertEqual(byID["keyboard_shortcuts"]?.shortcut, "⌘/")
        XCTAssertEqual(byID["paste_to_convert"]?.shortcut, "⌘V")

        let groups = KeyboardShortcutsCatalog.groupedEntries()
        let categories = groups.map(\.category)
        XCTAssertTrue(categories.contains("Media Viewer"))
        XCTAssertTrue(categories.contains("Audio Workspace"))

        let audioWorkspaceEntries = groups.first(where: { $0.category == "Audio Workspace" })?.entries ?? []
        XCTAssertFalse(audioWorkspaceEntries.isEmpty)
        XCTAssertTrue(audioWorkspaceEntries.contains { $0.shortcut == "Space" })
        XCTAssertTrue(audioWorkspaceEntries.contains { $0.shortcut == "⌘T" })
    }

    func testEscapeCancelAndPasteBlockedWhenM14AModalControllersPresented() {
        let dupBlocked = LocalConvertApp.isModalEscapeBlocked(
            monitorBlocked: false,
            isMediaViewerPresented: false,
            isShortcutsPresented: false,
            isQuickQRPresented: false,
            isDuplicateFinderPresented: true,
            isTextAndArchivePresented: false
        )
        XCTAssertTrue(dupBlocked)
        XCTAssertFalse(
            EscapeCancelMonitor.shouldAllowEscapeCancelShortcut(
                isConverting: true,
                isEscapeBlocked: dupBlocked,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: false
            )
        )
        XCTAssertFalse(
            LocalConvertApp.shouldAllowPasteToConvertShortcut(
                isConverting: false,
                isEscapeBlocked: dupBlocked,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: false,
                firstResponder: nil
            )
        )

        let textArchiveBlocked = LocalConvertApp.isModalEscapeBlocked(
            monitorBlocked: false,
            isMediaViewerPresented: false,
            isShortcutsPresented: false,
            isQuickQRPresented: false,
            isDuplicateFinderPresented: false,
            isTextAndArchivePresented: true
        )
        XCTAssertTrue(textArchiveBlocked)
        XCTAssertFalse(
            EscapeCancelMonitor.shouldAllowEscapeCancelShortcut(
                isConverting: true,
                isEscapeBlocked: textArchiveBlocked,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: false
            )
        )
        XCTAssertFalse(
            LocalConvertApp.shouldAllowPasteToConvertShortcut(
                isConverting: false,
                isEscapeBlocked: textArchiveBlocked,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: false,
                firstResponder: nil
            )
        )
    }
}

import XCTest
import AppKit
import Combine
import SwiftUI
@testable import LocalConvert

final class Milestone5SettingsAndConcurrencyTests: XCTestCase {

    // MARK: - LC-016: AppSettings.resetToDefaults() & OutputManager / AppState Sync

    @MainActor
    func testAppSettingsResetToDefaultsClearsOutputManagerKeysAndSyncsAppState() throws {
        let sandbox = try TestSandbox(runID: "M5-SettingsReset-\(UUID().uuidString)")
        let prevShared = AppState.shared
        defer {
            AppStoragePaths.clearTestOverrides()
            AppSettings.shared.resetToDefaults()
            AppState.shared = prevShared
            _ = sandbox.cleanup()
        }

        let stdOutputLocBefore = UserDefaults.standard.object(forKey: OutputManager.outputLocationKey) as? String
        let stdCustomDirBefore = UserDefaults.standard.object(forKey: OutputManager.customOutputDirKey) as? String
        let stdLastUsedBefore = UserDefaults.standard.object(forKey: OutputManager.lastUsedOutputDirKey) as? String
        let stdDefaultLocBefore = UserDefaults.standard.object(forKey: "settings.defaultOutputLocation") as? String

        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        let activeDefaults = AppStoragePaths.userDefaults
        XCTAssertFalse(activeDefaults === UserDefaults.standard)

        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let appState = AppState(
            undoCoordinator: coordinator,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history
        )
        XCTAssertTrue(AppState.shared === appState)

        // Mutate AppSettings, OutputManager, and AppState away from defaults
        let settings = AppSettings.shared
        settings.defaultImageQuality = 0.45
        settings.verboseLogging = true
        settings.defaultOutputLocation = .custom
        settings.customOutputDirectory = sandbox.outputsURL

        appState.outputLocation = .customFolder
        appState.customOutputDirectory = sandbox.outputsURL
        OutputManager.savePreferences(
            location: .customFolder,
            customDirectory: sandbox.outputsURL,
            defaults: activeDefaults
        )
        OutputManager.setLastUsedDirectory(sandbox.outputsURL, defaults: activeDefaults)
        OutputManager.savePreferences(
            location: .customFolder,
            customDirectory: sandbox.outputsURL,
            defaults: settings.defaults
        )
        OutputManager.setLastUsedDirectory(sandbox.outputsURL, defaults: settings.defaults)

        XCTAssertEqual(appState.outputLocation, .customFolder)
        XCTAssertEqual(appState.customOutputDirectory?.standardizedFileURL, sandbox.outputsURL.standardizedFileURL)
        XCTAssertNotNil(OutputManager.lastUsedDirectory(defaults: activeDefaults))

        // Reset to defaults
        settings.resetToDefaults()

        // 1. AppSettings values restored
        XCTAssertEqual(settings.defaultOutputLocation, .sameFolder)
        XCTAssertNil(settings.customOutputDirectory)
        XCTAssertEqual(settings.customOutputDirectoryPath, "")
        XCTAssertEqual(settings.defaultImageQuality, 0.90, accuracy: 0.0001)
        XCTAssertFalse(settings.verboseLogging)

        // 2. OutputManager keys cleared in both settings.defaults and active AppStoragePaths.userDefaults
        XCTAssertNil(activeDefaults.object(forKey: OutputManager.outputLocationKey))
        XCTAssertNil(activeDefaults.object(forKey: OutputManager.customOutputDirKey))
        XCTAssertNil(activeDefaults.object(forKey: OutputManager.lastUsedOutputDirKey))
        XCTAssertNil(settings.defaults.object(forKey: OutputManager.outputLocationKey))
        XCTAssertNil(settings.defaults.object(forKey: OutputManager.customOutputDirKey))
        XCTAssertNil(settings.defaults.object(forKey: OutputManager.lastUsedOutputDirKey))

        let reloaded = OutputManager.loadSavedPreferences(defaults: activeDefaults)
        XCTAssertEqual(reloaded.location, .sameFolder)
        XCTAssertNil(reloaded.customDirectory)
        XCTAssertNil(OutputManager.lastUsedDirectory(defaults: activeDefaults))

        // 3. AppState.shared synced back to .sameFolder / nil
        XCTAssertEqual(appState.outputLocation, .sameFolder)
        XCTAssertNil(appState.customOutputDirectory)

        // 4. Host UserDefaults.standard untouched
        XCTAssertEqual(UserDefaults.standard.object(forKey: OutputManager.outputLocationKey) as? String, stdOutputLocBefore)
        XCTAssertEqual(UserDefaults.standard.object(forKey: OutputManager.customOutputDirKey) as? String, stdCustomDirBefore)
        XCTAssertEqual(UserDefaults.standard.object(forKey: OutputManager.lastUsedOutputDirKey) as? String, stdLastUsedBefore)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "settings.defaultOutputLocation") as? String, stdDefaultLocBefore)
    }

    @MainActor
    func testIsolatedAppSettingsResetToDefaultsDoesNotMutateAppStateShared() throws {
        let sandboxA = try TestSandbox(runID: "M5-IsoA-\(UUID().uuidString)")
        let sandboxB = try TestSandbox(runID: "M5-IsoB-\(UUID().uuidString)")
        let prevShared = AppState.shared
        defer {
            AppStoragePaths.clearTestOverrides()
            AppSettings.shared.resetToDefaults()
            AppState.shared = prevShared
            _ = sandboxA.cleanup()
            _ = sandboxB.cleanup()
        }

        let coordinatorA = UndoRedoCoordinator(
            journalDirectoryURL: sandboxA.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandboxA.recoveryArtifactsURL)
        )
        let appState = AppState(
            undoCoordinator: coordinatorA,
            watchFolderStoreURL: sandboxA.watchFoldersFileURL,
            historyManager: HistoryManager(fileURL: sandboxA.historyFileURL)
        )
        appState.outputLocation = .customFolder
        appState.customOutputDirectory = sandboxA.outputsURL

        let isolatedDefaults = sandboxB.makeUserDefaults()
        let isolatedSettings = AppSettings(defaults: isolatedDefaults)
        isolatedSettings.defaultOutputLocation = .custom
        isolatedSettings.customOutputDirectory = sandboxB.outputsURL
        OutputManager.savePreferences(
            location: .customFolder,
            customDirectory: sandboxB.outputsURL,
            defaults: isolatedDefaults
        )
        OutputManager.setLastUsedDirectory(sandboxB.outputsURL, defaults: isolatedDefaults)

        isolatedSettings.resetToDefaults()

        // Isolated defaults & OutputManager keys reset
        XCTAssertEqual(isolatedSettings.defaultOutputLocation, .sameFolder)
        XCTAssertNil(isolatedSettings.customOutputDirectory)
        XCTAssertNil(isolatedDefaults.object(forKey: OutputManager.outputLocationKey))
        XCTAssertNil(isolatedDefaults.object(forKey: OutputManager.customOutputDirKey))
        XCTAssertNil(isolatedDefaults.object(forKey: OutputManager.lastUsedOutputDirKey))

        // AppState.shared remains untouched by non-shared isolated settings instance
        XCTAssertEqual(appState.outputLocation, .customFolder)
        XCTAssertEqual(appState.customOutputDirectory?.standardizedFileURL, sandboxA.outputsURL.standardizedFileURL)
    }

    // MARK: - LC-016: KeyboardShortcutDescriptor & Live Menu Binding Parity

    @MainActor
    func testKeyboardShortcutDescriptorParityWithLiveMenuBindings() {
        XCTAssertFalse(KeyboardShortcutDescriptor.hasDuplicateShortcuts)

        let descriptors = KeyboardShortcutDescriptor.defaultShortcuts
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

        // Verify newly unified shortcuts are present with exact key equivalents
        let audioWorkspace = byID["nav_audio_workspace"]
        XCTAssertEqual(audioWorkspace?.shortcut, "⌘9")
        XCTAssertEqual(audioWorkspace?.category, "Navigation")
        XCTAssertEqual(
            audioWorkspace?.keySpec,
            KeyboardShortcutDescriptor.KeySpec(key: .character("9"), modifiers: [.command])
        )
        XCTAssertNotNil(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_audio_workspace"))

        let editingHistory = byID["editing_history"]
        XCTAssertEqual(editingHistory?.shortcut, "⌥⌘Z")
        XCTAssertEqual(editingHistory?.category, "Edit")
        XCTAssertEqual(
            editingHistory?.keySpec,
            KeyboardShortcutDescriptor.KeySpec(key: .character("z"), modifiers: [.command, .option])
        )
        XCTAssertNotNil(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "editing_history"))

        let cancel = byID["cancel"]
        XCTAssertEqual(cancel?.shortcut, "Esc")
        XCTAssertEqual(cancel?.category, "Conversion")
        XCTAssertEqual(
            cancel?.keySpec,
            KeyboardShortcutDescriptor.KeySpec(key: .escape, modifiers: [])
        )
        XCTAssertNotNil(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "cancel"))

        // Verify every descriptor used by LocalConvertApp commands resolves a SwiftUI KeyboardShortcut
        let expectedLiveMenuIDs = [
            "settings", "undo", "redo", "editing_history",
            "add_files", "convert_all", "repeat_last", "cancel",
            "nav_convert", "nav_jobs", "nav_pdf", "nav_metadata",
            "nav_presets", "nav_history", "nav_audio", "nav_image",
            "nav_audio_workspace", "quit"
        ]
        for id in expectedLiveMenuIDs {
            let descriptor = KeyboardShortcutDescriptor.descriptor(forID: id)
            XCTAssertNotNil(descriptor, "Missing descriptor for menu ID '\(id)'")
            XCTAssertNotNil(descriptor?.keySpec, "Missing keySpec for menu ID '\(id)'")
            XCTAssertNotNil(KeyboardShortcutDescriptor.swiftUIShortcut(forID: id), "Missing SwiftUI KeyboardShortcut for menu ID '\(id)'")
        }

        // Verify all 9 non-Settings navigation tabs map 1:1 to ⌘1..⌘9 descriptors
        let navShortcuts = descriptors.filter { $0.category == "Navigation" }.map(\.shortcut)
        XCTAssertEqual(Set(navShortcuts), Set((1...9).map { "⌘\($0)" }))
    }

    @MainActor
    func testEscapeCancelMonitorProtectsTextEditingAndModals() {
        let primaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let idleResponder = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        primaryWindow.contentView = idleResponder
        primaryWindow.makeFirstResponder(idleResponder)

        // 1. Safe to allow Esc cancel when converting on primary window with no text input or modal
        XCTAssertFalse(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: primaryWindow,
                modalWindow: nil,
                primaryWindow: primaryWindow
            )
        )
        XCTAssertTrue(
            EscapeCancelMonitor.shouldAllowEscapeCancelShortcut(
                isConverting: true,
                isEscapeBlocked: false,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false
            )
        )

        // 2. Blocked when not converting
        XCTAssertFalse(
            EscapeCancelMonitor.shouldAllowEscapeCancelShortcut(
                isConverting: false,
                isEscapeBlocked: false,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false
            )
        )

        // 3. Blocked when an editable NSTextView is firstResponder
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        textView.isEditable = true
        primaryWindow.contentView = textView
        primaryWindow.makeFirstResponder(textView)
        XCTAssertTrue(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: primaryWindow,
                modalWindow: nil,
                primaryWindow: primaryWindow
            )
        )
        XCTAssertFalse(
            EscapeCancelMonitor.shouldAllowEscapeCancelShortcut(
                isConverting: true,
                isEscapeBlocked: false,
                isTextInputActive: true,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false
            )
        )

        // 4. Blocked when modals/sheets/popovers/alerts or secondary windows are active
        primaryWindow.contentView = idleResponder
        primaryWindow.makeFirstResponder(idleResponder)
        let secondaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        XCTAssertTrue(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: secondaryWindow,
                modalWindow: nil,
                primaryWindow: primaryWindow
            )
        )
        XCTAssertTrue(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: primaryWindow,
                modalWindow: secondaryWindow,
                primaryWindow: primaryWindow
            )
        )
        XCTAssertTrue(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: primaryWindow,
                modalWindow: nil,
                primaryWindow: primaryWindow,
                isEditingHistoryPresented: true
            )
        )
        XCTAssertTrue(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: primaryWindow,
                modalWindow: nil,
                primaryWindow: primaryWindow,
                isURLConfirmationPresented: true
            )
        )
        XCTAssertTrue(
            EscapeCancelMonitor.isEscapeInterceptedByTextOrModal(
                keyWindow: primaryWindow,
                modalWindow: nil,
                primaryWindow: primaryWindow,
                isErrorAlertPresented: true
            )
        )
    }

    // MARK: - LC-016: Scoped AppState objectWillChange Rebroadcasting

    @MainActor
    func testAppStateScopesSubStoreObjectWillChangeWithoutBreakingActiveTabs() throws {
        let sandbox = try TestSandbox(runID: "M5-AppStateScope-\(UUID().uuidString)")
        let prevShared = AppState.shared
        defer {
            AppState.shared = prevShared
            _ = sandbox.cleanup()
        }

        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let appState = AppState(
            undoCoordinator: coordinator,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: HistoryManager(fileURL: sandbox.historyFileURL)
        )

        var publishCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let sampleImageURL = sandbox.documentsURL.appendingPathComponent("sample.png")
        let samplePDFURL = sandbox.documentsURL.appendingPathComponent("sample.pdf")
        let sampleAudioURL = sandbox.documentsURL.appendingPathComponent("sample.mp3")

        // 1. On unrelated tab (.settings), sub-store mutations must NOT spam AppState.objectWillChange
        appState.selectedTab = .settings
        publishCount = 0

        appState.imageToolboxStore.setTargetFormat(.webp, for: sampleImageURL, recordUndo: false)
        appState.pdfToolboxStore.updateCompressionConfig(for: samplePDFURL.path, affectedURLs: [samplePDFURL], title: "Test DPI") { cfg in
            cfg.targetDPI = 120
        }
        appState.audioToolboxStore.updateState(for: sampleAudioURL, recordUndo: false) { state in
            state.targetFormat = .flac
        }
        appState.watchFolderManager.isGloballyPaused.toggle()
        XCTAssertEqual(publishCount, 0, "Inactive tab store mutations must not rebroadcast root AppState.objectWillChange")

        // 2. While on .settings, conversion progress ticks must NOT rebroadcast AppState.objectWillChange,
        //    whereas job active-count changes (for Sidebar badge) DO publish.
        let job = ConversionJob(
            inputURLs: [sampleImageURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: sandbox.outputsURL
        )
        appState.conversionManager.registerPending(job: job)
        XCTAssertEqual(publishCount, 1, "Adding active job should publish once to update Sidebar badge")

        publishCount = 0
        appState.conversionManager.jobStatuses[job.id] = .converting(.determinate(0.25, message: "Quarter"))
        appState.conversionManager.jobStatuses[job.id] = .converting(.determinate(0.75, message: "Three Quarters"))
        XCTAssertEqual(publishCount, 0, "Progress fraction updates on non-Convert/Jobs tabs must not rebroadcast AppState.objectWillChange")

        // 3. When each tab IS active, its store mutations DO rebroadcast to AppState.objectWillChange
        appState.selectedTab = .jobs
        publishCount = 0
        appState.conversionManager.jobStatuses[job.id] = .converting(.determinate(0.90, message: "Almost Done"))
        XCTAssertGreaterThan(publishCount, 0)
        appState.conversionManager.removeJob(id: job.id)

        appState.selectedTab = .imageToolbox
        publishCount = 0
        appState.imageToolboxStore.setTargetFormat(.avif, for: sampleImageURL, recordUndo: false)
        XCTAssertGreaterThan(publishCount, 0)

        appState.selectedTab = .pdfToolbox
        publishCount = 0
        appState.pdfToolboxStore.updateCompressionConfig(for: samplePDFURL.path, affectedURLs: [samplePDFURL], title: "Test DPI 2") { cfg in
            cfg.targetDPI = 96
        }
        XCTAssertGreaterThan(publishCount, 0)

        appState.selectedTab = .audioToolbox
        publishCount = 0
        appState.audioToolboxStore.updateState(for: sampleAudioURL, recordUndo: false) { state in
            state.targetFormat = .wav
        }
        XCTAssertGreaterThan(publishCount, 0)

        appState.selectedTab = .presets
        publishCount = 0
        appState.watchFolderManager.isGloballyPaused.toggle()
        XCTAssertGreaterThan(publishCount, 0)
    }

    // MARK: - LC-020: StructuredDiagnostics Concurrent Thread Safety

    func testStructuredDiagnosticsConcurrentReadsAndWritesWithOSAllocatedUnfairLock() async {
        StructuredDiagnostics.clearRecentEvents()
        defer { StructuredDiagnostics.clearRecentEvents() }

        let taskCount = 12
        let writesPerTask = 40

        await withTaskGroup(of: Void.self) { group in
            for workerIdx in 0..<taskCount {
                group.addTask {
                    for itemIdx in 0..<writesPerTask {
                        let event = StructuredDiagnostics.record(
                            category: itemIdx.isMultiple(of: 2) ? .conversion : .audioEditor,
                            severity: itemIdx.isMultiple(of: 3) ? .validation : .info,
                            stage: "concurrent_stage_\(workerIdx)",
                            operationID: "op-\(workerIdx)-\(itemIdx)",
                            filename: "track_\(workerIdx)_\(itemIdx).wav",
                            message: "Parallel diagnostic event \(workerIdx)-\(itemIdx)",
                            isVerboseEnabled: false
                        )
                        XCTAssertFalse(event.formattedLine.isEmpty)

                        if itemIdx.isMultiple(of: 5) {
                            let snapshot = StructuredDiagnostics.recentEvents()
                            XCTAssertLessThanOrEqual(snapshot.count, 200)
                        }
                        if itemIdx.isMultiple(of: 10) {
                            _ = StructuredDiagnostics.exportSanitizedSummary(limit: 20)
                        }
                    }
                }
            }
        }

        let finalEvents = StructuredDiagnostics.recentEvents()
        XCTAssertEqual(finalEvents.count, 200, "Buffer must stay bounded at maxEvents = 200 after 480 concurrent writes")
        let audioEvents = StructuredDiagnostics.recentEvents(category: .audioEditor)
        XCTAssertTrue(audioEvents.allSatisfy { $0.sanitizedFilename == "[REDACTED_AUDIO_FILE].wav" })

        StructuredDiagnostics.clearRecentEvents()
        XCTAssertTrue(StructuredDiagnostics.recentEvents().isEmpty)
    }
}

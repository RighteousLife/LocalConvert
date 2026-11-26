import SwiftUI
import AppKit

// MARK: - App Delegate for macOS Services & Open With

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var servicesProvider: ServicesProvider?
    @MainActor private static var pendingOpenURLs: [URL] = []
    @MainActor private static var pendingSchemeURLs: [URL] = []

    @MainActor static func consumePendingOpenURLs() -> [URL] {
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        return urls
    }

    @MainActor static func consumePendingSchemeURLs() -> [URL] {
        let urls = pendingSchemeURLs
        pendingSchemeURLs.removeAll()
        return urls
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let provider = ServicesProvider()
        self.servicesProvider = provider
        NSApplication.shared.servicesProvider = provider
        NSUpdateDynamicServices()
        Task { @MainActor in
            AppLifecycleManager.shared.applyVisibilityPreferences(settings: AppSettings.shared, forcePolicyRefresh: true)
            if ProcessInfo.processInfo.environment["LOCALCONVERT_UITEST"] == "1" {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let schemeURLs = urls.filter { $0.scheme?.lowercased() == "localconvert" }
            let otherURLs = urls.filter { $0.scheme?.lowercased() != "localconvert" }

            if let appState = AppState.shared {
                if !otherURLs.isEmpty {
                    appState.addFiles(urls: otherURLs)
                }
                for schemeURL in schemeURLs {
                    LocalConvertApp.handleIncomingURL(
                        schemeURL,
                        appState: appState,
                        coordinator: URLSchemeHandoffCoordinator.shared
                    )
                }
            } else {
                if !otherURLs.isEmpty {
                    Self.pendingOpenURLs.append(contentsOf: otherURLs)
                }
                if !schemeURLs.isEmpty {
                    Self.pendingSchemeURLs.append(contentsOf: schemeURLs)
                }
            }
            AppLifecycleManager.shared.restoreOrActivateMainWindow()
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag {
                _ = AppLifecycleManager.shared.restoreOrActivateMainWindow()
            } else if let win = AppLifecycleManager.shared.resolvePrimaryWindow(), win.isMiniaturized {
                win.deminiaturize(nil)
                win.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            AppLifecycleManager.shared.shouldTerminateAfterLastWindowClosed(
                settings: AppSettings.shared,
                appState: AppState.shared
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppLifecycleManager.shared.prepareForTermination(appState: AppState.shared)
        }
    }
}

// MARK: - Escape Cancel Context Monitor

@MainActor
final class EscapeCancelMonitor: ObservableObject {
    @Published private(set) var isEscapeBlocked: Bool = false

    private final class ObserverBag: @unchecked Sendable {
        var keyWindowObservation: NSKeyValueObservation?
        var firstResponderObservation: NSKeyValueObservation?
        var notificationTokens: [any NSObjectProtocol] = []

        deinit {
            keyWindowObservation?.invalidate()
            firstResponderObservation?.invalidate()
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    private let windowProvider: @MainActor () -> NSWindow?
    private let modalWindowProvider: @MainActor () -> NSWindow?
    private let primaryWindowProvider: @MainActor () -> NSWindow?
    private var activePopoverIDs = Set<ObjectIdentifier>()
    private let observers = ObserverBag()

    init(
        windowProvider: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow },
        modalWindowProvider: @escaping @MainActor () -> NSWindow? = { NSApp?.modalWindow },
        primaryWindowProvider: @escaping @MainActor () -> NSWindow? = { AppLifecycleManager.shared.resolvePrimaryWindow() }
    ) {
        self.windowProvider = windowProvider
        self.modalWindowProvider = modalWindowProvider
        self.primaryWindowProvider = primaryWindowProvider

        if let app = NSApp {
            observers.keyWindowObservation = app.observe(\.keyWindow, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.attachFirstResponderObserver()
                    self?.refreshNow()
                }
            }
        }

        let center = NotificationCenter.default
        let observedNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
            NSPopover.willShowNotification,
            NSPopover.didCloseNotification,
            NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification
        ]
        for name in observedNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let noteName = note.name
                let popoverID = (note.object as? NSPopover).map { ObjectIdentifier($0) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if noteName == NSPopover.willShowNotification, let popoverID {
                        self.activePopoverIDs.insert(popoverID)
                    } else if noteName == NSPopover.didCloseNotification, let popoverID {
                        self.activePopoverIDs.remove(popoverID)
                    } else if noteName == NSWindow.didBecomeKeyNotification || noteName == NSWindow.didResignKeyNotification {
                        self.attachFirstResponderObserver()
                    }
                    self.refreshNow()
                }
            }
            observers.notificationTokens.append(token)
        }

        attachFirstResponderObserver()
        refreshNow()
    }

    func refreshNow() {
        let blocked = !activePopoverIDs.isEmpty || Self.isEscapeInterceptedByTextOrModal(
            keyWindow: windowProvider(),
            modalWindow: modalWindowProvider(),
            primaryWindow: primaryWindowProvider()
        )
        if isEscapeBlocked != blocked {
            isEscapeBlocked = blocked
        }
    }

    private func attachFirstResponderObserver() {
        observers.firstResponderObservation?.invalidate()
        observers.firstResponderObservation = nil
        guard let window = windowProvider() else { return }
        observers.firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
    }

    static func isEscapeInterceptedByTextOrModal(
        keyWindow: NSWindow? = NSApp?.keyWindow,
        modalWindow: NSWindow? = NSApp?.modalWindow,
        primaryWindow: NSWindow? = AppLifecycleManager.shared.resolvePrimaryWindow(),
        isEditingHistoryPresented: Bool = false,
        isURLConfirmationPresented: Bool = false,
        isErrorAlertPresented: Bool = false,
        isCommandPalettePresented: Bool = false
    ) -> Bool {
        if modalWindow != nil { return true }
        if isEditingHistoryPresented || isURLConfirmationPresented || isErrorAlertPresented || isCommandPalettePresented { return true }
        if let keyWindow {
            if keyWindow.attachedSheet != nil || keyWindow.sheetParent != nil || !keyWindow.sheets.isEmpty {
                return true
            }
            if UndoMenuController.activeEditableTextResponder(from: keyWindow.firstResponder) != nil {
                return true
            }
            if let primaryWindow, keyWindow !== primaryWindow {
                return true
            }
        }
        if let primaryWindow, primaryWindow.attachedSheet != nil || !primaryWindow.sheets.isEmpty {
            return true
        }
        return false
    }

    static func shouldAllowEscapeCancelShortcut(
        isConverting: Bool,
        isEscapeBlocked: Bool,
        isTextInputActive: Bool,
        isEditingHistoryPresented: Bool,
        isURLConfirmationPresented: Bool,
        isErrorAlertPresented: Bool,
        isCommandPalettePresented: Bool = false
    ) -> Bool {
        isConverting
            && !isEscapeBlocked
            && !isTextInputActive
            && !isEditingHistoryPresented
            && !isURLConfirmationPresented
            && !isErrorAlertPresented
            && !isCommandPalettePresented
    }
}

// MARK: - App Scene

@main
struct LocalConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState: AppState
    @AppStorage("settings.appearanceMode", store: AppStoragePaths.userDefaults) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @ObservedObject private var systemAppearance = SystemAppearanceMonitor.shared
    @ObservedObject private var undoCoordinator: UndoRedoCoordinator
    @ObservedObject private var undoMenu: UndoMenuController
    @ObservedObject private var urlSchemeCoordinator = URLSchemeHandoffCoordinator.shared
    @ObservedObject private var commandPalette = CommandPaletteController.shared
    @StateObject private var escapeMonitor = EscapeCancelMonitor()

    private let isUITestingSession: Bool
    private let uitestingInputURLs: [URL]
    private let uitestingMetadataURL: URL?
    private let uitestingInitialTab: AppNavigationTab?
    private let uitestingMetadataManager: MetadataManager?
    private let uitestingAudioLibraryFolderURL: URL?
    private let uitestingAudioEditorFiles: [URL]
    private let uitestingWindowSize: CGSize?

    init() {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        let uiTesting = env["LOCALCONVERT_UITEST"] == "1" || args.contains("--uitesting")
        self.isUITestingSession = uiTesting

        func nonEmptyEnv(_ key: String) -> String? {
            guard let val = env[key], !val.isEmpty else { return nil }
            return val
        }

        if uiTesting {
            let sandboxRoot = nonEmptyEnv("LOCALCONVERT_UITEST_SANDBOX")
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("LocalConvert-UITest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)

            let artifacts = RecoveryArtifactManager(
                baseDirectoryURL: sandboxRoot.appendingPathComponent("RecoveryArtifacts", isDirectory: true)
            )
            let coordinator = UndoRedoCoordinator(
                journalDirectoryURL: sandboxRoot.appendingPathComponent("UndoHistory", isDirectory: true),
                artifactManager: artifacts
            )
            let menu = UndoMenuController(coordinator: coordinator)
            let history = HistoryManager(fileURL: sandboxRoot.appendingPathComponent("history.json"))
            let outDir = nonEmptyEnv("LOCALCONVERT_UITEST_OUTPUT")
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            if let outDir {
                try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            }
            let metaMgr = MetadataManager(
                undoCoordinator: coordinator,
                artifactManager: RecoveryArtifactManager(
                    baseDirectoryURL: sandboxRoot.appendingPathComponent("MetaArtifacts", isDirectory: true)
                ),
                historyManager: history
            )

            let state = AppState(
                undoCoordinator: coordinator,
                watchFolderStoreURL: sandboxRoot.appendingPathComponent("watch-folders.json"),
                historyManager: history,
                uitestingOutputDirectory: outDir
            )
            self._appState = StateObject(wrappedValue: state)
            self._undoCoordinator = ObservedObject(wrappedValue: coordinator)
            self._undoMenu = ObservedObject(wrappedValue: menu)
            self.uitestingMetadataManager = metaMgr
            let rawInputs = env["LOCALCONVERT_UITEST_INPUTS"] ?? ""
            self.uitestingInputURLs = rawInputs
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
            self.uitestingMetadataURL = nonEmptyEnv("LOCALCONVERT_UITEST_METADATA")
                .map { URL(fileURLWithPath: $0) }
            self.uitestingInitialTab = nonEmptyEnv("LOCALCONVERT_UITEST_TAB")
                .flatMap { AppNavigationTab(rawValue: $0) }
            self.uitestingAudioLibraryFolderURL = nonEmptyEnv("LOCALCONVERT_UITEST_AUDIO_LIBRARY_FOLDER")
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            let rawEditorFiles = env["LOCALCONVERT_UITEST_AUDIO_EDITOR_FILES"] ?? ""
            self.uitestingAudioEditorFiles = rawEditorFiles
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }
            if let wStr = nonEmptyEnv("LOCALCONVERT_UITEST_WINDOW_WIDTH"),
               let hStr = nonEmptyEnv("LOCALCONVERT_UITEST_WINDOW_HEIGHT"),
               let w = Double(wStr), let h = Double(hStr) {
                self.uitestingWindowSize = CGSize(width: w, height: h)
            } else {
                self.uitestingWindowSize = nil
            }
        } else {
            let state = AppState()
            self._appState = StateObject(wrappedValue: state)
            self._undoCoordinator = ObservedObject(wrappedValue: UndoRedoCoordinator.shared)
            self._undoMenu = ObservedObject(wrappedValue: UndoMenuController.shared)
            self.uitestingMetadataManager = nil
            self.uitestingInputURLs = []
            self.uitestingMetadataURL = nil
            self.uitestingInitialTab = nil
            self.uitestingAudioLibraryFolderURL = nil
            self.uitestingAudioEditorFiles = []
            self.uitestingWindowSize = nil
        }
    }

    private var preferredColorScheme: ColorScheme {
        (AppearanceMode(rawValue: appearanceModeRaw) ?? .system)
            .resolvedColorScheme(system: systemAppearance.colorScheme)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                undoCoordinator: undoCoordinator,
                undoMenu: undoMenu,
                commandPalette: commandPalette,
                metadataManager: uitestingMetadataManager ?? MetadataManager.shared
            )
                .environmentObject(appState)
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: AppTheme.Layout.minWindowWidth, minHeight: AppTheme.Layout.minWindowHeight)
                .onAppear {
                    MenuBarManager.shared.setup(appState: appState)
                    AppLifecycleManager.shared.applyVisibilityPreferences(settings: AppSettings.shared)
                    let isTesting = isUITestingSession
                        || NSClassFromString("XCTestCase") != nil
                        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                    if isUITestingSession {
                        undoCoordinator.bind(to: appState)
                        if let tab = uitestingInitialTab {
                            appState.selectedTab = tab
                        }
                        if !uitestingInputURLs.isEmpty && appState.droppedFiles.isEmpty {
                            appState.addFiles(urls: uitestingInputURLs)
                        }
                        if let metaURL = uitestingMetadataURL, let metaMgr = uitestingMetadataManager {
                            Task {
                                await metaMgr.load(url: metaURL)
                            }
                        }
                        if let libFolder = uitestingAudioLibraryFolderURL {
                            Task {
                                await appState.audioWorkspace.ensureInitialized()
                                if appState.audioWorkspace.libraryStore.rootFolders.isEmpty {
                                    await appState.audioWorkspace.libraryStore.addFolderAndScan(url: libFolder)
                                }
                            }
                        }
                        if !uitestingAudioEditorFiles.isEmpty && appState.audioEditorStore.project.mediaAssets.isEmpty {
                            appState.audioEditorStore.importAudioFiles(urls: uitestingAudioEditorFiles)
                        }
                        if let targetSize = uitestingWindowSize,
                           let win = AppLifecycleManager.shared.resolvePrimaryWindow() ?? NSApplication.shared.windows.first {
                            var frame = win.frame
                            frame.size = targetSize
                            win.setFrame(frame, display: true)
                        }
                    } else if !isTesting {
                        appState.watchFolderManager.reconcileAndStartEnabledRules()
                        Task {
                            await Self.bootstrapUndoCoordinator(appState: appState, undoCoordinator: undoCoordinator)
                        }
                        let deferredSchemeURLs = AppDelegate.consumePendingSchemeURLs()
                        for schemeURL in deferredSchemeURLs {
                            Self.handleIncomingURL(schemeURL, appState: appState, coordinator: urlSchemeCoordinator)
                        }
                    }
                }
                .onOpenURL { url in
                    Self.handleIncomingURL(url, appState: appState, coordinator: urlSchemeCoordinator)
                }
                .alert(
                    "Confirm URL Conversion",
                    isPresented: $urlSchemeCoordinator.isConfirmationPresented,
                    presenting: urlSchemeCoordinator.pendingConversionRequest
                ) { request in
                    Button("Convert \(request.stagedURLs.count == 1 ? "File" : "\(request.stagedURLs.count) Files")") {
                        urlSchemeCoordinator.confirmPendingConversion(appState: appState)
                    }
                    .accessibilityIdentifier("url_scheme.confirm_button")

                    Button("Cancel", role: .cancel) {
                        urlSchemeCoordinator.cancelPendingConversion()
                    }
                    .accessibilityIdentifier("url_scheme.cancel_button")
                } message: { request in
                    Text(URLSchemeHandoffCoordinator.confirmationMessage(for: request))
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(
            width: uitestingWindowSize?.width ?? AppTheme.Layout.defaultWindowWidth,
            height: uitestingWindowSize?.height ?? AppTheme.Layout.defaultWindowHeight
        )
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .settings, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "settings"))
            }

            CommandGroup(replacing: .undoRedo) {
                Button(undoMenu.undoTitle) {
                    undoMenu.performUndo()
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "undo"))
                .disabled(!undoMenu.canUndo)

                Button(undoMenu.redoTitle) {
                    undoMenu.performRedo()
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "redo"))
                .disabled(!undoMenu.canRedo)

                Divider()

                Button("Editing History...") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(appState: appState)
                    undoCoordinator.isEditingHistoryPresented.toggle()
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "editing_history"))
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Paste to Convert") {
                    Task { @MainActor in
                        _ = await Self.handlePasteToConvertCommand(appState: appState)
                    }
                }
                .keyboardShortcut(
                    isPasteToConvertShortcutEnabled
                        ? KeyboardShortcut("v", modifiers: .command)
                        : nil
                )
                .disabled(appState.isConverting)
            }

            CommandGroup(replacing: .newItem) {
                Button("Add Files...") {
                    openFilePicker()
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "add_files"))
                .disabled(appState.isConverting)
                
                Button("Convert All") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .convert, appState: appState)
                    appState.convertAll()
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "convert_all"))
                .disabled(!appState.canStartBatchConversion)

                Button("Repeat Last Conversion") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .convert, appState: appState)
                    appState.repeatLastConversion()
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "repeat_last"))
                .disabled(appState.isConverting || !appState.isRepeatConversionCompatible)

                Button("Cancel Active Conversion") {
                    appState.cancelConversion()
                }
                .keyboardShortcut(
                    isEscapeCancelShortcutEnabled
                        ? KeyboardShortcutDescriptor.swiftUIShortcut(forID: "cancel")
                        : nil
                )
                .disabled(!appState.isConverting)
            }
            
            CommandMenu("Navigate") {
                Button("Command Palette...") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(appState: appState)
                    commandPalette.toggle()
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "command_palette"))

                Divider()

                Button("Convert") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .convert, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_convert"))
                
                Button("Jobs Center") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .jobs, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_jobs"))
                
                Button("PDF Toolbox") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .pdfToolbox, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_pdf"))

                Button("Audio Workspace") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .audioWorkspace, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_audio_workspace"))

                Button("Image Toolbox") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .imageToolbox, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_image"))

                Button("Metadata") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .metadata, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_metadata"))

                Button("Presets") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .presets, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_presets"))

                Button("History") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .history, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_history"))

                Button("Settings") {
                    AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .settings, appState: appState)
                }
                .keyboardShortcut(KeyboardShortcutDescriptor.swiftUIShortcut(forID: "nav_settings"))
            }
        }
    }

    private var isEscapeCancelShortcutEnabled: Bool {
        EscapeCancelMonitor.shouldAllowEscapeCancelShortcut(
            isConverting: appState.isConverting,
            isEscapeBlocked: escapeMonitor.isEscapeBlocked,
            isTextInputActive: undoMenu.isTextInputActive,
            isEditingHistoryPresented: undoCoordinator.isEditingHistoryPresented,
            isURLConfirmationPresented: urlSchemeCoordinator.isConfirmationPresented,
            isErrorAlertPresented: appState.showError,
            isCommandPalettePresented: commandPalette.isPresented
        )
    }

    private var isPasteToConvertShortcutEnabled: Bool {
        Self.shouldAllowPasteToConvertShortcut(
            isConverting: appState.isConverting,
            isEscapeBlocked: escapeMonitor.isEscapeBlocked,
            isTextInputActive: undoMenu.isTextInputActive,
            isEditingHistoryPresented: undoCoordinator.isEditingHistoryPresented,
            isURLConfirmationPresented: urlSchemeCoordinator.isConfirmationPresented,
            isErrorAlertPresented: appState.showError,
            isCommandPalettePresented: commandPalette.isPresented,
            firstResponder: NSApp?.keyWindow?.firstResponder
        )
    }

    @MainActor
    static func shouldAllowPasteToConvertShortcut(
        isConverting: Bool,
        isEscapeBlocked: Bool,
        isTextInputActive: Bool,
        isEditingHistoryPresented: Bool,
        isURLConfirmationPresented: Bool,
        isErrorAlertPresented: Bool,
        isCommandPalettePresented: Bool,
        firstResponder: NSResponder?
    ) -> Bool {
        guard !isConverting,
              !isEscapeBlocked,
              !isTextInputActive,
              !isEditingHistoryPresented,
              !isURLConfirmationPresented,
              !isErrorAlertPresented,
              !isCommandPalettePresented else {
            return false
        }
        return UndoMenuController.activeEditableTextResponder(from: firstResponder) == nil
    }

    @MainActor
    @discardableResult
    static func handlePasteToConvertCommand(
        appState: AppState,
        firstResponder: NSResponder? = NSApp?.keyWindow?.firstResponder,
        pasteboard: NSPasteboard = .general,
        stagingDirectory: URL? = nil
    ) async -> Bool {
        if let textResponder = UndoMenuController.activeEditableTextResponder(from: firstResponder) {
            _ = NSApp?.sendAction(#selector(NSText.paste(_:)), to: textResponder, from: nil)
            return false
        }
        guard !appState.isConverting else { return false }
        let result = await ClipboardIntakeService.pasteToConvert(
            into: appState,
            from: pasteboard,
            stagingDirectory: stagingDirectory
        )
        return result != nil
    }
    
    @MainActor
    static func handleIncomingURL(
        _ url: URL,
        appState: AppState,
        coordinator: URLSchemeHandoffCoordinator = .shared
    ) {
        if url.scheme?.lowercased() == "localconvert" {
            coordinator.handleIncomingURL(url, appState: appState)
        } else if url.isFileURL {
            appState.addFiles(urls: [url])
        }
    }

    @MainActor
    static func bootstrapUndoCoordinator(appState: AppState, undoCoordinator: UndoRedoCoordinator) async {
        // Ensure all long-lived stores register their rehydrators before restoring persisted history.
        _ = appState.audioEditorStore
        _ = appState.imageToolboxStore
        _ = appState.pdfToolboxStore
        undoCoordinator.bind(to: appState)
        await undoCoordinator.restorePersistedHistory()
    }

    private func openFilePicker() {
        AppLifecycleManager.shared.restoreOrActivateMainWindow(appState: appState)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.routeOpenFiles(panel.urls)
        }
    }
}

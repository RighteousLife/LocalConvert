import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.appearanceMode", store: AppStoragePaths.userDefaults) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @ObservedObject private var systemAppearance = SystemAppearanceMonitor.shared
    @ObservedObject var undoCoordinator: UndoRedoCoordinator
    @ObservedObject var undoMenu: UndoMenuController
    @ObservedObject var commandPalette: CommandPaletteController
    @ObservedObject var shortcutsController: KeyboardShortcutsSheetController
    @ObservedObject var quickQRController: QuickQRGeneratorController
    let metadataManager: MetadataManager

    init(
        undoCoordinator: UndoRedoCoordinator = .shared,
        undoMenu: UndoMenuController = .shared,
        commandPalette: CommandPaletteController = .shared,
        shortcutsController: KeyboardShortcutsSheetController = .shared,
        quickQRController: QuickQRGeneratorController = .shared,
        metadataManager: MetadataManager = .shared
    ) {
        self.undoCoordinator = undoCoordinator
        self.undoMenu = undoMenu
        self.commandPalette = commandPalette
        self.shortcutsController = shortcutsController
        self.quickQRController = quickQRController
        self.metadataManager = metadataManager
    }

    private var preferredColorScheme: ColorScheme {
        (AppearanceMode(rawValue: appearanceModeRaw) ?? .system)
            .resolvedColorScheme(system: systemAppearance.colorScheme)
    }
    
    var body: some View {
        NavigationSplitView {
            SidebarView(initialTab: appState.selectedTab)
        } detail: {
            VStack(spacing: 0) {
                RestoredQueueBannerView(conversionManager: appState.conversionManager)
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .appWorkspaceSurface()
        }
        .appOpaqueWindowChrome(preferredColorScheme: preferredColorScheme)
        .navigationTitle(appState.selectedTab.localizedTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu {
                        Button("Instant") {
                            triggerScreenCapture(delay: .instant)
                        }
                        Button("3s Timer") {
                            triggerScreenCapture(delay: .threeSeconds)
                        }
                        Button("5s Timer") {
                            triggerScreenCapture(delay: .fiveSeconds)
                        }
                    } label: {
                        Label("Capture Screen to Markup", systemImage: "camera.viewfinder")
                    }

                    Button {
                        quickQRController.open()
                    } label: {
                        Label("Quick QR Generator...", systemImage: "qrcode")
                    }

                    Divider()

                    Button {
                        shortcutsController.open()
                    } label: {
                        Label("Keyboard Shortcuts (⌘/)", systemImage: "keyboard")
                    }
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .help("Screen Capture, Quick QR Generator, and Keyboard Shortcuts")
                .accessibilityLabel("Quick Tools")
                .accessibilityHint("Opens Screen Capture, Quick QR Generator, and Keyboard Shortcuts")
                .accessibilityIdentifier("toolbar.toolsMenu")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.openMediaViewerEmpty()
                } label: {
                    Label("Media Viewer", systemImage: "photo.on.rectangle.angled")
                }
                .help("Open Media Viewer (Photo, Markup & Video Editor)")
                .accessibilityLabel("Media Viewer")
                .accessibilityHint("Opens the unified photo, markup, and video viewer and editor")
                .accessibilityIdentifier("toolbar.mediaViewer")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    undoMenu.performUndo()
                } label: {
                    Label(undoMenu.undoTitle, systemImage: "arrow.uturn.backward")
                }
                .disabled(!undoMenu.canUndo)
                .help(undoMenu.canUndo ? "\(undoMenu.undoTitle) (⌘Z)" : String(localized: "Nothing to Undo (⌘Z)"))
                .accessibilityLabel(undoMenu.undoTitle)
                .accessibilityHint("Reverses the most recent operation in the active editing context")
                .accessibilityIdentifier("toolbar.undo")

                Button {
                    undoMenu.performRedo()
                } label: {
                    Label(undoMenu.redoTitle, systemImage: "arrow.uturn.forward")
                }
                .disabled(!undoMenu.canRedo)
                .help(undoMenu.canRedo ? "\(undoMenu.redoTitle) (⇧⌘Z)" : String(localized: "Nothing to Redo (⇧⌘Z)"))
                .accessibilityLabel(undoMenu.redoTitle)
                .accessibilityHint("Reapplies the most recently undone operation")
                .accessibilityIdentifier("toolbar.redo")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    undoCoordinator.isEditingHistoryPresented.toggle()
                } label: {
                    Label("Editing History", systemImage: "clock.arrow.2.circlepath")
                }
                .help("Show Editing History (⌥⌘Z)")
                .accessibilityLabel("Editing History")
                .accessibilityHint("Opens the chronological undo, redo, and editing history timeline")
                .accessibilityIdentifier("toolbar.editingHistory")
                .popover(isPresented: $undoCoordinator.isEditingHistoryPresented, arrowEdge: .bottom) {
                    EditingHistoryView(coordinator: undoCoordinator)
                        .frame(minWidth: 540, idealWidth: 600, minHeight: 420, idealHeight: 460, maxHeight: 520)
                }
            }
        }
        .alert(appState.errorTitle, isPresented: $appState.showError) {
            Button("OK") {}
                .accessibilityIdentifier("error.alert.ok")
        } message: {
            let parts = [
                appState.errorMessage,
                appState.errorSuggestion,
                appState.errorDetails
            ].compactMap { $0 }.filter { !$0.isEmpty }
            Text(parts.joined(separator: "\n\n"))
        }
        .overlay {
            if commandPalette.isPresented {
                CommandPaletteView(controller: commandPalette)
            }
        }
        .sheet(isPresented: $appState.isMediaViewerPresented) {
            MediaViewerSheetView()
                .environmentObject(appState)
                .preferredColorScheme(preferredColorScheme)
        }
        .sheet(isPresented: $shortcutsController.isPresented) {
            KeyboardShortcutsSheetView(controller: shortcutsController)
                .preferredColorScheme(preferredColorScheme)
        }
        .sheet(isPresented: $quickQRController.isPresented) {
            QuickQRGeneratorSheetView(controller: quickQRController)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private func triggerScreenCapture(delay: ScreenCaptureDelay) {
        Task { @MainActor in
            do {
                _ = try await ScreenCaptureService.shared.captureToMediaViewer(delay: delay, appState: appState)
            } catch {
                appState.showError(
                    title: String(localized: "Screen Capture Failed"),
                    message: error.localizedDescription
                )
            }
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedTab {
        case .convert:
            if appState.droppedFiles.isEmpty {
                DropZoneView()
            } else {
                FileListView()
            }
        case .jobs:
            JobsCenterView()
        case .pdfToolbox:
            PDFToolboxView()
        case .audioToolbox, .audioWorkspace:
            AudioWorkspaceRootView(
                coordinator: appState.audioWorkspace,
                editorStore: appState.audioEditorStore,
                undoCoordinator: undoCoordinator,
                undoMenu: undoMenu
            ) {
                AudioToolboxView(hideEmbeddedAudioEditor: true)
            }
        case .imageToolbox:
            ImageToolboxView()
        case .metadata:
            MetadataView(metadataManager: metadataManager)
        case .presets:
            PresetManagerView()
        case .history:
            HistoryView(historyManager: appState.historyManager)
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: AppNavigationTab?

    init(initialTab: AppNavigationTab) {
        _selection = State(initialValue: initialTab)
    }
    
    private var activeJobCount: Int {
        appState.conversionManager.runningOrWaitingCount
    }
    
    var body: some View {
        List(AppNavigationTab.allCases, id: \.self, selection: $selection) { tab in
            Label {
                Text(tab.localizedTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: tab.iconName)
                    .imageScale(.medium)
            }
            .badge(tab == .jobs && activeJobCount > 0 ? activeJobCount : 0)
            .help(tab.localizedDescription)
            .tag(tab)
            .accessibilityIdentifier("sidebar.tab.\(tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))")
        }
        .onAppear {
            if selection != appState.selectedTab {
                selection = appState.selectedTab
            }
        }
        .onChange(of: selection) { _, newSelection in
            if let newSelection, appState.selectedTab != newSelection {
                appState.selectedTab = newSelection
            }
        }
        .onChange(of: appState.selectedTab) { _, newTab in
            if selection != newTab {
                selection = newTab
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.list")
        .appMainSidebarSurface()
        .navigationSplitViewColumnWidth(
            min: AppTheme.Layout.mainSidebarMin,
            ideal: AppTheme.Layout.mainSidebarIdeal,
            max: AppTheme.Layout.mainSidebarMax
        )
    }
}

// MARK: - Restored Queue Banner

private struct RestoredQueueBannerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var conversionManager: ConversionManager

    private var bannerMessage: String {
        let count = conversionManager.restoredQueueCount
        let base = count == 1
            ? String(localized: "1 unfinished conversion from your previous session was restored.")
            : String(localized: "\(count) unfinished conversions from your previous session were restored.")
        let skipped = conversionManager.restoredSkippedMissingCount
        if skipped > 0 {
            let skippedText = skipped == 1
                ? String(localized: "1 missing file was skipped.")
                : String(localized: "\(skipped) missing files were skipped.")
            return "\(base) \(skippedText)"
        }
        return base
    }

    var body: some View {
        if conversionManager.hasRestoredQueueBanner {
            VStack(spacing: 0) {
                AppInfoBanner(
                    style: .info,
                    message: bannerMessage,
                    icon: "clock.arrow.circlepath",
                    actionTitle: String(localized: "Go to Convert"),
                    onAction: {
                        restoreToConvertQueue()
                    },
                    onDismiss: {
                        conversionManager.dismissRestoredQueueBanner(clearRestoredJobs: true)
                    }
                )
                .lineLimit(2)
                .truncationMode(.tail)
                .help(bannerMessage)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.sm)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("content.restoredQueueBanner")

                AppDivider()
            }
        }
    }

    private func restoreToConvertQueue() {
        let restoredJobs = conversionManager.consumeRestoredJobsForConvertTab()
        let urls = restoredJobs.flatMap(\.inputURLs)
        if !urls.isEmpty {
            appState.handleDroppedURLs(urls)
            for job in restoredJobs {
                guard let firstURL = job.inputURL else { continue }
                let resolvedTarget = firstURL.standardizedFileURL.resolvingSymlinksInPath()
                if let idx = appState.droppedFiles.firstIndex(where: {
                    $0.url.standardizedFileURL.resolvingSymlinksInPath() == resolvedTarget
                }) {
                    if appState.droppedFiles[idx].availableOutputFormats.contains(job.outputFormat) {
                        appState.droppedFiles[idx].selectedOutputFormat = job.outputFormat
                    }
                    appState.droppedFiles[idx].options = job.options
                }
            }
        }
        appState.selectedTab = .convert
    }
}

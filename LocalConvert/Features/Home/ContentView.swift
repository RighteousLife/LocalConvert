import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.appearanceMode", store: AppStoragePaths.userDefaults) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @ObservedObject private var systemAppearance = SystemAppearanceMonitor.shared
    @ObservedObject var undoCoordinator: UndoRedoCoordinator
    @ObservedObject var undoMenu: UndoMenuController
    @ObservedObject var commandPalette: CommandPaletteController
    let metadataManager: MetadataManager

    init(
        undoCoordinator: UndoRedoCoordinator = .shared,
        undoMenu: UndoMenuController = .shared,
        commandPalette: CommandPaletteController = .shared,
        metadataManager: MetadataManager = .shared
    ) {
        self.undoCoordinator = undoCoordinator
        self.undoMenu = undoMenu
        self.commandPalette = commandPalette
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
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appWorkspaceSurface()
        }
        .appOpaqueWindowChrome(preferredColorScheme: preferredColorScheme)
        .navigationTitle(appState.selectedTab.rawValue)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    undoMenu.performUndo()
                } label: {
                    Label(undoMenu.undoTitle, systemImage: "arrow.uturn.backward")
                }
                .disabled(!undoMenu.canUndo)
                .help(undoMenu.undoTitle)
                .accessibilityLabel(undoMenu.undoTitle)
                .accessibilityHint("Reverses the most recent operation in the active editing context")
                .accessibilityIdentifier("toolbar.undo")

                Button {
                    undoMenu.performRedo()
                } label: {
                    Label(undoMenu.redoTitle, systemImage: "arrow.uturn.forward")
                }
                .disabled(!undoMenu.canRedo)
                .help(undoMenu.redoTitle)
                .accessibilityLabel(undoMenu.redoTitle)
                .accessibilityHint("Reapplies the most recently undone operation")
                .accessibilityIdentifier("toolbar.redo")

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
        case .audioToolbox:
            AudioToolboxView()
        case .audioWorkspace:
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
            Label(tab.rawValue, systemImage: tab.iconName)
                .badge(tab == .jobs && activeJobCount > 0 ? activeJobCount : 0)
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

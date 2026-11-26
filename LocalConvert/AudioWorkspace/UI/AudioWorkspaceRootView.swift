import SwiftUI
import AppKit

struct AudioWorkspaceRootView<AudioToolsContent: View>: View {
    @ObservedObject var coordinator: AudioWorkspaceCoordinator
    @ObservedObject var editorStore: AudioEditorStore
    let undoCoordinator: UndoRedoCoordinator
    let undoMenu: UndoMenuController
    private let audioToolsContent: () -> AudioToolsContent

    @State private var localMode: AudioWorkspaceMode = .library
    @State private var searchFocusRequestToken: UInt64 = 0
    @State private var editorInspectorToggleToken: UInt64 = 0

    init(
        coordinator: AudioWorkspaceCoordinator,
        editorStore: AudioEditorStore,
        undoCoordinator: UndoRedoCoordinator = .shared,
        undoMenu: UndoMenuController = .shared,
        @ViewBuilder audioToolsContent: @escaping () -> AudioToolsContent
    ) {
        self.coordinator = coordinator
        self.editorStore = editorStore
        self.undoCoordinator = undoCoordinator
        self.undoMenu = undoMenu
        self.audioToolsContent = audioToolsContent
    }

    init(
        coordinator: AudioWorkspaceCoordinator,
        editorStore: AudioEditorStore,
        undoCoordinator: UndoRedoCoordinator = .shared,
        undoMenu: UndoMenuController = .shared
    ) where AudioToolsContent == EmptyView {
        self.coordinator = coordinator
        self.editorStore = editorStore
        self.undoCoordinator = undoCoordinator
        self.undoMenu = undoMenu
        self.audioToolsContent = { EmptyView() }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeaderBar

            Divider()

            Group {
                switch localMode {
                case .library:
                    HSplitView {
                        AudioLibrarySidebarView(
                            coordinator: coordinator,
                            store: coordinator.libraryStore
                        )
                        .frame(minWidth: 200, idealWidth: 228, maxWidth: 268)

                        AudioLibraryTrackListView(
                            coordinator: coordinator,
                            store: coordinator.libraryStore,
                            playback: coordinator.playbackCoordinator,
                            searchFocusRequestToken: searchFocusRequestToken,
                            onOpenInEditor: openInWaveformEditor
                        )
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)

                        if coordinator.isInspectorVisible {
                            AudioLibraryInspectorView(
                                store: coordinator.libraryStore,
                                record: coordinator.libraryStore.primaryInspectedRecord
                            )
                        }
                    }

                case .waveformEditor:
                    AudioEditorRootView(
                        store: editorStore,
                        isEmbeddedInAudioWorkspace: true,
                        externalInspectorToggleToken: editorInspectorToggleToken,
                        undoCoordinator: undoCoordinator,
                        undoMenu: undoMenu
                    )

                case .audioTools:
                    audioToolsContent()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            AudioPlayerBarView(
                coordinator: coordinator,
                playback: coordinator.playbackCoordinator
            )
        }
        .background(AppTheme.Colors.workspaceBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioworkspace.root")
        .background(
            AudioWorkspaceKeyMonitor(
                coordinator: coordinator,
                editorStore: editorStore,
                undoCoordinator: undoCoordinator,
                undoMenu: undoMenu,
                onFocusSearch: { searchFocusRequestToken &+= 1 },
                onToggleEditorInspector: { editorInspectorToggleToken &+= 1 }
            )
        )
        .onAppear {
            if localMode != coordinator.activeMode {
                localMode = coordinator.activeMode
            }
        }
        .onChange(of: localMode) { _, next in
            if coordinator.activeMode != next {
                Task { @MainActor in
                    coordinator.activeMode = next
                }
            }
        }
        .onChange(of: coordinator.activeMode) { _, next in
            if localMode != next {
                localMode = next
            }
        }
        .task {
            await coordinator.ensureInitialized()
        }
    }

    private var workspaceHeaderBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: 4) {
                ForEach(AudioWorkspaceMode.allCases) { mode in
                    let isSelected = localMode == mode
                    Button {
                        localMode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                            .font(AppTheme.Typography.subheadline)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBackground,
                                in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.rawValue) Mode")
                    .accessibilityValue(isSelected ? "Selected" : "Inactive")
                    .accessibilityIdentifier(mode.accessibilityIdentifier)
                }
            }

            Spacer()

            if coordinator.libraryStore.missingFileCount > 0 {
                Button {
                    localMode = .library
                    coordinator.libraryStore.sidebarSection = .missingFiles
                    Task { await coordinator.libraryStore.reloadMetadataAndTracks() }
                } label: {
                    Label(
                        "\(coordinator.libraryStore.missingFileCount) Missing",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(AppTheme.Typography.caption)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.Colors.warning)
                .accessibilityIdentifier("audioworkspace.header.missing_pill")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardBackground)
    }

    private func openInWaveformEditor(_ record: AudioLibraryRecord) {
        let resolvedURL = coordinator.resolveAssetURL(for: record)
        editorStore.importAudioFiles(urls: [resolvedURL])
        localMode = .waveformEditor
    }
}

// MARK: - Unified First-Responder-Safe Audio Workspace Shortcut Monitor

struct AudioWorkspaceKeyMonitor: NSViewRepresentable {
    let coordinator: AudioWorkspaceCoordinator
    let editorStore: AudioEditorStore
    var undoCoordinator: UndoRedoCoordinator = .shared
    var undoMenu: UndoMenuController = .shared
    let onFocusSearch: () -> Void
    let onToggleEditorInspector: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.workspaceCoordinator = coordinator
        context.coordinator.editorStore = editorStore
        context.coordinator.undoCoordinator = undoCoordinator
        context.coordinator.undoMenu = undoMenu
        context.coordinator.onFocusSearch = onFocusSearch
        context.coordinator.onToggleEditorInspector = onToggleEditorInspector
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: MonitorCoordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> MonitorCoordinator {
        MonitorCoordinator(
            workspaceCoordinator: coordinator,
            editorStore: editorStore,
            undoCoordinator: undoCoordinator,
            undoMenu: undoMenu,
            onFocusSearch: onFocusSearch,
            onToggleEditorInspector: onToggleEditorInspector
        )
    }

    @MainActor
    final class MonitorCoordinator {
        var workspaceCoordinator: AudioWorkspaceCoordinator
        var editorStore: AudioEditorStore
        var undoCoordinator: UndoRedoCoordinator
        var undoMenu: UndoMenuController
        var onFocusSearch: () -> Void
        var onToggleEditorInspector: () -> Void
        weak var hostView: NSView?
        private var monitor: Any?

        init(
            workspaceCoordinator: AudioWorkspaceCoordinator,
            editorStore: AudioEditorStore,
            undoCoordinator: UndoRedoCoordinator,
            undoMenu: UndoMenuController,
            onFocusSearch: @escaping () -> Void,
            onToggleEditorInspector: @escaping () -> Void
        ) {
            self.workspaceCoordinator = workspaceCoordinator
            self.editorStore = editorStore
            self.undoCoordinator = undoCoordinator
            self.undoMenu = undoMenu
            self.onFocusSearch = onFocusSearch
            self.onToggleEditorInspector = onToggleEditorInspector
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let hostWindow = self.hostView?.window
                let eventMatchesHostWindow = hostWindow != nil && event.window === hostWindow && hostWindow?.isKeyWindow == true
                guard eventMatchesHostWindow else { return event }

                let isModalPresented = self.editorStore.showExportSheet
                    || self.editorStore.showMissingRelinkSheet
                    || self.undoCoordinator.isEditingHistoryPresented
                    || !(hostWindow?.sheets.isEmpty ?? true)
                let isTextEditing = UndoMenuController.activeEditableTextResponder(from: hostWindow?.firstResponder) != nil

                let mode = self.workspaceCoordinator.activeMode
                guard let action = AudioWorkspaceShortcutRouter.resolve(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags,
                    mode: mode,
                    isTextEditing: isTextEditing,
                    isModalPresented: isModalPresented
                ) else {
                    return event
                }

                switch action {
                case .togglePlayPause:
                    if mode == .waveformEditor {
                        self.editorStore.togglePlayPause()
                    } else {
                        let playback = self.workspaceCoordinator.playbackCoordinator
                        Task { @MainActor in
                            await playback.togglePlayPause()
                        }
                    }
                case .splitAtPlayhead:
                    self.editorStore.splitAtPlayhead()
                case .trimToSelection:
                    self.editorStore.trimToSelection()
                case .deleteSelection:
                    self.editorStore.deleteSelectionOrClips(ripple: false)
                case .rippleDeleteSelection:
                    self.editorStore.deleteSelectionOrClips(ripple: true)
                case .zoomIn:
                    self.editorStore.zoomIn(viewportWidth: 720)
                case .zoomOut:
                    self.editorStore.zoomOut(viewportWidth: 720)
                case .zoomFit:
                    self.editorStore.fitProjectToWindow(viewportWidth: 720)
                case .focusSearch:
                    self.onFocusSearch()
                case .toggleInspector:
                    if mode == .library {
                        self.workspaceCoordinator.isInspectorVisible.toggle()
                    } else if mode == .waveformEditor {
                        self.onToggleEditorInspector()
                    }
                case .stepPlayheadLeft:
                    self.editorStore.skip(by: -1.0)
                case .stepPlayheadRight:
                    self.editorStore.skip(by: 1.0)
                case .nudgeLeft:
                    self.editorStore.nudgeSelectedClips(direction: -1)
                case .nudgeRight:
                    self.editorStore.nudgeSelectedClips(direction: 1)
                case .previousTrack:
                    let playback = self.workspaceCoordinator.playbackCoordinator
                    Task { @MainActor in await playback.previous() }
                case .nextTrack:
                    let playback = self.workspaceCoordinator.playbackCoordinator
                    Task { @MainActor in await playback.next() }
                case .toggleLoop:
                    self.editorStore.toggleLoopSelection()
                case .addMarker:
                    _ = self.editorStore.addMarkerAtPlayhead()
                case .returnToBeginning:
                    self.editorStore.returnToBeginning()
                case .undo:
                    self.undoMenu.performUndo()
                case .redo:
                    self.undoMenu.performRedo()
                }
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

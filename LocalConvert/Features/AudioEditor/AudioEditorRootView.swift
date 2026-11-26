import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct AudioEditorRootView: View {
    @ObservedObject var store: AudioEditorStore
    var isEmbeddedInAudioWorkspace: Bool = false
    var externalInspectorToggleToken: UInt64 = 0
    var undoCoordinator: UndoRedoCoordinator = .shared
    var undoMenu: UndoMenuController = .shared
    @State private var timelineViewportWidth: Double = 720
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            // Project & Editing Toolbar
            projectAndEditToolbar

            Divider()

            // Autosave Recovery Banner
            if let snap = store.recoverableAutosave {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("Unsaved session found for \"\(snap.project.name)\" (\(snap.savedAt.formatted(date: .abbreviated, time: .shortened))).")
                        .font(AppTheme.Typography.caption)
                    Spacer()
                    Button("Recover") {
                        store.restoreRecoverableAutosave()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .fixedSize(horizontal: true, vertical: false)
                    Button("Dismiss") {
                        store.discardRecoverableAutosave()
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, 6)
                .background(AppTheme.Colors.warningTint)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("audioworkspace.editor.recovery_banner")
            }

            // Missing-Source Warning Banner
            if !store.missingAssets.isEmpty {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Colors.error)
                    Text("\(store.missingAssets.count) source audio file(s) missing.")
                        .font(AppTheme.Typography.caption)
                    Spacer()
                    Button("Relink Missing Files...") {
                        store.showMissingRelinkSheet = true
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("audioworkspace.editor.missing_relink_button")
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, 6)
                .background(AppTheme.Colors.errorTint)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("audioworkspace.editor.missing_banner")
            }

            // Transport Bar
            TransportBarView(store: store, timelineViewportWidth: timelineViewportWidth)

            Divider()

            // Main Workspace: Timeline + Collapsible Inspector
            if store.project.tracks.allSatisfy({ $0.clips.isEmpty }) && store.project.tracks.count <= 1 {
                ZStack {
                    MultitrackTimelineView(store: store, viewportWidth: $timelineViewportWidth)
                    VStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Drop Audio Files onto the Timeline or Import to Start Editing")
                            .font(AppTheme.Typography.cardTitle)
                            .multilineTextAlignment(.center)
                        Text("Non-destructive multitrack editing: original files are never modified.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Import Audio Files...") {
                            openAudioImportPanel()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(AppTheme.Spacing.lg)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                }
            } else {
                HStack(spacing: 0) {
                    MultitrackTimelineView(store: store, viewportWidth: $timelineViewportWidth)
                    if showInspector {
                        Divider()
                        AudioEditorInspectorView(store: store)
                    }
                }
            }

            // Footer Status Bar
            if let status = store.playbackEngine.lastError ?? store.errorMessage ?? store.statusMessage {
                Divider()
                HStack {
                    Text(status)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(store.errorMessage != nil || store.playbackEngine.lastError != nil ? AppTheme.Colors.error : .secondary)
                    Spacer()
                    if store.errorMessage != nil || store.playbackEngine.lastError != nil {
                        Button("Clear") {
                            store.errorMessage = nil
                            store.playbackEngine.lastError = nil
                        }
                        .controlSize(.mini)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, 4)
                .background(AppTheme.Colors.subtleSurface)
            }
        }
        .onAppear { store.setEditorFocused(true) }
        .onDisappear { store.setEditorFocused(false) }
        .onChange(of: externalInspectorToggleToken) { _, _ in
            showInspector.toggle()
        }
        .sheet(isPresented: $store.showExportSheet) {
            AudioEditorExportSheet(store: store)
        }
        .sheet(isPresented: $store.showMissingRelinkSheet) {
            MissingSourceRelinkSheet(store: store)
        }
        .background(
            Group {
                if !isEmbeddedInAudioWorkspace {
                    AudioEditorKeyMonitor(
                        store: store,
                        viewportWidth: timelineViewportWidth,
                        undoCoordinator: undoCoordinator,
                        undoMenu: undoMenu,
                        onToggleInspector: { showInspector.toggle() }
                    )
                }
            }
        )
    }

    // MARK: - Top Toolbar

    private var projectAndEditToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.sm) {
                // Project Actions
                Menu {
                    Button("New Project") { store.newProject() }
                    Button("Open Project...") { openProjectPanel() }
                    Divider()
                    Button("Save Project") { saveProject(saveAs: false) }
                    Button("Save Project As...") { saveProject(saveAs: true) }
                    Button("Save Self-Contained Package...") { savePackagePanel() }
                } label: {
                    Label(store.project.name + (store.isDirty ? " •" : ""), systemImage: "folder")
                }
                .menuStyle(.borderlessButton)

                Button {
                    openAudioImportPanel()
                } label: {
                    Label("Import Audio", systemImage: "plus.circle")
                }

                Divider().frame(height: 18)

                // Editing Operations
                Button {
                    store.splitAtPlayhead()
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                .help("Split at Playhead (⌘E / B / S)")
                .accessibilityIdentifier("audioworkspace.editor.split")

                Button {
                    store.trimToSelection()
                } label: {
                    Label("Trim", systemImage: "crop")
                }
                .disabled(store.timeline.selectionRange == nil)
                .help("Trim to Selection (⌘T)")
                .accessibilityIdentifier("audioworkspace.editor.trim")

                Button {
                    store.copySelectedClips()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(store.selectedClipIDs.isEmpty)
                .help("Copy Selected Clips")

                Button {
                    store.cutSelectedClips()
                } label: {
                    Image(systemName: "scissors.badge.ellipsis")
                }
                .disabled(store.selectedClipIDs.isEmpty)
                .help("Cut Selected Clips")

                Button {
                    store.pasteAtPlayhead()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .disabled(store.clipboard.isEmpty)
                .help("Paste at Playhead")

                Button {
                    store.duplicateSelectedClips()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(store.selectedClipIDs.isEmpty)
                .help("Duplicate Selected Clips")

                Button {
                    store.consolidateSelectedClips()
                } label: {
                    Label("Consolidate", systemImage: "rectangle.compress.vertical")
                }
                .disabled(store.selectedClipIDs.count < 2)
                .help("Consolidate Adjacent Clips")

                Button {
                    store.insertSilence(duration: 1.0)
                } label: {
                    Label("Silence", systemImage: "waveform.path.badge.minus")
                }
                .help("Insert 1s Silence at Playhead")

                Button {
                    _ = store.addMarkerAtPlayhead()
                } label: {
                    Label("Marker", systemImage: "bookmark.fill")
                }
                .help("Add Marker at Playhead (M)")
                .accessibilityLabel("Add Marker at Playhead")

                Divider().frame(height: 18)

                // Nudge
                HStack(spacing: 2) {
                    Button {
                        store.nudgeSelectedClips(direction: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(store.selectedClipIDs.isEmpty)
                    .help("Nudge Left")

                    Picker("", selection: $store.nudgeIncrement) {
                        Text("10ms").tag(0.01)
                        Text("50ms").tag(0.05)
                        Text("100ms").tag(0.1)
                        Text("500ms").tag(0.5)
                        Text("1s").tag(1.0)
                    }
                    .frame(width: 68)
                    .labelsHidden()

                    Button {
                        store.nudgeSelectedClips(direction: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(store.selectedClipIDs.isEmpty)
                    .help("Nudge Right")
                }

                Divider().frame(height: 18)

                Button {
                    store.deleteSelectionOrClips(ripple: false)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(store.selectedClipIDs.isEmpty && store.timeline.selectionRange == nil)
                .help("Delete Selection / Clips (Delete)")
                .accessibilityLabel("Delete Selection or Clips")
                .accessibilityIdentifier("audioworkspace.editor.delete")

                Button {
                    store.deleteSelectionOrClips(ripple: true)
                } label: {
                    Label("Ripple Delete", systemImage: "arrow.left.to.line")
                }
                .disabled(store.selectedClipIDs.isEmpty && store.timeline.selectionRange == nil)
                .help("Ripple Delete (⌥Delete)")
                .accessibilityIdentifier("audioworkspace.editor.ripple_delete")

                Spacer()

                Toggle(isOn: $showInspector) {
                    Image(systemName: "sidebar.right")
                }
                .toggleStyle(.button)
                .help("Toggle Inspector (⌘I)")
                .accessibilityLabel("Toggle Editor Inspector")
                .accessibilityValue(showInspector ? "Shown" : "Hidden")
                .accessibilityIdentifier("audioworkspace.editor.inspector_toggle")

                Button {
                    store.showExportSheet = true
                } label: {
                    Label("Export...", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.project.duration <= 0)
                .accessibilityIdentifier("audioworkspace.editor.export")
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, 6)
        }
        .background(AppTheme.Colors.cardBackground)
    }

    // MARK: - Panels

    private func openAudioImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK {
            store.importAudioFiles(urls: panel.urls)
        }
    }

    private func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: ProjectPersistenceService.fileExtension) ?? .json,
            UTType(filenameExtension: ProjectPersistenceService.packageExtension) ?? .folder
        ]
        if panel.runModal() == .OK, let url = panel.url {
            store.openProject(from: url)
        }
    }

    private func saveProject(saveAs: Bool) {
        if !saveAs, let existing = store.currentProjectURL {
            store.saveProject(to: existing)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.project.name).\(ProjectPersistenceService.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            store.saveProject(to: url)
        }
    }

    private func savePackagePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.project.name).\(ProjectPersistenceService.packageExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            store.saveProject(to: url, selfContainedPackage: true)
        }
    }
}

// MARK: - Missing Source Relink Sheet

private struct MissingSourceRelinkSheet: View {
    @ObservedObject var store: AudioEditorStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Missing Source Audio Files")
                .font(AppTheme.Typography.pageTitle)
            Text("Original audio files referenced by this project could not be found at their saved locations.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)

            List(store.missingAssets) { asset in
                HStack {
                    VStack(alignment: .leading) {
                        Text(asset.displayName).font(AppTheme.Typography.cardTitle)
                        Text(asset.path).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Locate...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [.audio, .movie]
                        if panel.runModal() == .OK, let url = panel.url {
                            store.relinkMissingAsset(assetID: asset.id, newURL: url)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 480, height: 320)
    }
}

// MARK: - Safe Keyboard Navigation (respects active text fields)

struct AudioEditorKeyMonitor: NSViewRepresentable {
    let store: AudioEditorStore
    var viewportWidth: Double = 720
    var undoCoordinator: UndoRedoCoordinator = .shared
    var undoMenu: UndoMenuController = .shared
    var onToggleInspector: () -> Void = {}

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.viewportWidth = viewportWidth
        context.coordinator.undoCoordinator = undoCoordinator
        context.coordinator.undoMenu = undoMenu
        context.coordinator.onToggleInspector = onToggleInspector
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.store = store
        context.coordinator.viewportWidth = viewportWidth
        context.coordinator.undoCoordinator = undoCoordinator
        context.coordinator.undoMenu = undoMenu
        context.coordinator.onToggleInspector = onToggleInspector
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            store: store,
            viewportWidth: viewportWidth,
            undoCoordinator: undoCoordinator,
            undoMenu: undoMenu,
            onToggleInspector: onToggleInspector
        )
    }

    @MainActor
    static func shouldHandleKeyDown(
        isTextEditing: Bool,
        isModalPresented: Bool,
        eventMatchesHostWindow: Bool
    ) -> Bool {
        !isTextEditing && !isModalPresented && eventMatchesHostWindow
    }

    @MainActor
    final class Coordinator {
        var store: AudioEditorStore
        var viewportWidth: Double
        var undoCoordinator: UndoRedoCoordinator
        var undoMenu: UndoMenuController
        var onToggleInspector: () -> Void
        weak var hostView: NSView?
        private var monitor: Any?

        init(
            store: AudioEditorStore,
            viewportWidth: Double,
            undoCoordinator: UndoRedoCoordinator,
            undoMenu: UndoMenuController,
            onToggleInspector: @escaping () -> Void
        ) {
            self.store = store
            self.viewportWidth = viewportWidth
            self.undoCoordinator = undoCoordinator
            self.undoMenu = undoMenu
            self.onToggleInspector = onToggleInspector
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let hostWindow = self.hostView?.window
                let eventMatchesHostWindow = hostWindow != nil && event.window === hostWindow && hostWindow?.isKeyWindow == true
                let isModalPresented = self.store.showExportSheet
                    || self.store.showMissingRelinkSheet
                    || self.undoCoordinator.isEditingHistoryPresented
                    || !(hostWindow?.sheets.isEmpty ?? true)
                let isTextEditing = UndoMenuController.activeEditableTextResponder(from: hostWindow?.firstResponder) != nil

                guard AudioEditorKeyMonitor.shouldHandleKeyDown(
                    isTextEditing: isTextEditing,
                    isModalPresented: isModalPresented,
                    eventMatchesHostWindow: eventMatchesHostWindow
                ) else {
                    return event
                }

                guard let action = AudioWorkspaceShortcutRouter.resolve(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags,
                    mode: .waveformEditor,
                    isTextEditing: false,
                    isModalPresented: false
                ) else {
                    return event
                }

                switch action {
                case .togglePlayPause:
                    self.store.togglePlayPause()
                case .splitAtPlayhead:
                    self.store.splitAtPlayhead()
                case .trimToSelection:
                    self.store.trimToSelection()
                case .deleteSelection:
                    self.store.deleteSelectionOrClips(ripple: false)
                case .rippleDeleteSelection:
                    self.store.deleteSelectionOrClips(ripple: true)
                case .zoomIn:
                    self.store.zoomIn(viewportWidth: self.viewportWidth)
                case .zoomOut:
                    self.store.zoomOut(viewportWidth: self.viewportWidth)
                case .zoomFit:
                    self.store.fitProjectToWindow(viewportWidth: self.viewportWidth)
                case .toggleInspector:
                    self.onToggleInspector()
                case .stepPlayheadLeft:
                    self.store.skip(by: -1.0)
                case .stepPlayheadRight:
                    self.store.skip(by: 1.0)
                case .nudgeLeft:
                    self.store.nudgeSelectedClips(direction: -1)
                case .nudgeRight:
                    self.store.nudgeSelectedClips(direction: 1)
                case .toggleLoop:
                    self.store.toggleLoopSelection()
                case .addMarker:
                    _ = self.store.addMarkerAtPlayhead()
                case .returnToBeginning:
                    self.store.returnToBeginning()
                case .undo:
                    self.undoMenu.performUndo()
                case .redo:
                    self.undoMenu.performRedo()
                case .focusSearch, .previousTrack, .nextTrack:
                    return event
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

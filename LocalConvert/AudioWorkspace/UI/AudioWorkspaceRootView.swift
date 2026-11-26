import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AudioWorkspaceRootView<AudioToolsContent: View>: View {
    @ObservedObject var coordinator: AudioWorkspaceCoordinator
    @ObservedObject var editorStore: AudioEditorStore
    let undoCoordinator: UndoRedoCoordinator
    let undoMenu: UndoMenuController
    private let audioToolsContent: () -> AudioToolsContent

    @State private var localMode: AudioWorkspaceMode = .library
    @State private var searchFocusRequestToken: UInt64 = 0
    @State private var editorInspectorToggleToken: UInt64 = 0
    @State private var isTranscriptionSheetPresented = false

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
                    VStack(spacing: 0) {
                        audioToolsTranscribeCard
                        Divider()
                        audioToolsContent()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
        .sheet(isPresented: $isTranscriptionSheetPresented) {
            OfflineTranscriptionSheetView(coordinator: coordinator)
        }
    }

    private var audioToolsTranscribeCard: some View {
        AppCard(padding: AppTheme.Spacing.sm + 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md) {
                    transcribeCardDescription
                    Spacer(minLength: AppTheme.Spacing.xs)
                    transcribeOpenButton
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                    transcribeCardDescription
                    HStack {
                        Spacer(minLength: 0)
                        transcribeOpenButton
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioworkspace.tools.transcribe_card")
    }

    private var transcribeCardDescription: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "captions.bubble")
                .font(AppTheme.Typography.cardTitle)
                .foregroundStyle(AppTheme.Colors.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribe / Subtitles")
                    .font(AppTheme.Typography.cardTitle)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text("Offline on-device Speech-to-Text (.srt / .txt)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var transcribeOpenButton: some View {
        Button {
            isTranscriptionSheetPresented = true
        } label: {
            Label("Transcribe / Subtitles...", systemImage: "waveform.and.mic")
                .font(AppTheme.Typography.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityLabel("Transcribe / Subtitles")
        .accessibilityIdentifier("audioworkspace.tools.transcribe_button")
    }

    private var workspaceHeaderBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
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
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .strokeBorder(
                                        isSelected ? Color.clear : Color.primary.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(mode.rawValue) Mode")
                    .accessibilityValue(isSelected ? "Selected" : "Inactive")
                    .accessibilityIdentifier(mode.accessibilityIdentifier)
                }
            }
            .padding(3)
            .background(AppTheme.Colors.subtleSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

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

// MARK: - Offline Speech Transcription & Subtitle Export Sheet

@MainActor
private final class OfflineTranscriptionViewModel: ObservableObject {
    @Published var candidateURLs: [URL] = []
    @Published var selectedInputURL: URL?
    @Published var exportFormat: TranscriptionExportFormat = .srt
    @Published var localeChoices: [SpeechLocaleChoice] = []
    @Published var selectedLocaleIdentifier: String = Locale.current.identifier
    @Published var useCustomOutputDirectory = false
    @Published var customOutputDirectory: URL?

    @Published var isTranscribing = false
    @Published var progressFraction: Double? = nil
    @Published var progressMessage: String = ""
    @Published var errorMessage: String? = nil
    @Published var transcriptionResult: TranscriptionResult? = nil
    @Published var previewOutputText: String = ""

    private var activeTask: Task<Void, Never>? = nil

    var selectedLocaleChoice: SpeechLocaleChoice? {
        localeChoices.first { $0.identifier == selectedLocaleIdentifier }
    }

    var resolvedOutputDirectory: URL? {
        if useCustomOutputDirectory, let customOutputDirectory {
            return customOutputDirectory
        }
        if let appState = AppState.shared {
            if appState.outputLocation == .customFolder,
               let dir = appState.customOutputDirectory,
               OutputManager.isOutputDirectoryValid(dir) {
                return dir
            }
            if appState.outputLocation == .lastUsedFolder,
               let dir = OutputManager.lastUsedDirectory,
               OutputManager.isOutputDirectoryValid(dir) {
                return dir
            }
        }
        return selectedInputURL?.deletingLastPathComponent()
    }

    func loadInitialCandidatesAndLocales(coordinator: AudioWorkspaceCoordinator) {
        var seenPaths: Set<String> = []
        var urls: [URL] = []

        if let appState = AppState.shared {
            for file in appState.droppedFiles {
                guard let fmt = file.detectedFormat,
                      fmt.category == .audio || fmt.category == .video else { continue }
                let path = file.url.standardizedFileURL.path
                if seenPaths.insert(path).inserted {
                    urls.append(file.url)
                }
            }
        }

        for record in coordinator.libraryStore.displayedRecords {
            let resolved = coordinator.resolveAssetURL(for: record)
            let path = resolved.standardizedFileURL.path
            if seenPaths.insert(path).inserted {
                urls.append(resolved)
            }
        }

        candidateURLs = urls
        if selectedInputURL == nil {
            if let primary = coordinator.libraryStore.primaryInspectedRecord {
                selectedInputURL = coordinator.resolveAssetURL(for: primary)
            } else {
                selectedInputURL = urls.first
            }
        }

        let choices = OfflineSpeechTranscriptionEngine.shared.supportedLocaleChoices()
        localeChoices = choices
        if !choices.isEmpty, !choices.contains(where: { $0.identifier == selectedLocaleIdentifier }) {
            if let enUS = choices.first(where: { $0.identifier == "en-US" && $0.supportsOnDeviceRecognition }) {
                selectedLocaleIdentifier = enUS.identifier
            } else if let firstOnDevice = choices.first(where: { $0.supportsOnDeviceRecognition }) {
                selectedLocaleIdentifier = firstOnDevice.identifier
            } else if let first = choices.first {
                selectedLocaleIdentifier = first.identifier
            }
        }
    }

    func chooseMediaFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK, let url = panel.url {
            if !candidateURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                candidateURLs.insert(url, at: 0)
            }
            selectedInputURL = url
            errorMessage = nil
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            customOutputDirectory = url
            useCustomOutputDirectory = true
        }
    }

    func cancelTranscription() {
        activeTask?.cancel()
        activeTask = nil
    }

    func startTranscription() {
        guard let inputURL = selectedInputURL,
              let outputDir = resolvedOutputDirectory else {
            errorMessage = "Please select a source audio or video file and a writable output folder."
            return
        }

        activeTask?.cancel()
        errorMessage = nil
        transcriptionResult = nil
        previewOutputText = ""
        isTranscribing = true
        progressFraction = 0.05
        progressMessage = "Preparing offline speech recognizer..."

        let targetFormat = exportFormat
        let localeID = selectedLocaleIdentifier

        let resolveModel: @MainActor @Sendable () -> OfflineTranscriptionViewModel? = { [weak self] in self }
        activeTask = Task {
            do {
                let result = try await OfflineSpeechTranscriptionEngine.shared.transcribe(
                    inputURL: inputURL,
                    to: targetFormat,
                    outputDirectory: outputDir,
                    localeIdentifier: localeID,
                    existingFileHandling: .createUnique
                ) { progress in
                    Task { @MainActor in
                        guard let model = resolveModel() else { return }
                        model.progressFraction = progress.fractionCompleted
                        model.progressMessage = progress.statusMessage
                    }
                }
                guard let model = resolveModel() else { return }
                let filePreview = (try? String(contentsOf: result.outputURL, encoding: .utf8)) ?? result.transcriptText
                model.isTranscribing = false
                model.transcriptionResult = result
                model.previewOutputText = filePreview
                if AppSettings.shared.saveConversionHistory {
                    let inFmt = FileDetector.detectFormat(url: inputURL)?.displayName ?? inputURL.pathExtension.uppercased()
                    let inSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64)
                    let outSize = (try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? Int64)
                    AppState.shared?.historyManager.addEntry(
                        ConversionHistoryItem(
                            inputFilename: inputURL.lastPathComponent,
                            inputFormatName: inFmt,
                            outputFilename: result.outputURL.lastPathComponent,
                            outputFormatName: targetFormat.fileFormat.displayName,
                            status: .completed,
                            inputSizeBytes: inSize,
                            outputSizeBytes: outSize,
                            presetName: "Offline Speech-to-Text",
                            outputURLPath: result.outputURL.path,
                            inputURLPath: inputURL.path,
                            duration: result.durationSeconds,
                            source: .manual
                        )
                    )
                }
            } catch is CancellationError {
                guard let model = resolveModel() else { return }
                model.isTranscribing = false
                model.progressFraction = nil
                model.progressMessage = "Cancelled"
            } catch let convErr as ConversionError {
                guard let model = resolveModel() else { return }
                model.isTranscribing = false
                model.errorMessage = convErr.userFacingMessage
            } catch {
                guard let model = resolveModel() else { return }
                model.isTranscribing = false
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct OfflineTranscriptionSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: AudioWorkspaceCoordinator
    @StateObject private var model = OfflineTranscriptionViewModel()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    AppInfoBanner(
                        style: .info,
                        message: "Strictly offline: uses Apple on-device Speech Recognition (requiresOnDeviceRecognition = true) with zero network uploads. Source media is never modified."
                    )

                    sourceSelectionCard
                    optionsCard

                    if model.isTranscribing {
                        progressCard
                    }

                    if let errorMessage = model.errorMessage {
                        AppInfoBanner(
                            style: .error,
                            message: errorMessage,
                            onDismiss: { model.errorMessage = nil }
                        )
                    }

                    if let result = model.transcriptionResult {
                        resultCard(result)
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 420, idealHeight: 500)
        .background(AppTheme.Colors.workspaceBackground)
        .accessibilityIdentifier("audioworkspace.transcribe.sheet")
        .task {
            model.loadInitialCandidatesAndLocales(coordinator: coordinator)
        }
        .onDisappear {
            model.cancelTranscription()
        }
    }

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "captions.bubble")
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Offline Speech-to-Text & Subtitles")
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)
                Text("Transcribe audio or video tracks to .srt subtitles or .txt plain text")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Close") {
                model.cancelTranscription()
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("audioworkspace.transcribe.close")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.cardBackground)
    }

    private var sourceSelectionCard: some View {
        AppCard(title: "Source Audio / Video", icon: "waveform") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if !model.candidateURLs.isEmpty {
                    Picker("Track:", selection: $model.selectedInputURL) {
                        ForEach(model.candidateURLs, id: \.self) { url in
                            Text(url.lastPathComponent).tag(Optional(url))
                        }
                    }
                    .disabled(model.isTranscribing)
                }

                HStack(spacing: AppTheme.Spacing.sm) {
                    if let url = model.selectedInputURL {
                        Text(url.lastPathComponent)
                            .font(AppTheme.Typography.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No audio or video file selected")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: AppTheme.Spacing.xs)

                    Button("Choose File...") {
                        model.chooseMediaFile()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isTranscribing)
                    .accessibilityIdentifier("audioworkspace.transcribe.choose_file")
                }
            }
        }
    }

    private var optionsCard: some View {
        AppCard(title: "Transcription Options", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm + 2) {
                HStack {
                    Text("Export Format:")
                        .font(AppTheme.Typography.caption)
                        .frame(width: 110, alignment: .leading)
                    Picker("Export Format", selection: $model.exportFormat) {
                        ForEach(TranscriptionExportFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(model.isTranscribing)
                    .accessibilityIdentifier("audioworkspace.transcribe.format_picker")
                }

                HStack {
                    Text("Language:")
                        .font(AppTheme.Typography.caption)
                        .frame(width: 110, alignment: .leading)
                    if model.localeChoices.isEmpty {
                        Text(model.selectedLocaleIdentifier)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Language", selection: $model.selectedLocaleIdentifier) {
                            ForEach(model.localeChoices) { choice in
                                let suffix = choice.supportsOnDeviceRecognition ? "" : " (On-device unavailable)"
                                Text("\(choice.displayName)\(suffix)").tag(choice.identifier)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isTranscribing)
                        .accessibilityIdentifier("audioworkspace.transcribe.locale_picker")
                    }
                }

                if let choice = model.selectedLocaleChoice, !choice.supportsOnDeviceRecognition {
                    AppInfoBanner(
                        style: .warning,
                        message: "Offline on-device speech recognition is not installed for \(choice.displayName) on this Mac."
                    )
                }

                HStack {
                    Text("Output Folder:")
                        .font(AppTheme.Typography.caption)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 110, alignment: .leading)
                    Text(model.resolvedOutputDirectory?.path ?? "Same folder as source")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: AppTheme.Spacing.xs)
                    Button("Choose...") {
                        model.chooseOutputFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isTranscribing)
                }
            }
        }
    }

    private var progressCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                HStack {
                    if let progressFraction = model.progressFraction {
                        ProgressView(value: progressFraction)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Cancel", role: .cancel) {
                        model.cancelTranscription()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text(model.progressMessage.isEmpty ? "Transcribing on-device..." : model.progressMessage)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resultCard(_ result: TranscriptionResult) -> some View {
        AppCard(title: "Exported \(result.exportFormat.shortLabel.uppercased())", icon: "checkmark.circle.fill") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                AppInfoBanner(
                    style: .success,
                    message: "Saved \(result.outputURL.lastPathComponent) (\(result.segments.count) speech segments)"
                )

                ScrollView {
                    Text(model.previewOutputText)
                        .font(AppTheme.Typography.monoCaption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.Spacing.sm)
                }
                .frame(height: 120)
                .background(AppTheme.Colors.subtleSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                HStack(spacing: AppTheme.Spacing.sm) {
                    Button("Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.previewOutputText, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button {
                model.startTranscription()
            } label: {
                Label(
                    model.isTranscribing ? "Transcribing..." : "Transcribe to \(model.exportFormat.shortLabel)",
                    systemImage: "waveform.and.mic"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isTranscribing || model.selectedInputURL == nil)
            .accessibilityIdentifier("audioworkspace.transcribe.start_button")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm + 2)
        .background(AppTheme.Colors.cardBackground)
    }
}

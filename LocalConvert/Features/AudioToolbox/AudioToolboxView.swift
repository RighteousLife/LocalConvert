import SwiftUI
import UniformTypeIdentifiers

// MARK: - Audio Toolbox Navigation Sections

enum AudioToolboxSection: String, CaseIterable, Identifiable {
    case convert = "Convert & Codec"
    case trim = "Quick Trim & Segments"
    case audioEditor = "Audio Editor 2.0"
    case merge = "Merge Audio"
    case effects = "Adjust & Effects"
    case metadata = "Tags & Cover Art"
    case spotifyCompatibility = "Spotify Compatibility"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .convert: return "waveform.badge.plus"
        case .trim: return "scissors"
        case .audioEditor: return "slider.horizontal.below.rectangle"
        case .merge: return "arrow.triangle.merge"
        case .effects: return "slider.vertical.3"
        case .metadata: return "music.note.list"
        case .spotifyCompatibility: return "checkmark.seal"
        }
    }

    var summary: String {
        switch self {
        case .convert: return "Choose container format, codec, bitrate/VBR, sample rate, bit depth, channels, or lossless stream copy."
        case .trim: return "Inspect real audio waveforms, trim non-destructively, extract multiple segments, or remove silence."
        case .audioEditor: return "Non-destructive multitrack audio editor with timeline, scrubbing, fades, crossfades, effects, and mixdown."
        case .merge: return "Combine multiple audio tracks seamlessly in custom order across differing sample rates or formats."
        case .effects: return "Apply non-destructive EQ, fade-in/out, volume gain, speed/pitch scaling, noise reduction, compression, and EBU R128 normalization."
        case .metadata: return "Edit ID3 / Vorbis / MP4 tags, multi-line lyrics, and embedded album artwork."
        case .spotifyCompatibility: return "Inspect MP3, M4A, MP4, lossless, and DRM tracks for Spotify local-file playback and safely normalize metadata."
        }
    }
}

// MARK: - Audio Toolbox View

struct AudioToolboxView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var metadataManager = MetadataManager.shared
    @StateObject private var previewPlayer = AudioPreviewController()

    var hideEmbeddedAudioEditor: Bool = false

    @State private var primaryInfo: MediaInfo?
    @State private var waveform: AudioWaveformData?
    @State private var isLoadingWaveform = false
    @State private var waveformError: String?
    @State private var primaryDetailsTask: Task<Void, Never>?

    @State private var silenceIntervals: [AudioSilenceInterval] = []
    @State private var isDetectingSilence = false

    @State private var showSavePresetPopover = false
    @State private var presetName = ""
    @State private var presetDescription = ""
    @State private var statusBanner: String?
    @State private var isDropTargeted = false

    private var visibleSections: [AudioToolboxSection] {
        hideEmbeddedAudioEditor
            ? AudioToolboxSection.allCases.filter { $0 != .audioEditor }
            : AudioToolboxSection.allCases
    }

    private var selectedSection: AudioToolboxSection {
        let current = appState.audioToolboxStore.selectedSection
        if hideEmbeddedAudioEditor && current == .audioEditor {
            return .convert
        }
        return current
    }

    private var selectedSectionBinding: Binding<AudioToolboxSection> {
        Binding(
            get: { appState.audioToolboxStore.selectedSection },
            set: { appState.audioToolboxStore.selectedSection = $0 }
        )
    }

    private var selectedFileIds: Set<UUID> {
        appState.audioToolboxStore.selectedFileIds
    }

    private var orderedMergeIDs: [UUID] {
        appState.audioToolboxStore.orderedMergeIDs
    }

    private var candidateFiles: [DroppedFile] {
        appState.droppedFiles.filter { file in
            guard let fmt = file.detectedFormat else { return false }
            return fmt.category == .audio || fmt.category == .video
        }
    }

    private var selectedFiles: [DroppedFile] {
        if selectedSection == .merge {
            let map = Dictionary(uniqueKeysWithValues: candidateFiles.map { ($0.id, $0) })
            let ordered = orderedMergeIDs.compactMap { map[$0] }
            let selectedSet = selectedFileIds
            return ordered.filter { selectedSet.contains($0.id) }
        }
        return candidateFiles.filter { selectedFileIds.contains($0.id) }
    }

    private var primaryURL: URL? {
        selectedFiles.first?.url ?? candidateFiles.first?.url
    }

    private var targetFormat: FileFormat {
        appState.audioToolboxStore.targetFormat(for: primaryURL)
    }

    private var targetFormatBinding: Binding<FileFormat> {
        appState.audioToolboxStore.targetFormatBinding(for: primaryURL)
    }

    private var config: AudioToolboxConfig {
        appState.audioToolboxStore.config(for: primaryURL)
    }

    private var configBinding: Binding<AudioToolboxConfig> {
        appState.audioToolboxStore.configBinding(for: primaryURL)
    }

    private var preserveMetadata: Bool {
        appState.audioToolboxStore.preserveMetadata(for: primaryURL)
    }

    private var preserveMetadataBinding: Binding<Bool> {
        appState.audioToolboxStore.preserveMetadataBinding(for: primaryURL)
    }

    private var trimStart: Double {
        appState.audioToolboxStore.trimStart(for: primaryURL)
    }

    private var trimStartBinding: Binding<Double> {
        appState.audioToolboxStore.trimStartBinding(for: primaryURL)
    }

    private var trimEnd: Double {
        appState.audioToolboxStore.trimEnd(for: primaryURL)
    }

    private var trimEndBinding: Binding<Double> {
        appState.audioToolboxStore.trimEndBinding(for: primaryURL)
    }

    private var currentValidation: AudioValidationResult {
        var effective = config
        syncOperationAndTrim(into: &effective)
        return AudioConversionValidator.validate(
            config: effective,
            outputFormat: targetFormat,
            sourceInfo: primaryInfo
        )
    }

    var body: some View {
        HSplitView {
            // Left Toolbox Sidebar
            List(visibleSections, selection: selectedSectionBinding) { section in
                AppToolboxSidebarRow(
                    section.rawValue,
                    systemImage: section.iconName,
                    isSelected: selectedSection == section
                )
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(minWidth: AppTheme.Layout.toolboxSidebarMin, maxWidth: AppTheme.Layout.toolboxSidebarMax)
            .appSecondarySidebarSurface()

            // Main Workspace
            VStack(spacing: 0) {
                if selectedSection == .audioEditor {
                    AudioEditorRootView(store: appState.audioEditorStore)
                } else if candidateFiles.isEmpty && selectedSection != .spotifyCompatibility {
                    emptyDropView
                } else {
                    workspaceContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appWorkspaceSurface()
        }
        .navigationTitle("Audio Toolbox")
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onAppear { syncCandidateSelection() }
        .onChange(of: candidateFiles.map(\.id)) { _, _ in syncCandidateSelection() }
        .onChange(of: selectedFileIds) { _, _ in loadPrimaryDetails() }
        .onChange(of: selectedSection) { _, newSec in
            if newSec == .metadata, let url = primaryURL {
                Task { await metadataManager.load(url: url) }
            } else if newSec == .trim, waveform == nil {
                loadPrimaryDetails()
            }
        }
        .onDisappear {
            primaryDetailsTask?.cancel()
            previewPlayer.stop()
        }
    }

    // MARK: - Empty Drop Zone

    @ViewBuilder
    private var emptyDropView: some View {
        AppEmptyStateView(
            icon: "waveform.circle",
            title: "No Audio Files Loaded",
            subtitle: "Drop audio or video files anywhere, or add tracks to use Audio Toolbox.",
            isDropTargeted: isDropTargeted,
            primaryButtonTitle: "Add Audio Files...",
            primaryButtonIcon: "plus",
            onPrimaryAction: openFilePicker
        )
    }

    // MARK: - Workspace Content

    @ViewBuilder
    private var workspaceContent: some View {
        let audioMetadataText: String? = primaryInfo.flatMap { info in
            guard let audio = info.primaryAudioStream else { return nil }
            let rateStr = audio.sampleRate.map { "\($0 / 1000)kHz" } ?? ""
            let chStr = audio.channels == 1 ? "Mono" : (audio.channels == 2 ? "Stereo" : "\(audio.channels ?? 0)ch")
            return "\(audio.codecName.uppercased()) · \(rateStr) · \(chStr) · \(AudioWaveformView.formatTime(info.duration))"
        }

        VStack(spacing: 0) {
            AppToolboxHeader(
                title: selectedSection.rawValue,
                subtitle: selectedSection.summary,
                metadataText: selectedSection == .spotifyCompatibility ? nil : audioMetadataText
            )

            // File Selection Header Strip
            if selectedSection != .spotifyCompatibility {
                fileSelectionStrip
            }

            // Scrollable Main Section View
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    switch selectedSection {
                    case .convert:
                        AudioCodecOptionsView(
                            targetFormat: targetFormatBinding,
                            config: configBinding,
                            preserveMetadata: preserveMetadataBinding,
                            sourceInfo: primaryInfo,
                            validation: currentValidation
                        )

                    case .trim:
                        trimAndSegmentsSection

                    case .audioEditor:
                        EmptyView()

                    case .merge:
                        mergeOrderSection
                        AudioCodecOptionsView(
                            targetFormat: targetFormatBinding,
                            config: configBinding,
                            preserveMetadata: preserveMetadataBinding,
                            sourceInfo: primaryInfo,
                            validation: currentValidation
                        )

                    case .effects:
                        AudioEffectsView(config: configBinding, primaryInputURL: primaryURL)

                    case .metadata:
                        embeddedMetadataSection

                    case .spotifyCompatibility:
                        SpotifyCompatibilityView()
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }

            // Bottom Action Bar
            if selectedSection != .spotifyCompatibility {
                AppBottomActionBar {
                    bottomActionBar
                }
            }
        }
    }

    // MARK: - File Strip

    @ViewBuilder
    private var fileSelectionStrip: some View {
        let items = candidateFiles.map { file in
            AppFileSelectionStripItem(
                id: file.id,
                title: file.url.lastPathComponent,
                formatLabel: file.detectedFormat?.shortExtensionLabel ?? "",
                isSelected: selectedFileIds.contains(file.id)
            )
        }

        AppFileSelectionStrip(
            title: "Tracks (\(selectedFiles.count) of \(candidateFiles.count) selected)",
            items: items,
            onToggleItem: { id in
                if appState.audioToolboxStore.selectedFileIds.contains(id) {
                    appState.audioToolboxStore.selectedFileIds.remove(id)
                } else {
                    appState.audioToolboxStore.selectedFileIds.insert(id)
                }
            }
        ) {
            Button("Add More...") { openFilePicker() }
                .controlSize(.small)
            Button("Select All") { appState.audioToolboxStore.selectedFileIds = Set(candidateFiles.map(\.id)) }
                .controlSize(.small)
            Button("None") { appState.audioToolboxStore.selectedFileIds.removeAll() }
                .controlSize(.small)
        }
    }

    // MARK: - Trim, Segments & Silence Section

    @ViewBuilder
    private var trimAndSegmentsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: "Waveform & Range Selector", icon: "waveform") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm + 2) {
                    HStack {
                        Spacer()
                        if let url = primaryURL {
                            Button {
                                previewPlayer.togglePlay(
                                    url: url,
                                    startTime: trimStart,
                                    endTime: trimEnd > trimStart ? trimEnd : nil
                                )
                            } label: {
                                Label(previewPlayer.isPlaying ? "Stop Preview" : "Play Selection", systemImage: previewPlayer.isPlaying ? "stop.fill" : "play.fill")
                            }
                            .controlSize(.small)
                        }
                    }

                    if isLoadingWaveform {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Extracting real PCM waveform...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88)
                    } else if let wf = waveform {
                        AudioWaveformView(
                            waveform: wf,
                            trimStart: trimStartBinding,
                            trimEnd: trimEndBinding,
                            segments: config.segments,
                            silenceIntervals: silenceIntervals,
                            currentTime: previewPlayer.currentTime
                        )
                    } else if let err = waveformError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Numeric Trim Controls
                    let numericFields = HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("Start (s):")
                                .font(.caption)
                                .fixedSize(horizontal: true, vertical: false)
                            TextField("0.0", value: trimStartBinding, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 74)
                        }
                        HStack(spacing: 6) {
                            Text("End (s):")
                                .font(.caption)
                                .fixedSize(horizontal: true, vertical: false)
                            TextField("0.0", value: trimEndBinding, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 74)
                        }
                    }

                    let segmentButtons = HStack(spacing: 8) {
                        Button("Add Segment") {
                            let endVal = trimEnd > trimStart ? trimEnd : (primaryInfo?.duration ?? trimStart + 1.0)
                            let seg = AudioTrimSegment(
                                startTime: max(0, trimStart),
                                endTime: max(trimStart + 0.1, endVal),
                                label: "seg\(config.segments.count + 1)"
                            )
                            appState.audioToolboxStore.updateConfig(
                                for: primaryURL,
                                explicitType: .audioToolboxSegmentEdit,
                                explicitTitle: "Add Audio Segment",
                                transactionGroupID: UUID()
                            ) { $0.segments.append(seg) }
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(trimEnd <= trimStart)

                        if let wf = waveform {
                            Button("Reset Bounds") {
                                appState.audioToolboxStore.setTrimBounds(start: 0, end: wf.duration, for: primaryURL)
                            }
                            .controlSize(.small)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            numericFields
                            Spacer(minLength: AppTheme.Spacing.xs)
                            segmentButtons
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                            HStack(spacing: 12) {
                                numericFields
                                Spacer(minLength: 0)
                            }
                            HStack(spacing: AppTheme.Spacing.sm) {
                                segmentButtons
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }

            // Multi-Segment List
            AppCard(title: "Multi-Segment Extraction (\(config.segments.count) segments)", icon: "scissors") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack {
                        Spacer()
                        if !config.segments.isEmpty {
                            Button("Clear Segments", role: .destructive) {
                                appState.audioToolboxStore.updateConfig(
                                    for: primaryURL,
                                    explicitType: .audioToolboxSegmentEdit,
                                    explicitTitle: "Clear Audio Segments",
                                    transactionGroupID: UUID()
                                ) { $0.segments.removeAll() }
                            }
                            .controlSize(.small)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    if config.segments.isEmpty {
                        Text("When no segments are listed, single-range trim (Start → End) applies. Add multiple segments above to export separate clips.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(configBinding.segments) { $seg in
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    TextField("Label", text: $seg.label)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(minWidth: 80, maxWidth: 110)
                                    Text("Start:")
                                        .font(.caption)
                                        .fixedSize(horizontal: true, vertical: false)
                                    TextField("0.0", value: $seg.startTime, format: .number.precision(.fractionLength(2)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 66)
                                    Text("End:")
                                        .font(.caption)
                                        .fixedSize(horizontal: true, vertical: false)
                                    TextField("0.0", value: $seg.endTime, format: .number.precision(.fractionLength(2)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 66)
                                    Text("(\(String(format: "%.2fs", seg.duration)))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer(minLength: 0)
                                    Button(role: .destructive) {
                                        appState.audioToolboxStore.updateConfig(
                                            for: primaryURL,
                                            explicitType: .audioToolboxSegmentEdit,
                                            explicitTitle: "Remove Audio Segment",
                                            transactionGroupID: UUID()
                                        ) { $0.segments.removeAll { $0.id == seg.id } }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove segment")
                                }

                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                    HStack(spacing: 8) {
                                        TextField("Label", text: $seg.label)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(minWidth: 100, maxWidth: 180)
                                        Text("(\(String(format: "%.2fs", seg.duration)))")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Spacer(minLength: 0)
                                        Button(role: .destructive) {
                                            appState.audioToolboxStore.updateConfig(
                                                for: primaryURL,
                                                explicitType: .audioToolboxSegmentEdit,
                                                explicitTitle: "Remove Audio Segment",
                                                transactionGroupID: UUID()
                                            ) { $0.segments.removeAll { $0.id == seg.id } }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove segment")
                                    }
                                    HStack(spacing: 8) {
                                        Text("Start:")
                                            .font(.caption)
                                            .fixedSize(horizontal: true, vertical: false)
                                        TextField("0.0", value: $seg.startTime, format: .number.precision(.fractionLength(2)))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 72)
                                        Text("End:")
                                            .font(.caption)
                                            .fixedSize(horizontal: true, vertical: false)
                                        TextField("0.0", value: $seg.endTime, format: .number.precision(.fractionLength(2)))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 72)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Silence Detection & Removal
            AppCard(title: "Silence Detection & Trimming", icon: "waveform.slash") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm + 2) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Toggle("Auto-Remove Silence", isOn: configBinding.removeSilence)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            silenceScopeAndDetectControls
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Toggle("Auto-Remove Silence", isOn: configBinding.removeSilence)
                            HStack(spacing: AppTheme.Spacing.sm) {
                                silenceScopeAndDetectControls
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            silenceThresholdSlider
                            silenceMinDurationSlider
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            silenceThresholdSlider
                            silenceMinDurationSlider
                        }
                    }

                    if !silenceIntervals.isEmpty {
                        AppInfoBanner(
                            style: .warning,
                            message: "Detected \(silenceIntervals.count) silence interval(s): " + silenceIntervals.prefix(4).map {
                                "\(String(format: "%.1f–%.1fs", $0.start, $0.end))"
                            }.joined(separator: ", ") + (silenceIntervals.count > 4 ? "…" : "")
                        )
                    }
                }
            }
        }
    }

    // MARK: - Merge Section

    @ViewBuilder
    private var mergeOrderSection: some View {
        AppCard(title: "Merge Order", icon: "list.number") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Tracks are resampled cleanly and concatenated in top-to-bottom order.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)

                let files = selectedFiles
                if files.count < 2 {
                    AppInfoBanner(style: .warning, message: "Select at least 2 tracks above to merge.")
                } else {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        HStack {
                            Text("\(index + 1).")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(file.url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button { moveMergeItem(at: index, direction: -1) } label: {
                                Image(systemName: "arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(index == 0)
                            .accessibilityLabel("Move track up")

                            Button { moveMergeItem(at: index, direction: 1) } label: {
                                Image(systemName: "arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(index == files.count - 1)
                            .accessibilityLabel("Move track down")
                        }
                        .padding(.vertical, 2)
                    }

                    Divider()
                    HStack {
                        Text("Crossfade Overlap")
                            .font(.caption)
                            .frame(width: 120, alignment: .leading)
                        Slider(value: configBinding.mergeCrossfadeSeconds, in: 0.0...5.0, step: 0.25)
                            .accessibilityLabel("Merge crossfade overlap")
                            .accessibilityValue(config.mergeCrossfadeSeconds > 0.05 ? String(format: "%.2f seconds", config.mergeCrossfadeSeconds) : "Off")
                        Text(config.mergeCrossfadeSeconds > 0.05 ? String(format: "%.2fs (qsin)", config.mergeCrossfadeSeconds) : "Off (Gapless)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Embedded Metadata Section

    @ViewBuilder
    private var embeddedMetadataSection: some View {
        if metadataManager.isLoading {
            AppLoadingStateView(message: "Reading audio tags...")
        } else if let doc = metadataManager.document, let caps = metadataManager.capabilities {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if caps.canRemoveArtwork {
                    AppCard(title: "Cover Artwork", icon: "photo") {
                        ArtworkEditorView(
                            artwork: doc.artwork,
                            isWritable: caps.canWrite,
                            onArtworkChanged: { metadataManager.updateArtwork(data: $0) }
                        )
                    }
                }

                let editableFields = caps.fields.filter { $0.id != "artwork" && $0.valueType != .readOnlyTechnical }
                AppCard(title: "Audio Tags & Lyrics", icon: "tag") {
                    VStack(spacing: AppTheme.Spacing.xs + 2) {
                        ForEach(editableFields) { field in
                            MetadataFieldView(
                                descriptor: field,
                                value: doc.value(for: field.id),
                                onValueChanged: { metadataManager.updateField(id: field.id, value: $0) }
                            )
                        }
                    }
                }

                if let note = doc.technical["metadataNote"] {
                    AppInfoBanner(style: .info, message: note)
                }

                if let err = metadataManager.errorMessage {
                    AppInfoBanner(style: .error, message: err)
                } else if metadataManager.showSuccessToast {
                    AppInfoBanner(style: .success, message: "Tags saved without re-encoding audio")
                }

                HStack {
                    Spacer()
                    Button("Revert") { metadataManager.revert() }
                        .disabled(!metadataManager.isDirty || metadataManager.isSaving)
                    Button("Save In-Place") {
                        Task { _ = await metadataManager.saveInPlace(context: .audioToolbox) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!metadataManager.isDirty || metadataManager.isSaving || !caps.canWrite)
                    .help("Overwrite tags in the original audio file (supports Undo)")
                    Button("Save Copy...") {
                        presentAudioMetadataSaveCopyPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!metadataManager.isDirty || metadataManager.isSaving || !caps.canWrite)
                    .help("Save updated tags to a new audio file copy without modifying the original")
                }
            }
        } else {
            AppInfoBanner(style: .info, message: "Select an audio track to edit embedded tags, lyrics, and cover art.")
        }
    }

    private func presentAudioMetadataSaveCopyPanel() {
        guard let suggestedURL = metadataManager.suggestedSaveCopyURL() else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.prompt = "Save Tagged Audio Copy"
        if panel.runModal() == .OK, let targetURL = panel.url {
            Task {
                _ = await metadataManager.saveCopy(to: targetURL, context: .audioToolbox)
            }
        }
    }

    // MARK: - Bottom Action Bar

    @ViewBuilder
    private var bottomActionBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            if let statusBanner {
                Label(statusBanner, systemImage: "checkmark.circle.fill")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.success)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if appState.isConverting {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Processing in Jobs Center...")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Save Preset...") {
                presetName = "Audio \(targetFormat.displayName)"
                presetDescription = ""
                showSavePresetPopover = true
            }
            .fixedSize(horizontal: true, vertical: false)
            .popover(isPresented: $showSavePresetPopover) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Save Audio Toolbox Preset")
                        .font(.headline)
                    TextField("Preset Name", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Description (optional)", text: $presetDescription)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Cancel") { showSavePresetPopover = false }
                        Button("Save") {
                            var cfg = config
                            syncOperationAndTrim(into: &cfg)
                            appState.saveAudioToolboxPreset(
                                name: presetName,
                                description: presetDescription.isEmpty ? nil : presetDescription,
                                targetFormat: targetFormat,
                                config: cfg,
                                preserveMetadata: preserveMetadata
                            )
                            showSavePresetPopover = false
                            statusBanner = "Saved preset '\(presetName)'"
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
                .frame(width: 280)
            }

            if selectedSection != .metadata {
                Button(action: runAction) {
                    Text(primaryButtonTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!canRunPrimaryAction)
            }
        }
    }

    @ViewBuilder
    private var silenceScopeAndDetectControls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Picker("Scope", selection: configBinding.silenceTrimScope) {
                ForEach(AudioSilenceTrimScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .frame(minWidth: 150, maxWidth: 210)
            if let url = primaryURL {
                Button {
                    runSilenceDetection(url: url)
                } label: {
                    if isDetectingSilence {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Detect Silence", systemImage: "ear.badge.waveform")
                            .lineLimit(1)
                    }
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isDetectingSilence)
            }
        }
    }

    @ViewBuilder
    private var silenceThresholdSlider: some View {
        HStack {
            Text("Threshold:")
                .font(.caption)
                .fixedSize(horizontal: true, vertical: false)
            Slider(value: configBinding.silenceThresholdDB, in: -70...(-15), step: 1)
                .accessibilityLabel("Silence threshold")
                .accessibilityValue("\(Int(config.silenceThresholdDB)) decibels")
            Text("\(Int(config.silenceThresholdDB)) dB")
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var silenceMinDurationSlider: some View {
        HStack {
            Text("Min Duration:")
                .font(.caption)
                .fixedSize(horizontal: true, vertical: false)
            Slider(value: configBinding.silenceMinDurationSeconds, in: 0.1...5.0, step: 0.1)
                .accessibilityLabel("Minimum silence duration")
                .accessibilityValue(String(format: "%.1f seconds", config.silenceMinDurationSeconds))
            Text(String(format: "%.1fs", config.silenceMinDurationSeconds))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var primaryButtonTitle: String {
        switch selectedSection {
        case .merge:
            return "Merge \(selectedFiles.count) Tracks"
        case .trim:
            if !config.segments.isEmpty {
                return "Extract \(config.segments.count) Segment\(config.segments.count == 1 ? "" : "s")"
            }
            return config.removeSilence ? "Trim & Clean Audio" : "Export Trimmed Audio"
        default:
            return selectedFiles.count > 1 ? "Batch Process (\(selectedFiles.count))" : "Process Audio"
        }
    }

    private var canRunPrimaryAction: Bool {
        guard !selectedFiles.isEmpty && currentValidation.isValid else { return false }
        if selectedSection == .merge { return selectedFiles.count >= 2 }
        return true
    }

    // MARK: - Actions & Sync

    private func runAction() {
        var effective = config
        syncOperationAndTrim(into: &effective)
        let enqueued = appState.executeAudioToolbox(
            inputs: selectedFiles.map(\.url),
            outputFormat: targetFormat,
            config: effective,
            preserveMetadata: preserveMetadata
        )
        if enqueued {
            statusBanner = "Queued \(selectedFiles.count) job(s) in Jobs Center"
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    if let url = item as? URL {
                        urls.append(url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }
            if !urls.isEmpty {
                await MainActor.run {
                    appState.addFiles(urls: urls)
                }
            }
        }
        return true
    }

    private func syncOperationAndTrim(into cfg: inout AudioToolboxConfig) {
        switch selectedSection {
        case .merge:
            cfg.operation = .merge
        case .trim:
            if !cfg.segments.isEmpty {
                cfg.operation = .extractSegments
            } else if cfg.removeSilence {
                cfg.operation = .removeSilence
            } else {
                cfg.operation = .trim
            }
            let totalDur = primaryInfo?.duration ?? 0
            cfg.trimStartSeconds = trimStart > 0.01 ? trimStart : nil
            cfg.trimEndSeconds = (trimEnd > 0.01 && (totalDur == 0 || trimEnd < totalDur - 0.02)) ? trimEnd : nil
        default:
            cfg.operation = cfg.removeSilence ? .removeSilence : .convert
            let totalDur = primaryInfo?.duration ?? 0
            cfg.trimStartSeconds = trimStart > 0.01 ? trimStart : nil
            cfg.trimEndSeconds = (trimEnd > 0.01 && (totalDur == 0 || trimEnd < totalDur - 0.02)) ? trimEnd : nil
        }
    }

    private func syncCandidateSelection() {
        let validIDs = Set(candidateFiles.map(\.id))
        var updatedSelected = appState.audioToolboxStore.selectedFileIds.intersection(validIDs)
        if updatedSelected.isEmpty, let first = candidateFiles.first {
            updatedSelected.insert(first.id)
        }
        appState.audioToolboxStore.selectedFileIds = updatedSelected

        var updatedMerge = appState.audioToolboxStore.orderedMergeIDs.filter { validIDs.contains($0) }
        for f in candidateFiles where !updatedMerge.contains(f.id) {
            updatedMerge.append(f.id)
        }
        appState.audioToolboxStore.orderedMergeIDs = updatedMerge
        loadPrimaryDetails()
    }

    private func loadPrimaryDetails() {
        primaryDetailsTask?.cancel()

        guard let url = primaryURL, selectedSection != .spotifyCompatibility else {
            primaryInfo = nil
            waveform = nil
            isLoadingWaveform = false
            return
        }

        let needsWaveform = (selectedSection == .trim)
        isLoadingWaveform = needsWaveform
        waveformError = nil
        if !needsWaveform {
            waveform = nil
        }
        silenceIntervals = []

        let activeURL = url
        let section = selectedSection
        primaryDetailsTask = Task {
            do {
                let provider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
                let info = try await provider.probe(url: activeURL)
                if Task.isCancelled { return }

                let wf: AudioWaveformData?
                if needsWaveform {
                    wf = try await AudioAnalysisService.shared.extractWaveform(url: activeURL, bins: 180)
                } else {
                    wf = nil
                }
                if Task.isCancelled { return }

                await MainActor.run {
                    if self.primaryURL == activeURL {
                        self.primaryInfo = info
                        if let wf {
                            self.waveform = wf
                        }
                        let dur = info.duration > 0 ? info.duration : (wf?.duration ?? 0)
                        self.appState.audioToolboxStore.hydrateTrimBoundsIfNeeded(for: activeURL, duration: dur)
                        self.isLoadingWaveform = false
                    }
                }
                if section == .metadata && !Task.isCancelled {
                    await metadataManager.load(url: activeURL)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    if self.primaryURL == activeURL {
                        if needsWaveform {
                            self.waveformError = error.localizedDescription
                        }
                        self.isLoadingWaveform = false
                    }
                }
            }
        }
    }

    private func runSilenceDetection(url: URL) {
        isDetectingSilence = true
        let thresh = config.silenceThresholdDB
        let minDur = config.silenceMinDurationSeconds
        Task {
            do {
                let detected = try await AudioAnalysisService.shared.detectSilence(
                    url: url,
                    noiseThresholdDB: thresh,
                    minDuration: minDur
                )
                await MainActor.run {
                    self.silenceIntervals = detected
                    self.isDetectingSilence = false
                }
            } catch {
                await MainActor.run {
                    self.waveformError = error.localizedDescription
                    self.isDetectingSilence = false
                }
            }
        }
    }

    private func moveMergeItem(at selectedIdx: Int, direction: Int) {
        let currentSelected = selectedFiles
        let destSelected = selectedIdx + direction
        guard destSelected >= 0 && destSelected < currentSelected.count else { return }
        let idA = currentSelected[selectedIdx].id
        let idB = currentSelected[destSelected].id
        if let idxA = appState.audioToolboxStore.orderedMergeIDs.firstIndex(of: idA),
           let idxB = appState.audioToolboxStore.orderedMergeIDs.firstIndex(of: idB) {
            appState.audioToolboxStore.orderedMergeIDs.swapAt(idxA, idxB)
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.addFiles(urls: panel.urls)
        }
    }
}

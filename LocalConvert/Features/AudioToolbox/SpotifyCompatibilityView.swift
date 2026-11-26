import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Spotify Compatibility Workspace View

@MainActor
struct SpotifyCompatibilityView: View {
    @EnvironmentObject var appState: AppState

    @State private var trackURLs: [URL] = []
    @State private var selectedPaths: Set<String> = []
    @State private var activePath: String?
    @State private var reportsByPath: [String: SpotifyAnalysisReportItem] = [:]

    @State private var useCustomOutputDirectory = false
    @State private var customOutputDirectory: URL?
    @State private var resizeOversizedArtwork = false
    @State private var maxArtworkDimension = 1000
    @State private var singleFrontCoverOnly = false

    @State private var isWorking = false
    @State private var progressValue: Double = 0
    @State private var progressMessage = ""
    @State private var activeTask: Task<Void, Never>?

    @State private var statusBanner: (style: AppInfoBanner.BannerStyle, message: String)?
    @State private var isDropTargeted = false
    @FocusState private var focusedTrackPath: String?

    // MARK: - Derived State

    private var reportItemsInOrder: [SpotifyAnalysisReportItem] {
        trackURLs.compactMap { reportsByPath[$0.standardizedFileURL.path] }
    }

    private var activeReport: SpotifyAnalysisReportItem? {
        if let activePath, let report = reportsByPath[activePath] {
            return report
        }
        return reportItemsInOrder.first
    }

    private var targetURLsForAction: [URL] {
        if !selectedPaths.isEmpty {
            return trackURLs.filter { selectedPaths.contains($0.standardizedFileURL.path) }
        }
        return trackURLs
    }

    private var eligibleTargetsForNormalization: [SpotifyAnalysisReportItem] {
        targetURLsForAction
            .compactMap { reportsByPath[$0.standardizedFileURL.path] }
            .filter { $0.classification.isEligibleForNormalization && !$0.drmStatus.blocksModification }
    }

    private var effectiveOutputPolicyDescription: String {
        if useCustomOutputDirectory, let customOutputDirectory {
            return "Output Folder: \(customOutputDirectory.path)"
        }
        return "Output Folder: Same folder as source file (Safe Copy)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if let statusBanner {
                AppInfoBanner(
                    style: statusBanner.style,
                    message: statusBanner.message,
                    onDismiss: { self.statusBanner = nil }
                )
            }

            importAndDropCard

            if !trackURLs.isEmpty {
                summaryAndActionsCard
                optionsCard
                trackListCard
                if let item = activeReport {
                    inspectorCard(for: item)
                }
            }
        }
        .onAppear {
            seedFromAppState(autoAnalyze: false)
        }
        .onChange(of: appState.droppedFiles.map(\.url)) { _, _ in
            seedFromAppState(autoAnalyze: false)
        }
        .onDisappear {
            activeTask?.cancel()
            activeTask = nil
        }
    }

    // MARK: - Import & Drop Card

    @ViewBuilder
    private var importAndDropCard: some View {
        AppCard(title: "Local Audio & Container Inspection", icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inspect MP3, M4A, MP4, M4B, M4P, FLAC, WAV, OGG, and Opus tracks for Spotify Desktop Local Files compatibility.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text("Original source files are never overwritten or modified. DRM-protected and unknown containers remain read-only.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: AppTheme.Spacing.sm)

                    Button(action: openFiles) {
                        Label("Add Files...", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isWorking)
                    .accessibilityLabel("Add local audio files for Spotify compatibility inspection")
                }

                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(isDropTargeted ? AppTheme.Colors.accentTint : AppTheme.Colors.subtleSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(
                                    isDropTargeted ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder,
                                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: [5, 4])
                                )
                        )

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "arrow.down.doc")
                            .font(.subheadline)
                            .foregroundStyle(isDropTargeted ? AppTheme.Colors.accent : .secondary)
                        Text("Drag & drop audio tracks or folders here to inspect Spotify compatibility")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if !trackURLs.isEmpty {
                            Text("\(trackURLs.count) loaded")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm + 2)
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
                .accessibilityLabel("Drop zone for Spotify local files compatibility inspection")
            }
        }
    }

    // MARK: - Summary & Actions Card

    @ViewBuilder
    private var summaryAndActionsCard: some View {
        let reports = reportItemsInOrder
        let officialCount = reports.filter { $0.classification == .officiallyDocumented }.count
        let conditionalCount = reports.filter { $0.classification == .conditional }.count
        let unsupportedCount = reports.filter { $0.classification == .unsupportedFormat }.count
        let drmCount = reports.filter { $0.classification == .drmProtected || $0.classification == .unknownDRM }.count
        let videoCount = reports.filter { $0.classification == .incompatibleVideoContainer }.count
        let fixedCount = reports.filter { $0.normalizationState == .fixedSuccessfully || $0.normalizationState == .alreadyCompatible }.count

        AppCard(title: "Batch Summary & Actions", icon: "checklist") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        AppStatusBadge(text: "Tracks: \(trackURLs.count)", tint: .secondary)
                        if officialCount > 0 {
                            AppStatusBadge(text: "Officially Documented: \(officialCount)", tint: AppTheme.Colors.success)
                        }
                        if conditionalCount > 0 {
                            AppStatusBadge(text: "Conditional: \(conditionalCount)", tint: AppTheme.Colors.warning)
                        }
                        if unsupportedCount > 0 {
                            AppStatusBadge(text: "Unsupported: \(unsupportedCount)", tint: AppTheme.Colors.error)
                        }
                        if drmCount > 0 {
                            AppStatusBadge(text: "DRM / Unknown: \(drmCount)", tint: AppTheme.Colors.error)
                        }
                        if videoCount > 0 {
                            AppStatusBadge(text: "Video Container: \(videoCount)", tint: AppTheme.Colors.error)
                        }
                        if fixedCount > 0 {
                            AppStatusBadge(text: "Verified Ready: \(fixedCount)", tint: AppTheme.Colors.accent)
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        primaryBatchActionControls(reports: reports)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        selectionBatchActionControls
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            primaryBatchActionControls(reports: reports)
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: AppTheme.Spacing.md) {
                            selectionBatchActionControls
                            Spacer(minLength: 0)
                        }
                    }
                }

                if isWorking {
                    AppDivider()
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                        Text(progressMessage)
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Cancel") {
                            activeTask?.cancel()
                            progressMessage = "Cancelling..."
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Batch Action Control Groups

    @ViewBuilder
    private func primaryBatchActionControls(reports: [SpotifyAnalysisReportItem]) -> some View {
        Button(action: runAnalyzeTarget) {
            Label(
                selectedPaths.isEmpty ? "Analyze All" : "Analyze Selected (\(targetURLsForAction.count))",
                systemImage: "magnifyingglass"
            )
            .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isWorking || trackURLs.isEmpty)

        Button(action: runNormalizeEligible) {
            Label(
                selectedPaths.isEmpty
                    ? "Normalize Eligible (\(eligibleTargetsForNormalization.count))"
                    : "Normalize Selected (\(eligibleTargetsForNormalization.count))",
                systemImage: "wand.and.stars"
            )
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isWorking || eligibleTargetsForNormalization.isEmpty)

        Menu {
            Button("Export Markdown Report (.md)...") {
                exportReport(format: .markdown)
            }
            Button("Export JSON Report (.json)...") {
                exportReport(format: .json)
            }
        } label: {
            Label("Export Report", systemImage: "square.and.arrow.up")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(reports.isEmpty)
    }

    @ViewBuilder
    private var selectionBatchActionControls: some View {
        Button("Select All") {
            selectedPaths = Set(trackURLs.map { $0.standardizedFileURL.path })
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isWorking || trackURLs.isEmpty)

        Button("Clear Selection") {
            selectedPaths.removeAll()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isWorking || selectedPaths.isEmpty)

        Button("Remove Selected") {
            removeSelected()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isWorking || selectedPaths.isEmpty)

        Button("Clear All") {
            clearAll()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AppTheme.Colors.error)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isWorking || trackURLs.isEmpty)
    }

    // MARK: - Output & Normalization Options Card

    @ViewBuilder
    private var optionsCard: some View {
        AppCard(title: "Safe Normalization Options", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        outputDirectoryToggleControls
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Text(effectiveOutputPolicyDescription)
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            outputDirectoryToggleControls
                            Spacer(minLength: 0)
                        }
                        Text(effectiveOutputPolicyDescription)
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.lg) {
                        artworkPolicyToggles
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        artworkPolicyToggles
                    }
                }

                Text("MP3 normalization rewrites tags to ID3v2.3 UTF-16 with USLT lyrics and JPEG/PNG Front Cover art while copying compressed MPEG audio frames unchanged and verifying SHA-256 packet identity. M4A/MP4 audio-only normalization preserves raw AAC packets and updates native MP4/iTunes metadata boxes without transcoding.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var outputDirectoryToggleControls: some View {
        Toggle("Write safe copies to custom folder", isOn: $useCustomOutputDirectory)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isWorking)

        if useCustomOutputDirectory {
            Button("Choose Folder...") {
                chooseOutputFolder()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isWorking)
        }
    }

    @ViewBuilder
    private var artworkPolicyToggles: some View {
        Toggle("Resize oversized cover art (> \(String(maxArtworkDimension)) px)", isOn: $resizeOversizedArtwork)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isWorking)

        Toggle("Keep only single Front Cover art", isOn: $singleFrontCoverOnly)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isWorking)
    }

    // MARK: - Track List Card

    @ViewBuilder
    private var trackListCard: some View {
        AppCard(title: "Loaded Tracks", icon: "music.note.list") {
            LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(trackURLs, id: \.standardizedFileURL.path) { url in
                    let path = url.standardizedFileURL.path
                    let report = reportsByPath[path]
                    let isChecked = selectedPaths.contains(path)
                    let isActive = (activeReport?.inputURL.standardizedFileURL.path == path)
                        || (activeReport == nil && activePath == path)

                    trackRow(url: url, path: path, report: report, isChecked: isChecked, isActive: isActive)
                }
            }
        }
    }

    @ViewBuilder
    private func trackRow(
        url: URL,
        path: String,
        report: SpotifyAnalysisReportItem?,
        isChecked: Bool,
        isActive: Bool
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                toggleSelection(path: path)
            } label: {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? AppTheme.Colors.accent : .secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isChecked ? "Deselect \(url.lastPathComponent)" : "Select \(url.lastPathComponent)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(url.lastPathComponent)
                        .font(AppTheme.Typography.cardTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let report {
                        AppStatusBadge(
                            text: report.classification.rawValue,
                            tint: badgeColor(for: report.classification),
                            style: .rounded
                        )

                        if let normState = report.normalizationState {
                            AppStatusBadge(
                                text: normState.rawValue,
                                tint: badgeColor(for: normState)
                            )
                        }
                    } else {
                        AppStatusBadge(text: "Not Analyzed", tint: .secondary, style: .rounded)
                    }
                }

                if let report {
                    let codec = report.audioCodec?.uppercased() ?? "NO AUDIO"
                    let rate = report.sampleRate.map { "\($0) Hz" } ?? "-"
                    let art = report.artworkAnalysis.summaryText
                    Text("\(report.containerFormat) · \(codec) · \(rate) · \(report.drmStatus.label) · \(art)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(url.path)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if let outputURL = report?.outputURL {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Reveal normalized copy of \(url.lastPathComponent) in Finder")
            }

            if let outputURL = report?.outputURL {
                Button("Re-analyze Output") {
                    reanalyzeOutput(sourcePath: path, outputURL: outputURL)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs + 2)
        .background(isActive ? AppTheme.Colors.accentTint : AppTheme.Colors.subtleSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(
                    (isActive || focusedTrackPath == path) ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder,
                    lineWidth: (focusedTrackPath == path && !isActive) ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .focusable(true)
        .focused($focusedTrackPath, equals: path)
        .onKeyPress(.space) {
            toggleSelection(path: path)
            return .handled
        }
        .onKeyPress(.return) {
            activePath = path
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveTrackFocus(from: path, delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveTrackFocus(from: path, delta: 1)
            return .handled
        }
        .onTapGesture {
            activePath = path
            focusedTrackPath = path
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(trackAccessibilityLabel(url: url, report: report, isChecked: isChecked, isActive: isActive))
        .accessibilityValue(report?.classification.rawValue ?? "Not Analyzed")
        .accessibilityHint("Press Return to inspect track details, or Space to toggle batch selection.")
    }

    // MARK: - Detailed Inspector Card

    @ViewBuilder
    private func inspectorCard(for item: SpotifyAnalysisReportItem) -> some View {
        AppCard(title: "Inspector — \(item.inputURL.lastPathComponent)", icon: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                // Header status & summary reason
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    if let thumbData = item.artworkAnalysis.primaryValidThumbnailData,
                       let image = NSImage(data: thumbData) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                            )
                            .accessibilityLabel("Embedded album cover art thumbnail")
                    } else {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Colors.subtleSurface)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Image(systemName: item.artworkAnalysis.corruptCount > 0 ? "exclamationmark.triangle" : "music.note")
                                    .font(.title2)
                                    .foregroundStyle(item.artworkAnalysis.corruptCount > 0 ? AppTheme.Colors.warning : .secondary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                AppStatusBadge(
                                    text: item.classification.rawValue,
                                    tint: badgeColor(for: item.classification)
                                )
                                AppStatusBadge(
                                    text: item.drmStatus.label,
                                    tint: item.drmStatus.blocksModification ? AppTheme.Colors.error : AppTheme.Colors.success
                                )
                                if let verified = item.audioPayloadVerified {
                                    AppStatusBadge(
                                        text: verified ? "Audio SHA-256 Verified" : "Audio Hash Mismatch",
                                        tint: verified ? AppTheme.Colors.success : AppTheme.Colors.error
                                    )
                                }
                            }
                        }

                        Text(item.compatibilityReason)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let drmNote = item.drmStatus.explanation {
                            Text(drmNote)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                AppDivider()

                // Technical & Metadata Columns
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
                        inspectorTechnicalColumn(item: item)
                            .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
                        inspectorMetadataColumn(item: item)
                            .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        inspectorTechnicalColumn(item: item)
                        AppDivider()
                        inspectorMetadataColumn(item: item)
                    }
                }

                // Artwork entries
                if !item.artworkAnalysis.entries.isEmpty {
                    AppDivider()
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Embedded Cover Art (\(item.artworkAnalysis.summaryText))")
                            .font(AppTheme.Typography.cardTitle)
                        ForEach(item.artworkAnalysis.entries) { art in
                            let dims = (art.pixelWidth != nil && art.pixelHeight != nil)
                                ? "\(art.pixelWidth!)×\(art.pixelHeight!) px"
                                : "unreadable"
                            let mime = art.detectedMime ?? art.declaredMime ?? "unknown"
                            let stateText = art.isValid ? "Valid" : "Invalid (\(art.corruptionReason ?? "corrupt"))"
                            Text("#\(art.index + 1) \(art.pictureTypeName) · \(mime) · \(dims) · \(art.byteCount) bytes · \(stateText)")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(art.isValid ? .secondary : AppTheme.Colors.warning)
                        }
                    }
                }

                // Pre/Post hashes & Output path
                if let outputURL = item.outputURL {
                    AppDivider()
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Normalized Safe Copy")
                            .font(AppTheme.Typography.cardTitle)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text(outputURL.path)
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                        if let pre = item.preAudioHashSHA256, let post = item.postAudioHashSHA256 {
                            Text("Pre SHA-256:  \(pre)")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                            Text("Post SHA-256: \(post)")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(pre == post ? AppTheme.Colors.success : AppTheme.Colors.error)
                        }
                    }
                }

                // Actions, Reasons & Warnings
                let notes = item.metadataSummary.normalizationNeededReasons
                    + item.metadataSummary.unsupportedOrLimitationNotes
                    + item.normalizationActions
                    + item.warnings
                if !notes.isEmpty {
                    AppDivider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Diagnostic & Normalization Notes")
                            .font(AppTheme.Typography.cardTitle)
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, line in
                            Text("• \(line)")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inspectorTechnicalColumn(item: SpotifyAnalysisReportItem) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Technical Profile")
                .font(AppTheme.Typography.cardTitle)
            inspectorKeyValue("Container", item.containerFormat)
            inspectorKeyValue("Audio Codec", item.audioCodec ?? "None")
            if item.hasVideoStream {
                inspectorKeyValue("Video Stream", item.videoCodec ?? "Present")
            }
            inspectorKeyValue("Duration", item.duration > 0 ? AudioWaveformView.formatTime(item.duration) : "Unknown")
            inspectorKeyValue("Sample Rate", item.sampleRate.map { "\($0) Hz" } ?? "Unknown")
            inspectorKeyValue("Channels", item.channels.map { "\($0)" } ?? "Unknown")
            inspectorKeyValue("Bitrate", item.bitRate.map { "\($0 / 1000) kbps" } ?? "Unknown")
        }
    }

    @ViewBuilder
    private func inspectorMetadataColumn(item: SpotifyAnalysisReportItem) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Metadata & Tag Profile")
                .font(AppTheme.Typography.cardTitle)
            inspectorKeyValue("Tag Format", item.metadataSummary.tagFormat)
            if let version = item.metadataSummary.id3Version {
                inspectorKeyValue("ID3 Version", version)
            }
            if let enc = item.metadataSummary.textEncodingSummary {
                inspectorKeyValue("Text Encodings", enc)
            }
            inspectorKeyValue("Title", item.metadataSummary.title ?? "—")
            inspectorKeyValue("Artist", item.metadataSummary.artist ?? "—")
            inspectorKeyValue("Album", item.metadataSummary.album ?? "—")
            inspectorKeyValue("Album Artist", item.metadataSummary.albumArtist ?? "—")
            inspectorKeyValue("Year / Track / Disc", "\(item.metadataSummary.year ?? "—") · \(item.metadataSummary.trackNumber ?? "—") · \(item.metadataSummary.discNumber ?? "—")")
            inspectorKeyValue("Genre / Lyrics", "\(item.metadataSummary.genre ?? "—") · Lyrics: \(item.metadataSummary.hasLyrics ? "Yes" : "No")")
        }
    }

    @ViewBuilder
    private func inspectorKeyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
            Text("\(key):")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private func seedFromAppState(autoAnalyze: Bool) {
        let appURLs = appState.droppedFiles.compactMap { file -> URL? in
            guard let fmt = file.detectedFormat else { return nil }
            guard fmt.category == .audio || fmt.category == .video else { return nil }
            return file.url
        }
        if !appURLs.isEmpty {
            _ = addURLs(appURLs, notifyDuplicates: false)
            if autoAnalyze {
                runAnalyze(urls: trackURLs.filter { reportsByPath[$0.standardizedFileURL.path] == nil })
            }
        }
    }

    @discardableResult
    private func addURLs(_ urls: [URL], notifyDuplicates: Bool) -> [URL] {
        var existingPaths = Set(trackURLs.map { $0.standardizedFileURL.path })
        var added: [URL] = []
        var skippedDuplicates = 0

        for rawURL in urls {
            let expanded = expandURL(rawURL)
            for fileURL in expanded {
                let path = fileURL.standardizedFileURL.path
                if existingPaths.contains(path) {
                    skippedDuplicates += 1
                    continue
                }
                existingPaths.insert(path)
                trackURLs.append(fileURL)
                added.append(fileURL)
            }
        }

        if activePath == nil, let first = trackURLs.first {
            activePath = first.standardizedFileURL.path
        }

        if notifyDuplicates && skippedDuplicates > 0 {
            statusBanner = (
                .info,
                "Added \(added.count) file(s); skipped \(skippedDuplicates) duplicate(s)."
            )
        }
        return added
    }

    private func expandURL(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return []
        }
        guard isDir.boolValue else { return [url] }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var found: [URL] = []
        for case let candidate as URL in enumerator {
            if (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(candidate)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select audio or container files to inspect for Spotify compatibility"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }

        let added = addURLs(panel.urls, notifyDuplicates: true)
        if !added.isEmpty {
            runAnalyze(urls: added)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Output Folder"
        if panel.runModal() == .OK, let folder = panel.url {
            customOutputDirectory = folder
            useCustomOutputDirectory = true
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var dropped: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    if let url = item as? URL {
                        dropped.append(url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        dropped.append(url)
                    }
                }
            }
            if !dropped.isEmpty {
                let added = addURLs(dropped, notifyDuplicates: true)
                if !added.isEmpty {
                    runAnalyze(urls: added)
                }
            }
        }
        return true
    }

    private func runAnalyzeTarget() {
        runAnalyze(urls: targetURLsForAction)
    }

    private func runAnalyze(urls: [URL]) {
        guard !urls.isEmpty, !isWorking else { return }
        activeTask?.cancel()
        isWorking = true
        progressValue = 0
        progressMessage = "Analyzing \(urls.count) track(s)..."

        activeTask = Task {
            let service = SpotifyCompatibilityService.shared
            let results = await service.analyzeBatch(urls: urls, maxConcurrent: 4) { progress, msg in
                Task { @MainActor in
                    self.progressValue = progress
                    self.progressMessage = msg
                }
            }

            await MainActor.run {
                for item in results {
                    self.reportsByPath[item.inputURL.standardizedFileURL.path] = item
                }
                if self.activePath == nil, let first = results.first {
                    self.activePath = first.inputURL.standardizedFileURL.path
                }
                self.isWorking = false
                self.progressValue = 1.0
                let msg = "Analyzed \(results.count) track(s)."
                self.statusBanner = (.success, msg)
                self.announceAccessibility(msg)
            }
        }
    }

    private func runNormalizeEligible() {
        let candidates = eligibleTargetsForNormalization
        guard !candidates.isEmpty, !isWorking else { return }

        let customDir = useCustomOutputDirectory ? customOutputDirectory : nil
        let handling = AppSettings.shared.existingFileHandling
        let resize = resizeOversizedArtwork
        let maxDim = maxArtworkDimension
        let singleCover = singleFrontCoverOnly

        activeTask?.cancel()
        isWorking = true
        progressValue = 0
        progressMessage = "Normalizing \(candidates.count) compatible track(s)..."

        activeTask = Task {
            let service = SpotifyCompatibilityService.shared
            var updatedItems: [SpotifyAnalysisReportItem] = []

            for (index, item) in candidates.enumerated() {
                if Task.isCancelled { break }
                let resolvedDir = customDir ?? item.inputURL.deletingLastPathComponent()
                let opts = SpotifyNormalizationOptions(
                    outputDirectory: resolvedDir,
                    existingFileHandling: handling == .overwrite ? .createUnique : handling,
                    resizeOversizedArtwork: resize,
                    maxArtworkDimension: maxDim,
                    singleFrontCoverOnly: singleCover
                )
                let updated = await service.normalizeFile(item: item, options: opts)
                updatedItems.append(updated)

                let fraction = Double(index + 1) / Double(candidates.count)
                await MainActor.run {
                    self.reportsByPath[updated.inputURL.standardizedFileURL.path] = updated
                    self.progressValue = fraction
                    self.progressMessage = "Processed \(index + 1) of \(candidates.count)..."
                }
            }

            await MainActor.run {
                let createdOutputs = updatedItems
                    .filter { $0.normalizationState == .fixedSuccessfully }
                    .compactMap(\.outputURL)
                if !createdOutputs.isEmpty {
                    let cmd = OutputCreationUndoCommand(
                        title: "Normalize \(createdOutputs.count) Track(s) for Spotify",
                        context: .audioToolbox,
                        outputURLs: createdOutputs,
                        protectedSourceURLs: candidates.map(\.inputURL)
                    )
                    Task { await UndoRedoCoordinator.shared.record(cmd) }
                }

                let fixedCount = updatedItems.filter { $0.normalizationState == .fixedSuccessfully }.count
                let readyCount = updatedItems.filter { $0.normalizationState == .alreadyCompatible }.count
                let failedCount = updatedItems.filter {
                    $0.normalizationState == .failedValidation || $0.normalizationState == .processingError
                }.count
                self.isWorking = false
                self.progressValue = 1.0
                if failedCount > 0 {
                    let msg = "Completed normalization: \(fixedCount) fixed copy(ies), \(readyCount) already compatible, \(failedCount) failed validation."
                    self.statusBanner = (.warning, msg)
                    self.announceAccessibility(msg)
                } else {
                    let msg = "Normalization complete: \(fixedCount) fixed copy(ies) created, \(readyCount) already compatible. Originals left untouched."
                    self.statusBanner = (.success, msg)
                    self.announceAccessibility(msg)
                }
            }
        }
    }

    private func reanalyzeOutput(sourcePath: String, outputURL: URL) {
        guard !isWorking else { return }
        isWorking = true
        progressValue = 0.2
        progressMessage = "Re-analyzing output copy..."

        activeTask = Task {
            let reanalyzed = await SpotifyCompatibilityService.shared.analyzeFile(url: outputURL)
            await MainActor.run {
                if var existing = self.reportsByPath[sourcePath] {
                    existing.warnings.append(
                        "Post-write check on \(outputURL.lastPathComponent): \(reanalyzed.classification.rawValue) (\(reanalyzed.metadataSummary.tagFormat), \(reanalyzed.artworkAnalysis.summaryText))."
                    )
                    self.reportsByPath[sourcePath] = existing
                }
                self.isWorking = false
                self.progressValue = 1.0
                self.statusBanner = (
                    .info,
                    "Verified output copy: \(reanalyzed.classification.rawValue) · \(reanalyzed.metadataSummary.tagFormat)."
                )
            }
        }
    }

    private enum ExportFormat {
        case markdown
        case json
    }

    private func exportReport(format: ExportFormat) {
        let items = reportItemsInOrder
        guard !items.isEmpty else { return }

        let panel = NSSavePanel()
        switch format {
        case .markdown:
            panel.allowedContentTypes = [UTType.plainText]
            panel.nameFieldStringValue = "spotify-compatibility-report.md"
        case .json:
            panel.allowedContentTypes = [UTType.json]
            panel.nameFieldStringValue = "spotify-compatibility-report.json"
        }

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            switch format {
            case .markdown:
                let md = SpotifyCompatibilityService.exportReportMarkdown(items: items, includeLyricsNotice: true)
                try md.write(to: dest, atomically: true, encoding: .utf8)
            case .json:
                let data = try SpotifyCompatibilityService.exportReportJSON(items: items)
                try data.write(to: dest, options: .atomic)
            }
            statusBanner = (.success, "Exported report to \(dest.lastPathComponent)")
        } catch {
            statusBanner = (.error, "Failed to export report: \(error.localizedDescription)")
        }
    }

    private func toggleSelection(path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    private func moveTrackFocus(from currentPath: String, delta: Int) {
        let paths = trackURLs.map { $0.standardizedFileURL.path }
        guard let idx = paths.firstIndex(of: currentPath) else { return }
        let nextIdx = max(0, min(paths.count - 1, idx + delta))
        let nextPath = paths[nextIdx]
        focusedTrackPath = nextPath
        activePath = nextPath
    }

    private func trackAccessibilityLabel(
        url: URL,
        report: SpotifyAnalysisReportItem?,
        isChecked: Bool,
        isActive: Bool
    ) -> String {
        var parts = [url.lastPathComponent]
        parts.append(isChecked ? "selected" : "unselected")
        if isActive { parts.append("active in inspector") }
        if let report {
            parts.append(report.classification.rawValue)
            if let norm = report.normalizationState {
                parts.append(norm.rawValue)
            }
            parts.append(report.artworkAnalysis.summaryText)
        }
        return parts.joined(separator: ", ")
    }

    private func announceAccessibility(_ message: String) {
        AccessibilityAnnouncer.announce(message, priority: .medium)
    }

    private func removeSelected() {
        trackURLs.removeAll { selectedPaths.contains($0.standardizedFileURL.path) }
        for path in selectedPaths {
            reportsByPath.removeValue(forKey: path)
            if activePath == path { activePath = nil }
        }
        selectedPaths.removeAll()
        if activePath == nil {
            activePath = trackURLs.first?.standardizedFileURL.path
        }
    }

    private func clearAll() {
        activeTask?.cancel()
        trackURLs.removeAll()
        selectedPaths.removeAll()
        reportsByPath.removeAll()
        activePath = nil
        statusBanner = nil
    }

    private func badgeColor(for classification: SpotifyCompatibilityClassification) -> Color {
        switch classification {
        case .officiallyDocumented: return AppTheme.Colors.success
        case .conditional: return AppTheme.Colors.warning
        case .unsupportedFormat, .drmProtected, .unknownDRM, .incompatibleVideoContainer:
            return AppTheme.Colors.error
        }
    }

    private func badgeColor(for state: SpotifyNormalizationResultState) -> Color {
        switch state {
        case .alreadyCompatible, .fixedSuccessfully: return AppTheme.Colors.success
        case .conditionalCompatibility: return AppTheme.Colors.warning
        case .unsupportedFormat, .drmProtected, .failedValidation, .processingError:
            return AppTheme.Colors.error
        }
    }
}

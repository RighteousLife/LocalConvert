import SwiftUI
import AppKit
@preconcurrency import AVFoundation
@preconcurrency import AVKit

// MARK: - Video Trim Player Controller

@MainActor
final class VideoTrimPlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var fallbackImage: NSImage?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isLoadingFrame: Bool = false
    @Published var currentTimeSeconds: Double = 0
    @Published private(set) var usesNativePlayer: Bool = false

    private var activeURL: URL?
    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    private var playbackStopTimeSeconds: Double?
    private var frameFetchTask: Task<Void, Never>?
    private var frameFetchGeneration: Int = 0

    func configure(for url: URL, initialTimeSeconds: Double = 0) {
        cleanup()
        activeURL = url
        currentTimeSeconds = max(0, initialTimeSeconds)

        if VideoPreviewService.supportsNativeAVPlayer(url: url) {
            usesNativePlayer = true
            let item = AVPlayerItem(url: url)
            let avPlayer = AVPlayer(playerItem: item)
            avPlayer.actionAtItemEnd = .pause
            self.player = avPlayer

            let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
            timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
                let sec = CMTimeGetSeconds(cmTime)
                Task { @MainActor [weak self] in
                    guard let self, sec.isFinite else { return }
                    self.currentTimeSeconds = max(0, sec)
                    if let stopAt = self.playbackStopTimeSeconds, sec >= stopAt {
                        self.pause()
                        self.seek(to: stopAt)
                    }
                }
            }

            endObserverToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isPlaying = false
                    self?.playbackStopTimeSeconds = nil
                }
            }

            if initialTimeSeconds > 0 {
                seek(to: initialTimeSeconds)
            }
        } else {
            usesNativePlayer = false
            self.player = nil
            fetchFallbackFrame(at: initialTimeSeconds)
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        currentTimeSeconds = clamped
        if let player {
            let cm = CMTime(seconds: clamped, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            fetchFallbackFrame(at: clamped)
        }
    }

    func togglePlay(rangeStart: Double, rangeEnd: Double) {
        if isPlaying {
            pause()
        } else {
            play(from: currentTimeSeconds < rangeStart || currentTimeSeconds >= rangeEnd ? rangeStart : currentTimeSeconds, stopAt: rangeEnd)
        }
    }

    func playSelection(start: Double, end: Double) {
        guard end > start else { return }
        play(from: start, stopAt: end)
    }

    func play(from startSeconds: Double, stopAt: Double?) {
        guard let player else {
            isPlaying = false
            return
        }
        playbackStopTimeSeconds = stopAt
        let cm = CMTime(seconds: max(0, startSeconds), preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTimeSeconds = max(0, startSeconds)
                self.player?.play()
                self.isPlaying = true
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        playbackStopTimeSeconds = nil
    }

    func cleanup() {
        frameFetchTask?.cancel()
        frameFetchTask = nil
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        if let endObs = endObserverToken {
            NotificationCenter.default.removeObserver(endObs)
        }
        endObserverToken = nil
        player?.pause()
        player = nil
        isPlaying = false
        playbackStopTimeSeconds = nil
    }

    private func fetchFallbackFrame(at seconds: Double) {
        guard let url = activeURL else { return }
        frameFetchTask?.cancel()
        frameFetchGeneration += 1
        let gen = frameFetchGeneration
        isLoadingFrame = true

        frameFetchTask = Task {
            let cgImage = try? await VideoPreviewService.extractFrame(url: url, atSeconds: seconds, maxWidth: 640)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.frameFetchGeneration == gen else { return }
                self.isLoadingFrame = false
                if let cgImage {
                    self.fallbackImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                }
            }
        }
    }
}

// MARK: - AppKit AVPlayerView Surface

private struct VideoPlayerSurfaceView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - Interactive Video Trim Sheet

struct VideoTrimSheetView: View {
    let file: DroppedFile
    let onApply: (VideoTrimRange?, FileFormat?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playerController = VideoTrimPlayerController()

    @State private var mediaInfo: MediaInfo?
    @State private var probeError: String?
    @State private var isProbing = true

    @State private var thumbnails: [VideoPreviewThumbnail] = []
    @State private var isLoadingThumbnails = false

    @State private var startMs: Int64 = 0
    @State private var endMs: Int64 = 1_000
    @State private var startText: String = "00:00.00"
    @State private var endText: String = "00:01.00"
    @State private var startTextError: String?
    @State private var endTextError: String?

    @State private var trimMode: VideoTrimMode
    @State private var selectedTargetFormat: FileFormat?

    @State private var loadTask: Task<Void, Never>?

    init(
        file: DroppedFile,
        onApply: @escaping (VideoTrimRange?, FileFormat?) -> Void
    ) {
        self.file = file
        self.onApply = onApply
        let existingTrim = file.options.videoTrim
        _trimMode = State(initialValue: existingTrim?.mode ?? .frameAccurate)
        _selectedTargetFormat = State(initialValue: file.selectedOutputFormat)
        if let existingTrim {
            _startMs = State(initialValue: existingTrim.startMilliseconds)
            _endMs = State(initialValue: existingTrim.endMilliseconds)
            _startText = State(initialValue: VideoTrimTimestamp.formatDisplay(milliseconds: existingTrim.startMilliseconds))
            _endText = State(initialValue: VideoTrimTimestamp.formatDisplay(milliseconds: existingTrim.endMilliseconds))
        }
    }

    private var sourceDurationMs: Int64 {
        let dur = mediaInfo?.duration ?? 0
        guard dur.isFinite, dur > 0 else { return max(endMs, 1_000) }
        return max(100, Int64((dur * 1000.0).rounded()))
    }

    private var frameDurationMs: Int64 {
        if let fps = mediaInfo?.primaryVideoStream?.frameRate, fps > 1, fps <= 240 {
            return max(8, Int64((1000.0 / fps).rounded()))
        }
        return 33 // ~30fps default step
    }

    private var currentRange: VideoTrimRange {
        VideoTrimRange(startMilliseconds: startMs, endMilliseconds: endMs, mode: trimMode)
    }

    private var validationResult: VideoTrimValidationResult {
        if let startTextError {
            return VideoTrimValidationResult(
                isValid: false,
                errorMessage: startTextError,
                warningMessage: nil,
                isStreamCopyCompatible: false
            )
        }
        if let endTextError {
            return VideoTrimValidationResult(
                isValid: false,
                errorMessage: endTextError,
                warningMessage: nil,
                isStreamCopyCompatible: false
            )
        }
        return VideoTrimValidator.validate(
            range: currentRange,
            sourceDurationSeconds: mediaInfo?.duration,
            inputInfo: mediaInfo,
            outputFormat: selectedTargetFormat
        )
    }

    private var groupedTargetFormats: [(group: FormatGroup, formats: [FileFormat])] {
        let grouped = Dictionary(grouping: file.trimEligibleOutputFormats, by: { $0.group })
        return grouped
            .map { (group: $0.key, formats: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.group.sortOrder < $1.group.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().overlay(AppTheme.Colors.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    previewPlayerCard
                    timelineCard
                    rangeAndModeCard
                    disclosureBanners
                }
                .padding(AppTheme.Spacing.xl)
            }

            Divider().overlay(AppTheme.Colors.divider)
            footerBar
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 620, idealHeight: 690)
        .background(AppTheme.Colors.workspaceBackground)
        .task {
            await loadMediaAndThumbnails()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            playerController.cleanup()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Trim Video")
                    .font(AppTheme.Typography.sectionTitle)
                Text(file.fileName)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let info = mediaInfo {
                let dims: String = {
                    if let w = info.primaryVideoStream?.width, let h = info.primaryVideoStream?.height {
                        return "\(w)×\(h) · "
                    }
                    return ""
                }()
                let codec = info.primaryVideoStream?.codecName.uppercased() ?? "VIDEO"
                AppStatusBadge(
                    text: "\(codec) · \(dims)Duration \(VideoTrimTimestamp.formatDisplay(seconds: info.duration))",
                    tint: .secondary,
                    style: .rounded
                )
            } else if isProbing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Inspecting streams...")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Preview Player

    private var previewPlayerCard: some View {
        AppCard(title: "Video Preview", icon: "film") {
            VStack(spacing: AppTheme.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.black)

                    if let player = playerController.player, playerController.usesNativePlayer {
                        VideoPlayerSurfaceView(player: player)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    } else if let nsImage = playerController.fallbackImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    } else if let firstThumb = thumbnails.first {
                        Image(nsImage: NSImage(cgImage: firstThumb.cgImage, size: NSSize(width: firstThumb.cgImage.width, height: firstThumb.cgImage.height)))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "film")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.6))
                            Text(isProbing ? "Loading preview..." : "Preview unavailable")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }

                    if playerController.isLoadingFrame {
                        VStack {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(8)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(height: 220)
                .accessibilityLabel("Video preview surface")

                HStack(spacing: AppTheme.Spacing.sm) {
                    if playerController.usesNativePlayer {
                        Button {
                            playerController.togglePlay(
                                rangeStart: Double(startMs) / 1000.0,
                                rangeEnd: endMs > startMs ? Double(endMs) / 1000.0 : sourceDurationSeconds
                            )
                        } label: {
                            Label(playerController.isPlaying ? "Pause" : "Play Selection", systemImage: playerController.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.space, modifiers: [])
                        .accessibilityLabel(playerController.isPlaying ? "Pause preview" : "Play selected range")
                    } else {
                        Button {
                            playerController.seek(to: Double(startMs) / 1000.0)
                        } label: {
                            Label("Preview In", systemImage: "backward.end.fill")
                        }
                        .controlSize(.small)

                        Button {
                            playerController.seek(to: Double(endMs) / 1000.0)
                        } label: {
                            Label("Preview Out", systemImage: "forward.end.fill")
                        }
                        .controlSize(.small)
                    }

                    Button {
                        setStartMilliseconds(Int64((playerController.currentTimeSeconds * 1000.0).rounded()))
                    } label: {
                        Label("Set In (I)", systemImage: "arrow.right.to.line")
                    }
                    .controlSize(.small)
                    .keyboardShortcut("i", modifiers: [])
                    .help("Set trim start to current playhead position")

                    Button {
                        setEndMilliseconds(Int64((playerController.currentTimeSeconds * 1000.0).rounded()))
                    } label: {
                        Label("Set Out (O)", systemImage: "arrow.left.to.line")
                    }
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: [])
                    .help("Set trim end to current playhead position")

                    Spacer()

                    Text("Playhead: \(VideoTrimTimestamp.formatDisplay(seconds: playerController.currentTimeSeconds))")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Playhead position \(VideoTrimTimestamp.formatDisplay(seconds: playerController.currentTimeSeconds))")
                }
            }
        }
    }

    private var sourceDurationSeconds: Double {
        Double(sourceDurationMs) / 1000.0
    }

    // MARK: - Interactive Filmstrip Timeline

    private var timelineCard: some View {
        AppCard(title: "Timeline & Trim Handles", icon: "scissors") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                GeometryReader { geo in
                    let width = max(120, geo.size.width)
                    let durMs = max(100, sourceDurationMs)
                    let startFrac = min(max(Double(startMs) / Double(durMs), 0), 1)
                    let endFrac = min(max(Double(endMs) / Double(durMs), 0), 1)
                    let playFrac = min(max(playerController.currentTimeSeconds / (Double(durMs) / 1000.0), 0), 1)
                    let startX = startFrac * width
                    let endX = max(startX + 4, endFrac * width)
                    let playX = playFrac * width

                    ZStack(alignment: .leading) {
                        // Thumbnail strip background
                        HStack(spacing: 0) {
                            if thumbnails.isEmpty {
                                Rectangle()
                                    .fill(AppTheme.Colors.subtleSurface)
                                    .overlay {
                                        if isLoadingThumbnails {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                            } else {
                                ForEach(thumbnails) { thumb in
                                    Image(nsImage: NSImage(
                                        cgImage: thumb.cgImage,
                                        size: NSSize(width: thumb.cgImage.width, height: thumb.cgImage.height)
                                    ))
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .clipped()
                                }
                            }
                        }
                        .frame(width: width, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    let clampedX = min(max(val.location.x, 0), width)
                                    let targetSec = (clampedX / width) * (Double(durMs) / 1000.0)
                                    playerController.pause()
                                    playerController.seek(to: targetSec)
                                }
                        )

                        // Dimmed outside regions
                        Rectangle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: max(0, startX), height: 56)
                            .allowsHitTesting(false)

                        Rectangle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: max(0, width - endX), height: 56)
                            .offset(x: endX)
                            .allowsHitTesting(false)

                        // Selected window border
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(AppTheme.Colors.accent, lineWidth: 2)
                            .frame(width: max(4, endX - startX), height: 56)
                            .offset(x: startX)
                            .allowsHitTesting(false)

                        // Playhead vertical line
                        Rectangle()
                            .fill(AppTheme.Colors.error)
                            .frame(width: 2, height: 64)
                            .offset(x: min(max(0, playX - 1), width - 2))
                            .allowsHitTesting(false)

                        // Start handle
                        trimHandleView(isStart: true)
                            .offset(x: max(0, min(startX - 7, width - 14)))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { val in
                                        let clampedX = min(max(val.location.x, 0), width)
                                        let rawMs = Int64(((clampedX / width) * Double(durMs)).rounded())
                                        let bounded = min(rawMs, endMs - VideoTrimValidator.minimumTrimDurationMilliseconds)
                                        playerController.pause()
                                        setStartMilliseconds(max(0, bounded))
                                        playerController.seek(to: Double(startMs) / 1000.0)
                                    }
                            )
                            .accessibilityLabel("Trim start handle")
                            .accessibilityValue(VideoTrimTimestamp.formatDisplay(milliseconds: startMs))

                        // End handle
                        trimHandleView(isStart: false)
                            .offset(x: max(0, min(endX - 7, width - 14)))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { val in
                                        let clampedX = min(max(val.location.x, 0), width)
                                        let rawMs = Int64(((clampedX / width) * Double(durMs)).rounded())
                                        let bounded = max(rawMs, startMs + VideoTrimValidator.minimumTrimDurationMilliseconds)
                                        playerController.pause()
                                        setEndMilliseconds(min(durMs, bounded))
                                        playerController.seek(to: Double(endMs) / 1000.0)
                                    }
                            )
                            .accessibilityLabel("Trim end handle")
                            .accessibilityValue(VideoTrimTimestamp.formatDisplay(milliseconds: endMs))
                    }
                }
                .frame(height: 64)

                // Nudge & Summary Strip
                HStack(spacing: AppTheme.Spacing.md) {
                    nudgeGroup(label: "In:", currentMs: startMs) { delta in
                        let next = min(max(0, startMs + delta), endMs - VideoTrimValidator.minimumTrimDurationMilliseconds)
                        setStartMilliseconds(next)
                        playerController.seek(to: Double(startMs) / 1000.0)
                    }

                    Divider().frame(height: 16)

                    nudgeGroup(label: "Out:", currentMs: endMs) { delta in
                        let next = max(min(sourceDurationMs, endMs + delta), startMs + VideoTrimValidator.minimumTrimDurationMilliseconds)
                        setEndMilliseconds(next)
                        playerController.seek(to: Double(endMs) / 1000.0)
                    }

                    Spacer()

                    Button("Full Range") {
                        setStartMilliseconds(0)
                        setEndMilliseconds(sourceDurationMs)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func trimHandleView(isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(AppTheme.Colors.accent)
            .frame(width: 14, height: 60)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 22)
            )
            .help(isStart ? "Drag trim start handle" : "Drag trim end handle")
    }

    @ViewBuilder
    private func nudgeGroup(label: String, currentMs: Int64, onDelta: @escaping (Int64) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Button("-1s") { onDelta(-1000) }
                .controlSize(.mini)
            Button("-1f") { onDelta(-frameDurationMs) }
                .controlSize(.mini)
            Button("+1f") { onDelta(frameDurationMs) }
                .controlSize(.mini)
            Button("+1s") { onDelta(1000) }
                .controlSize(.mini)
        }
    }

    // MARK: - Range Inputs & Trim Mode

    private var rangeAndModeCard: some View {
        AppCard(title: "Range, Mode & Output Container", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack(spacing: AppTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start Time (MM:SS.mm or sec)")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        TextField("00:00.00", text: $startText)
                            .textFieldStyle(.roundedBorder)
                            .font(AppTheme.Typography.monoCaption)
                            .frame(width: 150)
                            .onChange(of: startText) { _, newValue in
                                parseStartInput(newValue)
                            }
                            .accessibilityLabel("Trim start time")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("End Time (MM:SS.mm or sec)")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        TextField("00:05.00", text: $endText)
                            .textFieldStyle(.roundedBorder)
                            .font(AppTheme.Typography.monoCaption)
                            .frame(width: 150)
                            .onChange(of: endText) { _, newValue in
                                parseEndInput(newValue)
                            }
                            .accessibilityLabel("Trim end time")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected Duration")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(VideoTrimTimestamp.formatDisplay(milliseconds: currentRange.durationMilliseconds))
                            .font(AppTheme.Typography.sectionTitle.monospacedDigit())
                            .foregroundStyle(validationResult.isValid ? AppTheme.Colors.accent : AppTheme.Colors.error)
                            .accessibilityLabel("Selected trim duration \(VideoTrimTimestamp.formatDisplay(milliseconds: currentRange.durationMilliseconds))")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Original Duration")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(VideoTrimTimestamp.formatDisplay(milliseconds: sourceDurationMs))
                            .font(AppTheme.Typography.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Divider().overlay(AppTheme.Colors.divider)

                HStack(spacing: AppTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trimming Mode")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Picker("Trimming Mode", selection: $trimMode) {
                            ForEach(VideoTrimMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 380)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Format")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Picker("Target Format", selection: $selectedTargetFormat) {
                            ForEach(groupedTargetFormats, id: \.group) { section in
                                Section(header: Text(section.group.rawValue)) {
                                    ForEach(section.formats) { fmt in
                                        let label = fmt == file.detectedFormat
                                            ? "\(fmt.shortExtensionLabel) (Same as Source)"
                                            : fmt.shortExtensionLabel
                                        Text(label).tag(Optional(fmt))
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                        .accessibilityLabel("Target output format for trimmed video")
                    }
                }

                Text(trimMode.explanation)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Disclosure & Validation Banners

    @ViewBuilder
    private var disclosureBanners: some View {
        if let probeError {
            AppInfoBanner(style: .error, message: probeError)
        } else if let error = validationResult.errorMessage {
            AppInfoBanner(style: .error, message: error)
        } else if let warning = validationResult.warningMessage {
            AppInfoBanner(style: .warning, message: warning)
        }

        if !playerController.usesNativePlayer && !isProbing && probeError == nil {
            AppInfoBanner(
                style: .info,
                message: "Showing decoded keyframe/scrub preview frames for .\(file.url.pathExtension.lowercased()) via FFmpeg. Output export supports both Stream Copy and Frame-Accurate modes where container codecs permit."
            )
        }

        if let outFmt = selectedTargetFormat, outFmt == file.detectedFormat {
            AppInfoBanner(
                style: .info,
                message: "Trimmed output will be saved non-destructively with the `_trimmed` suffix next to or in your configured output folder. The source file is never overwritten."
            )
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Button("Clear Trim", role: .destructive) {
                onApply(nil, selectedTargetFormat)
                dismiss()
            }
            .disabled(file.options.videoTrim == nil)

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("videotrim.cancelButton")

            Button("Apply Trim") {
                guard validationResult.isValid else { return }
                onApply(currentRange, selectedTargetFormat)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!validationResult.isValid || isProbing || probeError != nil)
            .accessibilityIdentifier("videotrim.applyButton")
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Helpers & Async Load

    private func setStartMilliseconds(_ value: Int64) {
        let clamped = max(0, min(value, sourceDurationMs))
        startMs = clamped
        startTextError = nil
        startText = VideoTrimTimestamp.formatDisplay(milliseconds: clamped)
    }

    private func setEndMilliseconds(_ value: Int64) {
        let clamped = max(0, min(value, sourceDurationMs))
        endMs = clamped
        endTextError = nil
        endText = VideoTrimTimestamp.formatDisplay(milliseconds: clamped)
    }

    private func parseStartInput(_ text: String) {
        guard let parsed = VideoTrimTimestamp.parseMilliseconds(text) else {
            startTextError = "Enter a valid start time (SS.mm, MM:SS.mm, or HH:MM:SS.mmm)."
            return
        }
        startTextError = nil
        startMs = parsed
    }

    private func parseEndInput(_ text: String) {
        guard let parsed = VideoTrimTimestamp.parseMilliseconds(text) else {
            endTextError = "Enter a valid end time (SS.mm, MM:SS.mm, or HH:MM:SS.mmm)."
            return
        }
        endTextError = nil
        endMs = parsed
    }

    private func loadMediaAndThumbnails() async {
        isProbing = true
        probeError = nil

        do {
            let provider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
            let info = try await provider.probe(url: file.url)
            guard !Task.isCancelled else { return }

            mediaInfo = info
            isProbing = false

            let durMs = max(100, Int64((info.duration * 1000.0).rounded()))
            if let existing = file.options.videoTrim {
                setStartMilliseconds(min(existing.startMilliseconds, max(0, durMs - 100)))
                setEndMilliseconds(min(max(existing.endMilliseconds, startMs + 100), durMs))
            } else {
                setStartMilliseconds(0)
                setEndMilliseconds(durMs)
            }

            playerController.configure(for: file.url, initialTimeSeconds: Double(startMs) / 1000.0)

            isLoadingThumbnails = true
            let thumbs = (try? await VideoPreviewService.extractFilmstrip(url: file.url, duration: info.duration, count: 10)) ?? []
            guard !Task.isCancelled else { return }
            thumbnails = thumbs
            isLoadingThumbnails = false
        } catch is CancellationError {
            return
        } catch {
            isProbing = false
            isLoadingThumbnails = false
            probeError = error.localizedDescription
        }
    }
}

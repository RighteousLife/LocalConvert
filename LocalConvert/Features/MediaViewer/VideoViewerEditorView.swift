import SwiftUI
import AppKit
@preconcurrency import AVFoundation
@preconcurrency import AVKit
import UniformTypeIdentifiers

// MARK: - Video Viewer Player Controller

@MainActor
final class VideoViewerPlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var fallbackImage: NSImage?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isLoadingFrame: Bool = false
    @Published var currentTimeSeconds: Double = 0
    @Published private(set) var usesNativePlayer: Bool = false
    @Published var exportProgress: Double = 0
    @Published var exportStatusMessage: String = ""

    private var activeURL: URL?
    private var timeObserverToken: Any?
    private var endObserverToken: NSObjectProtocol?
    private var frameFetchTask: Task<Void, Never>?
    private var frameFetchGeneration: Int = 0
    private var playbackRate: Float = 1.0
    private var muted: Bool = false

    func configure(for url: URL, initialTimeSeconds: Double = 0) {
        cleanup()
        activeURL = url
        currentTimeSeconds = max(0, initialTimeSeconds.isFinite ? initialTimeSeconds : 0)

        if VideoPreviewService.supportsNativeAVPlayer(url: url) {
            usesNativePlayer = true
            let item = AVPlayerItem(url: url)
            let avPlayer = AVPlayer(playerItem: item)
            avPlayer.actionAtItemEnd = .pause
            avPlayer.isMuted = muted
            self.player = avPlayer

            let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
            timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
                let sec = CMTimeGetSeconds(cmTime)
                Task { @MainActor [weak self] in
                    guard let self, sec.isFinite else { return }
                    self.currentTimeSeconds = max(0, sec)
                }
            }

            endObserverToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isPlaying = false
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

    func seek(to seconds: Double, maxDuration: Double? = nil) {
        var clamped = max(0, seconds.isFinite ? seconds : 0)
        if let maxDuration, maxDuration.isFinite, maxDuration > 0 {
            clamped = min(clamped, maxDuration)
        }
        currentTimeSeconds = clamped
        if let player {
            let cm = CMTime(seconds: clamped, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            fetchFallbackFrame(at: clamped)
        }
    }

    func step(by deltaSeconds: Double, maxDuration: Double) {
        seek(to: currentTimeSeconds + deltaSeconds, maxDuration: maxDuration)
    }

    func togglePlayPause(duration: Double) {
        if isPlaying {
            pause()
        } else {
            play(duration: duration)
        }
    }

    func play(duration: Double) {
        guard let player else {
            isPlaying = false
            return
        }
        if duration > 0, currentTimeSeconds >= duration - 0.05 {
            seek(to: 0, maxDuration: duration)
        }
        player.isMuted = muted
        player.play()
        player.rate = playbackRate
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func setMuted(_ isMuted: Bool) {
        muted = isMuted
        player?.isMuted = isMuted
    }

    func setSpeed(_ speed: Double) {
        let clamped = Float(QuickVideoCutterEngine.clampedSpeed(speed))
        playbackRate = clamped
        if isPlaying, let player {
            player.rate = clamped
        }
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
    }

    private func fetchFallbackFrame(at seconds: Double) {
        guard let url = activeURL else { return }
        frameFetchTask?.cancel()
        frameFetchGeneration += 1
        let gen = frameFetchGeneration
        isLoadingFrame = true

        frameFetchTask = Task {
            let cgImage = try? await VideoPreviewService.extractFrame(url: url, atSeconds: seconds, maxWidth: 960)
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

private struct VideoViewerPlayerSurface: NSViewRepresentable {
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

// MARK: - Video Viewer & Multi-Segment Cutter

@MainActor
struct VideoViewerEditorView: View {
    let url: URL
    let onSendToConvertQueue: ((URL) -> Void)?
    let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playerController = VideoViewerPlayerController()

    @State private var mediaInfo: MediaInfo?
    @State private var isProbing: Bool = true
    @State private var probeError: String?

    @State private var segments: [VideoSegment] = QuickVideoCutterEngine.initialSegments(durationSeconds: 1.0)
    @State private var selectedSegmentID: UUID?

    @State private var isMuted: Bool = false
    @State private var rotation: QuickVideoRotation = .deg0
    @State private var speedMultiplier: Double = 1.0

    @State private var isExportSheetPresented: Bool = false
    @State private var exportMode: QuickVideoExportMode = .losslessCut
    @State private var isExporting: Bool = false
    @State private var exportTask: Task<Void, Never>?

    @State private var bannerMessage: (style: AppInfoBanner.BannerStyle, text: String, revealURL: URL?)?

    init(
        url: URL,
        onSendToConvertQueue: ((URL) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.url = url
        self.onSendToConvertQueue = onSendToConvertQueue
        self.onDismiss = onDismiss
    }

    private var totalDurationSeconds: Double {
        let dur = mediaInfo?.duration ?? 0
        if dur.isFinite, dur > 0 {
            return dur
        }
        return max(segments.map(\.endSeconds).max() ?? 1.0, QuickVideoCutterEngine.minimumSegmentDuration)
    }

    private var selectedSegment: VideoSegment? {
        if let selectedSegmentID,
           let match = segments.first(where: { $0.id == selectedSegmentID }) {
            return match
        }
        return segments.first(where: {
            playerController.currentTimeSeconds >= $0.startSeconds &&
            playerController.currentTimeSeconds <= $0.endSeconds
        }) ?? segments.first
    }

    private var keptSegmentCount: Int {
        segments.filter(\.isKept).count
    }

    private var totalKeptDuration: Double {
        QuickVideoCutterEngine.totalKeptDurationSeconds(in: segments)
    }

    private var canDeleteOrDisableSelectedSegment: Bool {
        guard let selected = selectedSegment else { return false }
        if !selected.isKept { return true }
        return keptSegmentCount > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            AppDivider()

            VStack(spacing: AppTheme.Spacing.sm) {
                playerSurface
                    .layoutPriority(1)

                if let banner = bannerMessage {
                    AppInfoBanner(
                        style: banner.style,
                        message: banner.text,
                        actionTitle: banner.revealURL != nil ? String(localized: "Reveal") : nil,
                        onAction: banner.revealURL.map { reveal in
                            {
                                NSWorkspace.shared.activateFileViewerSelecting([reveal])
                            }
                        },
                        onDismiss: {
                            bannerMessage = nil
                        }
                    )
                }

                transportToolbar
                timelineSection
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)

            AppDivider()
            footerBar
        }
        .frame(minWidth: 720, minHeight: 490)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.workspaceBackground)
        .accessibilityIdentifier("videoViewer.root")
        .task(id: url) {
            await loadVideo()
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            playerController.cleanup()
        }
        .sheet(isPresented: $isExportSheetPresented) {
            exportSheetView
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Colors.accentTint)
                    .frame(width: 32, height: 32)
                Image(systemName: "film.stack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: AppTheme.Spacing.xs) {
                    if let info = mediaInfo {
                        if let w = info.primaryVideoStream?.width, let h = info.primaryVideoStream?.height {
                            Text("\(w)×\(h)")
                        }
                        if let codec = info.primaryVideoStream?.codecName.uppercased() {
                            Text("· \(codec)")
                        }
                        Text("· \(VideoTrimTimestamp.formatDisplay(seconds: info.duration))")
                    } else if isProbing {
                        Text("Inspecting video...")
                    } else if let probeError {
                        Text(probeError)
                            .foregroundStyle(AppTheme.Colors.error)
                    }
                }
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            if let onSendToConvertQueue {
                Button {
                    onSendToConvertQueue(url)
                } label: {
                    Label("Send to Convert Queue", systemImage: "arrow.uturn.right.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("videoViewer.sendToQueueButton")
            }

            Button {
                closeViewer()
            } label: {
                Text("Close")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("videoViewer.closeButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm + 2)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - Player Surface

    private var playerSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .fill(Color.black)

            if let player = playerController.player, playerController.usesNativePlayer {
                VideoViewerPlayerSurface(player: player)
                    .rotationEffect(.degrees(Double(rotation.rawValue)))
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            } else if let nsImage = playerController.fallbackImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(Double(rotation.rawValue)))
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            } else {
                VStack(spacing: AppTheme.Spacing.xs) {
                    if isProbing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(isProbing ? String(localized: "Loading video...") : String(localized: "Preview unavailable"))
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            if playerController.isLoadingFrame {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding(AppTheme.Spacing.sm)
                    }
                    Spacer()
                }
            }

            if rotation != .deg0 || isMuted || abs(speedMultiplier - 1.0) > 0.01 {
                VStack {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            if rotation != .deg0 {
                                AppStatusBadge(text: String(localized: "Rotate \(rotation.label)"), tint: .white)
                            }
                            if isMuted {
                                AppStatusBadge(text: String(localized: "Muted"), tint: AppTheme.Colors.warning)
                            }
                            if abs(speedMultiplier - 1.0) > 0.01 {
                                AppStatusBadge(text: speedLabel(speedMultiplier), tint: AppTheme.Colors.accent)
                            }
                        }
                        .padding(4)
                        .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    .padding(AppTheme.Spacing.sm)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video preview player")
        .accessibilityIdentifier("videoViewer.playerSurface")
    }

    // MARK: - Transport & Transform Toolbar

    private var transportToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.sm) {
                playbackControlsGroup
                AppDivider().frame(width: 1, height: 18)
                AppHeaderPill(
                    text: "\(VideoTrimTimestamp.formatDisplay(seconds: playerController.currentTimeSeconds)) / \(VideoTrimTimestamp.formatDisplay(seconds: totalDurationSeconds))",
                    systemImage: "clock"
                )
                Spacer(minLength: AppTheme.Spacing.xs)
                transformControlsGroup
                AppDivider().frame(width: 1, height: 18)
                snapshotControlsGroup
            }

            VStack(spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    playbackControlsGroup
                    Spacer()
                    AppHeaderPill(
                        text: "\(VideoTrimTimestamp.formatDisplay(seconds: playerController.currentTimeSeconds)) / \(VideoTrimTimestamp.formatDisplay(seconds: totalDurationSeconds))",
                        systemImage: "clock"
                    )
                }
                HStack(spacing: AppTheme.Spacing.sm) {
                    transformControlsGroup
                    Spacer()
                    snapshotControlsGroup
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm + 2)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private var playbackControlsGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                playerController.step(by: -5.0, maxDuration: totalDurationSeconds)
            } label: {
                Image(systemName: "gobackward.5")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("j", modifiers: [])
            .help("Step back 5 seconds (J)")
            .accessibilityLabel("Step back 5 seconds")
            .accessibilityIdentifier("videoViewer.shuttleBackButton")

            Button {
                playerController.togglePlayPause(duration: totalDurationSeconds)
            } label: {
                Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!playerController.usesNativePlayer)
            .help("Play or Pause (Space)")
            .accessibilityLabel(playerController.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("videoViewer.playPauseButton")

            Button {
                playerController.pause()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("k", modifiers: [])
            .disabled(!playerController.usesNativePlayer)
            .help("Pause playback (K)")
            .accessibilityLabel("Pause playback")
            .accessibilityIdentifier("videoViewer.pauseButton")

            Button {
                playerController.step(by: 5.0, maxDuration: totalDurationSeconds)
            } label: {
                Image(systemName: "goforward.5")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("l", modifiers: [])
            .help("Step forward 5 seconds (L)")
            .accessibilityLabel("Step forward 5 seconds")
            .accessibilityIdentifier("videoViewer.shuttleForwardButton")
        }
    }

    private var transformControlsGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                isMuted.toggle()
                playerController.setMuted(isMuted)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(isMuted ? AppTheme.Colors.warning : .primary)
            }
            .buttonStyle(.bordered)
            .tint(isMuted ? AppTheme.Colors.warning : nil)
            .controlSize(.small)
            .keyboardShortcut("m", modifiers: .command)
            .help(isMuted ? String(localized: "Unmute audio (⌘M)") : String(localized: "Mute audio (⌘M)"))
            .accessibilityLabel(isMuted ? String(localized: "Unmute audio") : String(localized: "Mute audio"))
            .accessibilityIdentifier("videoViewer.muteButton")

            Button {
                rotation = rotation.rotatedClockwise()
            } label: {
                Label(rotation.label, systemImage: "rotate.right")
            }
            .buttonStyle(.bordered)
            .tint(rotation != .deg0 ? AppTheme.Colors.accent : nil)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Rotate 90° clockwise")
            .accessibilityLabel("Rotate 90 degrees, current \(rotation.label)")
            .accessibilityIdentifier("videoViewer.rotateButton")

            Picker("Speed", selection: $speedMultiplier) {
                ForEach(QuickVideoCutterEngine.supportedSpeedMultipliers, id: \.self) { value in
                    Text(speedLabel(value)).tag(value)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 76)
            .onChange(of: speedMultiplier) { _, newValue in
                playerController.setSpeed(newValue)
            }
            .help("Playback and export speed")
            .accessibilityLabel("Playback speed")
            .accessibilityIdentifier("videoViewer.speedPicker")
        }
    }

    private var snapshotControlsGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Menu {
                Button("Save Frame as PNG...") {
                    saveFrameSnapshot(format: .png)
                }
                Button("Save Frame as JPEG...") {
                    saveFrameSnapshot(format: .jpeg)
                }
                Divider()
                Button("Copy Frame to Clipboard") {
                    copyFrameToClipboard()
                }
            } label: {
                Label("Frame", systemImage: "camera")
            }
            .controlSize(.small)
            .help("Save current frame or copy to clipboard")
            .accessibilityIdentifier("videoViewer.snapshotMenu")

            Button {
                copyFrameToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy current frame to clipboard")
            .accessibilityLabel("Copy current frame to clipboard")
            .accessibilityIdentifier("videoViewer.copyFrameButton")
        }
    }

    // MARK: - Multi-Segment Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            GeometryReader { geo in
                let width = max(120, geo.size.width)
                let duration = max(QuickVideoCutterEngine.minimumSegmentDuration, totalDurationSeconds)
                let playRatio = min(max(playerController.currentTimeSeconds / duration, 0), 1)
                let playX = playRatio * width

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Colors.elevatedSurface)
                        .frame(width: width, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                        )

                    ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                        let startFrac = min(max(seg.startSeconds / duration, 0), 1)
                        let endFrac = min(max(seg.endSeconds / duration, 0), 1)
                        let segX = startFrac * width
                        let segW = max(6, (endFrac - startFrac) * width)
                        let isSelected = (seg.id == selectedSegment?.id)

                        segmentBlockView(
                            segment: seg,
                            index: idx,
                            width: segW,
                            isSelected: isSelected
                        )
                        .offset(x: segX)
                        .onTapGesture {
                            selectedSegmentID = seg.id
                            if playerController.currentTimeSeconds < seg.startSeconds ||
                                playerController.currentTimeSeconds > seg.endSeconds {
                                playerController.seek(to: seg.startSeconds, maxDuration: duration)
                            }
                        }
                    }

                    // Playhead indicator with studio scrubber cap
                    VStack(spacing: 0) {
                        Capsule()
                            .fill(AppTheme.Colors.error)
                            .frame(width: 8, height: 5)
                        Rectangle()
                            .fill(AppTheme.Colors.error)
                            .frame(width: 2, height: 42)
                    }
                    .shadow(color: Color.black.opacity(0.28), radius: 2, y: 1)
                    .offset(x: min(max(0, playX - 4), width - 8))
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clampedX = min(max(value.location.x, 0), width)
                            let targetSec = (clampedX / width) * duration
                            playerController.pause()
                            playerController.seek(to: targetSec, maxDuration: duration)
                            if let match = segments.first(where: {
                                targetSec >= $0.startSeconds && targetSec <= $0.endSeconds
                            }) {
                                selectedSegmentID = match.id
                            }
                        }
                )
            }
            .frame(height: 48)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Multi-segment video timeline")
            .accessibilityIdentifier("videoViewer.timelineBar")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    timelineActionButtons
                    Spacer(minLength: AppTheme.Spacing.xs)
                    timelineKeptReadout
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    timelineActionButtons
                    HStack {
                        Spacer(minLength: 0)
                        timelineKeptReadout
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm + 2)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private var timelineActionButtons: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                applySetIn()
            } label: {
                Label("In (I)", systemImage: "arrow.right.to.line")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("i", modifiers: [])
            .help("Set active segment start to playhead (I)")
            .accessibilityIdentifier("videoViewer.setInButton")

            Button {
                applySetOut()
            } label: {
                Label("Out (O)", systemImage: "arrow.left.to.line")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("o", modifiers: [])
            .help("Set active segment end to playhead (O)")
            .accessibilityIdentifier("videoViewer.setOutButton")

            Button {
                applySplitAtPlayhead()
            } label: {
                Label("Split (⌘B)", systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("b", modifiers: .command)
            .help("Split segment at playhead (⌘B)")
            .accessibilityIdentifier("videoViewer.splitButton")

            Button {
                toggleSelectedSegment()
            } label: {
                let isSelectedKept = selectedSegment?.isKept ?? true
                Label(
                    isSelectedKept ? String(localized: "Delete Segment") : String(localized: "Restore Segment"),
                    systemImage: isSelectedKept ? "trash" : "arrow.uturn.backward"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canDeleteOrDisableSelectedSegment)
            .help("Toggle whether selected segment is kept or deleted")
            .accessibilityIdentifier("videoViewer.toggleSegmentButton")

            Button("Reset") {
                segments = QuickVideoCutterEngine.initialSegments(durationSeconds: totalDurationSeconds)
                selectedSegmentID = segments.first?.id
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(segments.count == 1 && segments.first?.isKept == true && segments.first?.startSeconds == 0)
        }
    }

    private var timelineKeptReadout: some View {
        Text("\(keptSegmentCount)/\(segments.count) kept · \(VideoTrimTimestamp.formatDisplay(seconds: totalKeptDuration))")
            .font(AppTheme.Typography.monoCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func segmentBlockView(
        segment: VideoSegment,
        index: Int,
        width: CGFloat,
        isSelected: Bool
    ) -> some View {
        let fillColor: Color = segment.isKept
            ? AppTheme.Colors.accent.opacity(isSelected ? 0.34 : 0.20)
            : AppTheme.Colors.neutralTint.opacity(0.55)
        let borderColor: Color = isSelected
            ? AppTheme.Colors.accent
            : (segment.isKept ? AppTheme.Colors.accent.opacity(0.45) : AppTheme.Colors.cardBorder)

        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                )

            if isSelected && segment.isKept && width >= 18 {
                HStack {
                    Capsule()
                        .fill(AppTheme.Colors.accent)
                        .frame(width: 3, height: 18)
                    Spacer()
                    Capsule()
                        .fill(AppTheme.Colors.accent)
                        .frame(width: 3, height: 18)
                }
                .padding(.horizontal, 3)
            }

            if width >= 46 {
                Text(segment.isKept ? String(localized: "Seg \(index + 1)") : String(localized: "Cut"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(segment.isKept ? Color.primary : Color.secondary)
                    .strikethrough(!segment.isKept)
                    .lineLimit(1)
            }
        }
        .frame(width: max(4, width - 2), height: 34)
        .padding(.horizontal, 1)
        .help("\(VideoTrimTimestamp.formatDisplay(seconds: segment.startSeconds)) → \(VideoTrimTimestamp.formatDisplay(seconds: segment.endSeconds)) (\(segment.isKept ? String(localized: "Kept") : String(localized: "Deleted")))")
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text("Space Play/Pause · J/K/L Shuttle · I/O In/Out · ⌘B Split · ⌘M Mute")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: AppTheme.Spacing.sm)

            Button {
                exportMode = (rotation != .deg0 || abs(speedMultiplier - 1.0) > 0.01)
                    ? .compressedMP4
                    : .losslessCut
                isExportSheetPresented = true
            } label: {
                Label("Export...", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isProbing || probeError != nil || keptSegmentCount == 0)
            .accessibilityIdentifier("videoViewer.exportButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm + 2)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - Export Sheet

    private var exportSheetView: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Export Edited Video")
                    .font(AppTheme.Typography.sectionTitle)
                Spacer()
                AppStatusBadge(
                    text: keptSegmentCount == 1
                        ? String(localized: "1 segment · \(VideoTrimTimestamp.formatDisplay(seconds: totalKeptDuration))")
                        : String(localized: "\(keptSegmentCount) segments · \(VideoTrimTimestamp.formatDisplay(seconds: totalKeptDuration))")
                )
            }

            AppDivider()

            Picker("Export Format", selection: $exportMode) {
                ForEach(QuickVideoExportMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(LocalizedStringKey(exportMode.descriptionText))
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if exportMode == .losslessCut && (rotation != .deg0 || abs(speedMultiplier - 1.0) > 0.01) {
                AppInfoBanner(
                    style: .warning,
                    message: String(localized: "Lossless Cut preserves original encoded packets and does not apply rotation (\(rotation.label)) or speed (\(speedLabel(speedMultiplier))). Switch to Compressed MP4 or Quick GIF to bake transforms.")
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Active Settings")
                    .font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Audio: \(isMuted ? String(localized: "Muted") : String(localized: "Included")) · Rotation: \(rotation.label) · Speed: \(speedLabel(speedMultiplier))")
                    .font(AppTheme.Typography.caption)
            }
            .padding(AppTheme.Spacing.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )

            if isExporting {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ProgressView(value: playerController.exportProgress, total: 1.0)
                    Text(playerController.exportStatusMessage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button(isExporting ? String(localized: "Cancel Export") : String(localized: "Cancel")) {
                    if isExporting {
                        exportTask?.cancel()
                        exportTask = nil
                        isExporting = false
                    } else {
                        isExportSheetPresented = false
                    }
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Choose Destination & Export...") {
                    runExportWithSavePanel()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting || keptSegmentCount == 0)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 480, height: 320)
        .background(AppTheme.Colors.workspaceBackground)
    }

    // MARK: - Actions

    private func loadVideo() async {
        isProbing = true
        probeError = nil
        playerController.configure(for: url)
        playerController.setMuted(isMuted)
        playerController.setSpeed(speedMultiplier)

        do {
            let provider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
            let info = try await provider.probe(url: url)
            guard !Task.isCancelled else { return }
            mediaInfo = info
            let initial = QuickVideoCutterEngine.initialSegments(durationSeconds: info.duration)
            segments = initial
            selectedSegmentID = initial.first?.id
            isProbing = false
        } catch {
            guard !Task.isCancelled else { return }
            // Fallback to AVAsset duration if FFprobe is unavailable
            if VideoPreviewService.supportsNativeAVPlayer(url: url) {
                let asset = AVURLAsset(url: url)
                if let cmDur = try? await asset.load(.duration) {
                    let sec = CMTimeGetSeconds(cmDur)
                    if sec.isFinite, sec > 0 {
                        let initial = QuickVideoCutterEngine.initialSegments(durationSeconds: sec)
                        segments = initial
                        selectedSegmentID = initial.first?.id
                        isProbing = false
                        return
                    }
                }
            }
            probeError = error.localizedDescription
            isProbing = false
        }
    }

    private func applySetIn() {
        let updated = QuickVideoCutterEngine.setInPoint(
            at: playerController.currentTimeSeconds,
            selectedSegmentID: selectedSegmentID,
            in: segments,
            totalDuration: totalDurationSeconds
        )
        segments = updated
    }

    private func applySetOut() {
        let updated = QuickVideoCutterEngine.setOutPoint(
            at: playerController.currentTimeSeconds,
            selectedSegmentID: selectedSegmentID,
            in: segments,
            totalDuration: totalDurationSeconds
        )
        segments = updated
    }

    private func applySplitAtPlayhead() {
        let beforeCount = segments.count
        let updated = QuickVideoCutterEngine.splitSegment(
            at: playerController.currentTimeSeconds,
            in: segments
        )
        segments = updated
        if updated.count > beforeCount,
           let rightSeg = updated.first(where: {
               playerController.currentTimeSeconds >= $0.startSeconds - 1e-4 &&
               playerController.currentTimeSeconds <= $0.endSeconds + 1e-4
           }) {
            selectedSegmentID = rightSeg.id
        }
    }

    private func toggleSelectedSegment() {
        guard let target = selectedSegment else { return }
        let updated = QuickVideoCutterEngine.toggleSegmentKept(id: target.id, in: segments)
        segments = updated
    }

    private func saveFrameSnapshot(format: QuickVideoSnapshotFormat) {
        let defaultURL = QuickVideoCutterEngine.defaultSnapshotURL(for: url, format: format)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.utType]
        panel.directoryURL = defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultURL.lastPathComponent

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let timestamp = playerController.currentTimeSeconds
        let currentRotation = rotation
        let inputURL = url

        Task {
            do {
                let savedURL = try await QuickVideoCutterEngine.exportFrameSnapshot(
                    from: inputURL,
                    atSeconds: timestamp,
                    to: destinationURL,
                    format: format,
                    rotation: currentRotation,
                    existingFileHandling: .overwrite
                )
                bannerMessage = (.success, String(localized: "Saved frame to \(savedURL.lastPathComponent)"), savedURL)
            } catch {
                bannerMessage = (.error, error.localizedDescription, nil)
            }
        }
    }

    private func copyFrameToClipboard() {
        let timestamp = playerController.currentTimeSeconds
        let currentRotation = rotation
        let inputURL = url

        Task {
            do {
                _ = try await QuickVideoCutterEngine.copyFrameToClipboard(
                    from: inputURL,
                    atSeconds: timestamp,
                    rotation: currentRotation
                )
                bannerMessage = (.success, String(localized: "Copied frame at \(VideoTrimTimestamp.formatDisplay(seconds: timestamp)) to clipboard."), nil)
            } catch {
                bannerMessage = (.error, error.localizedDescription, nil)
            }
        }
    }

    private func runExportWithSavePanel() {
        let defaultURL = QuickVideoCutterEngine.defaultExportURL(for: url, mode: exportMode)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = defaultURL.deletingLastPathComponent()
        panel.nameFieldStringValue = defaultURL.lastPathComponent
        switch exportMode {
        case .losslessCut:
            if let fmt = FileFormat.from(extension: defaultURL.pathExtension), let ut = fmt.utType {
                panel.allowedContentTypes = [ut]
            }
        case .compressedMP4:
            panel.allowedContentTypes = [.mpeg4Movie]
        case .quickGIF:
            panel.allowedContentTypes = [.gif]
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        let inputStd = url.standardizedFileURL.resolvingSymlinksInPath().path
        let destStd = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        if inputStd == destStd {
            bannerMessage = (.error, String(localized: "Cannot overwrite the source video file. Choose a different output name."), nil)
            isExportSheetPresented = false
            return
        }

        let request = QuickVideoExportRequest(
            inputURL: url,
            destinationURL: destinationURL,
            segments: segments,
            mode: exportMode,
            isMuted: isMuted,
            rotation: rotation,
            speedMultiplier: speedMultiplier,
            existingFileHandling: .overwrite
        )

        isExporting = true
        playerController.exportProgress = 0.02
        playerController.exportStatusMessage = String(localized: "Preparing export...")

        let controller = playerController
        exportTask?.cancel()
        exportTask = Task {
            do {
                let outputURL = try await QuickVideoCutterEngine.export(request) { [weak controller] prog in
                    Task { @MainActor [weak controller] in
                        if let frac = prog.fractionCompleted {
                            controller?.exportProgress = frac
                        }
                        controller?.exportStatusMessage = prog.statusMessage
                    }
                }
                guard !Task.isCancelled else { return }
                isExporting = false
                isExportSheetPresented = false
                bannerMessage = (.success, String(localized: "Exported \(outputURL.lastPathComponent)"), outputURL)
            } catch is CancellationError {
                isExporting = false
                bannerMessage = (.warning, String(localized: "Export cancelled."), nil)
            } catch {
                isExporting = false
                isExportSheetPresented = false
                bannerMessage = (.error, error.localizedDescription, nil)
            }
        }
    }

    private func closeViewer() {
        playerController.cleanup()
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func speedLabel(_ speed: Double) -> String {
        if abs(speed - 1.0) < 0.01 { return "1x" }
        if abs(speed - 2.0) < 0.01 { return "2x" }
        return String(format: "%.1fx", speed)
    }
}

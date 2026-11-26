import SwiftUI

struct AudioPlayerBarView: View {
    @ObservedObject var coordinator: AudioWorkspaceCoordinator
    @ObservedObject var playback: PlaybackCoordinator

    @State private var isDraggingScrubber = false
    @State private var scrubSeconds: Double = 0
    @State private var localVolume: Double = 1.0
    @State private var showQueuePopover = false
    @State private var showDevicePopover = false

    private var engine: AudioLibraryPlayerEngine { playback.engine }

    private var displayedElapsed: Double {
        isDraggingScrubber ? scrubSeconds : engine.currentSeconds
    }

    private var totalDuration: Double {
        max(0, engine.durationSeconds)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.md) {
                playerTrackInfoBlock
                    .frame(minWidth: 165, maxWidth: 260, alignment: .leading)
                playerTransportBlock
                    .frame(minWidth: 180, maxWidth: .infinity)
                playerRightControlsBlock
            }

            VStack(spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    playerTrackInfoBlock
                        .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    playerRightControlsBlock
                }
                playerTransportBlock
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardBackground)
        .onAppear {
            localVolume = engine.volume
        }
        .onChange(of: localVolume) { _, next in
            if abs(next - engine.volume) > 0.005 {
                playback.setVolume(next)
            }
        }
        .onChange(of: engine.volume) { _, next in
            if abs(localVolume - next) > 0.005 {
                localVolume = next
            }
        }
    }

    @ViewBuilder
    private var playerTrackInfoBlock: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            AudioArtworkThumbnailView(
                cacheKey: playback.currentTrack?.metadata.artworkCacheKey,
                provider: coordinator.artworkProvider,
                size: 42
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(playback.currentTrack?.metadata.title ?? playback.currentTrack?.asset.displayFilename ?? "Not Playing")
                    .font(AppTheme.Typography.cardTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitleText)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(isErrorState ? AppTheme.Colors.error : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("audioworkspace.player.track_info")
    }

    @ViewBuilder
    private var playerTransportBlock: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.md) {
                Button {
                    playback.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(playback.queueManager.queue.isShuffleEnabled ? AppTheme.Colors.accent : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Shuffle")
                .accessibilityLabel("Shuffle")
                .accessibilityValue(playback.queueManager.queue.isShuffleEnabled ? "On" : "Off")
                .accessibilityIdentifier("audioworkspace.player.shuffle")

                Button {
                    Task { await playback.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .disabled(playback.currentTrack == nil && playback.queueRecords.isEmpty)
                .help("Previous Track (⌘←)")
                .accessibilityLabel("Previous Track")
                .accessibilityIdentifier("audioworkspace.player.previous")

                Button {
                    Task { await playback.togglePlayPause() }
                } label: {
                    Image(systemName: playPauseIconName)
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(playback.currentTrack == nil && playback.queueManager.currentTrackID == nil)
                .help(isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("audioworkspace.player.play_pause")

                Button {
                    Task { await playback.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .disabled(playback.queueRecords.isEmpty)
                .help("Next Track (⌘→)")
                .accessibilityLabel("Next Track")
                .accessibilityIdentifier("audioworkspace.player.next")

                Button {
                    playback.cycleRepeatMode()
                } label: {
                    Image(systemName: repeatIconName)
                        .foregroundStyle(playback.queueManager.queue.repeatMode == .off ? .secondary : AppTheme.Colors.accent)
                }
                .buttonStyle(.plain)
                .help("Cycle Repeat Mode")
                .accessibilityLabel("Repeat Mode")
                .accessibilityValue(playback.queueManager.queue.repeatMode.rawValue)
                .accessibilityIdentifier("audioworkspace.player.repeat")
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Text(AudioLibraryTrackListView.formatDuration(displayedElapsed))
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 38, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { totalDuration > 0 ? displayedElapsed : 0 },
                        set: { newValue in
                            isDraggingScrubber = true
                            scrubSeconds = newValue
                        }
                    ),
                    in: 0...max(0.01, totalDuration),
                    onEditingChanged: { editing in
                        if !editing && isDraggingScrubber {
                            let target = scrubSeconds
                            isDraggingScrubber = false
                            Task { await playback.seek(toSeconds: target) }
                        }
                    }
                )
                .disabled(totalDuration <= 0 || engine.streamInfo == nil)
                .accessibilityLabel("Playback Position")
                .accessibilityValue(AudioLibraryTrackListView.formatDuration(displayedElapsed))
                .accessibilityIdentifier("audioworkspace.player.scrubber")

                Text(AudioLibraryTrackListView.formatDuration(totalDuration))
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 38, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var playerRightControlsBlock: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Menu("\(String(format: "%.2gx", engine.playbackRate))") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button("\(String(format: "%.2gx", rate))") {
                        playback.setPlaybackRate(rate)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 42)
            .accessibilityLabel("Playback Speed")
            .accessibilityIdentifier("audioworkspace.player.speed")

            Button {
                playback.toggleMute()
            } label: {
                Image(systemName: engine.isMuted || engine.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isMuted ? "Unmute" : "Mute")
            .accessibilityIdentifier("audioworkspace.player.mute")

            Slider(value: $localVolume, in: 0...1)
                .frame(width: 68)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((localVolume * 100).rounded())) percent")
                .accessibilityIdentifier("audioworkspace.player.volume")

            Button {
                showDevicePopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker")
                    Text(playback.activeOutputDevice?.name ?? "Default")
                        .font(AppTheme.Typography.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 88, alignment: .leading)
                }
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help("Select Audio Output Device")
            .accessibilityLabel("Audio Output Device")
            .accessibilityValue(playback.activeOutputDevice?.name ?? "System Default")
            .accessibilityIdentifier("audioworkspace.player.device_picker")
            .popover(isPresented: $showDevicePopover, arrowEdge: .top) {
                AudioOutputDevicePicker(playback: playback)
            }

            Button {
                showQueuePopover.toggle()
            } label: {
                Label("\(playback.queueRecords.count)", systemImage: "list.bullet")
                    .font(AppTheme.Typography.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Playback Queue, \(playback.queueRecords.count) tracks")
            .accessibilityIdentifier("audioworkspace.player.queue_button")
            .popover(isPresented: $showQueuePopover, arrowEdge: .top) {
                AudioPlaybackQueuePopover(coordinator: coordinator, playback: playback)
                    .frame(width: 340, height: 410)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var isPlaying: Bool {
        if case .playing = engine.playbackState { return true }
        return false
    }

    private var isErrorState: Bool {
        if case .error = engine.playbackState { return true }
        return playback.lastErrorMessage != nil
    }

    private var subtitleText: String {
        if case .error(let msg) = engine.playbackState {
            return msg
        }
        if let err = playback.lastErrorMessage {
            return err
        }
        guard let track = playback.currentTrack else {
            return "Select a track from the library"
        }
        let artist = track.metadata.artist ?? "Unknown Artist"
        let sr = String(format: "%.1fkHz", Double(track.asset.sampleRate.hz) / 1000.0)
        return "\(artist) · \(track.asset.codecName.uppercased()) \(sr)"
    }

    private var playPauseIconName: String {
        isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    private var repeatIconName: String {
        switch playback.queueManager.queue.repeatMode {
        case .one: return "repeat.1"
        case .all, .off: return "repeat"
        }
    }
}

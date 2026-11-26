import SwiftUI

struct TransportBarView: View {
    @ObservedObject var store: AudioEditorStore
    let timelineViewportWidth: Double

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.md) {
                transportButtonsSection
                timecodeReadout
                levelMetersSection

                Divider()
                    .frame(height: 18)

                snapToGridSection

                Spacer(minLength: 8)

                zoomControlsSection
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    transportButtonsSection
                    timecodeReadout
                    Spacer(minLength: 8)
                    levelMetersSection
                }

                HStack(spacing: AppTheme.Spacing.sm) {
                    snapToGridSection
                    Spacer(minLength: 8)
                    zoomControlsSection
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardBackground)
    }

    @ViewBuilder
    private var timecodeReadout: some View {
        // Timecode readout (isolated 60 Hz observer)
        PlayheadTimecodeReadout(
            playheadState: store.playheadState,
            totalDuration: store.project.duration,
            selectionRange: store.timeline.selectionRange
        )
    }

    @ViewBuilder
    private var levelMetersSection: some View {
        // Stereo L/R Level Meters + Dynamics GR
        VStack(spacing: 3) {
            LevelMeterBar(level: store.playbackEngine.meterL, label: "L")
            LevelMeterBar(level: store.playbackEngine.meterR, label: "R")
            if store.playbackEngine.gainReductionDB < -0.2 {
                Text(String(format: "GR %.1f dB", store.playbackEngine.gainReductionDB))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.warning)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(width: 90)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output Level Meter")
    }

    @ViewBuilder
    private var snapToGridSection: some View {
        // Snap to Grid Controls
        HStack(spacing: 4) {
            Toggle(isOn: Binding(
                get: { store.project.gridConfig.snapEnabled },
                set: { _ in store.toggleGridSnap() }
            )) {
                Image(systemName: "grid")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Snap Clips & Selection to Grid")
            .accessibilityLabel("Toggle Snap to Grid")

            Picker("Grid", selection: Binding(
                get: { store.project.gridConfig.interval },
                set: { store.setGridInterval($0) }
            )) {
                ForEach(TimelineSnapInterval.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 96)
            .disabled(!store.project.gridConfig.snapEnabled)
        }
    }

    @ViewBuilder
    private var zoomControlsSection: some View {
        // Zoom Controls
        HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                store.zoomOut(viewportWidth: timelineViewportWidth)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out (⌘-)")
            .accessibilityLabel("Zoom Out")
            .accessibilityIdentifier("audioworkspace.editor.zoom_out")

            Slider(
                value: Binding(
                    get: { log2(store.timeline.pixelsPerSecond) },
                    set: { store.timeline.pixelsPerSecond = pow(2, $0) }
                ),
                in: log2(TimelineState.minPixelsPerSecond)...log2(TimelineState.maxPixelsPerSecond)
            )
            .frame(width: 90)
            .accessibilityLabel("Timeline Zoom")
            .accessibilityIdentifier("audioworkspace.editor.zoom_slider")

            Button {
                store.zoomIn(viewportWidth: timelineViewportWidth)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In (⌘+)")
            .accessibilityLabel("Zoom In")
            .accessibilityIdentifier("audioworkspace.editor.zoom_in")

            Button("Fit") {
                store.fitProjectToWindow(viewportWidth: timelineViewportWidth)
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Fit Entire Project to Window (⌘0)")
            .accessibilityIdentifier("audioworkspace.editor.zoom_fit")

            Button("Fit Sel") {
                store.fitSelectionToWindow(viewportWidth: timelineViewportWidth)
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(store.timeline.selectionRange == nil)
            .help("Fit Selected Range to Window")
            .accessibilityIdentifier("audioworkspace.editor.zoom_fit_selection")
        }
    }

    @ViewBuilder
    private var transportButtonsSection: some View {
        // Transport buttons
        HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                store.returnToBeginning()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Return to Beginning (Home)")
            .accessibilityLabel("Return to Beginning")
            .accessibilityIdentifier("audioworkspace.editor.transport.beginning")

            Button {
                store.skip(by: -5.0)
            } label: {
                Image(systemName: "gobackward.5")
            }
            .help("Skip Backward 5s")
            .accessibilityLabel("Skip Backward 5 Seconds")
            .accessibilityIdentifier("audioworkspace.editor.transport.skip_back")

            Button {
                store.togglePlayPause()
            } label: {
                Image(systemName: store.playbackEngine.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.borderedProminent)
            .help("Play / Pause (Space)")
            .accessibilityLabel(store.playbackEngine.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("audioworkspace.editor.transport.play_pause")

            Button {
                store.stopPlayback()
            } label: {
                Image(systemName: "stop.fill")
            }
            .help("Stop")
            .accessibilityLabel("Stop")
            .accessibilityIdentifier("audioworkspace.editor.transport.stop")

            Button {
                store.skip(by: 5.0)
            } label: {
                Image(systemName: "goforward.5")
            }
            .help("Skip Forward 5s")
            .accessibilityLabel("Skip Forward 5 Seconds")
            .accessibilityIdentifier("audioworkspace.editor.transport.skip_forward")

            Divider()
                .frame(height: 18)

            Button {
                store.playFromSelection()
            } label: {
                Label("Play Selection", systemImage: "play.rectangle")
                    .labelStyle(.iconOnly)
            }
            .disabled(store.timeline.selectionRange == nil)
            .help("Play from Selection Start")
            .accessibilityLabel("Play from Selection Start")
            .accessibilityIdentifier("audioworkspace.editor.transport.play_selection")

            Toggle(isOn: Binding(
                get: { store.timeline.isLoopEnabled },
                set: { _ in store.toggleLoopSelection() }
            )) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .disabled(store.timeline.selectionRange == nil && store.timeline.loopRange == nil)
            .help("Loop Selected Range (L)")
            .accessibilityLabel("Loop Selection")
            .accessibilityValue(store.timeline.isLoopEnabled ? "On" : "Off")
            .accessibilityIdentifier("audioworkspace.editor.transport.loop")
        }
    }
}

private struct PlayheadTimecodeReadout: View {
    @ObservedObject var playheadState: AudioPlayheadState
    let totalDuration: TimeInterval
    let selectionRange: ClosedRange<TimeInterval>?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(AudioEditorTime.format(playheadState.playheadTime))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Total \(AudioEditorTime.format(totalDuration))")
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let sel = selectionRange {
                    Text("Sel \(AudioEditorTime.format(sel.upperBound - sel.lowerBound))")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, 4)
        .background(AppTheme.Colors.subtleSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playhead \(AudioEditorTime.format(playheadState.playheadTime))")
        .accessibilityValue(AudioEditorTime.format(playheadState.playheadTime))
        .accessibilityIdentifier("audioworkspace.editor.playhead_readout")
    }
}

private struct LevelMeterBar: View {
    let level: Float
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                let clamped = CGFloat(min(1.0, max(0.0, level)))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppTheme.Colors.neutralTint)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(clamped > 0.92 ? AppTheme.Colors.error : (clamped > 0.72 ? AppTheme.Colors.warning : AppTheme.Colors.success))
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 5)
        }
    }
}

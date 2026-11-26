import SwiftUI
import AVFoundation

// MARK: - Audio Preview Player

@MainActor
final class AudioPreviewController: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stopAtTime: Double?

    func togglePlay(url: URL, startTime: Double, endTime: Double?) {
        if isPlaying {
            stop()
            return
        }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.prepareToPlay()
            let clampedStart = max(0, min(startTime, max(0, audioPlayer.duration - 0.05)))
            audioPlayer.currentTime = clampedStart
            audioPlayer.play()

            self.player = audioPlayer
            self.stopAtTime = endTime
            self.currentTime = clampedStart
            self.isPlaying = true

            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
        } catch {
            stop()
        }
    }

    private func tick() {
        guard let player else {
            stop()
            return
        }
        if !player.isPlaying {
            stop()
            return
        }
        currentTime = player.currentTime
        if let limit = stopAtTime, limit > 0, player.currentTime >= limit {
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}

// MARK: - Interactive Waveform View

struct AudioWaveformView: View {
    let waveform: AudioWaveformData
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let segments: [AudioTrimSegment]
    let silenceIntervals: [AudioSilenceInterval]
    let currentTime: Double

    @State private var zoomScale: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
            HStack(spacing: 6) {
                Text("Zoom:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach([CGFloat(1.0), CGFloat(2.0), CGFloat(4.0)], id: \.self) { z in
                    Button("\(Int(z))×") { zoomScale = z }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(zoomScale == z ? .accentColor : .secondary)
                }
                Spacer()
                if zoomScale > 1.0 {
                    Text("Scroll horizontally to inspect zoomed waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { outerGeo in
                let baseWidth = max(1, outerGeo.size.width)
                let width = baseWidth * zoomScale
                let height = max(1, outerGeo.size.height)
                let duration = max(0.01, waveform.duration)

                ScrollView(.horizontal, showsIndicators: zoomScale > 1.0) {
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Colors.cardBackground)

                        // Detected silence regions
                        ForEach(silenceIntervals) { interval in
                            let x0 = CGFloat(interval.start / duration) * width
                            let w = max(2, CGFloat(interval.duration / duration) * width)
                            Rectangle()
                                .fill(AppTheme.Colors.warning.opacity(0.22))
                                .frame(width: w, height: height)
                                .offset(x: x0)
                        }

                        // Active multi-segments highlight (if present)
                        ForEach(segments) { seg in
                            let x0 = CGFloat(seg.startTime / duration) * width
                            let w = max(2, CGFloat(seg.duration / duration) * width)
                            Rectangle()
                                .fill(Color.green.opacity(0.18))
                                .frame(width: w, height: height)
                                .offset(x: x0)
                        }

                        // Waveform Peak + RMS bars rendered cleanly via Canvas
                        Canvas { context, size in
                            let count = waveform.peaks.count
                            guard count > 0 else { return }
                            let step = size.width / CGFloat(count)
                            let midY = size.height / 2.0
                            let maxHalf = max(4, (size.height - 12) / 2.0)

                            for idx in 0..<count {
                                let binTime = (Double(idx) + 0.5) / Double(count) * duration
                                let inSelection = binTime >= trimStart && binTime <= trimEnd

                                let peakAmp = CGFloat(max(0.03, waveform.peaks[idx]))
                                let rmsAmp = idx < waveform.rms.count ? CGFloat(waveform.rms[idx]) : peakAmp * 0.65

                                let x = CGFloat(idx) * step
                                let barW = max(1.2, step - 0.8)

                                let peakH = peakAmp * maxHalf * 2.0
                                let peakRect = CGRect(x: x, y: midY - peakH / 2.0, width: barW, height: peakH)
                                context.fill(
                                    Path(roundedRect: peakRect, cornerRadius: 0.8),
                                    with: .color(inSelection ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.25))
                                )

                                let rmsH = max(2.0, rmsAmp * maxHalf * 2.0)
                                let rmsRect = CGRect(x: x, y: midY - rmsH / 2.0, width: barW, height: rmsH)
                                context.fill(
                                    Path(roundedRect: rmsRect, cornerRadius: 0.8),
                                    with: .color(inSelection ? Color.accentColor : Color.secondary.opacity(0.45))
                                )
                            }
                        }

                        // Playhead line
                        if currentTime > 0 && currentTime <= duration {
                            let px = CGFloat(currentTime / duration) * width
                            Rectangle()
                                .fill(Color.primary)
                                .frame(width: 1.5, height: height)
                                .offset(x: px)
                        }

                        // Start Handle
                        let startX = CGFloat(min(trimStart, trimEnd) / duration) * width
                        trimHandle(color: .accentColor, alignmentLeft: true)
                            .offset(x: max(0, min(width - 10, startX - 5)))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { val in
                                        let ratio = max(0, min(1, val.location.x / width))
                                        let newTime = Double(ratio) * duration
                                        trimStart = min(newTime, max(0, trimEnd - 0.05))
                                    }
                            )

                        // End Handle
                        let endX = CGFloat(max(trimStart, trimEnd) / duration) * width
                        trimHandle(color: .accentColor, alignmentLeft: false)
                            .offset(x: max(0, min(width - 10, endX - 5)))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { val in
                                        let ratio = max(0, min(1, val.location.x / width))
                                        let newTime = Double(ratio) * duration
                                        trimEnd = max(newTime, min(duration, trimStart + 0.05))
                                    }
                            )
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
            }
            .frame(height: zoomScale > 1.0 ? 102 : 88)

            HStack {
                Text("Start: \(Self.formatTime(trimStart))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Selection: \(Self.formatTime(max(0, trimEnd - trimStart)))")
                    .font(.caption.monospacedDigit())
                    .fontWeight(.medium)
                Spacer()
                Text("Total: \(Self.formatTime(waveform.duration)) · End: \(Self.formatTime(trimEnd))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func trimHandle(color: Color, alignmentLeft: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14)
            Rectangle()
                .fill(color)
                .frame(width: 3)
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 18)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(alignmentLeft ? "Trim start handle" : "Trim end handle")
    }

    static func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let mins = Int(clamped) / 60
        let secs = clamped.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", mins, secs)
    }
}

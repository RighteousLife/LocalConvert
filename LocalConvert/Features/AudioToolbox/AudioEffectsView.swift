import SwiftUI

// MARK: - Audio Adjustments & DSP Effects View

struct AudioEffectsView: View {
    @Binding var config: AudioToolboxConfig
    let primaryInputURL: URL?

    @State private var isAnalyzingLoudness = false
    @State private var measuredLoudness: AudioLoudnessMeasurement?
    @State private var loudnessError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            // 1. Gain, Fade, Speed, Pitch, Reverse
            AppCard(title: "Volume, Fades, Speed & Pitch", icon: "dial.medium") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm + 2) {
                    sliderRow(
                        title: "Volume Gain",
                        value: $config.volumeGainDB,
                        range: -24...24,
                        step: 0.5,
                        formatted: String(format: "%+.1f dB", config.volumeGainDB)
                    )

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            sliderRow(
                                title: "Fade In",
                                value: $config.fadeInSeconds,
                                range: 0...15,
                                step: 0.25,
                                formatted: String(format: "%.2fs", config.fadeInSeconds)
                            )
                            sliderRow(
                                title: "Fade Out",
                                value: $config.fadeOutSeconds,
                                range: 0...15,
                                step: 0.25,
                                formatted: String(format: "%.2fs", config.fadeOutSeconds)
                            )
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            sliderRow(
                                title: "Fade In",
                                value: $config.fadeInSeconds,
                                range: 0...15,
                                step: 0.25,
                                formatted: String(format: "%.2fs", config.fadeInSeconds)
                            )
                            sliderRow(
                                title: "Fade Out",
                                value: $config.fadeOutSeconds,
                                range: 0...15,
                                step: 0.25,
                                formatted: String(format: "%.2fs", config.fadeOutSeconds)
                            )
                        }
                    }

                    Divider()

                    HStack {
                        Text("Playback Speed")
                            .frame(width: 120, alignment: .leading)
                        Slider(value: $config.speedMultiplier, in: 0.25...4.0, step: 0.05)
                            .accessibilityLabel("Playback Speed")
                            .accessibilityValue(String(format: "%.2f times", config.speedMultiplier))
                        Text(String(format: "%.2f×", config.speedMultiplier))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text("Quick:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { spd in
                                Button(String(format: "%.2g×", spd)) {
                                    config.speedMultiplier = spd
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            Spacer()
                            Toggle("Reverse Audio", isOn: $config.reverseAudio)
                                .controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            HStack(spacing: 6) {
                                Text("Quick:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { spd in
                                    Button(String(format: "%.2g×", spd)) {
                                        config.speedMultiplier = spd
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            Toggle("Reverse Audio", isOn: $config.reverseAudio)
                                .controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    sliderRow(
                        title: "Pitch Shift",
                        value: $config.pitchSemitones,
                        range: -12...12,
                        step: 0.5,
                        formatted: String(format: "%+.1f st", config.pitchSemitones)
                    )
                }
            }

            // 2. Equalizer & High-Pass / Low-Pass
            AppCard(title: "Equalizer & Frequency Filters", icon: "slider.vertical.3") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm + 2) {
                    let currentEQPreset = config.activeEQPreset
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text("EQ Preset:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            Button("Flat") { config.activeEQPreset = .flat }
                                .buttonStyle(.bordered)
                                .tint(currentEQPreset == .flat ? AppTheme.Colors.accent : nil)
                                .controlSize(.mini)
                                .fixedSize(horizontal: true, vertical: false)
                            Button("Vocal Clarity") { config.activeEQPreset = .vocalClarity }
                                .buttonStyle(.bordered)
                                .tint(currentEQPreset == .vocalClarity ? AppTheme.Colors.accent : nil)
                                .controlSize(.mini)
                                .fixedSize(horizontal: true, vertical: false)
                            Button("Bass Boost") { config.activeEQPreset = .bassBoost }
                                .buttonStyle(.bordered)
                                .tint(currentEQPreset == .bassBoost ? AppTheme.Colors.accent : nil)
                                .controlSize(.mini)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            AppStatusBadge(
                                text: currentEQPreset.rawValue,
                                tint: currentEQPreset == .custom ? AppTheme.Colors.warning : AppTheme.Colors.accent
                            )
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            HStack(spacing: 8) {
                                Text("EQ Preset:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                                AppStatusBadge(
                                    text: currentEQPreset.rawValue,
                                    tint: currentEQPreset == .custom ? AppTheme.Colors.warning : AppTheme.Colors.accent
                                )
                            }
                            HStack(spacing: 6) {
                                Button("Flat") { config.activeEQPreset = .flat }
                                    .buttonStyle(.bordered)
                                    .tint(currentEQPreset == .flat ? AppTheme.Colors.accent : nil)
                                    .controlSize(.mini)
                                    .fixedSize(horizontal: true, vertical: false)
                                Button("Vocal Clarity") { config.activeEQPreset = .vocalClarity }
                                    .buttonStyle(.bordered)
                                    .tint(currentEQPreset == .vocalClarity ? AppTheme.Colors.accent : nil)
                                    .controlSize(.mini)
                                    .fixedSize(horizontal: true, vertical: false)
                                Button("Bass Boost") { config.activeEQPreset = .bassBoost }
                                    .buttonStyle(.bordered)
                                    .tint(currentEQPreset == .bassBoost ? AppTheme.Colors.accent : nil)
                                    .controlSize(.mini)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }

                    ForEach($config.eqBands) { $band in
                        HStack {
                            Text(band.label)
                                .font(.caption)
                                .frame(width: 145, alignment: .leading)
                            Slider(value: $band.gainDB, in: -12...12, step: 0.5)
                            Text(String(format: "%+.1f dB", band.gainDB))
                                .font(.caption.monospacedDigit())
                                .frame(width: 58, alignment: .trailing)
                        }
                    }

                    Divider()

                    HStack(spacing: 16) {
                        Toggle("High-Pass Filter", isOn: Binding(
                            get: { config.highPassHz != nil },
                            set: { config.highPassHz = $0 ? 80.0 : nil }
                        ))
                        if let hp = config.highPassHz {
                            Slider(
                                value: Binding(
                                    get: { hp },
                                    set: { config.highPassHz = $0 }
                                ),
                                in: 30...400,
                                step: 5
                            )
                            Text("\(Int(hp)) Hz")
                                .font(.caption.monospacedDigit())
                                .frame(width: 56, alignment: .trailing)
                        }
                    }

                    HStack(spacing: 16) {
                        Toggle("Low-Pass Filter", isOn: Binding(
                            get: { config.lowPassHz != nil },
                            set: { config.lowPassHz = $0 ? 12000.0 : nil }
                        ))
                        if let lp = config.lowPassHz {
                            Slider(
                                value: Binding(
                                    get: { lp },
                                    set: { config.lowPassHz = $0 }
                                ),
                                in: 1500...18000,
                                step: 250
                            )
                            Text("\(Int(lp)) Hz")
                                .font(.caption.monospacedDigit())
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }

            // 3. Noise Reduction, Dynamics, Normalization & Spatial
            AppCard(title: "Noise Reduction, Dynamics, Loudness & Stereo", icon: "sparkles") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm + 2) {
                    // Noise Reduction (FFmpeg afftdn + adeclick)
                    HStack {
                        Text("Noise Reduction (FFT)")
                            .frame(width: 155, alignment: .leading)
                        Picker("", selection: $config.noiseReduction) {
                            ForEach(AudioNoiseReductionLevel.allCases) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Toggle("De-Click / Impulse Removal", isOn: $config.declickEnabled)

                    Divider()

                    // Dynamics
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Toggle("Compressor", isOn: $config.compressorEnabled)
                                .frame(width: 120, alignment: .leading)
                            if config.compressorEnabled {
                                Text("Thresh \(Int(config.compressorThresholdDB)) dB")
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Slider(value: $config.compressorThresholdDB, in: -40...(-4), step: 1)
                                Text(String(format: "%.1f:1", config.compressorRatio))
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Slider(value: $config.compressorRatio, in: 1.5...12.0, step: 0.5)
                            }
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Toggle("Compressor", isOn: $config.compressorEnabled)
                            if config.compressorEnabled {
                                HStack(spacing: 8) {
                                    Text("Thresh \(Int(config.compressorThresholdDB)) dB")
                                        .font(.caption.monospacedDigit())
                                        .fixedSize(horizontal: true, vertical: false)
                                    Slider(value: $config.compressorThresholdDB, in: -40...(-4), step: 1)
                                }
                                HStack(spacing: 8) {
                                    Text("Ratio \(String(format: "%.1f:1", config.compressorRatio))")
                                        .font(.caption.monospacedDigit())
                                        .fixedSize(horizontal: true, vertical: false)
                                    Slider(value: $config.compressorRatio, in: 1.5...12.0, step: 0.5)
                                }
                            }
                        }
                    }

                    HStack {
                        Toggle("Peak Limiter", isOn: $config.limiterEnabled)
                            .frame(width: 120, alignment: .leading)
                        if config.limiterEnabled {
                            Text("Ceiling \(String(format: "%.1f dB", config.limiterCeilingDB))")
                                .font(.caption.monospacedDigit())
                            Slider(value: $config.limiterCeilingDB, in: -6.0...(-0.1), step: 0.1)
                        }
                    }

                    Divider()

                    // Loudness Normalization
                    HStack {
                        Text("Normalization")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $config.normalizationMode) {
                            ForEach(AudioNormalizationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        Spacer()
                        if let url = primaryInputURL {
                            Button {
                                analyzeLoudness(url: url)
                            } label: {
                                if isAnalyzingLoudness {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Inspect Loudness", systemImage: "waveform.and.magnifyingglass")
                                }
                            }
                            .controlSize(.small)
                            .disabled(isAnalyzingLoudness)
                        }
                    }

                    if config.normalizationMode == .ebuR128 {
                        HStack {
                            Text("Target Loudness")
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                            Slider(value: $config.targetLUFS, in: -24...(-9), step: 0.5)
                                .accessibilityLabel("Target Loudness")
                                .accessibilityValue(String(format: "%.1f LUFS", config.targetLUFS))
                            Text(String(format: "%.1f LUFS", config.targetLUFS))
                                .font(.caption.monospacedDigit())
                                .frame(width: 72, alignment: .trailing)
                        }
                        HStack {
                            Text("True Peak Ceiling")
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                            Slider(value: $config.targetTruePeakDB, in: -4...0, step: 0.5)
                                .accessibilityLabel("True Peak Ceiling")
                                .accessibilityValue(String(format: "%.1f decibels true peak", config.targetTruePeakDB))
                            Text(String(format: "%.1f dBTP", config.targetTruePeakDB))
                                .font(.caption.monospacedDigit())
                                .frame(width: 72, alignment: .trailing)
                        }
                    } else if config.normalizationMode == .peak {
                        HStack {
                            Text("Target Peak")
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                            Slider(value: $config.peakNormalizeTargetDB, in: -6...0, step: 0.5)
                                .accessibilityLabel("Target Peak")
                                .accessibilityValue(String(format: "%.1f dBFS", config.peakNormalizeTargetDB))
                            Text(String(format: "%.1f dBFS", config.peakNormalizeTargetDB))
                                .font(.caption.monospacedDigit())
                                .frame(width: 72, alignment: .trailing)
                        }
                    }

                    if let m = measuredLoudness {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 14) {
                                if let lufs = m.integratedLUFS {
                                    Text("Integrated: \(String(format: "%.1f LUFS", lufs))")
                                }
                                if let lra = m.loudnessRangeLU {
                                    Text("LRA: \(String(format: "%.1f LU", lra))")
                                }
                                if let tp = m.truePeakDBTP {
                                    Text("True Peak: \(String(format: "%.1f dBTP", tp))")
                                }
                            }
                            HStack(spacing: 14) {
                                if let maxDB = m.maxVolumeDB {
                                    Text("Sample Peak: \(String(format: "%.1f dBFS", maxDB))")
                                }
                                if let meanDB = m.meanVolumeDB {
                                    Text("Mean: \(String(format: "%.1f dBFS", meanDB))")
                                }
                                if let thresh = m.thresholdLUFS {
                                    Text("Thresh: \(String(format: "%.1f LUFS", thresh))")
                                }
                                if let offset = m.loudnormTargetOffset {
                                    Text("2-Pass Offset: \(String(format: "%+.2f dB", offset))")
                                }
                            }
                            if let actualMode = m.normalizationTypeUsed {
                                let modeNote = actualMode == "dynamic"
                                    ? "Pass-2 Mode: Dynamic (true-peak ceiling prevents linear gain)"
                                    : "Pass-2 Mode: Linear (dynamics preserved)"
                                Text(modeNote)
                                    .foregroundStyle(actualMode == "dynamic" ? AppTheme.Colors.warning : AppTheme.Colors.success)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    } else if let loudnessError {
                        Text(loudnessError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Divider()

                    // Stereo & Channel Tools
                    sliderRow(
                        title: "L/R Balance",
                        value: $config.channelBalance,
                        range: -1.0...1.0,
                        step: 0.05,
                        formatted: abs(config.channelBalance) < 0.02 ? "Center" : (config.channelBalance < 0 ? String(format: "L %.0f%%", -config.channelBalance * 100) : String(format: "R %.0f%%", config.channelBalance * 100))
                    )

                    sliderRow(
                        title: "Stereo Width",
                        value: $config.stereoWidth,
                        range: 0.0...2.0,
                        step: 0.05,
                        formatted: String(format: "%.0f%%", config.stereoWidth * 100)
                    )

                    HStack {
                        Toggle("Swap Left & Right Channels", isOn: $config.swapChannels)
                        Spacer()
                        Button("Reset All Effects") {
                            resetEffectsOnly()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatted: String
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 120, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(formatted)
            Text(formatted)
                .font(.caption.monospacedDigit())
                .frame(width: 68, alignment: .trailing)
        }
    }

    private func analyzeLoudness(url: URL) {
        isAnalyzingLoudness = true
        loudnessError = nil
        let tLUFS = config.targetLUFS
        let tTP = config.targetTruePeakDB
        Task {
            do {
                let result = try await AudioAnalysisService.shared.measureLoudness(
                    url: url,
                    targetLUFS: tLUFS,
                    targetTruePeakDB: tTP,
                    includeTwoPassLoudnorm: true
                )
                await MainActor.run {
                    self.measuredLoudness = result
                    self.isAnalyzingLoudness = false
                }
            } catch {
                await MainActor.run {
                    self.loudnessError = error.localizedDescription
                    self.isAnalyzingLoudness = false
                }
            }
        }
    }

    private func resetEffectsOnly() {
        config.volumeGainDB = 0
        config.fadeInSeconds = 0
        config.fadeOutSeconds = 0
        config.speedMultiplier = 1.0
        config.pitchSemitones = 0
        config.reverseAudio = false
        config.eqBands = AudioEQBand.defaultBands
        config.highPassHz = nil
        config.lowPassHz = nil
        config.compressorEnabled = false
        config.limiterEnabled = false
        config.normalizationMode = .none
        config.channelBalance = 0
        config.stereoWidth = 1.0
        config.swapChannels = false
        config.noiseReduction = .off
        config.declickEnabled = false
    }
}

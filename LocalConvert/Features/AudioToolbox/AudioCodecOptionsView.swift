import SwiftUI

// MARK: - Audio Codec & Container Configuration View

struct AudioCodecOptionsView: View {
    @Binding var targetFormat: FileFormat
    @Binding var config: AudioToolboxConfig
    @Binding var preserveMetadata: Bool
    let sourceInfo: MediaInfo?
    let validation: AudioValidationResult

    static let writableAudioFormats: [FileFormat] = FormatCapabilityRegistry.shared
        .writableFormats(in: .audio)
        .sorted { $0.displayName < $1.displayName }

    private var supportedCodecs: [AudioCodecID] {
        AudioCodecRegistry.supportedCodecs(for: targetFormat)
    }

    private var activeCodec: AudioCodecID {
        let resolved = config.resolvedCodec(for: targetFormat)
        return supportedCodecs.contains(resolved) ? resolved : AudioCodecRegistry.defaultCodec(for: targetFormat)
    }

    private var spec: AudioCodecSpec {
        AudioCodecRegistry.spec(for: activeCodec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: "Encoding & Format Profile", icon: "waveform.path.ecg") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    // Output Format
                    HStack {
                        Text("Output Format")
                            .frame(width: 130, alignment: .leading)
                        Picker("", selection: $targetFormat) {
                            ForEach(Self.writableAudioFormats, id: \.self) { fmt in
                                Text("\(fmt.displayName) (.\(fmt.fileExtension))").tag(fmt)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: targetFormat) { _, newFormat in
                            sanitizeConfig(for: newFormat)
                        }
                    }

                    // Dynamic Codec Selection
                    HStack {
                        Text("Codec")
                            .frame(width: 130, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { activeCodec },
                            set: { newCodec in
                                if newCodec == .streamCopy {
                                    config.preferStreamCopy = true
                                    config.codec = .streamCopy
                                } else {
                                    config.preferStreamCopy = false
                                    config.codec = newCodec
                                }
                                sanitizeParamsForCodec(newCodec)
                            }
                        )) {
                            ForEach(supportedCodecs) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }
                        .labelsHidden()
                    }

                    if let note = spec.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if activeCodec == .streamCopy {
                        let compatible = AudioCodecRegistry.isStreamCopyCompatible(
                            sourceCodecName: sourceInfo?.primaryAudioStream?.codecName,
                            targetFormat: targetFormat
                        )
                        HStack(spacing: 6) {
                            Image(systemName: compatible ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(compatible ? .green : .orange)
                            Text(compatible
                                 ? "Source codec (\(sourceInfo?.primaryAudioStream?.codecName ?? "unknown")) can be stream-copied cleanly without re-encoding."
                                 : "Stream copy requires compatible container codec (\(sourceInfo?.primaryAudioStream?.codecName ?? "none") → .\(targetFormat.fileExtension)) and no active DSP filters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Divider()

                        // Rate Control: CBR / VBR
                        if spec.supportsCBR || spec.supportsVBR {
                            if spec.supportsCBR && spec.supportsVBR {
                                HStack {
                                    Text("Bitrate Mode")
                                        .frame(width: 130, alignment: .leading)
                                    Picker("", selection: $config.bitrateMode) {
                                        ForEach(AudioBitrateMode.allCases) { mode in
                                            Text(mode.rawValue).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 180)
                                }
                            }

                            if config.bitrateMode == .vbr && spec.supportsVBR {
                                if let range = spec.vbrQualityRange {
                                    HStack {
                                        Text(spec.vbrLabel ?? "VBR Quality")
                                            .frame(width: 130, alignment: .leading)
                                        let currentQ = config.vbrQuality ?? ((range.lowerBound + range.upperBound) / 2)
                                        Slider(
                                            value: Binding(
                                                get: { Double(currentQ) },
                                                set: { config.vbrQuality = Int($0.rounded()) }
                                            ),
                                            in: Double(range.lowerBound)...Double(range.upperBound),
                                            step: 1
                                        )
                                        Text("\(currentQ)")
                                            .font(.caption.monospacedDigit())
                                            .frame(width: 30, alignment: .trailing)
                                    }
                                } else if !spec.bitrateOptionsKbps.isEmpty {
                                    bitratePickerRow
                                }
                            } else if spec.supportsCBR && !spec.bitrateOptionsKbps.isEmpty {
                                bitratePickerRow
                            }
                        }

                        // Lossless Compression Level
                        if spec.supportsCompressionLevel, let range = spec.compressionLevelRange {
                            HStack {
                                Text("Compression Level")
                                    .frame(width: 130, alignment: .leading)
                                let current = config.compressionLevel ?? 5
                                Slider(
                                    value: Binding(
                                        get: { Double(current) },
                                        set: { config.compressionLevel = Int($0.rounded()) }
                                    ),
                                    in: Double(range.lowerBound)...Double(range.upperBound),
                                    step: 1
                                )
                                Text("\(current)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }

                        // Sample Rate
                        if !spec.supportedSampleRates.isEmpty {
                            HStack {
                                Text("Sample Rate")
                                    .frame(width: 130, alignment: .leading)
                                Picker("", selection: $config.sampleRateHz) {
                                    Text("Original (Auto)").tag(Int?.none)
                                    ForEach(spec.supportedSampleRates, id: \.self) { rate in
                                        let label = (rate % 1000 == 0) ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000.0)
                                        Text(label).tag(Int?.some(rate))
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        // Bit Depth
                        if let fixed = spec.fixedBitDepth {
                            HStack {
                                Text("Bit Depth")
                                    .frame(width: 130, alignment: .leading)
                                Text("\(fixed)-bit (\(activeCodec.shortLabel))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else if !spec.supportedBitDepths.isEmpty {
                            HStack {
                                Text("Bit Depth")
                                    .frame(width: 130, alignment: .leading)
                                Picker("", selection: $config.bitDepth) {
                                    Text("Auto").tag(Int?.none)
                                    ForEach(spec.supportedBitDepths, id: \.self) { bd in
                                        Text("\(bd)-bit").tag(Int?.some(bd))
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        // Channels
                        if !spec.supportedChannelCounts.isEmpty {
                            HStack {
                                Text("Channels")
                                    .frame(width: 130, alignment: .leading)
                                Picker("", selection: $config.channelMode) {
                                    Text("Original").tag(AudioChannelMode.original)
                                    if spec.supportedChannelCounts.contains(1) {
                                        Text("Mono (1 ch)").tag(AudioChannelMode.mono)
                                    }
                                    if spec.supportedChannelCounts.contains(2) {
                                        Text("Stereo (2 ch)").tag(AudioChannelMode.stereo)
                                    }
                                    if spec.supportedChannelCounts.contains(3) {
                                        Text("Surround 2.1 (3 ch)").tag(AudioChannelMode.surround21)
                                    }
                                    if spec.supportedChannelCounts.contains(6) {
                                        Text("Surround 5.1 (6 ch)").tag(AudioChannelMode.surround51)
                                    }
                                    if spec.supportedChannelCounts.contains(8) {
                                        Text("Surround 7.1 (8 ch)").tag(AudioChannelMode.surround71)
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        // Resampler & Dithering Precision
                        HStack {
                            Text("Resampler")
                                .frame(width: 130, alignment: .leading)
                            Picker("", selection: $config.resamplerEngine) {
                                ForEach(AudioResamplerEngine.allCases) { engine in
                                    Text(engine.rawValue).tag(engine)
                                }
                            }
                            .labelsHidden()
                        }

                        if config.bitDepth == 16 || activeCodec == .pcmS16LE || activeCodec == .pcmS16BE || activeCodec == .flac {
                            HStack {
                                Text("Dithering (16-bit)")
                                    .frame(width: 130, alignment: .leading)
                                Picker("", selection: $config.ditherMethod) {
                                    ForEach(AudioDitherMethod.allCases) { dither in
                                        Text(dither.rawValue).tag(dither)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }

                    Toggle("Preserve Source Metadata Tags", isOn: $preserveMetadata)
                }
            }

            // Validation Messages
            if !validation.errors.isEmpty || !validation.warnings.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    ForEach(validation.errors, id: \.self) { err in
                        AppInfoBanner(style: .error, message: err)
                    }
                    ForEach(validation.warnings, id: \.self) { warn in
                        AppInfoBanner(style: .warning, message: warn)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bitratePickerRow: some View {
        HStack {
            Text("Bitrate")
                .frame(width: 130, alignment: .leading)
            Picker("", selection: $config.bitrateKbps) {
                Text("Auto (\(spec.defaultBitrateKbps ?? 192) kbps)").tag(Int?.none)
                ForEach(spec.bitrateOptionsKbps, id: \.self) { kbps in
                    Text("\(kbps) kbps").tag(Int?.some(kbps))
                }
            }
            .labelsHidden()
        }
    }

    private func sanitizeConfig(for format: FileFormat) {
        let supported = AudioCodecRegistry.supportedCodecs(for: format)
        if config.preferStreamCopy {
            config.codec = .streamCopy
        } else if let current = config.codec, !supported.contains(current) {
            config.codec = AudioCodecRegistry.defaultCodec(for: format)
        } else if config.codec == nil {
            config.codec = AudioCodecRegistry.defaultCodec(for: format)
        }
        sanitizeParamsForCodec(config.resolvedCodec(for: format))
    }

    private func sanitizeParamsForCodec(_ codec: AudioCodecID) {
        let s = AudioCodecRegistry.spec(for: codec)
        if !s.supportsVBR && config.bitrateMode == .vbr {
            config.bitrateMode = .cbr
        }
        if !s.supportsCBR && s.supportsVBR {
            config.bitrateMode = .vbr
        }
        if let sr = config.sampleRateHz, !s.supportedSampleRates.isEmpty, !s.supportedSampleRates.contains(sr) {
            config.sampleRateHz = nil
        }
        if let bd = config.bitDepth, !s.supportedBitDepths.isEmpty, !s.supportedBitDepths.contains(bd) {
            config.bitDepth = nil
        } else if s.supportedBitDepths.isEmpty {
            config.bitDepth = nil
        }
        if let ch = config.channelMode.channelCount, !s.supportedChannelCounts.isEmpty, !s.supportedChannelCounts.contains(ch) {
            config.channelMode = .original
        }
        if let br = config.bitrateKbps, !s.bitrateOptionsKbps.contains(br) {
            config.bitrateKbps = nil
        }
    }
}

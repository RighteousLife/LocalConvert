import Foundation

// MARK: - Enums

enum AudioBitrateMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case cbr = "CBR"
    case vbr = "VBR"
    var id: String { rawValue }
}

enum AudioChannelMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case original = "Original"
    case mono = "Mono (1 ch)"
    case stereo = "Stereo (2 ch)"
    case surround21 = "Surround 2.1 (3 ch)"
    case surround51 = "Surround 5.1 (6 ch)"
    case surround71 = "Surround 7.1 (8 ch)"

    var id: String { rawValue }

    var channelCount: Int? {
        switch self {
        case .original: return nil
        case .mono: return 1
        case .stereo: return 2
        case .surround21: return 3
        case .surround51: return 6
        case .surround71: return 8
        }
    }

    var ffmpegLayoutName: String? {
        switch self {
        case .original: return nil
        case .mono: return "mono"
        case .stereo: return "stereo"
        case .surround21: return "2.1"
        case .surround51: return "5.1"
        case .surround71: return "7.1"
        }
    }
}

enum AudioDitherMethod: String, Sendable, Codable, CaseIterable, Identifiable {
    case auto = "Auto (Default)"
    case triangular = "Triangular (TPDF)"
    case triangularHP = "Triangular High-Pass"
    case shibata = "Shibata Noise Shaping"
    case lipshitz = "Lipshitz Noise Shaping"

    var id: String { rawValue }

    var ffmpegValue: String? {
        switch self {
        case .auto: return nil
        case .triangular: return "triangular"
        case .triangularHP: return "triangular_hp"
        case .shibata: return "shibata"
        case .lipshitz: return "lipshitz"
        }
    }
}

enum AudioResamplerEngine: String, Sendable, Codable, CaseIterable, Identifiable {
    case kaiserSinc = "High-Precision Kaiser Sinc (swr)"
    case standard = "Standard SW Resampler (swr)"

    var id: String { rawValue }
}

enum AudioSilenceTrimScope: String, Sendable, Codable, CaseIterable, Identifiable {
    case all = "Leading, Internal & Trailing"
    case edgesOnly = "Leading & Trailing Only"

    var id: String { rawValue }
}

enum AudioNormalizationMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case none = "Off"
    case ebuR128 = "EBU R128 (LUFS)"
    case peak = "Peak Normalization"

    var id: String { rawValue }
}

enum AudioNoiseReductionLevel: String, Sendable, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case light = "Light"
    case moderate = "Moderate"
    case aggressive = "Aggressive"

    var id: String { rawValue }

    var nrAmountDB: Double {
        switch self {
        case .off: return 0
        case .light: return 8
        case .moderate: return 16
        case .aggressive: return 26
        }
    }

    var noiseFloorDB: Double {
        switch self {
        case .off: return -50
        case .light: return -45
        case .moderate: return -38
        case .aggressive: return -30
        }
    }
}

enum AudioToolboxOperation: String, Sendable, Codable, CaseIterable, Identifiable {
    case convert = "convert"
    case trim = "trim"
    case extractSegments = "extractSegments"
    case merge = "merge"
    case removeSilence = "removeSilence"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .convert: return "Convert & Process"
        case .trim: return "Trim Audio"
        case .extractSegments: return "Extract Segments"
        case .merge: return "Merge Audio Files"
        case .removeSilence: return "Detect & Trim Silence"
        }
    }
}

// MARK: - Equalizer & Edit Models

struct AudioEQBand: Identifiable, Sendable, Codable, Equatable, Hashable {
    var id: String
    var label: String
    var frequencyHz: Double
    var gainDB: Double
    var qFactor: Double

    static let defaultBands: [AudioEQBand] = [
        AudioEQBand(id: "bass", label: "Sub / Bass (80 Hz)", frequencyHz: 80, gainDB: 0, qFactor: 1.0),
        AudioEQBand(id: "low_mid", label: "Warmth (250 Hz)", frequencyHz: 250, gainDB: 0, qFactor: 1.0),
        AudioEQBand(id: "mid", label: "Midrange (1 kHz)", frequencyHz: 1000, gainDB: 0, qFactor: 1.0),
        AudioEQBand(id: "presence", label: "Presence (4 kHz)", frequencyHz: 4000, gainDB: 0, qFactor: 1.0),
        AudioEQBand(id: "air", label: "Treble (10 kHz)", frequencyHz: 10000, gainDB: 0, qFactor: 1.0)
    ]

    static let vocalClarityBands: [AudioEQBand] = [
        AudioEQBand(id: "bass", label: "Sub / Bass (80 Hz)", frequencyHz: 80, gainDB: -4, qFactor: 1.0),
        AudioEQBand(id: "low_mid", label: "Warmth (250 Hz)", frequencyHz: 250, gainDB: -2, qFactor: 1.0),
        AudioEQBand(id: "mid", label: "Midrange (1 kHz)", frequencyHz: 1000, gainDB: 1.5, qFactor: 1.0),
        AudioEQBand(id: "presence", label: "Presence (4 kHz)", frequencyHz: 4000, gainDB: 4.5, qFactor: 1.0),
        AudioEQBand(id: "air", label: "Treble (10 kHz)", frequencyHz: 10000, gainDB: 2.0, qFactor: 1.0)
    ]

    static let bassBoostBands: [AudioEQBand] = [
        AudioEQBand(id: "bass", label: "Sub / Bass (80 Hz)", frequencyHz: 80, gainDB: 6.0, qFactor: 0.9),
        AudioEQBand(id: "low_mid", label: "Warmth (250 Hz)", frequencyHz: 250, gainDB: 3.0, qFactor: 1.0),
        AudioEQBand(id: "mid", label: "Midrange (1 kHz)", frequencyHz: 1000, gainDB: 0, qFactor: 1.0),
        AudioEQBand(id: "presence", label: "Presence (4 kHz)", frequencyHz: 4000, gainDB: 0, qFactor: 1.0),
        AudioEQBand(id: "air", label: "Treble (10 kHz)", frequencyHz: 10000, gainDB: 1.0, qFactor: 1.0)
    ]
}

enum AudioEQPreset: String, CaseIterable, Sendable, Identifiable {
    case flat = "Flat"
    case vocalClarity = "Vocal Clarity"
    case bassBoost = "Bass Boost"
    case custom = "Custom"

    var id: String { rawValue }

    var bands: [AudioEQBand]? {
        switch self {
        case .flat: return AudioEQBand.defaultBands
        case .vocalClarity: return AudioEQBand.vocalClarityBands
        case .bassBoost: return AudioEQBand.bassBoostBands
        case .custom: return nil
        }
    }

    static func matching(bands: [AudioEQBand]) -> AudioEQPreset {
        if bandsMatches(bands, target: AudioEQBand.defaultBands) {
            return .flat
        }
        if bandsMatches(bands, target: AudioEQBand.vocalClarityBands) {
            return .vocalClarity
        }
        if bandsMatches(bands, target: AudioEQBand.bassBoostBands) {
            return .bassBoost
        }
        return .custom
    }

    private static func bandsMatches(_ lhs: [AudioEQBand], target: [AudioEQBand]) -> Bool {
        guard lhs.count == target.count else { return false }
        for (a, b) in zip(lhs, target) {
            if a.id != b.id
                || abs(a.frequencyHz - b.frequencyHz) > 0.001
                || abs(a.gainDB - b.gainDB) > 0.001
                || abs(a.qFactor - b.qFactor) > 0.001 {
                return false
            }
        }
        return true
    }
}

struct AudioTrimSegment: Identifiable, Sendable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var startTime: Double
    var endTime: Double
    var label: String = ""

    var duration: Double {
        max(0, endTime - startTime)
    }

    var isValid: Bool {
        startTime >= 0 && endTime > startTime
    }
}

struct AudioSilenceInterval: Identifiable, Sendable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var duration: Double
}

struct AudioWaveformData: Sendable, Codable, Equatable {
    let peaks: [Float]
    let rms: [Float]
    let duration: Double
    let sampleRate: Int
    let channels: Int
}

struct AudioLoudnessMeasurement: Sendable, Codable, Equatable {
    let integratedLUFS: Double?
    let maxVolumeDB: Double?
    let meanVolumeDB: Double?
    let truePeakDBTP: Double?
    var loudnessRangeLU: Double? = nil
    var thresholdLUFS: Double? = nil
    var shortTermMaxLUFS: Double? = nil
    var momentaryMaxLUFS: Double? = nil
    var loudnormMeasuredInputI: Double? = nil
    var loudnormMeasuredInputTP: Double? = nil
    var loudnormMeasuredInputLRA: Double? = nil
    var loudnormMeasuredInputThresh: Double? = nil
    var loudnormTargetOffset: Double? = nil
    var normalizationTypeUsed: String? = nil
    var predictedOutputI: Double? = nil
    var predictedOutputTP: Double? = nil
}

// MARK: - Unified Audio Toolbox Configuration

struct AudioToolboxConfig: Sendable, Codable, Equatable, Hashable {
    static let customOptionConfigKey = "audio_toolbox_config"
    static let customOptionOperationKey = "audio_operation"

    var operation: AudioToolboxOperation = .convert

    // Conversion & Codec Parameters
    var codec: AudioCodecID? = nil
    var bitrateMode: AudioBitrateMode = .cbr
    var bitrateKbps: Int? = nil
    var vbrQuality: Int? = nil
    var compressionLevel: Int? = nil
    var sampleRateHz: Int? = nil
    var bitDepth: Int? = nil
    var channelMode: AudioChannelMode = .original
    var resamplerEngine: AudioResamplerEngine = .kaiserSinc
    var ditherMethod: AudioDitherMethod = .triangular

    // Stream Copy Preference
    var preferStreamCopy: Bool = false

    // Editing & Merge
    var trimStartSeconds: Double? = nil
    var trimEndSeconds: Double? = nil
    var segments: [AudioTrimSegment] = []
    var reverseAudio: Bool = false
    var mergeCrossfadeSeconds: Double = 0.0

    // Silence Removal
    var removeSilence: Bool = false
    var silenceThresholdDB: Double = -45.0
    var silenceMinDurationSeconds: Double = 0.5
    var silenceTrimScope: AudioSilenceTrimScope = .all

    // Adjustments & Time/Pitch
    var volumeGainDB: Double = 0.0
    var fadeInSeconds: Double = 0.0
    var fadeOutSeconds: Double = 0.0
    var speedMultiplier: Double = 1.0
    var pitchSemitones: Double = 0.0

    // Effects & Spatial / Channels
    var eqBands: [AudioEQBand] = AudioEQBand.defaultBands
    var activeEQPreset: AudioEQPreset {
        get { AudioEQPreset.matching(bands: eqBands) }
        set {
            if let bands = newValue.bands {
                eqBands = bands
            }
        }
    }
    var highPassHz: Double? = nil
    var lowPassHz: Double? = nil
    var compressorEnabled: Bool = false
    var compressorThresholdDB: Double = -18.0
    var compressorRatio: Double = 4.0
    var limiterEnabled: Bool = false
    var limiterCeilingDB: Double = -1.0
    var normalizationMode: AudioNormalizationMode = .none
    var targetLUFS: Double = -14.0
    var targetTruePeakDB: Double = -1.0
    var peakNormalizeTargetDB: Double = -1.0
    var channelBalance: Double = 0.0   // -1.0 (full left) ... +1.0 (full right)
    var stereoWidth: Double = 1.0      // 0.0 (narrow/mono) ... 2.0 (wide)
    var swapChannels: Bool = false
    var noiseReduction: AudioNoiseReductionLevel = .off
    var declickEnabled: Bool = false

    /// Whether any signal-processing filter is requested (prevents stream copy).
    var requiresAudioFilterProcessing: Bool {
        if operation == .removeSilence || removeSilence || reverseAudio {
            return true
        }
        if abs(volumeGainDB) > 0.01 || fadeInSeconds > 0.01 || fadeOutSeconds > 0.01 {
            return true
        }
        if abs(speedMultiplier - 1.0) > 0.005 || abs(pitchSemitones) > 0.05 {
            return true
        }
        if eqBands.contains(where: { abs($0.gainDB) > 0.05 }) {
            return true
        }
        if let hp = highPassHz, hp > 10 { return true }
        if let lp = lowPassHz, lp > 100 { return true }
        if compressorEnabled || limiterEnabled || normalizationMode != .none {
            return true
        }
        if abs(channelBalance) > 0.01 || abs(stereoWidth - 1.0) > 0.01 || swapChannels {
            return true
        }
        if noiseReduction != .off || declickEnabled {
            return true
        }
        return false
    }

    var hasTrimWindow: Bool {
        if let s = trimStartSeconds, s > 0 { return true }
        if let e = trimEndSeconds, e > 0 { return true }
        return false
    }

    /// Resolves effective AudioCodecID considering explicit config, m4a_lossless legacy flag, and container default.
    func resolvedCodec(for outputFormat: FileFormat, legacyLosslessM4A: Bool = false) -> AudioCodecID {
        if preferStreamCopy {
            return .streamCopy
        }
        if let explicit = codec {
            return explicit
        }
        if outputFormat == .m4a && legacyLosslessM4A {
            return .alac
        }
        return AudioCodecRegistry.defaultCodec(for: outputFormat)
    }

    // MARK: - ConversionOptions Serialization

    func applying(to options: ConversionOptions) -> ConversionOptions {
        var copy = options
        var custom = copy.customOptions
        custom[Self.customOptionOperationKey] = operation.rawValue
        if let data = try? JSONEncoder().encode(self),
           let json = String(data: data, encoding: .utf8) {
            custom[Self.customOptionConfigKey] = json
        }
        if let explicitCodec = codec {
            custom["audio_codec"] = explicitCodec.rawValue
        } else {
            custom.removeValue(forKey: "audio_codec")
        }
        if let sr = sampleRateHz {
            custom["audio_sample_rate"] = String(sr)
        } else {
            custom.removeValue(forKey: "audio_sample_rate")
        }
        if let br = bitrateKbps {
            custom["audio_bitrate_kbps"] = String(br)
        } else {
            custom.removeValue(forKey: "audio_bitrate_kbps")
        }
        custom["audio_bitrate_mode"] = bitrateMode.rawValue
        copy.customOptions = custom
        return copy
    }

    static func from(options: ConversionOptions, outputFormat: FileFormat? = nil) -> AudioToolboxConfig {
        let custom = options.customOptions
        let hasExplicitAudioToolboxConfig = (custom[customOptionConfigKey] != nil)
        var config: AudioToolboxConfig
        if let json = custom[customOptionConfigKey],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AudioToolboxConfig.self, from: data) {
            config = decoded
        } else {
            config = AudioToolboxConfig()
        }

        if let opStr = custom[customOptionOperationKey],
           let op = AudioToolboxOperation(rawValue: opStr) {
            config.operation = op
        }
        if let codecStr = custom["audio_codec"],
           let c = AudioCodecID(rawValue: codecStr) {
            config.codec = c
        }
        if custom["audio_stream_copy"] == "true" {
            config.preferStreamCopy = true
            config.codec = .streamCopy
        }
        if let modeStr = custom["audio_bitrate_mode"],
           let mode = AudioBitrateMode(rawValue: modeStr) {
            config.bitrateMode = mode
        }
        if let brStr = custom["audio_bitrate_kbps"], let br = Int(brStr) {
            config.bitrateKbps = br
        }
        if let vbrStr = custom["audio_vbr_quality"], let q = Int(vbrStr) {
            config.vbrQuality = q
        }
        if let srStr = custom["audio_sample_rate"], let sr = Int(srStr) {
            config.sampleRateHz = sr
        }
        if let bdStr = custom["audio_bit_depth"], let bd = Int(bdStr) {
            config.bitDepth = bd
        }
        if let chStr = custom["audio_channels"], let ch = Int(chStr) {
            switch ch {
            case 1: config.channelMode = .mono
            case 2: config.channelMode = .stereo
            case 3: config.channelMode = .surround21
            case 6: config.channelMode = .surround51
            case 8: config.channelMode = .surround71
            default: break
            }
        }

        if !hasExplicitAudioToolboxConfig
            && custom["audio_bitrate_mode"] == nil
            && custom["audio_bitrate_kbps"] == nil {
            let legacyLosslessM4A = (custom["m4a_lossless"] == "true")
            let resolvedCodec: AudioCodecID?
            if config.preferStreamCopy {
                resolvedCodec = .streamCopy
            } else if let outputFormat {
                resolvedCodec = config.resolvedCodec(for: outputFormat, legacyLosslessM4A: legacyLosslessM4A)
            } else {
                resolvedCodec = config.codec
            }
            if let resolvedCodec, AudioCodecRegistry.spec(for: resolvedCodec).supportsVBR {
                config.bitrateMode = .vbr
            } else {
                config.bitrateMode = .cbr
            }
        }
        return config
    }
}

// MARK: - Validation

struct AudioValidationResult: Sendable, Equatable {
    let errors: [String]
    let warnings: [String]

    var isValid: Bool { errors.isEmpty }
}

enum AudioConversionValidator {

    static func validate(
        config: AudioToolboxConfig,
        outputFormat: FileFormat,
        sourceInfo: MediaInfo? = nil,
        legacyLosslessM4A: Bool = false
    ) -> AudioValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        guard outputFormat.category == .audio else {
            errors.append("Target format \(outputFormat.displayName) is not an audio format.")
            return AudioValidationResult(errors: errors, warnings: warnings)
        }

        let effectiveCodec = config.resolvedCodec(for: outputFormat, legacyLosslessM4A: legacyLosslessM4A)
        let supportedForContainer = AudioCodecRegistry.supportedCodecs(for: outputFormat)
        if !supportedForContainer.contains(effectiveCodec) {
            errors.append("\(effectiveCodec.displayName) is not supported in .\(outputFormat.fileExtension) containers.")
        }

        // Stream Copy validation
        if effectiveCodec == .streamCopy {
            if config.requiresAudioFilterProcessing {
                errors.append("Stream Copy cannot be used when audio filters, EQ, gain, speed, pitch, normalization, or fade effects are active.")
            }
            if config.sampleRateHz != nil || config.bitDepth != nil || config.channelMode != .original {
                errors.append("Stream Copy cannot change sample rate, bit depth, or channel layout.")
            }
            if config.operation == .merge {
                errors.append("Merging multiple audio files requires re-encoding unless all inputs are identical.")
            }
            if let srcCodec = sourceInfo?.primaryAudioStream?.codecName {
                if !AudioCodecRegistry.isStreamCopyCompatible(sourceCodecName: srcCodec, targetFormat: outputFormat) {
                    errors.append("Source codec '\(srcCodec)' cannot be stream-copied into .\(outputFormat.fileExtension).")
                }
            }
        }

        let spec = AudioCodecRegistry.spec(for: effectiveCodec)

        // Sample Rate validation
        if let sr = config.sampleRateHz, effectiveCodec != .streamCopy {
            if !spec.supportedSampleRates.isEmpty && !spec.supportedSampleRates.contains(sr) {
                errors.append("\(effectiveCodec.shortLabel) does not support \(sr) Hz sample rate. Supported: \(spec.supportedSampleRates.map { "\($0) Hz" }.joined(separator: ", ")).")
            }
        }

        // Bit depth validation
        if let bd = config.bitDepth, effectiveCodec != .streamCopy {
            if let fixed = spec.fixedBitDepth {
                if bd != fixed {
                    errors.append("\(effectiveCodec.displayName) has a fixed \(fixed)-bit depth.")
                }
            } else if spec.supportedBitDepths.isEmpty {
                errors.append("\(effectiveCodec.shortLabel) is a compressed format without configurable PCM bit depth.")
            } else if !spec.supportedBitDepths.contains(bd) {
                errors.append("\(effectiveCodec.shortLabel) does not support \(bd)-bit output. Supported: \(spec.supportedBitDepths.map { "\($0)-bit" }.joined(separator: ", ")).")
            }
        }

        // Channel layout & Downmix validation
        if let targetCh = config.channelMode.channelCount, effectiveCodec != .streamCopy {
            if !spec.supportedChannelCounts.isEmpty && !spec.supportedChannelCounts.contains(targetCh) {
                errors.append("\(effectiveCodec.shortLabel) does not support \(targetCh) channels. Allowed: \(spec.supportedChannelCounts.map(String.init).joined(separator: ", ")).")
            } else if let srcCh = sourceInfo?.primaryAudioStream?.channels, srcCh > targetCh {
                warnings.append("Channel downmix: \(srcCh) ch → \(targetCh) ch folds surround channels during encoding.")
            }
        }

        // Lossy-to-lossy generational quality warning
        if effectiveCodec != .streamCopy,
           !effectiveCodec.isLossless,
           let srcCodec = sourceInfo?.primaryAudioStream?.codecName.lowercased(),
           ["mp3", "aac", "opus", "vorbis", "ac3", "eac3", "dts", "dca", "wmav1", "wmav2", "amr_nb", "amr_wb"].contains(srcCodec) {
            warnings.append("Re-encoding from lossy \(srcCodec.uppercased()) to lossy \(effectiveCodec.shortLabel) introduces generational quality loss.")
        }

        // Merge crossfade bounds
        if config.mergeCrossfadeSeconds < 0 || config.mergeCrossfadeSeconds > 10 {
            errors.append("Merge crossfade duration must be between 0 and 10 seconds.")
        }

        // Cover art container capability notice
        if let srcInfo = sourceInfo, srcInfo.hasVideo,
           let srcFmt = FileDetector.detectFormat(url: srcInfo.url), srcFmt.category == .audio,
           !AudioCodecRegistry.supportsCoverArt(for: outputFormat) {
            warnings.append("Target container .\(outputFormat.fileExtension) does not support embedded album artwork; cover art stream will be omitted.")
        }

        // Bitrate & VBR validation
        if config.bitrateMode == .vbr {
            if !spec.supportsVBR && effectiveCodec != .streamCopy {
                errors.append("\(effectiveCodec.shortLabel) does not support VBR mode; select CBR.")
            }
            if let q = config.vbrQuality, let range = spec.vbrQualityRange, !range.contains(q) {
                errors.append("VBR quality \(q) is out of allowed range \(range.lowerBound)...\(range.upperBound) for \(effectiveCodec.shortLabel).")
            }
        } else if let br = config.bitrateKbps {
            if !spec.supportsCBR && effectiveCodec != .streamCopy {
                warnings.append("\(effectiveCodec.shortLabel) is lossless/fixed-mode and ignores custom bitrate.")
            } else if !spec.bitrateOptionsKbps.isEmpty && (br < spec.bitrateOptionsKbps.first! || br > spec.bitrateOptionsKbps.last!) {
                errors.append("Bitrate \(br) kbps is outside \(spec.bitrateOptionsKbps.first!)–\(spec.bitrateOptionsKbps.last!) kbps for \(effectiveCodec.shortLabel).")
            }
        }

        // Trim / Segment validation
        let srcDuration = sourceInfo?.duration
        if let start = config.trimStartSeconds {
            if start < 0 {
                errors.append("Trim start time cannot be negative.")
            }
            if let dur = srcDuration, dur > 0, start >= dur {
                errors.append("Trim start time (\(String(format: "%.2f", start))s) exceeds audio duration (\(String(format: "%.2f", dur))s).")
            }
        }
        if let end = config.trimEndSeconds {
            if end <= 0 {
                errors.append("Trim end time must be greater than zero.")
            }
            if let start = config.trimStartSeconds, end <= start {
                errors.append("Trim end time must be greater than start time.")
            }
            if let dur = srcDuration, dur > 0, end > dur + 0.05 {
                warnings.append("Trim end time exceeds source duration; output will end at \(String(format: "%.2f", dur))s.")
            }
        }

        if config.operation == .extractSegments {
            if config.segments.isEmpty {
                errors.append("Add at least one valid segment to extract.")
            } else {
                for (index, seg) in config.segments.enumerated() {
                    if !seg.isValid {
                        errors.append("Segment \(index + 1) has an invalid range (\(seg.startTime)s – \(seg.endTime)s).")
                    } else if let dur = srcDuration, dur > 0, seg.startTime >= dur {
                        errors.append("Segment \(index + 1) starts past the end of the file.")
                    }
                }
            }
        }

        // Speed / Pitch bounds
        if config.speedMultiplier < 0.25 || config.speedMultiplier > 4.0 {
            errors.append("Playback speed must be between 0.25× and 4.0×.")
        }
        if config.pitchSemitones < -12.0 || config.pitchSemitones > 12.0 {
            errors.append("Pitch shift must be between -12 and +12 semitones.")
        }
        if let hp = config.highPassHz, let lp = config.lowPassHz, hp >= lp {
            errors.append("High-pass frequency (\(Int(hp)) Hz) must be lower than low-pass frequency (\(Int(lp)) Hz).")
        }

        return AudioValidationResult(errors: errors, warnings: warnings)
    }
}

import Foundation

// MARK: - Audio Codec Identifier

enum AudioCodecID: String, Sendable, Codable, CaseIterable, Identifiable {
    case streamCopy = "copy"
    case aac = "aac"
    case aacAT = "aac_at"
    case alac = "alac"
    case mp3 = "libmp3lame"
    case flac = "flac"
    case pcmS16LE = "pcm_s16le"
    case pcmS24LE = "pcm_s24le"
    case pcmS32LE = "pcm_s32le"
    case pcmF32LE = "pcm_f32le"
    case pcmS16BE = "pcm_s16be"
    case pcmS24BE = "pcm_s24be"
    case pcmS32BE = "pcm_s32be"
    case opus = "libopus"
    case vorbis = "vorbis"
    case ac3 = "ac3"
    case eac3 = "eac3"
    case dts = "dca"
    case wmav2 = "wmav2"
    case wavpack = "wavpack"

    var id: String { rawValue }

    var ffmpegEncoderName: String { rawValue }

    var displayName: String {
        switch self {
        case .streamCopy: return "Stream Copy (No Re-encode)"
        case .aac: return "AAC-LC (FFmpeg)"
        case .aacAT: return "AAC-LC (Apple AudioToolbox)"
        case .alac: return "ALAC (Apple Lossless)"
        case .mp3: return "MP3 (LAME)"
        case .flac: return "FLAC (Free Lossless)"
        case .pcmS16LE: return "PCM 16-bit LE"
        case .pcmS24LE: return "PCM 24-bit LE"
        case .pcmS32LE: return "PCM 32-bit LE"
        case .pcmF32LE: return "PCM 32-bit Float LE"
        case .pcmS16BE: return "PCM 16-bit BE"
        case .pcmS24BE: return "PCM 24-bit BE"
        case .pcmS32BE: return "PCM 32-bit BE"
        case .opus: return "Opus (libopus)"
        case .vorbis: return "Vorbis (Native Experimental)"
        case .ac3: return "Dolby Digital (AC-3)"
        case .eac3: return "Dolby Digital Plus (E-AC-3)"
        case .dts: return "DTS (Coherent Acoustics)"
        case .wmav2: return "Windows Media Audio v2"
        case .wavpack: return "WavPack"
        }
    }

    var shortLabel: String {
        switch self {
        case .streamCopy: return "Copy"
        case .aac: return "AAC"
        case .aacAT: return "AAC (AT)"
        case .alac: return "ALAC"
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        case .pcmS16LE, .pcmS16BE: return "PCM 16-bit"
        case .pcmS24LE, .pcmS24BE: return "PCM 24-bit"
        case .pcmS32LE, .pcmS32BE: return "PCM 32-bit"
        case .pcmF32LE: return "PCM 32f"
        case .opus: return "Opus"
        case .vorbis: return "Vorbis"
        case .ac3: return "AC-3"
        case .eac3: return "E-AC-3"
        case .dts: return "DTS"
        case .wmav2: return "WMA v2"
        case .wavpack: return "WavPack"
        }
    }

    var isLossless: Bool {
        switch self {
        case .alac, .flac, .pcmS16LE, .pcmS24LE, .pcmS32LE, .pcmF32LE,
             .pcmS16BE, .pcmS24BE, .pcmS32BE, .wavpack:
            return true
        case .streamCopy, .aac, .aacAT, .mp3, .opus, .vorbis, .ac3, .eac3, .dts, .wmav2:
            return false
        }
    }

    var isPCM: Bool {
        switch self {
        case .pcmS16LE, .pcmS24LE, .pcmS32LE, .pcmF32LE, .pcmS16BE, .pcmS24BE, .pcmS32BE:
            return true
        default:
            return false
        }
    }

    var requiresExperimentalFlag: Bool {
        self == .vorbis || self == .dts
    }
}

// MARK: - Audio Codec Capability Specification

struct AudioCodecSpec: Sendable, Equatable {
    let codec: AudioCodecID
    let supportedOutputContainers: [FileFormat]
    let supportsCBR: Bool
    let supportsVBR: Bool
    let bitrateOptionsKbps: [Int]
    let defaultBitrateKbps: Int?
    /// Inclusive VBR quality scale (`0...9` for LAME lower-is-better, `0...14` or `1...10` depending on codec)
    let vbrQualityRange: ClosedRange<Int>?
    let vbrHigherIsBetter: Bool
    let vbrLabel: String?
    /// Supported explicit sample rates in Hz (empty means source / container default)
    let supportedSampleRates: [Int]
    /// Supported bit depths (e.g. 16, 24, 32) if configurable independently of codec
    let supportedBitDepths: [Int]
    /// Fixed implied bit depth for explicit PCM codecs
    let fixedBitDepth: Int?
    /// Allowed channel counts
    let supportedChannelCounts: [Int]
    let supportsCompressionLevel: Bool
    let compressionLevelRange: ClosedRange<Int>?
    let note: String?
}

// MARK: - Registry & Validation

enum AudioCodecRegistry {

    static let standardSampleRates: [Int] = [22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000]

    static func supportsCoverArt(for format: FileFormat) -> Bool {
        [.mp3, .m4a, .m4b, .alac, .flac].contains(format)
    }

    static let allSpecs: [AudioCodecID: AudioCodecSpec] = [
        .aac: AudioCodecSpec(
            codec: .aac,
            supportedOutputContainers: [.m4a, .m4b, .m4r, .aac, .mka],
            supportsCBR: true,
            supportsVBR: false,
            bitrateOptionsKbps: [64, 96, 128, 160, 192, 256, 320],
            defaultBitrateKbps: 192,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [22050, 32000, 44100, 48000, 88200, 96000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 6],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Standard FFmpeg AAC-LC CBR encoder."
        ),
        .aacAT: AudioCodecSpec(
            codec: .aacAT,
            supportedOutputContainers: [.m4a, .m4b, .m4r, .aac, .mka],
            supportsCBR: true,
            supportsVBR: true,
            bitrateOptionsKbps: [64, 96, 128, 160, 192, 256, 320],
            defaultBitrateKbps: 192,
            vbrQualityRange: 0...14,
            vbrHigherIsBetter: false,
            vbrLabel: "Quality (0 best – 14 smallest)",
            supportedSampleRates: [32000, 44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 6],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Hardware-accelerated macOS Apple AudioToolbox AAC encoder (supports VBR)."
        ),
        .alac: AudioCodecSpec(
            codec: .alac,
            supportedOutputContainers: [.m4a, .alac],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [44100, 48000, 88200, 96000, 192000],
            supportedBitDepths: [16, 24],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 6],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Apple Lossless (stored in M4A/MP4 container)."
        ),
        .mp3: AudioCodecSpec(
            codec: .mp3,
            supportedOutputContainers: [.mp3, .mka],
            supportsCBR: true,
            supportsVBR: true,
            bitrateOptionsKbps: [64, 96, 128, 160, 192, 256, 320],
            defaultBitrateKbps: 192,
            vbrQualityRange: 0...9,
            vbrHigherIsBetter: false,
            vbrLabel: "LAME VBR (V0 best – V9 smallest)",
            supportedSampleRates: [32000, 44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "MP3 supports Mono or Stereo at 32 / 44.1 / 48 kHz."
        ),
        .flac: AudioCodecSpec(
            codec: .flac,
            supportedOutputContainers: [.flac, .ogg, .mka],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000],
            supportedBitDepths: [16, 24],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: true,
            compressionLevelRange: 0...8,
            note: "Lossless compression (level 0 fastest – 8 smallest) with 16-bit or 24-bit output."
        ),
        .pcmS16LE: AudioCodecSpec(
            codec: .pcmS16LE,
            supportedOutputContainers: [.wav, .caf, .mka],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [],
            fixedBitDepth: 16,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Uncompressed 16-bit Little-Endian linear PCM."
        ),
        .pcmS24LE: AudioCodecSpec(
            codec: .pcmS24LE,
            supportedOutputContainers: [.wav, .caf, .mka],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [],
            fixedBitDepth: 24,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Uncompressed 24-bit studio linear PCM."
        ),
        .pcmS32LE: AudioCodecSpec(
            codec: .pcmS32LE,
            supportedOutputContainers: [.wav, .caf, .mka],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [],
            fixedBitDepth: 32,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Uncompressed 32-bit integer linear PCM."
        ),
        .pcmF32LE: AudioCodecSpec(
            codec: .pcmF32LE,
            supportedOutputContainers: [.wav, .caf],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [],
            fixedBitDepth: 32,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Uncompressed 32-bit IEEE float PCM."
        ),
        .pcmS16BE: AudioCodecSpec(
            codec: .pcmS16BE,
            supportedOutputContainers: [.aiff, .au],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [],
            fixedBitDepth: 16,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Uncompressed 16-bit Big-Endian PCM for AIFF / AU."
        ),
        .pcmS24BE: AudioCodecSpec(
            codec: .pcmS24BE,
            supportedOutputContainers: [.aiff, .au],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [],
            fixedBitDepth: 24,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Uncompressed 24-bit Big-Endian PCM for AIFF / AU."
        ),
        .pcmS32BE: AudioCodecSpec(
            codec: .pcmS32BE,
            supportedOutputContainers: [.aiff, .au],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [],
            fixedBitDepth: 32,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Uncompressed 32-bit Big-Endian PCM for AIFF / AU."
        ),
        .opus: AudioCodecSpec(
            codec: .opus,
            supportedOutputContainers: [.opus, .ogg, .mka],
            supportsCBR: true,
            supportsVBR: true,
            bitrateOptionsKbps: [32, 64, 96, 128, 160, 192, 256, 320, 480],
            defaultBitrateKbps: 160,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 3, 6, 8],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Opus encodes internally at 48 kHz and supports both VBR and CBR."
        ),
        .vorbis: AudioCodecSpec(
            codec: .vorbis,
            supportedOutputContainers: [.ogg, .mka],
            supportsCBR: true,
            supportsVBR: true,
            bitrateOptionsKbps: [64, 96, 128, 160, 192, 256, 320],
            defaultBitrateKbps: 192,
            vbrQualityRange: 1...10,
            vbrHigherIsBetter: true,
            vbrLabel: "Quality (1–10, higher = better)",
            supportedSampleRates: [44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Bundled FFmpeg native Vorbis encoder (experimental; requires stereo/mono)."
        ),
        .ac3: AudioCodecSpec(
            codec: .ac3,
            supportedOutputContainers: [.ac3, .mka],
            supportsCBR: true,
            supportsVBR: false,
            bitrateOptionsKbps: [192, 256, 384, 448, 640],
            defaultBitrateKbps: 384,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [32000, 44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 6],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Dolby Digital AC-3 (up to 640 kbps, 5.1 surround supported)."
        ),
        .eac3: AudioCodecSpec(
            codec: .eac3,
            supportedOutputContainers: [.eac3, .mka],
            supportsCBR: true,
            supportsVBR: false,
            bitrateOptionsKbps: [192, 256, 384, 448, 640, 768],
            defaultBitrateKbps: 448,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [32000, 44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 6],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Dolby Digital Plus E-AC-3 (5.1 surround supported)."
        ),
        .dts: AudioCodecSpec(
            codec: .dts,
            supportedOutputContainers: [.dts, .mka],
            supportsCBR: true,
            supportsVBR: false,
            bitrateOptionsKbps: [384, 512, 768, 1024, 1536],
            defaultBitrateKbps: 768,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2, 6],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Bundled FFmpeg native DCA encoder (44.1 / 48 kHz)."
        ),
        .wmav2: AudioCodecSpec(
            codec: .wmav2,
            supportedOutputContainers: [.wma],
            supportsCBR: true,
            supportsVBR: false,
            bitrateOptionsKbps: [64, 96, 128, 192, 256, 320],
            defaultBitrateKbps: 192,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Windows Media Audio v2 (Mono / Stereo only)."
        ),
        .wavpack: AudioCodecSpec(
            codec: .wavpack,
            supportedOutputContainers: [.wv, .mka],
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: standardSampleRates,
            supportedBitDepths: [16, 24, 32],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2],
            supportsCompressionLevel: true,
            compressionLevelRange: 0...8,
            note: "Lossless WavPack hybrid/archival codec."
        ),
        .streamCopy: AudioCodecSpec(
            codec: .streamCopy,
            supportedOutputContainers: FileFormat.allCases.filter { $0.category == .audio },
            supportsCBR: false,
            supportsVBR: false,
            bitrateOptionsKbps: [],
            defaultBitrateKbps: nil,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: "Copies compressed bitstream directly when compatible and no audio filters are active."
        )
    ]

    static func spec(for codec: AudioCodecID) -> AudioCodecSpec {
        allSpecs[codec] ?? AudioCodecSpec(
            codec: codec,
            supportedOutputContainers: [.mp3],
            supportsCBR: true,
            supportsVBR: false,
            bitrateOptionsKbps: [128, 192, 256, 320],
            defaultBitrateKbps: 192,
            vbrQualityRange: nil,
            vbrHigherIsBetter: true,
            vbrLabel: nil,
            supportedSampleRates: [44100, 48000],
            supportedBitDepths: [],
            fixedBitDepth: nil,
            supportedChannelCounts: [1, 2],
            supportsCompressionLevel: false,
            compressionLevelRange: nil,
            note: nil
        )
    }

    static func defaultCodec(for outputFormat: FileFormat) -> AudioCodecID {
        switch outputFormat {
        case .mp3: return .mp3
        case .wav: return .pcmS16LE
        case .flac: return .flac
        case .m4a, .m4b, .m4r, .aac: return .aac
        case .alac: return .alac
        case .ogg, .opus: return .opus
        case .aiff, .au: return .pcmS16BE
        case .caf: return .pcmS16LE
        case .ac3: return .ac3
        case .eac3: return .eac3
        case .dts: return .dts
        case .wma: return .wmav2
        case .wv: return .wavpack
        case .mka: return .flac
        default: return .mp3
        }
    }

    /// Authoritative list of codecs that bundled FFmpeg supports for the given target audio container.
    static func supportedCodecs(for outputFormat: FileFormat) -> [AudioCodecID] {
        switch outputFormat {
        case .mp3:
            return [.mp3, .streamCopy]
        case .m4a, .m4b:
            return [.aac, .aacAT, .alac, .streamCopy]
        case .m4r:
            return [.aac, .aacAT, .streamCopy]
        case .aac:
            return [.aac, .aacAT, .streamCopy]
        case .alac:
            return [.alac, .streamCopy]
        case .flac:
            return [.flac, .streamCopy]
        case .wav:
            return [.pcmS16LE, .pcmS24LE, .pcmS32LE, .pcmF32LE, .streamCopy]
        case .caf:
            return [.pcmS16LE, .pcmS24LE, .pcmS32LE, .pcmF32LE, .alac, .aac, .streamCopy]
        case .aiff, .au:
            return [.pcmS16BE, .pcmS24BE, .pcmS32BE, .streamCopy]
        case .opus:
            return [.opus, .streamCopy]
        case .ogg:
            return [.opus, .vorbis, .flac, .streamCopy]
        case .ac3:
            return [.ac3, .streamCopy]
        case .eac3:
            return [.eac3, .streamCopy]
        case .dts:
            return [.dts, .streamCopy]
        case .wma:
            return [.wmav2, .streamCopy]
        case .wv:
            return [.wavpack, .streamCopy]
        case .mka:
            return [.flac, .opus, .aac, .mp3, .vorbis, .ac3, .eac3, .pcmS16LE, .pcmS24LE, .streamCopy]
        default:
            return []
        }
    }

    /// Checks whether an already-encoded bitstream codec (`ffprobe` codec_name) can be stream-copied into `targetFormat`.
    static func isStreamCopyCompatible(sourceCodecName: String?, targetFormat: FileFormat) -> Bool {
        guard let raw = sourceCodecName?.lowercased() else { return false }
        switch targetFormat {
        case .mp3:
            return raw == "mp3"
        case .m4a, .m4b:
            return raw == "aac" || raw == "alac"
        case .m4r:
            return raw == "aac"
        case .aac:
            return raw == "aac"
        case .alac:
            return raw == "alac"
        case .flac:
            return raw == "flac"
        case .wav:
            return raw.hasPrefix("pcm_") && !raw.hasSuffix("be")
        case .aiff, .au:
            return raw.hasPrefix("pcm_") && (raw.hasSuffix("be") || raw == "pcm_s8" || raw == "pcm_u8")
        case .caf:
            return raw.hasPrefix("pcm_") || raw == "aac" || raw == "alac"
        case .opus:
            return raw == "opus"
        case .ogg:
            return raw == "opus" || raw == "vorbis" || raw == "flac"
        case .ac3:
            return raw == "ac3"
        case .eac3:
            return raw == "eac3"
        case .dts:
            return raw == "dts" || raw == "dca"
        case .wma:
            return raw == "wmav2" || raw == "wmav1"
        case .wv:
            return raw == "wavpack"
        case .mka:
            return true
            default:
                return false
        }
    }

    // MARK: - Runtime FFmpeg Capability Inspection

    struct RuntimeCapabilityReport: Sendable {
        let verifiedEncoders: Set<String>
        let verifiedDecoders: Set<String>
        let verifiedFilters: Set<String>
        let availableCodecs: [AudioCodecID]
        let decodeOnlyCodecs: [String]
    }

    static func inspectRuntimeCapabilities(ffmpegPath: String) async -> RuntimeCapabilityReport {
        func runQuery(_ flag: String) -> String {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ffmpegPath)
            p.arguments = ["-hide_banner", flag]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: d, encoding: .utf8) ?? ""
        }

        func parseCapabilityNames(_ output: String, kindPrefix: String) -> Set<String> {
            var set = Set<String>()
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let cols = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard cols.count >= 2, cols[0].hasPrefix(kindPrefix) else { continue }
                set.insert(String(cols[1]))
            }
            return set
        }

        let encOut = runQuery("-encoders")
        let decOut = runQuery("-decoders")
        let fltOut = runQuery("-filters")

        let encoders = parseCapabilityNames(encOut, kindPrefix: "A")
        let decoders = parseCapabilityNames(decOut, kindPrefix: "A")
        var filters = Set<String>()
        for line in fltOut.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let cols = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            if cols.count >= 3 && (cols[2].contains("->A") || cols[2].contains("A->")) {
                filters.insert(String(cols[1]))
            }
        }

        let supported = AudioCodecID.allCases.filter { $0 != .streamCopy && encoders.contains($0.ffmpegEncoderName) }
        var decodeOnly: [String] = []
        if decoders.contains("ape") && !encoders.contains("ape") { decodeOnly.append("ape") }
        if (decoders.contains("amr_nb") || decoders.contains("amrnb")) && !encoders.contains("libopencore_amrnb") {
            decodeOnly.append("amr")
        }

        return RuntimeCapabilityReport(
            verifiedEncoders: encoders,
            verifiedDecoders: decoders,
            verifiedFilters: filters,
            availableCodecs: supported,
            decodeOnlyCodecs: decodeOnly
        )
    }
}

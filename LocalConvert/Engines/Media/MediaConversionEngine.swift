import Foundation
import os.log

// MARK: - Media Conversion Engine

final class MediaConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "MediaEngine"
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "MediaEngine")
    let provider: any FFmpegProvider
    
    init(provider: any FFmpegProvider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)) {
        self.provider = provider
    }
    
    // MARK: - Supported Formats
    
    private static let audioInputs: Set<FileFormat> = [
        .mp3, .wav, .flac, .aac, .m4a, .m4b, .ogg, .opus, .aiff, .caf, .alac,
        .ac3, .eac3, .dts, .wma, .au, .wv, .mka, .amr, .ape
    ]
    
    private static let audioOutputs: Set<FileFormat> = [
        .mp3, .wav, .flac, .aac, .m4a, .m4b, .ogg, .opus, .aiff, .caf, .alac,
        .ac3, .eac3, .dts, .wma, .au, .wv, .mka
    ]
    
    private static let videoInputs: Set<FileFormat> = [
        .mp4, .mov, .mkv, .webm, .avi, .wmv, .asf, .m4v, .threeGP, .threeG2,
        .mts, .m2ts, .mpg, .ts, .flv, .f4v, .vob, .m2v, .ogv
    ]
    
    private static let videoOutputs: Set<FileFormat> = [
        .mp4, .mov, .mkv, .webm, .avi, .wmv, .asf, .m4v, .threeGP, .threeG2,
        .mpg, .ts, .flv, .f4v, .vob, .m2v
    ]
    
    var supportedInputFormats: Set<FileFormat> {
        Self.audioInputs
            .union(Self.videoInputs)
            .union([.gif, .apng])
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        Self.audioOutputs
            .union(Self.videoOutputs)
            .union([.gif, .apng])
    }
    
    // MARK: - Capabilities
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        availableOutputFormats(for: input).contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        
        var formats = Set<FileFormat>()
        let inCat = input.category
        
        if inCat == .audio {
            formats.formUnion(Self.audioOutputs)
        } else if inCat == .video {
            formats.formUnion(Self.videoOutputs)
            formats.formUnion(Self.audioOutputs)
            formats.insert(.gif)
            formats.insert(.apng)
        } else if input == .gif || input == .apng {
            formats.formUnion(Self.videoOutputs)
        }
        
        formats.remove(input)
        return formats
    }
    
    // MARK: - Option Descriptors
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        optionDescriptors(from: input, to: output, allowSameFormat: false)
    }

    func optionDescriptors(from input: FileFormat, to output: FileFormat, allowSameFormat: Bool) -> [ConversionOptionDescriptor] {
        let routeAllowed = canConvert(from: input, to: output)
            || (allowSameFormat && input == output && supportedInputFormats.contains(input) && supportedOutputFormats.contains(output))
        guard routeAllowed else { return [] }
        var descriptors: [ConversionOptionDescriptor] = []
        
        let isVideoOutput = output.category == .video
        let isAudioOutput = output.category == .audio
        let isVideoInput = input.category == .video
        
        // Filter presets based on media type and container compatibility
        var validPresets: [ConversionPreset] = [.custom, .smallFile, .web, .maximumQuality]
        if isVideoOutput && ConversionOptions.h264AACVideoContainers.contains(output) {
            validPresets.append(.videoMaximumCompatibility)
        }
        
        if isVideoInput {
            validPresets.append(.audioOnly)
        }
        
        // Ensure uniqueness and consistent ordering
        let orderedPresets: [ConversionPreset] = ConversionPreset.allCases.filter { validPresets.contains($0) }
        
        // Smart Presets
        descriptors.append(
            ConversionOptionDescriptor(
                id: "preset",
                title: "Smart Preset",
                description: "Auto-configure settings for common use cases",
                kind: .preset(orderedPresets)
            )
        )
        
        if isVideoOutput || isAudioOutput {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "mediaQuality",
                    title: isVideoOutput ? "Video Quality" : "Audio Quality",
                    description: isVideoOutput
                        ? "Encoding quality preset (CRF)"
                        : "Audio encoding bitrate and quality preset",
                    kind: .qualityPreset([.low, .medium, .high, .maximum])
                )
            )
        }
        
        descriptors.append(
            ConversionOptionDescriptor(
                id: "preserveMetadata",
                title: "Preserve Metadata",
                description: "Keep original media tags and metadata",
                kind: .toggle(title: "Preserve Metadata", defaultValue: true)
            )
        )
        
        if isVideoOutput {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "targetFileSizeMB",
                    title: "Target File Size",
                    description: "Constrain output size by adjusting bitrate",
                    kind: .targetSize([nil, 8.0, 25.0, 50.0, 100.0, 500.0])
                )
            )
        } else if output.category == .audio {
            let codecs = AudioCodecRegistry.supportedCodecs(for: output)
            if !codecs.isEmpty {
                let codecChoices = [OptionChoice(value: "", label: "Auto (\(AudioCodecRegistry.defaultCodec(for: output).shortLabel))")]
                    + codecs.map { OptionChoice(value: $0.rawValue, label: $0.displayName) }
                descriptors.append(
                    ConversionOptionDescriptor(
                        id: "audio_codec",
                        title: "Audio Codec",
                        description: "Encoder or stream copy mode for .\(output.fileExtension)",
                        kind: .picker(choices: codecChoices, defaultValue: "")
                    )
                )
            }

            let defaultCodec = AudioCodecRegistry.defaultCodec(for: output)
            let spec = AudioCodecRegistry.spec(for: defaultCodec)
            if !spec.supportedSampleRates.isEmpty {
                let rateChoices = [OptionChoice(value: "", label: "Source Rate")]
                    + spec.supportedSampleRates.map { rate in
                        let khz = (rate % 1000 == 0) ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000.0)
                        return OptionChoice(value: "\(rate)", label: khz)
                    }
                descriptors.append(
                    ConversionOptionDescriptor(
                        id: "audio_sample_rate",
                        title: "Sample Rate",
                        description: "Target audio sampling frequency",
                        kind: .picker(choices: rateChoices, defaultValue: "")
                    )
                )
            }

            let channelChoices: [OptionChoice] = [
                OptionChoice(value: "", label: "Original"),
                OptionChoice(value: "1", label: "Mono (1 ch)"),
                OptionChoice(value: "2", label: "Stereo (2 ch)")
            ] + (spec.supportedChannelCounts.contains(6) ? [OptionChoice(value: "6", label: "Surround 5.1 (6 ch)")] : [])
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "audio_channels",
                    title: "Channels",
                    description: "Target audio channel configuration",
                    kind: .picker(choices: channelChoices, defaultValue: "")
                )
            )

            if output == .m4a {
                descriptors.append(
                    ConversionOptionDescriptor(
                        id: "m4a_lossless",
                        title: "Apple Lossless (ALAC)",
                        description: "Encode lossless ALAC audio inside M4A container instead of AAC",
                        kind: .toggle(title: "Encode as Apple Lossless (ALAC)", defaultValue: false)
                    )
                )
            }
        }
        
        return descriptors
    }
    
    // MARK: - Availability
    
    func isAvailable() async -> Bool {
        await provider.isAvailable()
    }
    
    // MARK: - Conversion Execution
    
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard !inputs.isEmpty else { throw ConversionError.invalidInput("No inputs") }
        return try await provider.convertBatch(
            inputs: inputs,
            to: outputFormat,
            outputDirectory: outputDirectory,
            options: options,
            progress: progress
        )
    }
}

import Foundation
import os.log

// MARK: - Media Conversion Engine

final class MediaConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "MediaEngine"
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "MediaEngine")
    let provider: any FFmpegProvider
    
    init(provider: any FFmpegProvider = BundledFFmpegProvider(fallbackToSystem: true)) {
        self.provider = provider
    }
    
    // MARK: - Supported Formats
    
    var supportedInputFormats: Set<FileFormat> {
        [
            // Audio
            .mp3, .wav, .flac, .aac, .m4a, .ogg, .opus, .aiff, .caf, .alac, .ac3,
            // Video
            .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v, .threeGP, .mts, .m2ts,
            // Animated Image
            .gif
        ]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [
            // Audio
            .mp3, .wav, .flac, .m4a, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3,
            // Video
            .mp4, .mov, .mkv, .webm, .avi,
            // Animated Image
            .gif
        ]
    }
    
    // MARK: - Capabilities
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        guard supportedInputFormats.contains(input),
              supportedOutputFormats.contains(output),
              input != output else {
            return false
        }
        
        let inCat = input.category
        let outCat = output.category
        
        // 1. Audio → Audio
        if inCat == .audio && outCat == .audio {
            return true
        }
        
        // 2. Video → Video
        if inCat == .video && outCat == .video {
            return true
        }
        
        // 3. Video → Audio (Audio extraction)
        if inCat == .video && outCat == .audio {
            return true
        }
        
        // 4. GIF → Video
        if input == .gif && outCat == .video {
            return true
        }
        
        // 5. Video → GIF
        if inCat == .video && output == .gif {
            return true
        }
        
        return false
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        
        var formats = Set<FileFormat>()
        let inCat = input.category
        
        if inCat == .audio {
            // Audio outputs
            let audioOutputs: Set<FileFormat> = [.mp3, .wav, .flac, .m4a, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3]
            formats.formUnion(audioOutputs)
        } else if inCat == .video {
            // Video outputs
            let videoOutputs: Set<FileFormat> = [.mp4, .mov, .mkv, .webm, .avi]
            formats.formUnion(videoOutputs)
            // Audio extraction outputs
            let audioOutputs: Set<FileFormat> = [.mp3, .wav, .flac, .m4a, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3]
            formats.formUnion(audioOutputs)
            // GIF output
            formats.insert(.gif)
        } else if input == .gif {
            // GIF to Video outputs
            let videoOutputs: Set<FileFormat> = [.mp4, .mov, .mkv, .webm, .avi]
            formats.formUnion(videoOutputs)
        }
        
        formats.remove(input)
        return formats
    }
    
    // MARK: - Option Descriptors
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        guard canConvert(from: input, to: output) else { return [] }
        var descriptors: [ConversionOptionDescriptor] = []
        
        let isVideoOutput = output.category == .video
        let isVideoInput = input.category == .video
        
        // Filter presets based on media type
        var validPresets: [ConversionPreset] = [.custom, .smallFile]
        if isVideoOutput {
            validPresets.append(contentsOf: [.web, .maximumQuality, .videoMaximumCompatibility])
        } else {
            validPresets.append(contentsOf: [.web, .maximumQuality])
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
        guard let input = inputs.first else { throw ConversionError.invalidInput("No inputs") }
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let finalURL = try await provider.convert(
            input: input,
            to: outputFormat,
            outputDirectory: outputDirectory,
            options: options,
            progress: progress
        )
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        
        return ConversionResult(
            outputURL: finalURL,
            outputFormat: outputFormat,
            fileSize: fileSize,
            duration: duration,
            engineName: name
        )
    }
}

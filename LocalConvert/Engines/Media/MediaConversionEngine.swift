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
            .mp3, .wav, .flac, .aac, .m4a, .ogg, .opus, .aiff,
            // Video
            .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v
        ]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [
            // Audio
            .mp3, .wav, .flac, .m4a, .aac, .ogg, .opus,
            // Video
            .mp4, .mov, .mkv, .webm, .avi
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
        
        return false
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        
        var formats = Set<FileFormat>()
        let inCat = input.category
        
        if inCat == .audio {
            // Audio outputs
            let audioOutputs: Set<FileFormat> = [.mp3, .wav, .flac, .m4a, .aac, .ogg, .opus]
            formats.formUnion(audioOutputs)
        } else if inCat == .video {
            // Video outputs
            let videoOutputs: Set<FileFormat> = [.mp4, .mov, .mkv, .webm, .avi]
            formats.formUnion(videoOutputs)
            // Audio extraction outputs
            let audioOutputs: Set<FileFormat> = [.mp3, .wav, .flac, .m4a, .aac, .ogg, .opus]
            formats.formUnion(audioOutputs)
        }
        
        formats.remove(input)
        return formats
    }
    
    // MARK: - Option Descriptors
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        guard canConvert(from: input, to: output) else { return [] }
        var descriptors: [ConversionOptionDescriptor] = []
        
        let isVideoOutput = output.category == .video
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
        
        return descriptors
    }
    
    // MARK: - Availability
    
    func isAvailable() async -> Bool {
        await provider.isAvailable()
    }
    
    // MARK: - Conversion Execution
    
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
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

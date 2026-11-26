import Foundation
import os.log

// MARK: - Subtitle Conversion Engine

final class SubtitleConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "SubtitleEngine"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "SubtitleEngine")
    private let ffmpegProvider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
    
    private static let textSubtitleInputs: Set<FileFormat> = [.srt, .vtt, .ass, .ssa, .sub]
    private static let textSubtitleOutputs: Set<FileFormat> = [.srt, .vtt, .ass, .ssa]
    private static let extractableVideoInputs: Set<FileFormat> = [.mp4, .mov, .mkv, .webm, .avi, .m4v, .ts]
    private static let bitmapSubtitleCodecs: Set<String> = [
        "dvd_subtitle", "hdmv_pgs_subtitle", "dvb_subtitle", "pgssub", "dvdsub", "xsub"
    ]
    
    var supportedInputFormats: Set<FileFormat> {
        Self.textSubtitleInputs.union(Self.extractableVideoInputs)
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        Self.textSubtitleOutputs
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        availableOutputFormats(for: input).contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard input != .sup else { return [] }
        if Self.textSubtitleInputs.contains(input) || Self.extractableVideoInputs.contains(input) {
            var outputs = Self.textSubtitleOutputs
            outputs.remove(input)
            return outputs
        }
        return []
    }
    
    func isAvailable() async -> Bool {
        await ffmpegProvider.isAvailable()
    }
    
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let input = inputs.first else {
            throw ConversionError.invalidInput("No input subtitle or video file specified.")
        }
        
        guard Self.textSubtitleOutputs.contains(outputFormat) else {
            throw ConversionError.unsupportedConversion(from: FileDetector.detectFormat(url: input) ?? .sup, to: outputFormat)
        }
        
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }
        
        let detectedInput = FileDetector.detectFormat(url: input)
        if detectedInput == .sup {
            throw ConversionError.invalidInput("Blu-ray PGS (.sup) subtitles are bitmap images and cannot be converted to text subtitles without OCR.")
        }
        
        guard let ffmpegPath = await ffmpegProvider.findFFmpegPath(),
              let ffprobePath = await ffmpegProvider.findFFprobePath() else {
            throw ConversionError.engineNotAvailable("FFmpeg is required for subtitle conversion.")
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        try Task.checkCancellation()
        
        progress(.determinate(0.15, message: "Analyzing subtitle stream..."))
        
        let info = try await MediaProbe.probe(url: input, ffprobePath: ffprobePath)
        
        var args: [String] = ["-y", "-i", input.path]
        if Self.extractableVideoInputs.contains(detectedInput ?? .mp4) || info.hasVideo {
            guard !info.subtitleStreams.isEmpty else {
                throw ConversionError.invalidInput("The video '\(input.lastPathComponent)' does not contain any subtitle track.")
            }
            guard let textStream = info.subtitleStreams.first(where: { !Self.bitmapSubtitleCodecs.contains($0.codecName.lowercased()) }) else {
                throw ConversionError.invalidInput("'\(input.lastPathComponent)' contains only bitmap subtitles (e.g. PGS/DVD), which cannot be extracted to text subtitles without OCR.")
            }
            args += ["-map", "0:\(textStream.index)"]
        } else {
            guard !info.subtitleStreams.isEmpty else {
                throw ConversionError.invalidInput("No valid subtitle stream found in \(input.lastPathComponent).")
            }
        }
        
        let codecArg: String
        let formatArg: String
        switch outputFormat {
        case .srt:
            codecArg = "srt"; formatArg = "srt"
        case .vtt:
            codecArg = "webvtt"; formatArg = "webvtt"
        case .ass:
            codecArg = "ass"; formatArg = "ass"
        case .ssa:
            codecArg = "ssa"; formatArg = "ass"
        default:
            throw ConversionError.unsupportedConversion(from: detectedInput ?? .srt, to: outputFormat)
        }
        
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Subtitle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        
        let tempOut = scratchDir.appendingPathComponent("output.\(outputFormat.fileExtension)")
        args += ["-vn", "-an", "-c:s", codecArg, "-f", formatArg, tempOut.path]
        
        progress(.determinate(0.45, message: "Converting subtitle to \(outputFormat.shortExtensionLabel)..."))
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args

        let output = try await AsyncProcessRunner.run(process)
        guard output.terminationStatus == 0 else {
            let errStr = String(data: output.stderr, encoding: .utf8) ?? "Subtitle conversion failed."
            throw ConversionError.engineExecutionFailed(
                "Could not convert subtitle '\(input.lastPathComponent)' to \(outputFormat.displayName).",
                underlyingError: errStr
            )
        }
        
        guard FileManager.default.fileExists(atPath: tempOut.path),
              let content = try? String(contentsOf: tempOut, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.engineExecutionFailed("Subtitle output file was empty.", underlyingError: nil)
        }
        
        if outputFormat == .vtt && !content.contains("WEBVTT") {
            throw ConversionError.engineExecutionFailed("Generated WebVTT file is missing the WEBVTT header.", underlyingError: nil)
        }
        if (outputFormat == .ass || outputFormat == .ssa) && !content.contains("[Script Info]") {
            throw ConversionError.engineExecutionFailed("Generated ASS/SSA file is missing [Script Info] section.", underlyingError: nil)
        }
        
        let finalOutput = try ConversionManager.finalizeOutputFile(
            from: tempOut,
            for: input,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )
        
        let size = (try? FileManager.default.attributesOfItem(atPath: finalOutput.path)[.size] as? Int64) ?? 0
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        progress(.determinate(1.0, message: "Complete"))
        logger.info("Subtitle conversion succeeded: \(input.lastPathComponent) -> \(finalOutput.lastPathComponent)")
        
        return ConversionResult(
            outputURL: finalOutput,
            additionalOutputURLs: [],
            outputFormat: outputFormat,
            fileSize: size,
            duration: duration,
            engineName: name
        )
    }
}

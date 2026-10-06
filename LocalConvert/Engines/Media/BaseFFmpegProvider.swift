import Foundation
import os.log

// MARK: - Base FFmpeg Provider

class BaseFFmpegProvider: FFmpegProvider, @unchecked Sendable {
    
    var providerName: String { "Base FFmpeg" }
    
    let logger = Logger(subsystem: "com.localconvert.app", category: "FFmpegProvider")
    
    // MARK: - Executable Resolution (Subclasses must override)
    
    func findFFmpegPath() async -> String? {
        nil
    }
    
    func findFFprobePath() async -> String? {
        nil
    }
    
    // MARK: - Availability
    
    func isAvailable() async -> Bool {
        let ffmpeg = await findFFmpegPath()
        let ffprobe = await findFFprobePath()
        return ffmpeg != nil && ffprobe != nil
    }
    
    // MARK: - Version
    
    func version() async -> String? {
        guard let ffmpegPath = await findFFmpegPath() else { return nil }
        
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-version"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.components(separatedBy: .newlines).first
        } catch {
            logger.error("Failed to query FFmpeg version: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    // MARK: - Probing
    
    func probe(url: URL) async throws -> MediaInfo {
        guard let ffprobePath = await findFFprobePath() else {
            throw ConversionError.engineNotAvailable("ffprobe is required to inspect media files.")
        }
        return try await MediaProbe.probe(url: url, ffprobePath: ffprobePath)
    }
    
    // MARK: - Conversion
    
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL {
        guard let ffmpegPath = await findFFmpegPath(),
              let ffprobePath = await findFFprobePath() else {
            throw ConversionError.engineNotAvailable(
                "FFmpeg is required for audio and video conversion."
            )
        }
        
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }
        
        progress(.determinate(0.05, message: "Analyzing media streams..."))
        
        // 1. Probe source file to get streams and duration
        let inputInfo = try await MediaProbe.probe(url: input, ffprobePath: ffprobePath)
        let totalDuration = max(inputInfo.duration, 0.1)
        
        try Task.checkCancellation()
        
        // 2. Prepare isolated scratch directory
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        
        let tempOutputFile = tempRoot.appendingPathComponent("output.\(outputFormat.fileExtension)")
        
        // 3. Construct FFmpeg command arguments
        let arguments = buildFFmpegArguments(
            inputURL: input,
            outputURL: tempOutputFile,
            inputInfo: inputInfo,
            outputFormat: outputFormat,
            options: options
        )
        
        progress(.determinate(0.1, message: "Starting media conversion..."))
        
        // 4. Configure Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        // 5. Run process and stream progress via stdout
        return try await withTaskCancellationHandler {
            let stderrTask = Task { () -> Data in
                return stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }
            
            try process.run()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                try Task.checkCancellation()
                
                if line.hasPrefix("out_time_us=") {
                    let valStr = String(line.dropFirst("out_time_us=".count))
                    if let us = Double(valStr) {
                        let seconds = us / 1_000_000.0
                        let fraction = min(0.95, max(0.1, (seconds / totalDuration) * 0.95))
                        progress(.determinate(fraction, message: "Converting media (\(Int(fraction * 100))%)..."))
                    }
                } else if line == "progress=end" {
                    progress(.determinate(0.98, message: "Finalizing file..."))
                }
            }
            
            if process.isRunning {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in
                        continuation.resume()
                    }
                }
            }
            try Task.checkCancellation()
            
            let errorData = await stderrTask.value
            guard process.terminationStatus == 0 else {
                let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let safeError = errorString ?? "none"
                logger.error("FFmpeg conversion failed (exit code \(process.terminationStatus)): \(safeError, privacy: .public)")
                
                throw ConversionError.engineExecutionFailed(
                    "The media file could not be converted. The source file may be corrupted or in an unsupported codec format.",
                    underlyingError: errorString
                )
            }
            
            progress(.determinate(0.98, message: "Verifying output media..."))
            
            guard FileManager.default.fileExists(atPath: tempOutputFile.path) else {
                throw ConversionError.engineExecutionFailed(
                    "FFmpeg finished, but output file was not created.",
                    underlyingError: nil
                )
            }
            
            // 6. Validate output with ffprobe
            _ = try await MediaProbe.validate(
                outputURL: tempOutputFile,
                expectedFormat: outputFormat,
                ffprobePath: ffprobePath
            )
            
            // 7. Move to final collision-safe output location
            let finalOutput = ConversionManager.outputURL(for: input, format: outputFormat, in: outputDirectory)
            try FileManager.default.moveItem(at: tempOutputFile, to: finalOutput)
            
            progress(.determinate(1.0, message: "Complete"))
            logger.info("Media conversion succeeded: \(input.lastPathComponent) -> \(finalOutput.lastPathComponent)")
            
            return finalOutput
            
        } onCancel: {
            process.terminate()
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }
    
    // MARK: - Argument Construction
    
    func buildFFmpegArguments(
        inputURL: URL,
        outputURL: URL,
        inputInfo: MediaInfo,
        outputFormat: FileFormat,
        options: ConversionOptions
    ) -> [String] {
        var args: [String] = [
            "-y",                   // Overwrite output in scratch folder
            "-i", inputURL.path,    // Input file path
            "-progress", "pipe:1",  // Machine-readable progress on stdout
            "-nostats"              // Disable interactive stderr stats
        ]
        
        // Metadata preservation
        if options.preserveMetadata {
            args += ["-map_metadata", "0"]
        } else {
            args += ["-map_metadata", "-1"]
        }
        
        let targetCategory = outputFormat.category
        let sourceIsVideo = inputInfo.hasVideo
        
        if targetCategory == .audio {
            // Audio output (Audio to Audio, or Video to Audio Extraction)
            if sourceIsVideo {
                args.append("-vn") // Strip video stream
            }
            args.append("-sn")     // Strip subtitle streams from audio outputs
            args += audioEncodingArguments(for: outputFormat, options: options)
            
        } else if targetCategory == .video || outputFormat == .gif {
            // Video or Animated Image output
            if outputFormat == .gif {
                // Video to GIF uses high quality palette filter and omits subtitles
                args += [
                    "-filter_complex", "[0:v] fps=15,scale=min(640\\,iw):-1:flags=lanczos,split [a][b];[a] palettegen=stats_mode=diff [p];[b][p] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
                ]
            } else {
                let isStreamCopyable = canStreamCopy(inputInfo: inputInfo, targetFormat: outputFormat)
                
                if isStreamCopyable {
                    logger.info("Using stream copy for \(inputURL.lastPathComponent) -> \(outputFormat.rawValue)")
                    args += ["-c", "copy"]
                } else {
                    args += videoEncodingArguments(for: outputFormat, options: options, duration: inputInfo.duration)
                    args += audioEncodingArgumentsForVideo(targetFormat: outputFormat)
                    
                    // Route-aware subtitle preservation during video transcoding
                    if inputInfo.hasSubtitles {
                        if outputFormat == .mp4 || outputFormat == .mov {
                            args += ["-c:s", "mov_text"]
                        } else if outputFormat == .mkv {
                            args += ["-c:s", "copy"]
                        } else if outputFormat == .webm {
                            args += ["-c:s", "webvtt"]
                        } else {
                            args += ["-sn"]
                        }
                    }
                }
            }
        }
        
        args.append(outputURL.path)
        return args
    }
    
    // MARK: - Stream Copy Evaluation
    
    func canStreamCopy(inputInfo: MediaInfo, targetFormat: FileFormat) -> Bool {
        guard let videoCodec = inputInfo.primaryVideoStream?.codecName.lowercased() else { return false }
        let audioCodec = inputInfo.primaryAudioStream?.codecName.lowercased()
        
        switch targetFormat {
        case .mp4:
            // MP4 accepts H.264/HEVC video + AAC audio
            let videoOK = ["h264", "avc1", "hevc", "h265"].contains(videoCodec)
            let audioOK = audioCodec == nil || audioCodec == "aac" || audioCodec == "mp3"
            return videoOK && audioOK
            
        case .mov:
            // MOV accepts H.264/HEVC/ProRes + AAC/PCM
            let videoOK = ["h264", "avc1", "hevc", "h265", "prores"].contains(videoCodec)
            let audioOK = audioCodec == nil || ["aac", "pcm_s16le", "pcm_s24le", "alac", "mp3"].contains(audioCodec!)
            return videoOK && audioOK
            
        case .mkv:
            // MKV container accepts virtually any codec via stream copy
            return true
            
        default:
            return false
        }
    }
    
    // MARK: - Audio Encoding Arguments
    
    func audioEncodingArguments(for format: FileFormat, options: ConversionOptions) -> [String] {
        let quality = options.effectiveMediaQuality
        
        switch format {
        case .mp3:
            // LAME VBR quality: low(5), medium(4), high(2), maximum(0)
            let vbr: String
            switch quality {
            case .low: vbr = "5"
            case .medium: vbr = "4"
            case .high: vbr = "2"
            case .maximum: vbr = "0"
            }
            return ["-c:a", "libmp3lame", "-q:a", vbr]
            
        case .wav:
            return ["-c:a", "pcm_s16le"]
            
        case .flac:
            return ["-c:a", "flac"]
            
        case .m4a, .aac:
            let bitrate: String
            switch quality {
            case .low: bitrate = "128k"
            case .medium: bitrate = "192k"
            case .high: bitrate = "256k"
            case .maximum: bitrate = "320k"
            }
            return ["-c:a", "aac", "-b:a", bitrate]
            
        case .ogg:
            return ["-c:a", "libopus", "-b:a", "160k"]
            
        case .opus:
            return ["-c:a", "libopus", "-b:a", "160k"]
            
        case .aiff:
            return ["-c:a", "pcm_s16be"]
            
        case .caf:
            return ["-c:a", "pcm_s16le"]
            
        case .alac:
            return ["-c:a", "alac", "-f", "ipod"]
            
        case .ac3:
            let bitrate: String
            switch quality {
            case .low: bitrate = "192k"
            case .medium: bitrate = "384k"
            case .high: bitrate = "448k"
            case .maximum: bitrate = "640k"
            }
            return ["-c:a", "ac3", "-b:a", bitrate]
            
        default:
            return ["-c:a", "libmp3lame"]
        }
    }
    
    // MARK: - Video Encoding Arguments
    
    func videoEncodingArguments(for format: FileFormat, options: ConversionOptions, duration: Double) -> [String] {
        let quality = options.effectiveMediaQuality
        let evenScaleFilter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        
        var targetVideoBitrate: String? = nil
        if let targetMB = options.targetFileSizeMB, duration > 0 {
            // Allocate 128kbps for audio, rest for video.
            // Target bits = targetMB * 8 * 1024 * 1024
            let targetBits = targetMB * 8388608.0
            let audioBits = 128000.0 * duration
            let videoBits = max(100000.0, targetBits - audioBits)
            let videoBps = videoBits / duration
            targetVideoBitrate = "\(Int(videoBps))"
        }
        
        switch format {
        case .mp4, .mov, .mkv:
            // Use Apple Silicon / macOS native hardware accelerated VideoToolbox (LGPLv3+)
            let q: String
            switch quality {
            case .low: q = "45"
            case .medium: q = "60"
            case .high: q = "75"
            case .maximum: q = "90"
            }
            
            var args = [
                "-c:v", "h264_videotoolbox",
                "-pix_fmt", "yuv420p",
                "-vf", evenScaleFilter
            ]
            
            if let bitrate = targetVideoBitrate {
                args += ["-b:v", bitrate, "-maxrate", bitrate, "-bufsize", "\(Int(Double(bitrate)! * 2))"]
            } else {
                args += ["-q:v", q]
            }
            return args
            
        case .webm:
            // VP9 with CRF
            let crf: String
            switch quality {
            case .low: crf = "36"
            case .medium: crf = "31"
            case .high: crf = "25"
            case .maximum: crf = "18"
            }
            
            var args = [
                "-c:v", "libvpx-vp9",
                "-pix_fmt", "yuv420p",
                "-vf", evenScaleFilter
            ]
            
            if let bitrate = targetVideoBitrate {
                args += ["-b:v", bitrate, "-maxrate", bitrate, "-bufsize", "\(Int(Double(bitrate)! * 2))"]
            } else {
                args += ["-crf", crf, "-b:v", "0"]
            }
            return args
            
        case .avi:
            return [
                "-c:v", "mpeg4",
                "-q:v", "3"
            ]
            
        default:
            return [
                "-c:v", "h264_videotoolbox",
                "-q:v", "60",
                "-pix_fmt", "yuv420p"
            ]
        }
    }
    
    func audioEncodingArgumentsForVideo(targetFormat: FileFormat) -> [String] {
        switch targetFormat {
        case .webm:
            return ["-c:a", "libopus", "-b:a", "128k"]
        case .avi:
            return ["-c:a", "libmp3lame", "-b:a", "192k"]
        default:
            return ["-c:a", "aac", "-b:a", "192k"]
        }
    }
}

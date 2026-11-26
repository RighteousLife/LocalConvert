import Foundation
import os.log

// MARK: - Base FFmpeg Provider

class BaseFFmpegProvider: FFmpegProvider, @unchecked Sendable {
    
    static let defaultConversionTimeoutSeconds: TimeInterval = 1800.0
    static let maxRingtoneDurationSeconds: Double = 30.0
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
        if let trim = options.videoTrim {
            let trimValidation = VideoTrimValidator.validate(
                range: trim,
                sourceDurationSeconds: inputInfo.duration,
                inputInfo: inputInfo,
                outputFormat: outputFormat
            )
            guard trimValidation.isValid else {
                throw ConversionError.invalidInput(trimValidation.errorMessage ?? "Invalid video trim configuration.")
            }
        }
        if outputFormat == .m4r {
            try Self.validateRingtoneDurationOption(options: options)
        }
        let durationLimit = Self.effectiveOutputDurationLimitSeconds(outputFormat: outputFormat, options: options)
        let totalDuration: Double = {
            if let limit = durationLimit {
                if options.videoTrim != nil {
                    return max(limit, 0.1)
                }
                if inputInfo.duration > 0 {
                    return max(min(inputInfo.duration, limit), 0.1)
                }
                return max(limit, 0.1)
            }
            return max(inputInfo.duration, 0.1)
        }()
        
        if outputFormat.category == .audio && !inputInfo.hasAudio {
            throw ConversionError.invalidInput("The source media file does not contain an audio stream to extract.")
        }

        if (outputFormat.category == .video || outputFormat == .gif || outputFormat == .apng) && !inputInfo.hasRealVideo {
            throw ConversionError.invalidInput("The source media file does not contain a video stream.")
        }
        
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
        
        if let subtitleWarning = Self.droppedBitmapSubtitleWarning(inputInfo: inputInfo, outputFormat: outputFormat) {
            progress(.determinate(0.08, message: subtitleWarning))
        }
        progress(.determinate(0.1, message: "Starting media conversion..."))
        
        let conversionStart = CFAbsoluteTimeGetCurrent()
        let primaryResult = try await executeFFmpegProcess(
            ffmpegPath: ffmpegPath,
            arguments: arguments,
            totalDuration: totalDuration,
            timeout: Self.defaultConversionTimeoutSeconds,
            progress: progress
        )

        if primaryResult.terminationStatus != 0 {
            let errorString = primaryResult.stderrString
            let safeError = errorString ?? "none"

            if Self.isVideoToolboxHardwareFailure(stderr: safeError, arguments: arguments) {
                let diagnosticSummary = Self.videoToolboxDiagnosticSummary(from: safeError)
                logger.warning("h264_videotoolbox failed (\(diagnosticSummary, privacy: .public)); checking software fallback.")
                try Task.checkCancellation()

                if await supportsVideoEncoder("libx264", ffmpegPath: ffmpegPath),
                   let fallbackArguments = Self.softwareH264FallbackArguments(from: arguments, options: options) {
                    try? FileManager.default.removeItem(at: tempOutputFile)
                    StructuredDiagnostics.record(
                        category: .videoProcessing,
                        severity: .info,
                        stage: "h264VideoToolboxFallback",
                        filename: input.lastPathComponent,
                        message: "h264_videotoolbox failed (\(diagnosticSummary)); retrying with software libx264."
                    )
                    progress(.determinate(0.12, message: "Hardware H.264 encoder unavailable; retrying with software H.264..."))

                    let elapsed = CFAbsoluteTimeGetCurrent() - conversionStart
                    let remainingTimeout = max(1.0, Self.defaultConversionTimeoutSeconds - elapsed)
                    let fallbackResult = try await executeFFmpegProcess(
                        ffmpegPath: ffmpegPath,
                        arguments: fallbackArguments,
                        totalDuration: totalDuration,
                        timeout: remainingTimeout,
                        progress: progress
                    )
                    guard fallbackResult.terminationStatus == 0 else {
                        let fallbackError = fallbackResult.stderrString ?? "none"
                        logger.error("FFmpeg libx264 fallback failed (exit code \(fallbackResult.terminationStatus)): \(fallbackError, privacy: .public)")
                        StructuredDiagnostics.record(
                            category: .videoProcessing,
                            severity: .internalError,
                            stage: "h264VideoToolboxFallbackFailed",
                            filename: input.lastPathComponent,
                            message: "Software libx264 fallback also failed after h264_videotoolbox error: \(Self.videoToolboxDiagnosticSummary(from: fallbackError))"
                        )
                        throw ConversionError.engineExecutionFailed(
                            "The media file could not be converted (hardware VideoToolbox and software libx264 encoders failed).",
                            underlyingError: Self.combineFallbackErrors(primary: errorString, fallback: fallbackResult.stderrString)
                        )
                    }
                } else {
                    logger.error("h264_videotoolbox failed (exit code \(primaryResult.terminationStatus)) and libx264 fallback unavailable: \(safeError, privacy: .public)")
                    StructuredDiagnostics.record(
                        category: .videoProcessing,
                        severity: .internalError,
                        stage: "h264VideoToolboxFailed",
                        filename: input.lastPathComponent,
                        message: "h264_videotoolbox failed (\(diagnosticSummary)); software libx264 fallback unavailable in active FFmpeg build."
                    )
                    throw ConversionError.engineExecutionFailed(
                        "Hardware H.264 encoder (h264_videotoolbox) failed: \(diagnosticSummary)",
                        underlyingError: errorString
                    )
                }
            } else {
                logger.error("FFmpeg conversion failed (exit code \(primaryResult.terminationStatus)): \(safeError, privacy: .public)")
                throw ConversionError.engineExecutionFailed(
                    "The media file could not be converted. The source file may be corrupted or in an unsupported codec format.",
                    underlyingError: errorString
                )
            }
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

        // 7. Move to atomic policy-resolved output location
        let finalOutput = try ConversionManager.finalizeOutputFile(
            from: tempOutputFile,
            for: input,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )

        progress(.determinate(1.0, message: "Complete"))
        logger.info("Media conversion succeeded: \(input.lastPathComponent) -> \(finalOutput.lastPathComponent)")

        return finalOutput
    }

    // MARK: - Subprocess Execution & VideoToolbox Fallback Helpers

    private func executeFFmpegProcess(
        ffmpegPath: String,
        arguments: [String],
        totalDuration: Double,
        timeout: TimeInterval,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> (terminationStatus: Int32, stderrString: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrTask = Task.detached(priority: .utility) { () -> Data in
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try await AsyncProcessRunner.awaitExit(of: process, timeout: timeout) {
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
            }
        } catch let timeoutErr as ProcessTimeoutError {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stderrTask.value
            throw ConversionError.engineExecutionFailed(
                "Media conversion timed out after \(Int(timeoutErr.timeoutSeconds)) seconds.",
                underlyingError: timeoutErr.localizedDescription
            )
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stderrTask.value
            throw error
        }

        let errorData = await stderrTask.value
        let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, errorString)
    }

    func supportsVideoEncoder(_ encoderName: String, ffmpegPath: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-hide_banner", "-encoders"]
        do {
            let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 10.0)
            guard output.terminationStatus == 0,
                  let listing = String(data: output.stdout, encoding: .utf8) else {
                return false
            }
            for line in listing.split(whereSeparator: \.isNewline) {
                let tokens = line.split(whereSeparator: \.isWhitespace)
                if tokens.count >= 2, tokens[0].hasPrefix("V"), tokens[1] == encoderName {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }

    static func isVideoToolboxHardwareFailure(stderr: String, arguments: [String]) -> Bool {
        guard let vcodecIdx = arguments.firstIndex(of: "-c:v"),
              vcodecIdx + 1 < arguments.count,
              arguments[vcodecIdx + 1] == "h264_videotoolbox" else {
            return false
        }
        let lowered = stderr.lowercased()
        let directMarkers = [
            "h264_videotoolbox",
            "vtcompressionsession",
            "videotoolbox",
            "cannot create compression session"
        ]
        if directMarkers.contains(where: { lowered.contains($0) }) {
            return true
        }
        let genericEncoderFailures = [
            "error while opening encoder for output stream",
            "error initializing output stream",
            "generic error in an external library",
            "hardware encoder"
        ]
        return genericEncoderFailures.contains(where: { lowered.contains($0) })
    }

    static func videoToolboxDiagnosticSummary(from stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let matched = lines.filter { line in
            let lowered = line.lowercased()
            return lowered.contains("videotoolbox")
                || lowered.contains("vtcompression")
                || lowered.contains("compression session")
                || lowered.contains("encoder")
                || lowered.contains("error")
        }
        let selected = (matched.isEmpty ? lines : matched).suffix(3).joined(separator: " | ")
        let sanitized = ErrorDetailsFormatter.sanitize(selected)
        return sanitized.isEmpty ? "VideoToolbox encoder initialization error" : sanitized
    }

    static func softwareH264FallbackArguments(
        from arguments: [String],
        options: ConversionOptions
    ) -> [String]? {
        guard let vcodecIdx = arguments.firstIndex(of: "-c:v"),
              vcodecIdx + 1 < arguments.count,
              arguments[vcodecIdx + 1] == "h264_videotoolbox" else {
            return nil
        }

        var updated = arguments
        updated[vcodecIdx + 1] = "libx264"

        let crf: String
        switch options.effectiveMediaQuality {
        case .low: crf = "28"
        case .medium: crf = "23"
        case .high: crf = "20"
        case .maximum: crf = "17"
        }

        if let qIdx = updated.firstIndex(of: "-q:v"), qIdx + 1 < updated.count {
            updated[qIdx] = "-crf"
            updated[qIdx + 1] = crf
        }
        return updated
    }

    private static func combineFallbackErrors(primary: String?, fallback: String?) -> String? {
        let parts = [
            primary.map { "Primary (h264_videotoolbox): \($0)" },
            fallback.map { "Fallback (libx264): \($0)" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
    
    // MARK: - Ringtone Duration Helpers

    static func validateRingtoneDurationOption(options: ConversionOptions) throws {
        let rawValue = options.customOptions["ringtone_duration"] ?? options.customOptions["max_duration"]
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return
        }
        guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else {
            throw ConversionError.invalidInput("Ringtone duration must be a positive number of seconds.")
        }
    }

    static func resolvedRingtoneDurationCapSeconds(from options: ConversionOptions) -> Double {
        let rawValue = options.customOptions["ringtone_duration"] ?? options.customOptions["max_duration"]
        if let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let seconds = Double(raw),
           seconds.isFinite,
           seconds > 0 {
            return min(seconds, maxRingtoneDurationSeconds)
        }
        return maxRingtoneDurationSeconds
    }

    static func effectiveOutputDurationLimitSeconds(
        outputFormat: FileFormat,
        options: ConversionOptions
    ) -> Double? {
        if outputFormat == .m4r {
            let cap = resolvedRingtoneDurationCapSeconds(from: options)
            if let trim = options.videoTrim {
                return min(trim.durationSeconds, cap)
            }
            return cap
        }
        return options.videoTrim?.durationSeconds
    }

    // MARK: - Argument Construction
    
    func buildFFmpegArguments(
        inputURL: URL,
        outputURL: URL,
        inputInfo: MediaInfo,
        outputFormat: FileFormat,
        options: ConversionOptions
    ) -> [String] {
        var args: [String] = ["-y"]
        if let trim = options.videoTrim {
            args += ["-ss", trim.ffmpegStartTimestamp]
        }
        args += ["-i", inputURL.path]
        if let durationLimit = Self.effectiveOutputDurationLimitSeconds(outputFormat: outputFormat, options: options) {
            let ms = max(100, Int64((durationLimit * 1000.0).rounded()))
            args += ["-t", VideoTrimTimestamp.formatFFmpeg(milliseconds: ms)]
        }
        args += [
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
        let sourceHasRealVideo = inputInfo.hasRealVideo
        let keepCoverArt = targetCategory == .audio
            && !sourceHasRealVideo
            && inputInfo.hasAttachedArtwork
            && options.preserveMetadata
            && AudioCodecRegistry.supportsCoverArt(for: outputFormat)
        let effectiveDuration = max(0.1, options.videoTrim?.durationSeconds ?? inputInfo.duration)
        
        if targetCategory == .audio {
            // Audio output (Audio to Audio, or Video to Audio Extraction)
            if keepCoverArt {
                args += ["-map", "0:a", "-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic"]
            } else if inputInfo.hasVideo {
                args.append("-vn") // Strip video stream or unsupported cover stream
            }
            args.append("-sn")     // Strip subtitle streams from audio outputs
            args += audioEncodingArguments(for: outputFormat, options: options)
            
        } else if targetCategory == .video || outputFormat == .gif || outputFormat == .apng {
            // Video or Animated Image output
            if outputFormat == .gif {
                // Video to GIF uses high quality palette filter and omits subtitles
                args += [
                    "-filter_complex", "[0:v] fps=15,scale=min(640\\,iw):-1:flags=lanczos,split [a][b];[a] palettegen=stats_mode=diff [p];[b][p] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                    "-an", "-sn"
                ]
            } else if outputFormat == .apng {
                args += [
                    "-vf", "fps=15,scale=min(640\\,iw):-1:flags=lanczos",
                    "-plays", "0",
                    "-an", "-sn",
                    "-f", "apng"
                ]
            } else {
                let isStreamCopyable = canStreamCopy(inputInfo: inputInfo, targetFormat: outputFormat, options: options)

                if isStreamCopyable {
                    logger.info("Using stream copy for \(inputURL.lastPathComponent) -> \(outputFormat.rawValue)")
                    args += ["-c", "copy"]
                    args += subtitleArguments(for: outputFormat, inputInfo: inputInfo, isStreamCopy: true)
                    if options.hasVideoTrim {
                        args += ["-avoid_negative_ts", "make_zero"]
                        if [.mp4, .mov, .m4v].contains(outputFormat) {
                            args += ["-movflags", "+faststart"]
                        }
                    }
                } else {
                    args += subtitleArguments(for: outputFormat, inputInfo: inputInfo, isStreamCopy: false)
                    args += videoEncodingArguments(for: outputFormat, options: options, duration: effectiveDuration, inputInfo: inputInfo)
                    args += audioEncodingArgumentsForVideo(targetFormat: outputFormat, options: options)
                    if options.hasVideoTrim {
                        args += ["-avoid_negative_ts", "make_zero"]
                        if [.mp4, .mov, .m4v].contains(outputFormat) {
                            args += ["-movflags", "+faststart"]
                        }
                    }
                }
            }
        }

        args.append(outputURL.path)
        return args
    }

    static func droppedBitmapSubtitleWarning(
        inputInfo: MediaInfo,
        outputFormat: FileFormat
    ) -> String? {
        guard outputFormat.category == .video, outputFormat != .mkv else {
            return nil
        }
        let textIndices = Set(inputInfo.textSubtitleStreams.map(\.index))
        let droppedBitmapStreams = inputInfo.subtitleStreams.filter { !textIndices.contains($0.index) }
        guard !droppedBitmapStreams.isEmpty else {
            return nil
        }
        let codecs = Array(Set(droppedBitmapStreams.map { $0.codecName.uppercased() })).sorted().joined(separator: ", ")
        return "Dropped \(droppedBitmapStreams.count) bitmap subtitle stream(s) (\(codecs)) because \(outputFormat.displayName) does not support PGS/DVD bitmap subtitles (use MKV to preserve them)."
    }

    private func subtitleArguments(
        for outputFormat: FileFormat,
        inputInfo: MediaInfo,
        isStreamCopy: Bool
    ) -> [String] {
        let baseStreamMap = ["-map", "0:v:0?", "-map", "0:a?"]
        guard inputInfo.hasSubtitles else {
            return inputInfo.audioStreams.count > 1 ? baseStreamMap : []
        }

        if outputFormat == .mkv {
            var args = baseStreamMap + ["-map", "0:s?"]
            if !isStreamCopy {
                args += ["-c:s", "copy"]
            }
            return args
        }

        if let bitmapWarning = Self.droppedBitmapSubtitleWarning(inputInfo: inputInfo, outputFormat: outputFormat) {
            logger.warning("\(bitmapWarning, privacy: .public)")
            StructuredDiagnostics.record(
                category: .videoProcessing,
                severity: .validation,
                stage: "bitmapSubtitleDropped",
                filename: inputInfo.url.lastPathComponent,
                message: bitmapWarning
            )
        }

        let targetCodec: String?
        if [.mp4, .mov, .m4v].contains(outputFormat) {
            targetCodec = "mov_text"
        } else if outputFormat == .webm {
            targetCodec = "webvtt"
        } else {
            targetCodec = nil
        }

        guard let codec = targetCodec, !inputInfo.textSubtitleStreams.isEmpty else {
            return (inputInfo.audioStreams.count > 1 ? baseStreamMap : []) + ["-sn"]
        }

        var subArgs = baseStreamMap
        for sub in inputInfo.textSubtitleStreams {
            subArgs += ["-map", "0:\(sub.index)"]
        }
        subArgs += ["-c:s", codec]
        return subArgs
    }

    // MARK: - Stream Copy Evaluation

    static func canStreamCopyContainerAndCodecs(inputInfo: MediaInfo, targetFormat: FileFormat) -> Bool {
        guard targetFormat.category == .video else { return false }
        guard let videoCodec = inputInfo.primaryVideoStream?.codecName.lowercased() else { return false }
        let nonStreamCopyCodecs: Set<String> = ["gif", "apng", "png", "mjpeg", "webp", "bmp", "tiff", "jxl"]
        if nonStreamCopyCodecs.contains(videoCodec) {
            return false
        }
        let audioCodecs = inputInfo.audioStreams.map { $0.codecName.lowercased() }

        switch targetFormat {
        case .mp4, .m4v:
            // MP4 / M4V accepts H.264/HEVC video + AAC/MP3 audio across all audio streams
            let videoOK = ["h264", "avc1", "hevc", "h265"].contains(videoCodec)
            let audioOK = audioCodecs.allSatisfy { $0 == "aac" || $0 == "mp3" }
            return videoOK && audioOK

        case .mov:
            // MOV accepts H.264/HEVC/ProRes + AAC/PCM/ALAC/MP3 across all audio streams
            let videoOK = ["h264", "avc1", "hevc", "h265", "prores"].contains(videoCodec)
            let audioOK = audioCodecs.allSatisfy { ["aac", "pcm_s16le", "pcm_s24le", "alac", "mp3"].contains($0) }
            return videoOK && audioOK

        case .mkv:
            // MKV container accepts virtually any codec via stream copy
            return true

        case .webm:
            let videoOK = ["vp8", "vp9", "av1"].contains(videoCodec)
            let audioOK = audioCodecs.allSatisfy { $0 == "opus" || $0 == "vorbis" }
            return videoOK && audioOK

        default:
            return false
        }
    }

    func canStreamCopy(inputInfo: MediaInfo, targetFormat: FileFormat, options: ConversionOptions = .default) -> Bool {
        if let trim = options.videoTrim {
            return trim.mode == .streamCopy && Self.canStreamCopyContainerAndCodecs(inputInfo: inputInfo, targetFormat: targetFormat)
        }

        if options.effectiveTargetFileSizeBytes != nil
            || (options.mediaQuality != nil && options.mediaQuality != .high)
            || options.effectivePreset != nil
            || options.customOptions["vcodec"] != nil
            || options.customOptions["acodec"] != nil
            || options.customOptions["pix_fmt"] != nil
            || options.customOptions["profile:v"] != nil {
            return false
        }

        // Preserve non-trim behavior: WebM non-trim tests expect VP9/Opus re-encode unless explicitly requested for trim stream-copy
        if targetFormat == .webm {
            return false
        }

        return Self.canStreamCopyContainerAndCodecs(inputInfo: inputInfo, targetFormat: targetFormat)
    }
    
    // MARK: - Audio Encoding Arguments
    
    func audioEncodingArguments(for format: FileFormat, options: ConversionOptions) -> [String] {
        let quality = options.effectiveMediaQuality
        
        switch format {
        case .mp3:
            let vbr: String
            switch quality {
            case .low: vbr = "5"
            case .medium: vbr = "3"
            case .high: vbr = "2"
            case .maximum: vbr = "0"
            }
            return ["-c:a", "libmp3lame", "-q:a", vbr]
            
        case .wav:
            return ["-c:a", "pcm_s16le"]
            
        case .flac:
            return ["-c:a", "flac"]
            
        case .m4a, .aac:
            if format == .m4a && options.customOptions["m4a_lossless"] == "true" {
                return ["-c:a", "alac"]
            }
            let bitrate: String
            switch quality {
            case .low: bitrate = "128k"
            case .medium: bitrate = "192k"
            case .high: bitrate = "256k"
            case .maximum: bitrate = "320k"
            }
            return ["-c:a", "aac", "-b:a", bitrate]
            
        case .m4b:
            let bitrate: String
            switch quality {
            case .low: bitrate = "96k"
            case .medium: bitrate = "128k"
            case .high: bitrate = "192k"
            case .maximum: bitrate = "256k"
            }
            return ["-c:a", "aac", "-b:a", bitrate, "-f", "mp4"]

        case .m4r:
            let bitrate: String
            switch quality {
            case .low: bitrate = "128k"
            case .medium: bitrate = "192k"
            case .high: bitrate = "256k"
            case .maximum: bitrate = "320k"
            }
            let rawACodec = options.customOptions["acodec"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let encoder = (rawACodec == "aac_at") ? "aac_at" : "aac"
            return ["-c:a", encoder, "-b:a", bitrate, "-f", "ipod"]
            
        case .ogg, .opus:
            let bitrate: String
            switch quality {
            case .low: bitrate = "96k"
            case .medium: bitrate = "128k"
            case .high: bitrate = "192k"
            case .maximum: bitrate = "256k"
            }
            return ["-c:a", "libopus", "-b:a", bitrate]
            
        case .aiff, .au:
            return ["-c:a", "pcm_s16be"]
            
        case .caf:
            return ["-c:a", "pcm_s16le"]
            
        case .alac:
            return ["-c:a", "alac", "-f", "ipod"]
            
        case .ac3, .eac3:
            let bitrate: String
            switch quality {
            case .low: bitrate = "192k"
            case .medium: bitrate = "384k"
            case .high: bitrate = "448k"
            case .maximum: bitrate = "640k"
            }
            let codec = (format == .eac3) ? "eac3" : "ac3"
            return ["-c:a", codec, "-b:a", bitrate]
            
        case .dts:
            return ["-c:a", "dca", "-strict", "-2", "-b:a", "768k"]
            
        case .wma:
            let bitrate: String
            switch quality {
            case .low: bitrate = "128k"
            case .medium: bitrate = "192k"
            case .high, .maximum: bitrate = "256k"
            }
            return ["-c:a", "wmav2", "-b:a", bitrate]
            
        case .wv:
            return ["-c:a", "wavpack"]
            
        case .mka:
            return ["-c:a", "flac"]
            
        default:
            return ["-c:a", "libmp3lame"]
        }
    }
    
    // MARK: - Video Encoding Arguments

    static let minimumTargetVideoBitrateBps: Double = 100_000.0

    static func parseBitrateBps(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let multiplier: Double
        let numericPart: Substring
        if trimmed.hasSuffix("kbps") {
            multiplier = 1_000.0
            numericPart = trimmed.dropLast(4)
        } else if trimmed.hasSuffix("k") {
            multiplier = 1_000.0
            numericPart = trimmed.dropLast(1)
        } else if trimmed.hasSuffix("mbps") {
            multiplier = 1_000_000.0
            numericPart = trimmed.dropLast(4)
        } else if trimmed.hasSuffix("m") {
            multiplier = 1_000_000.0
            numericPart = trimmed.dropLast(1)
        } else {
            multiplier = 1.0
            numericPart = trimmed[...]
        }

        guard let value = Double(numericPart.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite,
              value > 0 else {
            return nil
        }
        return value * multiplier
    }

    private static func customVideoAudioBitrateString(from options: ConversionOptions) -> String? {
        if let rawKbps = options.customOptions["audio_bitrate_kbps"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let kbps = Int(rawKbps),
           kbps > 0 {
            let clamped = min(1536, max(16, kbps))
            return "\(clamped)k"
        }
        for key in ["b:a", "audio_bitrate"] {
            if let raw = options.customOptions[key],
               let bps = parseBitrateBps(raw) {
                let kbps = max(16, min(1536, Int((bps / 1_000.0).rounded())))
                return "\(kbps)k"
            }
        }
        return nil
    }

    static func effectiveAudioBitrateBps(
        for targetFormat: FileFormat,
        options: ConversionOptions,
        inputInfo: MediaInfo? = nil,
        audioArgs: [String]
    ) -> Double {
        if let inputInfo, !inputInfo.hasAudio {
            return 0.0
        }
        if audioArgs.contains("-an") {
            return 0.0
        }
        if let codecIdx = audioArgs.firstIndex(of: "-c:a"),
           codecIdx + 1 < audioArgs.count,
           audioArgs[codecIdx + 1].lowercased() == "copy" {
            if let sourceBitrate = inputInfo?.primaryAudioStream?.bitRate, sourceBitrate > 0 {
                return Double(sourceBitrate)
            }
            return 128_000.0
        }
        if let bitrateIdx = audioArgs.firstIndex(of: "-b:a"),
           bitrateIdx + 1 < audioArgs.count,
           let parsedBps = parseBitrateBps(audioArgs[bitrateIdx + 1]) {
            return parsedBps
        }
        if let customBitrate = customVideoAudioBitrateString(from: options),
           let parsedBps = parseBitrateBps(customBitrate) {
            return parsedBps
        }
        switch targetFormat {
        case .m2v:
            return 0.0
        case .webm, .flv:
            return 128_000.0
        case .m4r:
            return 256_000.0
        default:
            return 192_000.0
        }
    }

    static func calculateTargetVideoBitrateBps(
        targetBytes: Int64,
        duration: Double,
        outputFormat: FileFormat,
        options: ConversionOptions,
        inputInfo: MediaInfo? = nil,
        audioArgs: [String]
    ) -> Int {
        guard targetBytes > 0, duration > 0 else {
            return Int(minimumTargetVideoBitrateBps)
        }
        let targetBits = Double(targetBytes) * 8.0
        let audioBps = effectiveAudioBitrateBps(
            for: outputFormat,
            options: options,
            inputInfo: inputInfo,
            audioArgs: audioArgs
        )
        let audioBits = audioBps * duration
        let videoBits = max(minimumTargetVideoBitrateBps * duration, targetBits - audioBits)
        let videoBps = max(minimumTargetVideoBitrateBps, videoBits / duration)
        return Int(videoBps)
    }
    
    func videoEncodingArguments(
        for format: FileFormat,
        options: ConversionOptions,
        duration: Double,
        inputInfo: MediaInfo? = nil
    ) -> [String] {
        let quality = options.effectiveMediaQuality
        let evenScaleFilter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

        var targetVideoBitrate: String? = nil
        if let targetBytes = options.effectiveTargetFileSizeBytes, duration > 0 {
            let audioArgs = audioEncodingArgumentsForVideo(targetFormat: format, options: options)
            let videoBps = Self.calculateTargetVideoBitrateBps(
                targetBytes: targetBytes,
                duration: duration,
                outputFormat: format,
                options: options,
                inputInfo: inputInfo,
                audioArgs: audioArgs
            )
            targetVideoBitrate = "\(videoBps)"
        }

        let vtQuality: String
        let legacyQFactor: String
        switch quality {
        case .low:
            vtQuality = "45"
            legacyQFactor = "6"
        case .medium:
            vtQuality = "60"
            legacyQFactor = "4"
        case .high:
            vtQuality = "75"
            legacyQFactor = "3"
        case .maximum:
            vtQuality = "90"
            legacyQFactor = "2"
        }

        let rawCustomVCodec = options.customOptions["vcodec"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customVCodec = (rawCustomVCodec == "libx264") ? "h264_videotoolbox" : rawCustomVCodec
        let customPixFmt = options.customOptions["pix_fmt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customProfile = options.customOptions["profile:v"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        func applyBitrateOrLegacyQuality(_ args: inout [String]) {
            if let bitrate = targetVideoBitrate {
                args += ["-b:v", bitrate, "-maxrate", bitrate, "-bufsize", "\(Int(Double(bitrate)! * 2))"]
            } else {
                args += ["-q:v", legacyQFactor]
            }
        }

        switch format {
        case .mp4, .mov, .mkv, .m4v, .threeGP, .threeG2, .ts, .f4v:
            var args = [
                "-c:v", (customVCodec?.isEmpty == false ? customVCodec! : "h264_videotoolbox"),
                "-pix_fmt", (customPixFmt?.isEmpty == false ? customPixFmt! : "yuv420p"),
                "-vf", evenScaleFilter
            ]
            if let profile = customProfile, !profile.isEmpty {
                args += ["-profile:v", profile]
            }
            if format == .m4v { args += ["-f", "ipod"] }
            else if format == .threeGP { args += ["-f", "3gp"] }
            else if format == .threeG2 { args += ["-f", "3g2"] }
            else if format == .ts { args += ["-f", "mpegts"] }
            else if format == .f4v { args += ["-f", "f4v"] }

            if let bitrate = targetVideoBitrate {
                args += ["-b:v", bitrate, "-maxrate", bitrate, "-bufsize", "\(Int(Double(bitrate)! * 2))"]
            } else {
                args += ["-q:v", vtQuality]
            }
            return args

        case .webm:
            let crf: String
            switch quality {
            case .low: crf = "36"
            case .medium: crf = "31"
            case .high: crf = "25"
            case .maximum: crf = "18"
            }

            var args = [
                "-c:v", "libvpx-vp9",
                "-pix_fmt", (customPixFmt?.isEmpty == false ? customPixFmt! : "yuv420p"),
                "-vf", evenScaleFilter
            ]

            if let bitrate = targetVideoBitrate {
                args += ["-b:v", bitrate, "-maxrate", bitrate, "-bufsize", "\(Int(Double(bitrate)! * 2))"]
            } else {
                args += ["-crf", crf, "-b:v", "0"]
            }
            return args

        case .avi:
            var args = ["-c:v", "mpeg4", "-vf", evenScaleFilter]
            applyBitrateOrLegacyQuality(&args)
            return args

        case .flv:
            var args = ["-c:v", "flv", "-vf", evenScaleFilter]
            applyBitrateOrLegacyQuality(&args)
            return args

        case .wmv, .asf:
            var args = ["-c:v", "wmv2", "-vf", evenScaleFilter]
            applyBitrateOrLegacyQuality(&args)
            args += ["-f", "asf"]
            return args

        case .mpg, .vob, .m2v:
            var args = ["-c:v", "mpeg2video", "-pix_fmt", (customPixFmt?.isEmpty == false ? customPixFmt! : "yuv420p"), "-vf", evenScaleFilter]
            applyBitrateOrLegacyQuality(&args)
            if format == .vob { args += ["-f", "vob"] }
            else if format == .m2v { args += ["-f", "mpeg2video"] }
            else { args += ["-f", "mpeg"] }
            return args

        default:
            var args = [
                "-c:v", (customVCodec?.isEmpty == false ? customVCodec! : "h264_videotoolbox"),
                "-pix_fmt", (customPixFmt?.isEmpty == false ? customPixFmt! : "yuv420p"),
                "-vf", evenScaleFilter
            ]
            if let bitrate = targetVideoBitrate {
                args += ["-b:v", bitrate, "-maxrate", bitrate, "-bufsize", "\(Int(Double(bitrate)! * 2))"]
            } else {
                args += ["-q:v", vtQuality]
            }
            return args
        }
    }

    func audioEncodingArgumentsForVideo(targetFormat: FileFormat, options: ConversionOptions = .default) -> [String] {
        if targetFormat == .m2v {
            return ["-an"]
        }
        let customBitrate = Self.customVideoAudioBitrateString(from: options)
        if let customACodec = options.customOptions["acodec"]?.trimmingCharacters(in: .whitespacesAndNewlines), !customACodec.isEmpty {
            let lowered = customACodec.lowercased()
            if lowered == "none" || lowered == "an" || lowered == "-an" {
                return ["-an"]
            }
            if lowered == "copy" {
                return ["-c:a", "copy"]
            }
            let isAACCodec = (lowered == "aac" || lowered == "aac_at")
            if !isAACCodec || ConversionOptions.h264AACVideoContainers.contains(targetFormat) {
                return ["-c:a", customACodec, "-b:a", customBitrate ?? "192k"]
            }
        }
        switch targetFormat {
        case .webm:
            return ["-c:a", "libopus", "-b:a", customBitrate ?? "128k"]
        case .avi:
            return ["-c:a", "libmp3lame", "-b:a", customBitrate ?? "192k"]
        case .flv:
            return ["-c:a", "libmp3lame", "-ar", "44100", "-b:a", customBitrate ?? "128k"]
        case .wmv, .asf:
            return ["-c:a", "wmav2", "-b:a", customBitrate ?? "192k"]
        case .mpg:
            return ["-c:a", "mp2", "-ar", "48000", "-b:a", customBitrate ?? "192k"]
        case .vob:
            return ["-c:a", "ac3", "-ar", "48000", "-ac", "2", "-b:a", customBitrate ?? "192k"]
        default:
            return ["-c:a", "aac", "-b:a", customBitrate ?? "192k"]
        }
    }
}

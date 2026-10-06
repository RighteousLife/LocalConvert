import Foundation
import os.log

// MARK: - Media Probe

/// Uses ffprobe to inspect audio and video media files
struct MediaProbe: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "MediaProbe")
    
    /// Probes a media file using ffprobe and extracts comprehensive container & stream information
    static func probe(url: URL, ffprobePath: String) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        let stdoutTask = Task { () -> Data in
            return stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task { () -> Data in
            return stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        
        do {
            try process.run()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            throw ConversionError.engineExecutionFailed(
                "Failed to execute ffprobe: \(error.localizedDescription)",
                underlyingError: error.localizedDescription
            )
        }
        
        if process.isRunning {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }
        let outputData = await stdoutTask.value
        let errorData = await stderrTask.value
        
        guard process.terminationStatus == 0 else {
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown ffprobe error"
            throw ConversionError.invalidInput("The media file could not be read or parsed by ffprobe: \(errorMsg)")
        }
        
        guard !outputData.isEmpty else {
            throw ConversionError.invalidInput("ffprobe returned empty output for \(url.lastPathComponent)")
        }
        
        let decoder = JSONDecoder()
        let dto: FFprobeOutputDTO
        do {
            dto = try decoder.decode(FFprobeOutputDTO.self, from: outputData)
        } catch {
            throw ConversionError.engineExecutionFailed(
                "Failed to parse ffprobe JSON metadata.",
                underlyingError: error.localizedDescription
            )
        }
        
        // Parse streams
        var streams: [MediaStreamInfo] = []
        if let rawStreams = dto.streams {
            for rawStream in rawStreams {
                let streamType: MediaStreamType
                switch rawStream.codec_type?.lowercased() {
                case "video": streamType = .video
                case "audio": streamType = .audio
                case "subtitle": streamType = .subtitle
                default: streamType = .other
                }
                
                // Parse frame rate (e.g. "30/1" or "29.97")
                var frameRate: Double? = nil
                if let rFr = rawStream.r_frame_rate, !rFr.isEmpty {
                    let parts = rFr.split(separator: "/")
                    if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                        frameRate = num / den
                    } else if let val = Double(rFr) {
                        frameRate = val
                    }
                }
                
                let streamDuration = rawStream.duration.flatMap { Double($0) }
                let bitRate = rawStream.bit_rate.flatMap { Int64($0) }
                let sampleRate = rawStream.sample_rate.flatMap { Int($0) }
                
                let streamInfo = MediaStreamInfo(
                    index: rawStream.index,
                    streamType: streamType,
                    codecName: rawStream.codec_name ?? "unknown",
                    codecLongName: rawStream.codec_long_name,
                    bitRate: bitRate,
                    width: rawStream.width,
                    height: rawStream.height,
                    frameRate: frameRate,
                    sampleRate: sampleRate,
                    channels: rawStream.channels,
                    duration: streamDuration
                )
                streams.append(streamInfo)
            }
        }
        
        let formatDuration = dto.format?.duration.flatMap { Double($0) } ?? 0.0
        let formatName = dto.format?.format_name ?? "unknown"
        let fileSize = dto.format?.size.flatMap { Int64($0) }
            ?? (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        let bitRate = dto.format?.bit_rate.flatMap { Int64($0) }
        
        return MediaInfo(
            url: url,
            formatName: formatName,
            duration: formatDuration,
            fileSize: fileSize,
            bitRate: bitRate,
            streams: streams
        )
    }
    
    /// Validates an output file created by FFmpeg to ensure it has valid media streams and non-zero duration
    static func validate(outputURL: URL, expectedFormat: FileFormat, ffprobePath: String) async throws -> MediaInfo {
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ConversionError.engineExecutionFailed(
                "Conversion output file does not exist at \(outputURL.lastPathComponent).",
                underlyingError: nil
            )
        }
        
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0
        guard fileSize > 0 else {
            throw ConversionError.engineExecutionFailed(
                "Conversion output file is 0 bytes: \(outputURL.lastPathComponent).",
                underlyingError: nil
            )
        }
        
        let info = try await probe(url: outputURL, ffprobePath: ffprobePath)
        
        if expectedFormat.category == .video {
            guard info.hasVideo else {
                throw ConversionError.engineExecutionFailed(
                    "Generated video file \(outputURL.lastPathComponent) contains no video stream.",
                    underlyingError: "Streams found: \(info.streams.map { $0.codecName }.joined(separator: ", "))"
                )
            }
        } else if expectedFormat.category == .audio {
            guard info.hasAudio else {
                throw ConversionError.engineExecutionFailed(
                    "Generated audio file \(outputURL.lastPathComponent) contains no audio stream.",
                    underlyingError: "Streams found: \(info.streams.map { $0.codecName }.joined(separator: ", "))"
                )
            }
        }
        
        return info
    }
}

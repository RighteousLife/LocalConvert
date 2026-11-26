import Foundation

// MARK: - Video Trim Mode

enum VideoTrimMode: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case frameAccurate = "Frame-Accurate (Re-encode)"
    case streamCopy = "Fast Stream Copy (Keyframe)"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .frameAccurate: return "Frame-Accurate"
        case .streamCopy: return "Stream Copy"
        }
    }

    var explanation: String {
        switch self {
        case .frameAccurate:
            return "Decodes and re-encodes the selected segment so start/end cuts match your requested timestamps as closely as frame timing allows while preserving A/V sync."
        case .streamCopy:
            return "Copies compressed video and audio packets without re-encoding for maximum speed. Cut boundaries depend on source keyframe (GOP) positions, so actual start time and duration may differ from your exact selection."
        }
    }
}

// MARK: - Video Trim Range

struct VideoTrimRange: Codable, Sendable, Equatable, Hashable {
    var startMilliseconds: Int64
    var endMilliseconds: Int64
    var mode: VideoTrimMode

    init(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        mode: VideoTrimMode = .frameAccurate
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.mode = mode
    }

    init(
        startSeconds: Double,
        endSeconds: Double,
        mode: VideoTrimMode = .frameAccurate
    ) {
        let clampedStart = startSeconds.isFinite ? startSeconds : 0
        let clampedEnd = endSeconds.isFinite ? endSeconds : 0
        self.startMilliseconds = Int64((clampedStart * 1000.0).rounded())
        self.endMilliseconds = Int64((clampedEnd * 1000.0).rounded())
        self.mode = mode
    }

    var startSeconds: Double {
        Double(startMilliseconds) / 1000.0
    }

    var endSeconds: Double {
        Double(endMilliseconds) / 1000.0
    }

    var durationMilliseconds: Int64 {
        max(0, endMilliseconds - startMilliseconds)
    }

    var durationSeconds: Double {
        Double(durationMilliseconds) / 1000.0
    }

    var ffmpegStartTimestamp: String {
        VideoTrimTimestamp.formatFFmpeg(milliseconds: startMilliseconds)
    }

    var ffmpegEndTimestamp: String {
        VideoTrimTimestamp.formatFFmpeg(milliseconds: endMilliseconds)
    }

    var ffmpegDurationTimestamp: String {
        VideoTrimTimestamp.formatFFmpeg(milliseconds: durationMilliseconds)
    }

    var displaySummary: String {
        let includeHours = max(startMilliseconds, endMilliseconds) >= 3_600_000
        let startStr = VideoTrimTimestamp.formatDisplay(milliseconds: startMilliseconds, includeHours: includeHours)
        let endStr = VideoTrimTimestamp.formatDisplay(milliseconds: endMilliseconds, includeHours: includeHours)
        let durStr = String(format: "%.2fs", durationSeconds)
        return "\(startStr) → \(endStr) (\(durStr))"
    }
}

// MARK: - Timestamp Parsing & Formatting (Exact Millisecond Arithmetic)

enum VideoTrimTimestamp: Sendable {

    /// Formats milliseconds into FFmpeg `-ss` / `-t` timestamp string `HH:MM:SS.mmm`.
    static func formatFFmpeg(milliseconds: Int64) -> String {
        let safeMs = max(0, milliseconds)
        let totalSeconds = safeMs / 1000
        let ms = safeMs % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, seconds, ms)
    }

    /// Formats milliseconds for compact UI display (`MM:SS.mm` or `HH:MM:SS.mm`).
    static func formatDisplay(milliseconds: Int64, includeHours: Bool = false) -> String {
        let safeMs = max(0, milliseconds)
        let roundedCentiseconds = (safeMs + 5) / 10
        let centiseconds = roundedCentiseconds % 100
        let totalSeconds = roundedCentiseconds / 100
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600

        if includeHours || hours > 0 {
            return String(format: "%02lld:%02lld:%02lld.%02lld", hours, minutes, seconds, centiseconds)
        }
        return String(format: "%02lld:%02lld.%02lld", minutes, seconds, centiseconds)
    }

    /// Formats seconds as centisecond UI display using exact integer rounding.
    static func formatDisplay(seconds: Double, includeHours: Bool = false) -> String {
        let safeMs = seconds.isFinite ? Int64((max(0, seconds) * 1000.0).rounded()) : 0
        return formatDisplay(milliseconds: safeMs, includeHours: includeHours)
    }

    /// Parses `SS(.mmm)`, `MM:SS(.mmm)`, or `HH:MM:SS(.mmm)` strings into exact non-negative milliseconds.
    static func parseMilliseconds(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("-"),
              !trimmed.contains("+"),
              !trimmed.contains(" ") else {
            return nil
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }

        func parseASCIIUnsignedInt(_ s: String, maxValue: Int64) -> Int64? {
            guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int64(s), value >= 0, value <= maxValue else {
                return nil
            }
            return value
        }

        func parseSecondsAndMilliseconds(_ segment: String, enforceSubMinute: Bool) -> Int64? {
            let dotParts = segment.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (1...2).contains(dotParts.count) else { return nil }

            let wholeStr = dotParts[0]
            let fracStr = dotParts.count == 2 ? dotParts[1] : ""

            if dotParts.count == 2 && fracStr.isEmpty {
                return nil
            }
            if wholeStr.isEmpty && fracStr.isEmpty {
                return nil
            }
            if !wholeStr.isEmpty && !wholeStr.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return nil
            }
            if !fracStr.isEmpty && !fracStr.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return nil
            }
            if enforceSubMinute && wholeStr.isEmpty {
                return nil
            }

            let wholeSeconds: Int64
            if wholeStr.isEmpty {
                wholeSeconds = 0
            } else {
                guard let parsedWhole = Int64(wholeStr), parsedWhole >= 0, parsedWhole <= 3_599_999 else {
                    return nil
                }
                wholeSeconds = parsedWhole
            }

            if enforceSubMinute && wholeSeconds >= 60 {
                return nil
            }

            var millis: Int64 = 0
            if !fracStr.isEmpty {
                let digits = Array(fracStr)
                let padded: String = {
                    if digits.count == 1 { return "\(digits[0])00" }
                    if digits.count == 2 { return "\(digits[0])\(digits[1])0" }
                    return String(digits.prefix(3))
                }()
                guard var baseMs = Int64(padded) else { return nil }
                if digits.count > 3, let fourth = digits[3].wholeNumberValue, fourth >= 5 {
                    baseMs += 1
                }
                millis = baseMs
            }

            return wholeSeconds * 1000 + millis
        }

        switch parts.count {
        case 1:
            return parseSecondsAndMilliseconds(parts[0], enforceSubMinute: false)

        case 2:
            guard let minutes = parseASCIIUnsignedInt(parts[0], maxValue: 59_999),
                  let secsMs = parseSecondsAndMilliseconds(parts[1], enforceSubMinute: true) else {
                return nil
            }
            return minutes * 60_000 + secsMs

        case 3:
            guard let hours = parseASCIIUnsignedInt(parts[0], maxValue: 999),
                  let minutes = parseASCIIUnsignedInt(parts[1], maxValue: 59),
                  let secsMs = parseSecondsAndMilliseconds(parts[2], enforceSubMinute: true) else {
                return nil
            }
            return hours * 3_600_000 + minutes * 60_000 + secsMs

        default:
            return nil
        }
    }
}

// MARK: - Video Trim Validation

struct VideoTrimValidationResult: Sendable, Equatable {
    let isValid: Bool
    let errorMessage: String?
    let warningMessage: String?
    let isStreamCopyCompatible: Bool
}

enum VideoTrimValidator: Sendable {
    static let minimumTrimDurationMilliseconds: Int64 = 100 // 0.10 seconds

    static func validate(
        range: VideoTrimRange,
        sourceDurationSeconds: Double?,
        inputInfo: MediaInfo? = nil,
        outputFormat: FileFormat? = nil
    ) -> VideoTrimValidationResult {
        let streamCopyCompatible: Bool
        if let inputInfo, let outputFormat {
            streamCopyCompatible = BaseFFmpegProvider.canStreamCopyContainerAndCodecs(
                inputInfo: inputInfo,
                targetFormat: outputFormat
            )
        } else if let outputFormat {
            streamCopyCompatible = (outputFormat.category == .video && [.mp4, .m4v, .mov, .mkv, .webm].contains(outputFormat))
        } else {
            streamCopyCompatible = true
        }

        guard range.startMilliseconds >= 0 else {
            return VideoTrimValidationResult(
                isValid: false,
                errorMessage: "Start time must be 0 or greater.",
                warningMessage: nil,
                isStreamCopyCompatible: streamCopyCompatible
            )
        }

        guard range.endMilliseconds > range.startMilliseconds else {
            return VideoTrimValidationResult(
                isValid: false,
                errorMessage: "End time must be greater than start time.",
                warningMessage: nil,
                isStreamCopyCompatible: streamCopyCompatible
            )
        }

        guard range.durationMilliseconds >= minimumTrimDurationMilliseconds else {
            return VideoTrimValidationResult(
                isValid: false,
                errorMessage: "Selected trim duration must be at least 0.10 seconds.",
                warningMessage: nil,
                isStreamCopyCompatible: streamCopyCompatible
            )
        }

        if let dur = sourceDurationSeconds, dur.isFinite, dur > 0 {
            let maxMs = Int64((dur * 1000.0).rounded())
            if range.endMilliseconds > maxMs {
                return VideoTrimValidationResult(
                    isValid: false,
                    errorMessage: "End time (\(VideoTrimTimestamp.formatDisplay(milliseconds: range.endMilliseconds))) exceeds source duration (\(VideoTrimTimestamp.formatDisplay(milliseconds: maxMs))).",
                    warningMessage: nil,
                    isStreamCopyCompatible: streamCopyCompatible
                )
            }
        }

        if range.mode == .streamCopy {
            if let outputFormat, outputFormat.category != .video {
                return VideoTrimValidationResult(
                    isValid: false,
                    errorMessage: "Fast Stream Copy requires a video container target (.\(outputFormat.fileExtension) requires Frame-Accurate re-encoding).",
                    warningMessage: nil,
                    isStreamCopyCompatible: false
                )
            }

            if !streamCopyCompatible, let inputInfo, let outputFormat {
                let vCodec = inputInfo.primaryVideoStream?.codecName ?? "unknown"
                let aCodecs = inputInfo.audioStreams.map(\.codecName).joined(separator: ", ")
                let streamDesc = aCodecs.isEmpty ? vCodec : "\(vCodec) + \(aCodecs)"
                return VideoTrimValidationResult(
                    isValid: false,
                    errorMessage: "Fast Stream Copy cannot remux (\(streamDesc)) directly into .\(outputFormat.fileExtension). Switch to Frame-Accurate (Re-encode) or choose a compatible container.",
                    warningMessage: nil,
                    isStreamCopyCompatible: false
                )
            }

            return VideoTrimValidationResult(
                isValid: true,
                errorMessage: nil,
                warningMessage: VideoTrimMode.streamCopy.explanation,
                isStreamCopyCompatible: streamCopyCompatible
            )
        }

        return VideoTrimValidationResult(
            isValid: true,
            errorMessage: nil,
            warningMessage: nil,
            isStreamCopyCompatible: streamCopyCompatible
        )
    }
}

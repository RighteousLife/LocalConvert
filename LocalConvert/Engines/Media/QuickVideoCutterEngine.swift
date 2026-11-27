import Foundation
import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - Multi-Segment Timeline Models

struct VideoSegment: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: UUID
    var startSeconds: Double
    var endSeconds: Double
    var isKept: Bool

    init(
        id: UUID = UUID(),
        startSeconds: Double,
        endSeconds: Double,
        isKept: Bool = true
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.isKept = isKept
    }

    var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }

    var startMilliseconds: Int64 {
        Int64((max(0, startSeconds) * 1000.0).rounded())
    }

    var endMilliseconds: Int64 {
        Int64((max(0, endSeconds) * 1000.0).rounded())
    }

    var cmTimeRange: CMTimeRange {
        let start = CMTime(seconds: max(0, startSeconds), preferredTimescale: 600)
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 600)
        return CMTimeRange(start: start, duration: duration)
    }

    var ffmpegStartTimestamp: String {
        VideoTrimTimestamp.formatFFmpeg(milliseconds: startMilliseconds)
    }

    var ffmpegDurationTimestamp: String {
        let durMs = max(100, Int64((durationSeconds * 1000.0).rounded()))
        return VideoTrimTimestamp.formatFFmpeg(milliseconds: durMs)
    }
}

enum QuickVideoRotation: Int, CaseIterable, Sendable, Codable, Identifiable, Hashable {
    case deg0 = 0
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270

    var id: Int { rawValue }

    var label: String {
        "\(rawValue)°"
    }

    func rotatedClockwise() -> QuickVideoRotation {
        switch self {
        case .deg0: return .deg90
        case .deg90: return .deg180
        case .deg180: return .deg270
        case .deg270: return .deg0
        }
    }

    var ffmpegTransposeFilter: String? {
        switch self {
        case .deg0: return nil
        case .deg90: return "transpose=1"
        case .deg180: return "transpose=1,transpose=1"
        case .deg270: return "transpose=2"
        }
    }
}

enum QuickVideoExportMode: String, CaseIterable, Sendable, Identifiable, Hashable {
    case losslessCut = "Lossless Cut"
    case compressedMP4 = "Compressed MP4"
    case quickGIF = "Quick GIF"

    var id: String { rawValue }

    var descriptionText: String {
        switch self {
        case .losslessCut:
            return "Stream-copies kept segments without re-encoding for near-instant export. Rotation & speed require Compressed MP4."
        case .compressedMP4:
            return "Re-encodes kept segments to H.264/AAC MP4 with full support for multi-segment cuts, mute, rotation, and playback speed."
        case .quickGIF:
            return "Creates an optimized animated GIF with palette generation from kept segments, including rotation and speed."
        }
    }
}

enum QuickVideoSnapshotFormat: String, CaseIterable, Sendable, Identifiable, Hashable {
    case png = "PNG"
    case jpeg = "JPEG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }
}

enum VideoCropAspectRatio: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case none = "Original"
    case free = "Free"
    case widescreen16x9 = "16:9"
    case vertical9x16 = "9:16"
    case square1x1 = "1:1"

    var id: String { rawValue }

    var aspectRatio: Double? {
        switch self {
        case .none, .free: return nil
        case .widescreen16x9: return 16.0 / 9.0
        case .vertical9x16: return 9.0 / 16.0
        case .square1x1: return 1.0
        }
    }
}

struct VideoCropConfiguration: Codable, Sendable, Equatable, Hashable {
    var aspectRatio: VideoCropAspectRatio
    var normalizedRect: NormalizedRect

    init(
        aspectRatio: VideoCropAspectRatio = .none,
        normalizedRect: NormalizedRect = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.aspectRatio = aspectRatio
        self.normalizedRect = normalizedRect
    }

    var isActive: Bool {
        guard aspectRatio != .none else { return false }
        if aspectRatio == .free {
            return normalizedRect.x > 0.001
                || normalizedRect.y > 0.001
                || normalizedRect.width < 0.999
                || normalizedRect.height < 0.999
        }
        return true
    }

    static func centeredNormalizedRect(
        for aspectRatio: VideoCropAspectRatio,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> NormalizedRect {
        guard let targetRatio = aspectRatio.aspectRatio,
              sourceWidth > 0,
              sourceHeight > 0 else {
            return aspectRatio == .free
                ? NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
                : NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        }
        let sourceRatio = Double(sourceWidth) / Double(sourceHeight)
        if sourceRatio > targetRatio {
            let normW = min(1.0, max(0.05, targetRatio / sourceRatio))
            let x = (1.0 - normW) / 2.0
            return NormalizedRect(x: x, y: 0.0, width: normW, height: 1.0)
        } else {
            let normH = min(1.0, max(0.05, sourceRatio / targetRatio))
            let y = (1.0 - normH) / 2.0
            return NormalizedRect(x: 0.0, y: y, width: 1.0, height: normH)
        }
    }
}

struct SRTSubtitleCue: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: Int
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

struct VideoAudioProcessingOptions: Codable, Sendable, Equatable, Hashable {
    var loudnessNormalize: Bool
    var trimSilence: Bool
    var targetIntegratedLUFS: Double
    var targetTruePeakDBTP: Double
    var targetLRA: Double
    var silenceThresholdDB: Double
    var silenceStopDurationSeconds: Double

    init(
        loudnessNormalize: Bool = false,
        trimSilence: Bool = false,
        targetIntegratedLUFS: Double = -16.0,
        targetTruePeakDBTP: Double = -1.5,
        targetLRA: Double = 11.0,
        silenceThresholdDB: Double = -50.0,
        silenceStopDurationSeconds: Double = 0.5
    ) {
        self.loudnessNormalize = loudnessNormalize
        self.trimSilence = trimSilence
        self.targetIntegratedLUFS = targetIntegratedLUFS
        self.targetTruePeakDBTP = targetTruePeakDBTP
        self.targetLRA = targetLRA
        self.silenceThresholdDB = silenceThresholdDB
        self.silenceStopDurationSeconds = silenceStopDurationSeconds
    }

    var hasAnyEffect: Bool {
        loudnessNormalize || trimSilence
    }
}

enum VideoExtractAudioFormat: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case m4a = "M4A"
    case mp3 = "MP3"
    case wav = "WAV"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        case .wav: return "wav"
        }
    }

    var fileFormat: FileFormat {
        switch self {
        case .m4a: return .m4a
        case .mp3: return .mp3
        case .wav: return .wav
        }
    }

    var utType: UTType {
        switch self {
        case .m4a: return UTType(filenameExtension: "m4a") ?? .mpeg4Audio
        case .mp3: return .mp3
        case .wav: return .wav
        }
    }

    var codecArguments: [String] {
        switch self {
        case .m4a:
            return ["-c:a", "aac", "-b:a", "256k"]
        case .mp3:
            return ["-c:a", "libmp3lame", "-q:a", "2"]
        case .wav:
            return ["-c:a", "pcm_s16le"]
        }
    }
}

struct MultiClipJoinRequest: Sendable, Equatable {
    let clipURLs: [URL]
    let destinationURL: URL
    let existingFileHandling: ExistingFileHandling
    let audioProcessing: VideoAudioProcessingOptions
    let subtitleURL: URL?

    init(
        clipURLs: [URL],
        destinationURL: URL,
        existingFileHandling: ExistingFileHandling = .createUnique,
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions(),
        subtitleURL: URL? = nil
    ) {
        self.clipURLs = clipURLs
        self.destinationURL = destinationURL
        self.existingFileHandling = existingFileHandling
        self.audioProcessing = audioProcessing
        self.subtitleURL = subtitleURL
    }
}

struct QuickVideoExportRequest: Sendable, Equatable {
    let inputURL: URL
    let destinationURL: URL
    let segments: [VideoSegment]
    let mode: QuickVideoExportMode
    let isMuted: Bool
    let rotation: QuickVideoRotation
    let speedMultiplier: Double
    let existingFileHandling: ExistingFileHandling
    let gifFPS: Int
    let gifMaxWidth: Int
    let cropConfiguration: VideoCropConfiguration
    let subtitleURL: URL?
    let audioProcessing: VideoAudioProcessingOptions

    init(
        inputURL: URL,
        destinationURL: URL,
        segments: [VideoSegment],
        mode: QuickVideoExportMode,
        isMuted: Bool = false,
        rotation: QuickVideoRotation = .deg0,
        speedMultiplier: Double = 1.0,
        existingFileHandling: ExistingFileHandling = .createUnique,
        gifFPS: Int = 15,
        gifMaxWidth: Int = 640,
        cropConfiguration: VideoCropConfiguration = VideoCropConfiguration(),
        subtitleURL: URL? = nil,
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions()
    ) {
        self.inputURL = inputURL
        self.destinationURL = destinationURL
        self.segments = segments
        self.mode = mode
        self.isMuted = isMuted
        self.rotation = rotation
        self.speedMultiplier = speedMultiplier
        self.existingFileHandling = existingFileHandling
        self.gifFPS = gifFPS
        self.gifMaxWidth = gifMaxWidth
        self.cropConfiguration = cropConfiguration
        self.subtitleURL = subtitleURL
        self.audioProcessing = audioProcessing
    }
}

// MARK: - Quick Video Cutter Engine

enum QuickVideoCutterEngine: Sendable {

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "QuickVideoCutterEngine")
    static let minimumSegmentDuration: Double = 0.10
    static let supportedSpeedMultipliers: [Double] = [0.5, 1.0, 1.5, 2.0]
    static let minSpeedMultiplier: Double = 0.5
    static let maxSpeedMultiplier: Double = 2.0

    // MARK: - Timeline Segment Math

    static func initialSegments(durationSeconds: Double) -> [VideoSegment] {
        let safeDuration = (durationSeconds.isFinite && durationSeconds > 0)
            ? max(minimumSegmentDuration, durationSeconds)
            : minimumSegmentDuration
        return [VideoSegment(startSeconds: 0, endSeconds: safeDuration, isKept: true)]
    }

    static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1.0 }
        return min(max(speed, minSpeedMultiplier), maxSpeedMultiplier)
    }

    /// Trims the start (`In`) of the active segment (or the segment enclosing `timeSeconds`),
    /// clamped cleanly against the previous segment end and `endSeconds - minimumSegmentDuration`.
    static func setInPoint(
        at timeSeconds: Double,
        selectedSegmentID: UUID?,
        in segments: [VideoSegment],
        totalDuration: Double
    ) -> [VideoSegment] {
        guard !segments.isEmpty, timeSeconds.isFinite, totalDuration.isFinite, totalDuration > 0 else {
            return segments
        }
        let sorted = segments.sorted { $0.startSeconds < $1.startSeconds }
        let targetIndex = resolveTargetSegmentIndex(
            at: timeSeconds,
            selectedSegmentID: selectedSegmentID,
            in: sorted
        )
        guard let idx = targetIndex else { return sorted }

        var updated = sorted
        let lowerBound = idx > 0 ? updated[idx - 1].endSeconds : 0.0
        let upperBound = max(lowerBound, updated[idx].endSeconds - minimumSegmentDuration)
        let clamped = min(max(timeSeconds, lowerBound), upperBound)
        guard updated[idx].endSeconds - clamped >= minimumSegmentDuration - 1e-6 else {
            return sorted
        }
        updated[idx].startSeconds = clamped
        return updated
    }

    /// Trims the end (`Out`) of the active segment (or the segment enclosing `timeSeconds`),
    /// clamped cleanly against `startSeconds + minimumSegmentDuration` and the next segment start / `totalDuration`.
    static func setOutPoint(
        at timeSeconds: Double,
        selectedSegmentID: UUID?,
        in segments: [VideoSegment],
        totalDuration: Double
    ) -> [VideoSegment] {
        guard !segments.isEmpty, timeSeconds.isFinite, totalDuration.isFinite, totalDuration > 0 else {
            return segments
        }
        let sorted = segments.sorted { $0.startSeconds < $1.startSeconds }
        let targetIndex = resolveTargetSegmentIndex(
            at: timeSeconds,
            selectedSegmentID: selectedSegmentID,
            in: sorted
        )
        guard let idx = targetIndex else { return sorted }

        var updated = sorted
        let lowerBound = updated[idx].startSeconds + minimumSegmentDuration
        let upperBound = idx + 1 < updated.count ? min(totalDuration, updated[idx + 1].startSeconds) : totalDuration
        guard upperBound >= lowerBound - 1e-6 else {
            return sorted
        }
        let clamped = min(max(timeSeconds, lowerBound), upperBound)
        guard clamped - updated[idx].startSeconds >= minimumSegmentDuration - 1e-6 else {
            return sorted
        }
        updated[idx].endSeconds = clamped
        return updated
    }

    /// Splits the segment enclosing `timeSeconds` into two segments at `timeSeconds`.
    /// Rejects splits within `minimumSegmentDuration` of either boundary so zero-duration segments never arise.
    static func splitSegment(
        at timeSeconds: Double,
        in segments: [VideoSegment]
    ) -> [VideoSegment] {
        guard timeSeconds.isFinite else { return segments }
        let sorted = segments.sorted { $0.startSeconds < $1.startSeconds }

        guard let idx = sorted.firstIndex(where: { seg in
            timeSeconds >= seg.startSeconds + minimumSegmentDuration - 1e-6 &&
            timeSeconds <= seg.endSeconds - minimumSegmentDuration + 1e-6
        }) else {
            return sorted
        }

        let target = sorted[idx]
        let splitPoint = min(
            max(timeSeconds, target.startSeconds + minimumSegmentDuration),
            target.endSeconds - minimumSegmentDuration
        )
        guard splitPoint - target.startSeconds >= minimumSegmentDuration - 1e-6,
              target.endSeconds - splitPoint >= minimumSegmentDuration - 1e-6 else {
            return sorted
        }

        let firstHalf = VideoSegment(
            id: target.id,
            startSeconds: target.startSeconds,
            endSeconds: splitPoint,
            isKept: target.isKept
        )
        let secondHalf = VideoSegment(
            startSeconds: splitPoint,
            endSeconds: target.endSeconds,
            isKept: target.isKept
        )

        var result = sorted
        result.replaceSubrange(idx...idx, with: [firstHalf, secondHalf])
        return result
    }

    /// Toggles `isKept` on the specified segment while preventing an empty kept set.
    static func toggleSegmentKept(
        id: UUID,
        in segments: [VideoSegment]
    ) -> [VideoSegment] {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else {
            return segments
        }
        var updated = segments
        if updated[idx].isKept {
            let keptCount = updated.filter(\.isKept).count
            guard keptCount > 1 else {
                return segments
            }
            updated[idx].isKept = false
        } else {
            updated[idx].isKept = true
        }
        return updated
    }

    /// Marks the specified segment as deleted (`isKept = false`), preventing an empty kept set.
    static func deleteSegment(
        id: UUID,
        in segments: [VideoSegment]
    ) -> [VideoSegment] {
        guard let idx = segments.firstIndex(where: { $0.id == id }) else {
            return segments
        }
        guard segments[idx].isKept else { return segments }
        let keptCount = segments.filter(\.isKept).count
        guard keptCount > 1 else { return segments }
        var updated = segments
        updated[idx].isKept = false
        return updated
    }

    /// Validates and normalizes kept segments into sorted, non-overlapping, clamped ranges.
    static func normalizedKeptSegments(
        from segments: [VideoSegment],
        totalDuration: Double? = nil
    ) throws -> [VideoSegment] {
        let kept = segments
            .filter(\.isKept)
            .sorted { $0.startSeconds < $1.startSeconds }

        guard !kept.isEmpty else {
            throw ConversionError.invalidInput("At least one kept video segment is required for export.")
        }

        let maxDuration = totalDuration.flatMap { ($0.isFinite && $0 > 0) ? $0 : nil }
        var validated: [VideoSegment] = []
        validated.reserveCapacity(kept.count)

        for seg in kept {
            guard seg.startSeconds.isFinite, seg.endSeconds.isFinite else {
                throw ConversionError.invalidInput("Segment contains non-finite timestamps.")
            }
            let clampedStart = max(0.0, seg.startSeconds)
            let clampedEnd = maxDuration.map { min($0, seg.endSeconds) } ?? seg.endSeconds
            guard clampedEnd - clampedStart >= minimumSegmentDuration - 1e-6 else {
                throw ConversionError.invalidInput("Every kept segment must be at least \(String(format: "%.2f", minimumSegmentDuration)) seconds long.")
            }
            if let prev = validated.last, clampedStart < prev.endSeconds - 1e-4 {
                throw ConversionError.invalidInput("Kept video segments must not overlap.")
            }
            validated.append(
                VideoSegment(
                    id: seg.id,
                    startSeconds: clampedStart,
                    endSeconds: clampedEnd,
                    isKept: true
                )
            )
        }

        return validated
    }

    static func totalKeptDurationSeconds(in segments: [VideoSegment]) -> Double {
        segments.filter(\.isKept).reduce(0.0) { $0 + $1.durationSeconds }
    }

    private static func resolveTargetSegmentIndex(
        at timeSeconds: Double,
        selectedSegmentID: UUID?,
        in sortedSegments: [VideoSegment]
    ) -> Int? {
        if let selectedID = selectedSegmentID,
           let idx = sortedSegments.firstIndex(where: { $0.id == selectedID }) {
            return idx
        }
        if let idx = sortedSegments.firstIndex(where: {
            timeSeconds >= $0.startSeconds && timeSeconds <= $0.endSeconds
        }) {
            return idx
        }
        return sortedSegments.indices.first
    }

    // MARK: - Pure FFmpeg Argument Construction

    static func buildSingleSegmentLosslessCutArguments(
        inputURL: URL,
        outputURL: URL,
        segment: VideoSegment,
        isMuted: Bool = false,
        includeProgressPipe: Bool = false
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-ss", segment.ffmpegStartTimestamp,
            "-i", inputURL.path,
            "-t", segment.ffmpegDurationTimestamp
        ]
        if includeProgressPipe {
            args += ["-progress", "pipe:1", "-nostats"]
        }
        args += ["-c", "copy"]
        if isMuted {
            args.append("-an")
        }
        args += ["-avoid_negative_ts", "make_zero"]
        let ext = outputURL.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            args += ["-movflags", "+faststart"]
        }
        args.append(outputURL.path)
        return args
    }

    static func buildLosslessConcatArguments(
        concatListURL: URL,
        outputURL: URL,
        isMuted: Bool = false,
        includeProgressPipe: Bool = false
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", concatListURL.path
        ]
        if includeProgressPipe {
            args += ["-progress", "pipe:1", "-nostats"]
        }
        args += ["-c", "copy"]
        if isMuted {
            args.append("-an")
        }
        let ext = outputURL.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            args += ["-movflags", "+faststart"]
        }
        args.append(outputURL.path)
        return args
    }

    /// Unified lossless cut argument builder:
    /// - 1 kept segment: direct `-ss/-i/-t -c copy`
    /// - >1 kept segments: concat demuxer arguments referencing `concatListURL`
    static func buildCutArguments(
        inputURL: URL,
        outputURL: URL,
        segments: [VideoSegment],
        concatListURL: URL? = nil,
        isMuted: Bool = false,
        includeProgressPipe: Bool = false
    ) throws -> [String] {
        let kept = try normalizedKeptSegments(from: segments)
        if kept.count == 1 {
            return buildSingleSegmentLosslessCutArguments(
                inputURL: inputURL,
                outputURL: outputURL,
                segment: kept[0],
                isMuted: isMuted,
                includeProgressPipe: includeProgressPipe
            )
        }
        guard let concatListURL else {
            throw ConversionError.invalidInput("A concat list URL is required for multi-segment lossless cut.")
        }
        return buildLosslessConcatArguments(
            concatListURL: concatListURL,
            outputURL: outputURL,
            isMuted: isMuted,
            includeProgressPipe: includeProgressPipe
        )
    }

    static func formatConcatListFile(segmentURLs: [URL]) -> String {
        segmentURLs.map { segURL in
            let escaped = segURL.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escaped)'"
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - Video Studio Pure Filter & Argument Builders

    static func pixelCropRect(
        from configuration: VideoCropConfiguration,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (width: Int, height: Int, x: Int, y: Int)? {
        guard configuration.isActive, sourceWidth >= 2, sourceHeight >= 2 else {
            return nil
        }

        let rect = configuration.normalizedRect
        var rawW = Int((rect.width * Double(sourceWidth)).rounded())
        var rawH = Int((rect.height * Double(sourceHeight)).rounded())
        var rawX = Int((rect.x * Double(sourceWidth)).rounded())
        var rawY = Int((rect.y * Double(sourceHeight)).rounded())

        rawW = min(sourceWidth, max(2, rawW))
        rawH = min(sourceHeight, max(2, rawH))

        if let targetRatio = configuration.aspectRatio.aspectRatio {
            let currentRatio = Double(rawW) / Double(max(1, rawH))
            if abs(currentRatio - targetRatio) > 0.01 {
                if currentRatio > targetRatio {
                    rawW = Int((Double(rawH) * targetRatio).rounded())
                } else {
                    rawH = Int((Double(rawW) / targetRatio).rounded())
                }
            }
        }

        let evenW = max(2, min(sourceWidth - (sourceWidth % 2), (rawW / 2) * 2))
        let evenH = max(2, min(sourceHeight - (sourceHeight % 2), (rawH / 2) * 2))
        rawX = min(max(0, rawX), max(0, sourceWidth - evenW))
        rawY = min(max(0, rawY), max(0, sourceHeight - evenH))
        return (width: evenW, height: evenH, x: rawX, y: rawY)
    }

    static func buildCropFilter(
        configuration: VideoCropConfiguration,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil
    ) -> String? {
        guard configuration.isActive else { return nil }

        if let w = sourceWidth, let h = sourceHeight, w >= 2, h >= 2,
           let px = pixelCropRect(from: configuration, sourceWidth: w, sourceHeight: h) {
            return "crop=\(px.width):\(px.height):\(px.x):\(px.y)"
        }

        let r = configuration.normalizedRect
        let isDefaultFullRect = r.x <= 0.001 && r.y <= 0.001 && r.width >= 0.999 && r.height >= 0.999

        if isDefaultFullRect {
            switch configuration.aspectRatio {
            case .none, .free:
                return nil
            case .widescreen16x9:
                return "crop=trunc(min(iw\\,ih*16/9)/2)*2:trunc(min(ih\\,iw*9/16)/2)*2:(iw-ow)/2:(ih-oh)/2"
            case .vertical9x16:
                return "crop=trunc(min(iw\\,ih*9/16)/2)*2:trunc(min(ih\\,iw*16/9)/2)*2:(iw-ow)/2:(ih-oh)/2"
            case .square1x1:
                return "crop=trunc(min(iw\\,ih)/2)*2:trunc(min(ih\\,iw)/2)*2:(iw-ow)/2:(ih-oh)/2"
            }
        }

        let wFrac = String(format: "%.4f", r.width)
        let hFrac = String(format: "%.4f", r.height)
        let xFrac = String(format: "%.4f", r.x)
        let yFrac = String(format: "%.4f", r.y)
        return "crop=trunc(iw*\(wFrac)/2)*2:trunc(ih*\(hFrac)/2)*2:trunc(iw*\(xFrac)):trunc(ih*\(yFrac))"
    }

    static func escapeFFmpegFilterPath(_ path: String) -> String {
        var escaped = path
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: ":", with: "\\:")
        escaped = escaped.replacingOccurrences(of: "'", with: "'\\\\\\''")
        return escaped
    }

    static func buildSubtitleBurnInFilter(srtURL: URL) -> String {
        "subtitles='\(escapeFFmpegFilterPath(srtURL.path))'"
    }

    static func buildAudioProcessingFilters(options: VideoAudioProcessingOptions) -> [String] {
        var filters: [String] = []
        if options.trimSilence {
            let thresh = formatCleanFilterNumber(options.silenceThresholdDB, maxDecimals: 1)
            let stopDur = formatCleanFilterNumber(max(0.05, options.silenceStopDurationSeconds), maxDecimals: 2)
            filters.append(
                "silenceremove=start_periods=1:start_threshold=\(thresh)dB:stop_periods=-1:stop_duration=\(stopDur):stop_threshold=\(thresh)dB"
            )
        }
        if options.loudnessNormalize {
            let lufs = formatCleanFilterNumber(min(-5.0, max(-36.0, options.targetIntegratedLUFS)), maxDecimals: 1)
            let tp = formatCleanFilterNumber(min(0.0, max(-9.0, options.targetTruePeakDBTP)), maxDecimals: 1)
            let lra = formatCleanFilterNumber(min(50.0, max(1.0, options.targetLRA)), maxDecimals: 1)
            filters.append("loudnorm=I=\(lufs):TP=\(tp):LRA=\(lra)")
        }
        return filters
    }

    private static func formatCleanFilterNumber(_ value: Double, maxDecimals: Int) -> String {
        let formatted = String(format: "%.\(maxDecimals)f", value)
        guard formatted.contains(".") else { return formatted }
        var trimmed = formatted
        while trimmed.last == "0" {
            trimmed.removeLast()
        }
        if trimmed.last == "." {
            trimmed.removeLast()
        }
        return trimmed
    }

    static func parseSRTFile(at url: URL) throws -> [SRTSubtitleCue] {
        let data = try Data(contentsOf: url)
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
        return parseSRTCues(from: raw)
    }

    static func parseSRTCues(from content: String) -> [SRTSubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SRTSubtitleCue] = []
        var nextID = 1

        for rawBlock in blocks {
            let lines = rawBlock
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            let arrowIndex = lines.firstIndex(where: { $0.contains("-->") })
            guard let tsLineIdx = arrowIndex else { continue }

            let tsLine = lines[tsLineIdx]
            let parts = tsLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseSRTTimestamp(parts[0]),
                  let end = parseSRTTimestamp(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]),
                  end > start else {
                continue
            }

            let textLines = lines.dropFirst(tsLineIdx + 1)
            let rawText = textLines.joined(separator: "\n")
            let cleanText = stripBasicSRTMarkup(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }

            let explicitID = tsLineIdx > 0 ? Int(lines[0]) : nil
            cues.append(
                SRTSubtitleCue(
                    id: explicitID ?? nextID,
                    startSeconds: start,
                    endSeconds: end,
                    text: cleanText
                )
            )
            nextID += 1
        }

        return cues.sorted { $0.startSeconds < $1.startSeconds }
    }

    static func remapSRTCues(
        _ cues: [SRTSubtitleCue],
        keptSegments: [VideoSegment],
        speedMultiplier: Double = 1.0
    ) -> [SRTSubtitleCue] {
        let speed = clampedSpeed(speedMultiplier)
        var remapped: [SRTSubtitleCue] = []
        var timelineOffset = 0.0
        var nextID = 1

        for seg in keptSegments {
            for cue in cues {
                let overlapStart = max(cue.startSeconds, seg.startSeconds)
                let overlapEnd = min(cue.endSeconds, seg.endSeconds)
                guard overlapEnd - overlapStart >= 0.02 else { continue }
                let outStart = (timelineOffset + (overlapStart - seg.startSeconds)) / speed
                let outEnd = (timelineOffset + (overlapEnd - seg.startSeconds)) / speed
                remapped.append(
                    SRTSubtitleCue(
                        id: nextID,
                        startSeconds: outStart,
                        endSeconds: outEnd,
                        text: cue.text
                    )
                )
                nextID += 1
            }
            timelineOffset += seg.durationSeconds
        }

        return remapped
    }

    private static func parseSRTTimestamp(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 3 {
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let s = Double(parts[2]),
                  h >= 0, m >= 0, s >= 0 else { return nil }
            return h * 3600.0 + m * 60.0 + s
        } else {
            guard let m = Double(parts[0]),
                  let s = Double(parts[1]),
                  m >= 0, s >= 0 else { return nil }
            return m * 60.0 + s
        }
    }

    private static func stripBasicSRTMarkup(_ text: String) -> String {
        guard text.contains("<") || text.contains("{") else { return text }
        var output = text
        if let htmlRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
            output = htmlRegex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output),
                withTemplate: ""
            )
        }
        if let assRegex = try? NSRegularExpression(pattern: "\\{\\\\[^}]+\\}") {
            output = assRegex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output),
                withTemplate: ""
            )
        }
        return output
    }

    static func buildCompressedMP4Arguments(
        inputURL: URL,
        outputURL: URL,
        segments: [VideoSegment],
        hasAudio: Bool = true,
        isMuted: Bool = false,
        rotation: QuickVideoRotation = .deg0,
        speedMultiplier: Double = 1.0,
        cropConfiguration: VideoCropConfiguration = VideoCropConfiguration(),
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        subtitleURL: URL? = nil,
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions(),
        includeProgressPipe: Bool = false
    ) throws -> [String] {
        try buildCompressedMP4ArgumentsInternal(
            inputURL: inputURL,
            outputURL: outputURL,
            segments: segments,
            hasAudio: hasAudio,
            isMuted: isMuted,
            rotation: rotation,
            speedMultiplier: speedMultiplier,
            cropConfiguration: cropConfiguration,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            subtitleURL: subtitleURL,
            subtitleOverlayConcatURL: nil,
            audioProcessing: audioProcessing,
            includeProgressPipe: includeProgressPipe
        )
    }

    private static func buildCompressedMP4ArgumentsInternal(
        inputURL: URL,
        outputURL: URL,
        segments: [VideoSegment],
        hasAudio: Bool = true,
        isMuted: Bool = false,
        rotation: QuickVideoRotation = .deg0,
        speedMultiplier: Double = 1.0,
        cropConfiguration: VideoCropConfiguration = VideoCropConfiguration(),
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        subtitleURL: URL? = nil,
        subtitleOverlayConcatURL: URL? = nil,
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions(),
        includeProgressPipe: Bool = false
    ) throws -> [String] {
        let kept = try normalizedKeptSegments(from: segments)
        let speed = clampedSpeed(speedMultiplier)
        let includeAudio = hasAudio && !isMuted

        var filterParts: [String] = []
        var concatInputs: [String] = []

        for (index, seg) in kept.enumerated() {
            let startStr = String(format: "%.3f", seg.startSeconds)
            let endStr = String(format: "%.3f", seg.endSeconds)
            filterParts.append("[0:v]trim=start=\(startStr):end=\(endStr),setpts=PTS-STARTPTS[v\(index)]")
            if includeAudio {
                filterParts.append("[0:a]atrim=start=\(startStr):end=\(endStr),asetpts=PTS-STARTPTS[a\(index)]")
                concatInputs.append("[v\(index)][a\(index)]")
            } else {
                concatInputs.append("[v\(index)]")
            }
        }

        let videoSourcePad: String
        let audioSourcePad: String?

        if kept.count == 1 {
            videoSourcePad = "[v0]"
            audioSourcePad = includeAudio ? "[a0]" : nil
        } else {
            let aCount = includeAudio ? 1 : 0
            if includeAudio {
                filterParts.append("\(concatInputs.joined())concat=n=\(kept.count):v=1:a=\(aCount)[vcat][acat]")
                videoSourcePad = "[vcat]"
                audioSourcePad = "[acat]"
            } else {
                filterParts.append("\(concatInputs.joined())concat=n=\(kept.count):v=1:a=0[vcat]")
                videoSourcePad = "[vcat]"
                audioSourcePad = nil
            }
        }

        var videoTransformFilters: [String] = []
        if let transpose = rotation.ffmpegTransposeFilter {
            videoTransformFilters.append(transpose)
        }
        let rotatedDimensions = rotatedPixelDimensions(width: sourceWidth, height: sourceHeight, rotation: rotation)
        if let cropFilter = buildCropFilter(
            configuration: cropConfiguration,
            sourceWidth: rotatedDimensions.width,
            sourceHeight: rotatedDimensions.height
        ) {
            videoTransformFilters.append(cropFilter)
        }
        if abs(speed - 1.0) > 0.001 {
            let ptsScale = String(format: "%.6f", 1.0 / speed)
            videoTransformFilters.append("setpts=\(ptsScale)*PTS")
        }
        videoTransformFilters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        if let subtitleURL, subtitleOverlayConcatURL == nil {
            videoTransformFilters.append(buildSubtitleBurnInFilter(srtURL: subtitleURL))
        }

        if subtitleOverlayConcatURL != nil {
            filterParts.append("\(videoSourcePad)\(videoTransformFilters.joined(separator: ","))[vpre]")
            filterParts.append("[vpre][1:v]overlay=0:H-h:eof_action=pass[vout]")
        } else {
            filterParts.append("\(videoSourcePad)\(videoTransformFilters.joined(separator: ","))[vout]")
        }

        if let audioSourcePad {
            var audioFilters: [String] = []
            if abs(speed - 1.0) > 0.001 {
                audioFilters.append(buildAtempoFilterChain(speed: speed))
            }
            audioFilters.append(contentsOf: buildAudioProcessingFilters(options: audioProcessing))
            let audioChain = audioFilters.isEmpty ? "anull" : audioFilters.joined(separator: ",")
            filterParts.append("\(audioSourcePad)\(audioChain)[aout]")
        }

        let filterGraph = filterParts.joined(separator: ";")
        var args: [String] = ["-y", "-i", inputURL.path]
        if let subtitleOverlayConcatURL {
            args += ["-f", "concat", "-safe", "0", "-i", subtitleOverlayConcatURL.path]
        }
        if includeProgressPipe {
            args += ["-progress", "pipe:1", "-nostats"]
        }
        args += [
            "-filter_complex", filterGraph,
            "-map", "[vout]"
        ]
        if includeAudio {
            args += ["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"]
        } else {
            args.append("-an")
        }
        args += [
            "-sn",
            "-c:v", "h264_videotoolbox",
            "-pix_fmt", "yuv420p",
            "-q:v", "65",
            "-movflags", "+faststart",
            outputURL.path
        ]
        return args
    }

    static func buildGIFArguments(
        inputURL: URL,
        outputURL: URL,
        segments: [VideoSegment],
        rotation: QuickVideoRotation = .deg0,
        speedMultiplier: Double = 1.0,
        fps: Int = 15,
        maxWidth: Int = 640,
        cropConfiguration: VideoCropConfiguration = VideoCropConfiguration(),
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        includeProgressPipe: Bool = false
    ) throws -> [String] {
        let kept = try normalizedKeptSegments(from: segments)
        let speed = clampedSpeed(speedMultiplier)
        let safeFPS = min(max(fps, 1), 30)
        let safeWidth = min(max(maxWidth, 120), 1920)

        var filterParts: [String] = []
        var concatInputs: [String] = []
        for (index, seg) in kept.enumerated() {
            let startStr = String(format: "%.3f", seg.startSeconds)
            let endStr = String(format: "%.3f", seg.endSeconds)
            filterParts.append("[0:v]trim=start=\(startStr):end=\(endStr),setpts=PTS-STARTPTS[v\(index)]")
            concatInputs.append("[v\(index)]")
        }

        let sourcePad: String
        if kept.count == 1 {
            sourcePad = "[v0]"
        } else {
            filterParts.append("\(concatInputs.joined())concat=n=\(kept.count):v=1:a=0[vcat]")
            sourcePad = "[vcat]"
        }

        var transformFilters: [String] = []
        if let transpose = rotation.ffmpegTransposeFilter {
            transformFilters.append(transpose)
        }
        let rotatedDimensions = rotatedPixelDimensions(width: sourceWidth, height: sourceHeight, rotation: rotation)
        if let cropFilter = buildCropFilter(
            configuration: cropConfiguration,
            sourceWidth: rotatedDimensions.width,
            sourceHeight: rotatedDimensions.height
        ) {
            transformFilters.append(cropFilter)
        }
        if abs(speed - 1.0) > 0.001 {
            let ptsScale = String(format: "%.6f", 1.0 / speed)
            transformFilters.append("setpts=\(ptsScale)*PTS")
        }
        transformFilters.append("fps=\(safeFPS)")
        transformFilters.append("scale=min(\(safeWidth)\\,iw):-1:flags=lanczos")
        transformFilters.append("split[g1][g2]")

        filterParts.append("\(sourcePad)\(transformFilters.joined(separator: ","))")
        filterParts.append("[g1]palettegen=stats_mode=diff[pal]")
        filterParts.append("[g2][pal]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle[gifout]")

        var args: [String] = ["-y", "-i", inputURL.path]
        if includeProgressPipe {
            args += ["-progress", "pipe:1", "-nostats"]
        }
        args += [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[gifout]",
            "-an",
            "-sn",
            "-loop", "0",
            outputURL.path
        ]
        return args
    }

    static func buildMultiClipConcatDemuxerArguments(
        concatListURL: URL,
        outputURL: URL,
        includeAudio: Bool = true,
        includeProgressPipe: Bool = false
    ) -> [String] {
        buildLosslessConcatArguments(
            concatListURL: concatListURL,
            outputURL: outputURL,
            isMuted: !includeAudio,
            includeProgressPipe: includeProgressPipe
        )
    }

    static func buildMultiClipConcatFilterArguments(
        inputURLs: [URL],
        outputURL: URL,
        targetWidth: Int,
        targetHeight: Int,
        hasAudioPerClip: [Bool],
        clipDurations: [Double] = [],
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions(),
        subtitleURL: URL? = nil,
        includeProgressPipe: Bool = false
    ) throws -> [String] {
        try buildMultiClipConcatFilterArgumentsInternal(
            inputURLs: inputURLs,
            outputURL: outputURL,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            hasAudioPerClip: hasAudioPerClip,
            clipDurations: clipDurations,
            audioProcessing: audioProcessing,
            subtitleURL: subtitleURL,
            subtitleOverlayConcatURL: nil,
            includeProgressPipe: includeProgressPipe
        )
    }

    private static func buildMultiClipConcatFilterArgumentsInternal(
        inputURLs: [URL],
        outputURL: URL,
        targetWidth: Int,
        targetHeight: Int,
        hasAudioPerClip: [Bool],
        clipDurations: [Double] = [],
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions(),
        subtitleURL: URL? = nil,
        subtitleOverlayConcatURL: URL? = nil,
        includeProgressPipe: Bool = false
    ) throws -> [String] {
        guard inputURLs.count >= 2 else {
            throw ConversionError.invalidInput("At least 2 video clips are required to join.")
        }
        let evenW = max(2, (targetWidth / 2) * 2)
        let evenH = max(2, (targetHeight / 2) * 2)
        let anyHasAudio = hasAudioPerClip.contains(true)

        var args: [String] = ["-y"]
        for url in inputURLs {
            args += ["-i", url.path]
        }
        if let subtitleOverlayConcatURL {
            args += ["-f", "concat", "-safe", "0", "-i", subtitleOverlayConcatURL.path]
        }
        if includeProgressPipe {
            args += ["-progress", "pipe:1", "-nostats"]
        }

        var filterParts: [String] = []
        var concatInputs: [String] = []

        for index in inputURLs.indices {
            filterParts.append(
                "[\(index):v]scale=\(evenW):\(evenH):force_original_aspect_ratio=decrease,pad=\(evenW):\(evenH):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)]"
            )
            if anyHasAudio {
                let clipHasAudio = index < hasAudioPerClip.count ? hasAudioPerClip[index] : false
                if clipHasAudio {
                    filterParts.append("[\(index):a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a\(index)]")
                } else {
                    let dur = index < clipDurations.count ? max(0.1, clipDurations[index]) : 1.0
                    let durStr = String(format: "%.3f", dur)
                    filterParts.append("anullsrc=channel_layout=stereo:sample_rate=48000:d=\(durStr)[a\(index)]")
                }
                concatInputs.append("[v\(index)][a\(index)]")
            } else {
                concatInputs.append("[v\(index)]")
            }
        }

        let audioCount = anyHasAudio ? 1 : 0
        if anyHasAudio {
            filterParts.append("\(concatInputs.joined())concat=n=\(inputURLs.count):v=1:a=\(audioCount)[vcat][acat]")
        } else {
            filterParts.append("\(concatInputs.joined())concat=n=\(inputURLs.count):v=1:a=0[vcat]")
        }

        if let subtitleOverlayConcatURL {
            let subInputIndex = inputURLs.count
            filterParts.append("[vcat][\(subInputIndex):v]overlay=0:H-h:eof_action=pass[vout]")
        } else if let subtitleURL {
            filterParts.append("[vcat]\(buildSubtitleBurnInFilter(srtURL: subtitleURL))[vout]")
        } else {
            filterParts.append("[vcat]null[vout]")
        }

        if anyHasAudio {
            let audioFilters = buildAudioProcessingFilters(options: audioProcessing)
            let audioChain = audioFilters.isEmpty ? "anull" : audioFilters.joined(separator: ",")
            filterParts.append("[acat]\(audioChain)[aout]")
        }

        args += [
            "-filter_complex", filterParts.joined(separator: ";"),
            "-map", "[vout]"
        ]
        if anyHasAudio {
            args += ["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"]
        } else {
            args.append("-an")
        }
        args += [
            "-sn",
            "-c:v", "h264_videotoolbox",
            "-pix_fmt", "yuv420p",
            "-q:v", "65",
            "-movflags", "+faststart",
            outputURL.path
        ]
        return args
    }

    static func canStreamCopyConcat(infos: [MediaInfo]) -> Bool {
        guard infos.count >= 2 else { return false }
        guard let first = infos.first,
              let firstVideo = first.primaryVideoStream,
              let firstWidth = firstVideo.width,
              let firstHeight = firstVideo.height else {
            return false
        }
        let firstVideoCodec = firstVideo.codecName.lowercased()
        let firstHasAudio = first.hasAudio
        let firstAudioCodec = first.primaryAudioStream?.codecName.lowercased()
        let firstSampleRate = first.primaryAudioStream?.sampleRate
        let firstChannels = first.primaryAudioStream?.channels

        return infos.dropFirst().allSatisfy { info in
            guard let v = info.primaryVideoStream,
                  v.width == firstWidth,
                  v.height == firstHeight,
                  v.codecName.lowercased() == firstVideoCodec,
                  info.hasAudio == firstHasAudio else {
                return false
            }
            if firstHasAudio {
                return info.primaryAudioStream?.codecName.lowercased() == firstAudioCodec
                    && info.primaryAudioStream?.sampleRate == firstSampleRate
                    && info.primaryAudioStream?.channels == firstChannels
            }
            return true
        }
    }

    static func buildExtractAudioArguments(
        inputURL: URL,
        outputURL: URL,
        format: VideoExtractAudioFormat,
        segments: [VideoSegment]? = nil,
        speedMultiplier: Double = 1.0,
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions(),
        includeProgressPipe: Bool = false
    ) throws -> [String] {
        let speed = clampedSpeed(speedMultiplier)
        var args: [String] = ["-y", "-i", inputURL.path]
        if includeProgressPipe {
            args += ["-progress", "pipe:1", "-nostats"]
        }

        let kept: [VideoSegment]?
        if let segments, !segments.isEmpty {
            kept = try normalizedKeptSegments(from: segments)
        } else {
            kept = nil
        }

        var postAudioFilters: [String] = []
        if abs(speed - 1.0) > 0.001 {
            postAudioFilters.append(buildAtempoFilterChain(speed: speed))
        }
        postAudioFilters.append(contentsOf: buildAudioProcessingFilters(options: audioProcessing))

        if let kept {
            var filterParts: [String] = []
            var concatInputs: [String] = []
            for (index, seg) in kept.enumerated() {
                let startStr = String(format: "%.3f", seg.startSeconds)
                let endStr = String(format: "%.3f", seg.endSeconds)
                filterParts.append("[0:a]atrim=start=\(startStr):end=\(endStr),asetpts=PTS-STARTPTS[a\(index)]")
                concatInputs.append("[a\(index)]")
            }
            let basePad: String
            if kept.count == 1 {
                basePad = "[a0]"
            } else {
                filterParts.append("\(concatInputs.joined())concat=n=\(kept.count):v=0:a=1[acat]")
                basePad = "[acat]"
            }
            let audioChain = postAudioFilters.isEmpty ? "anull" : postAudioFilters.joined(separator: ",")
            filterParts.append("\(basePad)\(audioChain)[aout]")
            args += ["-filter_complex", filterParts.joined(separator: ";"), "-map", "[aout]"]
        } else if !postAudioFilters.isEmpty {
            args += ["-af", postAudioFilters.joined(separator: ",")]
        }

        args += ["-vn", "-sn"]
        args += format.codecArguments
        args.append(outputURL.path)
        return args
    }

    static func buildContactSheetArguments(
        inputURL: URL,
        outputURL: URL,
        durationSeconds: Double,
        rotation: QuickVideoRotation = .deg0,
        cropConfiguration: VideoCropConfiguration = VideoCropConfiguration(),
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        tileWidth: Int = 480,
        padding: Int = 8,
        margin: Int = 8,
        includeProgressPipe: Bool = false
    ) -> [String] {
        let safeDuration = (durationSeconds.isFinite && durationSeconds > 0.1) ? durationSeconds : 1.0
        let sampleFPS = max(0.01, min(30.0, 9.0 / safeDuration))
        let fpsString = String(format: "%.6f", sampleFPS)
        let safeTileWidth = min(max(tileWidth, 160), 960)
        let safePadding = min(max(padding, 0), 32)
        let safeMargin = min(max(margin, 0), 32)

        var filters: [String] = ["fps=\(fpsString)"]
        if let transpose = rotation.ffmpegTransposeFilter {
            filters.append(transpose)
        }
        let rotatedDimensions = rotatedPixelDimensions(width: sourceWidth, height: sourceHeight, rotation: rotation)
        if let cropFilter = buildCropFilter(
            configuration: cropConfiguration,
            sourceWidth: rotatedDimensions.width,
            sourceHeight: rotatedDimensions.height
        ) {
            filters.append(cropFilter)
        }
        filters.append("scale=\(safeTileWidth):-1:flags=lanczos")
        filters.append("tile=3x3:padding=\(safePadding):margin=\(safeMargin):color=black")

        var args: [String] = ["-y", "-i", inputURL.path]
        if includeProgressPipe {
            args += ["-progress", "pipe:1", "-nostats"]
        }
        args += [
            "-vf", filters.joined(separator: ","),
            "-frames:v", "1",
            "-an",
            "-sn",
            "-c:v", "png",
            outputURL.path
        ]
        return args
    }

    static func rotatedPixelDimensions(
        width: Int?,
        height: Int?,
        rotation: QuickVideoRotation
    ) -> (width: Int?, height: Int?) {
        guard let width, let height else { return (width, height) }
        if rotation == .deg90 || rotation == .deg270 {
            return (height, width)
        }
        return (width, height)
    }

    private static func buildAtempoFilterChain(speed: Double) -> String {
        var remaining = clampedSpeed(speed)
        var stages: [String] = []
        while remaining > 2.0 {
            stages.append("atempo=2.0")
            remaining /= 2.0
        }
        while remaining < 0.5 {
            stages.append("atempo=0.5")
            remaining *= 2.0
        }
        stages.append(String(format: "atempo=%.4f", remaining))
        return stages.joined(separator: ",")
    }

    // MARK: - Default Output Naming

    static func defaultExportURL(
        for inputURL: URL,
        mode: QuickVideoExportMode,
        in directory: URL? = nil
    ) -> URL {
        let targetDir = directory ?? inputURL.deletingLastPathComponent()
        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL)
        let suffix: String
        let ext: String
        switch mode {
        case .losslessCut:
            suffix = "_cut"
            let rawExt = inputURL.pathExtension.lowercased()
            ext = rawExt.isEmpty ? "mp4" : rawExt
        case .compressedMP4:
            suffix = "_edited"
            ext = "mp4"
        case .quickGIF:
            suffix = "_clip"
            ext = "gif"
        }
        return OutputReservationCoordinator.uniqueOutputURL(
            directory: targetDir,
            baseName: "\(baseName)\(suffix)",
            extension: ext
        )
    }

    static func defaultSnapshotURL(
        for inputURL: URL,
        format: QuickVideoSnapshotFormat,
        in directory: URL? = nil
    ) -> URL {
        let targetDir = directory ?? inputURL.deletingLastPathComponent()
        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL)
        return OutputReservationCoordinator.uniqueOutputURL(
            directory: targetDir,
            baseName: "\(baseName)_frame",
            extension: format.fileExtension
        )
    }

    static func defaultExtractAudioURL(
        for inputURL: URL,
        format: VideoExtractAudioFormat,
        in directory: URL? = nil
    ) -> URL {
        let targetDir = directory ?? inputURL.deletingLastPathComponent()
        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL)
        return OutputReservationCoordinator.uniqueOutputURL(
            directory: targetDir,
            baseName: "\(baseName)_audio",
            extension: format.fileExtension
        )
    }

    static func defaultContactSheetURL(
        for inputURL: URL,
        in directory: URL? = nil
    ) -> URL {
        let targetDir = directory ?? inputURL.deletingLastPathComponent()
        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL)
        return OutputReservationCoordinator.uniqueOutputURL(
            directory: targetDir,
            baseName: "\(baseName)_contact_sheet",
            extension: "png"
        )
    }

    static func defaultJoinedClipURL(
        for firstURL: URL,
        in directory: URL? = nil
    ) -> URL {
        let targetDir = directory ?? firstURL.deletingLastPathComponent()
        let baseName = FileFormat.baseNameByStrippingExtension(from: firstURL)
        return OutputReservationCoordinator.uniqueOutputURL(
            directory: targetDir,
            baseName: "\(baseName)_joined",
            extension: "mp4"
        )
    }

    // MARK: - Execution & Atomic Commit

    static func export(
        _ request: QuickVideoExportRequest,
        ffmpegPath: String? = nil,
        ffprobePath: String? = nil,
        progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: request.inputURL.path) else {
            throw ConversionError.inputFileNotFound(request.inputURL)
        }
        if let subURL = request.subtitleURL {
            guard FileManager.default.fileExists(atPath: subURL.path) else {
                throw ConversionError.inputFileNotFound(subURL)
            }
        }

        let inputStd = request.inputURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destStd = request.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard inputStd != destStd else {
            throw ConversionError.invalidInput("Export destination must not overwrite the source video file.")
        }

        let outputDir = request.destinationURL.deletingLastPathComponent()
        try OutputReservationCoordinator.validateWritableDirectory(outputDir)

        let (resolvedFFmpeg, resolvedFFprobe) = try await resolveFFmpegAndFFprobe(
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath
        )

        try Task.checkCancellation()
        progress(.determinate(0.05, message: "Inspecting source video..."))

        let inputInfo = try await MediaProbe.probe(url: request.inputURL, ffprobePath: resolvedFFprobe)
        guard inputInfo.hasRealVideo else {
            throw ConversionError.invalidInput("The source file does not contain a video stream.")
        }

        let kept = try normalizedKeptSegments(from: request.segments, totalDuration: inputInfo.duration)
        let totalKeptDuration = max(0.1, totalKeptDurationSeconds(in: kept))

        let finalDestinationURL: URL
        if request.existingFileHandling == .createUnique {
            let base = FileFormat.baseNameByStrippingExtension(from: request.destinationURL)
            let ext = request.destinationURL.pathExtension
            finalDestinationURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: outputDir,
                baseName: base,
                extension: ext,
                sourceURL: request.inputURL,
                policy: .createUnique
            )
        } else {
            finalDestinationURL = request.destinationURL
        }
        defer {
            if request.existingFileHandling == .createUnique {
                OutputReservationCoordinator.releaseReservedOutputURL(finalDestinationURL)
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-VideoCutter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let outExt = finalDestinationURL.pathExtension.isEmpty ? "mp4" : finalDestinationURL.pathExtension
        let tempOutputURL = tempRoot.appendingPathComponent("export.\(outExt)")

        let sourceW = inputInfo.primaryVideoStream?.width
        let sourceH = inputInfo.primaryVideoStream?.height

        switch request.mode {
        case .losslessCut:
            try await executeLosslessCut(
                inputURL: request.inputURL,
                tempOutputURL: tempOutputURL,
                tempRoot: tempRoot,
                segments: kept,
                isMuted: request.isMuted,
                totalKeptDuration: totalKeptDuration,
                ffmpegPath: resolvedFFmpeg,
                progress: progress
            )

        case .compressedMP4:
            var subtitleOverlayConcatURL: URL?
            if let subURL = request.subtitleURL {
                let hasLibass = await supportsVideoFilter("subtitles", ffmpegPath: resolvedFFmpeg)
                if !hasLibass {
                    let rawCues = try parseSRTFile(at: subURL)
                    let remapped = remapSRTCues(
                        rawCues,
                        keptSegments: kept,
                        speedMultiplier: request.speedMultiplier
                    )
                    if !remapped.isEmpty {
                        let outDims = effectiveOutputDimensions(
                            sourceWidth: sourceW ?? 1280,
                            sourceHeight: sourceH ?? 720,
                            rotation: request.rotation,
                            cropConfiguration: request.cropConfiguration
                        )
                        subtitleOverlayConcatURL = try prepareSubtitleOverlayConcatFile(
                            cues: remapped,
                            videoWidth: outDims.width,
                            videoHeight: outDims.height,
                            in: tempRoot
                        )
                    }
                }
            }

            let args = try buildCompressedMP4ArgumentsInternal(
                inputURL: request.inputURL,
                outputURL: tempOutputURL,
                segments: kept,
                hasAudio: inputInfo.hasAudio,
                isMuted: request.isMuted,
                rotation: request.rotation,
                speedMultiplier: request.speedMultiplier,
                cropConfiguration: request.cropConfiguration,
                sourceWidth: sourceW,
                sourceHeight: sourceH,
                subtitleURL: subtitleOverlayConcatURL == nil ? request.subtitleURL : nil,
                subtitleOverlayConcatURL: subtitleOverlayConcatURL,
                audioProcessing: request.audioProcessing,
                includeProgressPipe: true
            )
            let expectedDuration = max(0.1, totalKeptDuration / clampedSpeed(request.speedMultiplier))
            try await runFFmpegWithProgress(
                ffmpegPath: resolvedFFmpeg,
                arguments: args,
                totalDuration: expectedDuration,
                timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
                progress: progress
            )

        case .quickGIF:
            let args = try buildGIFArguments(
                inputURL: request.inputURL,
                outputURL: tempOutputURL,
                segments: kept,
                rotation: request.rotation,
                speedMultiplier: request.speedMultiplier,
                fps: request.gifFPS,
                maxWidth: request.gifMaxWidth,
                cropConfiguration: request.cropConfiguration,
                sourceWidth: sourceW,
                sourceHeight: sourceH,
                includeProgressPipe: true
            )
            let expectedDuration = max(0.1, totalKeptDuration / clampedSpeed(request.speedMultiplier))
            try await runFFmpegWithProgress(
                ffmpegPath: resolvedFFmpeg,
                arguments: args,
                totalDuration: expectedDuration,
                timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
                progress: progress
            )
        }

        try Task.checkCancellation()
        progress(.determinate(0.96, message: "Validating exported media..."))

        let expectedFormat: FileFormat = {
            if request.mode == .quickGIF { return .gif }
            return FileFormat.from(extension: finalDestinationURL.pathExtension) ?? .mp4
        }()
        _ = try await MediaProbe.validate(
            outputURL: tempOutputURL,
            expectedFormat: expectedFormat,
            ffprobePath: resolvedFFprobe
        )

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempOutputURL,
            to: finalDestinationURL,
            policy: request.existingFileHandling
        )

        progress(.determinate(1.0, message: "Export complete"))
        logger.info("QuickVideoCutter exported \(committedURL.lastPathComponent, privacy: .public)")
        return committedURL
    }

    static func joinClips(
        _ request: MultiClipJoinRequest,
        ffmpegPath: String? = nil,
        ffprobePath: String? = nil,
        progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard request.clipURLs.count >= 2 else {
            throw ConversionError.invalidInput("Select at least 2 video clips to join.")
        }
        for clipURL in request.clipURLs {
            guard FileManager.default.fileExists(atPath: clipURL.path) else {
                throw ConversionError.inputFileNotFound(clipURL)
            }
            let clipStd = clipURL.standardizedFileURL.resolvingSymlinksInPath().path
            let destStd = request.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
            guard clipStd != destStd else {
                throw ConversionError.invalidInput("Joined output destination must not overwrite any source clip.")
            }
        }
        if let subURL = request.subtitleURL {
            guard FileManager.default.fileExists(atPath: subURL.path) else {
                throw ConversionError.inputFileNotFound(subURL)
            }
        }

        let outputDir = request.destinationURL.deletingLastPathComponent()
        try OutputReservationCoordinator.validateWritableDirectory(outputDir)

        let (resolvedFFmpeg, resolvedFFprobe) = try await resolveFFmpegAndFFprobe(
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath
        )

        try Task.checkCancellation()
        progress(.determinate(0.05, message: "Inspecting \(request.clipURLs.count) video clips..."))

        var infos: [MediaInfo] = []
        infos.reserveCapacity(request.clipURLs.count)
        for clipURL in request.clipURLs {
            try Task.checkCancellation()
            let info = try await MediaProbe.probe(url: clipURL, ffprobePath: resolvedFFprobe)
            guard info.hasRealVideo else {
                throw ConversionError.invalidInput("Clip \(clipURL.lastPathComponent) does not contain a video stream.")
            }
            infos.append(info)
        }

        let finalDestinationURL: URL
        if request.existingFileHandling == .createUnique {
            let base = FileFormat.baseNameByStrippingExtension(from: request.destinationURL)
            let ext = request.destinationURL.pathExtension.isEmpty ? "mp4" : request.destinationURL.pathExtension
            finalDestinationURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: outputDir,
                baseName: base,
                extension: ext,
                sourceURL: request.clipURLs.first,
                policy: .createUnique
            )
        } else {
            finalDestinationURL = request.destinationURL
        }
        defer {
            if request.existingFileHandling == .createUnique {
                OutputReservationCoordinator.releaseReservedOutputURL(finalDestinationURL)
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-VideoCutter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let outExt = finalDestinationURL.pathExtension.isEmpty ? "mp4" : finalDestinationURL.pathExtension
        let tempOutputURL = tempRoot.appendingPathComponent("joined.\(outExt)")
        let totalDuration = max(0.1, infos.reduce(0.0) { $0 + max(0.1, $1.duration) })

        let canCopy = canStreamCopyConcat(infos: infos)
            && !request.audioProcessing.hasAnyEffect
            && request.subtitleURL == nil

        if canCopy {
            let concatListURL = tempRoot.appendingPathComponent("join_concat.txt")
            try formatConcatListFile(segmentURLs: request.clipURLs)
                .write(to: concatListURL, atomically: true, encoding: .utf8)
            let args = buildMultiClipConcatDemuxerArguments(
                concatListURL: concatListURL,
                outputURL: tempOutputURL,
                includeAudio: infos.first?.hasAudio ?? true,
                includeProgressPipe: true
            )
            progress(.determinate(0.15, message: "Joining clips (stream copy)..."))
            try await runFFmpegWithProgress(
                ffmpegPath: resolvedFFmpeg,
                arguments: args,
                totalDuration: totalDuration,
                timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
                progress: progress
            )
        } else {
            let targetWidth = max(2, ((infos.first?.primaryVideoStream?.width ?? 1280) / 2) * 2)
            let targetHeight = max(2, ((infos.first?.primaryVideoStream?.height ?? 720) / 2) * 2)

            var subtitleOverlayConcatURL: URL?
            if let subURL = request.subtitleURL {
                let hasLibass = await supportsVideoFilter("subtitles", ffmpegPath: resolvedFFmpeg)
                if !hasLibass {
                    let cues = try parseSRTFile(at: subURL)
                    if !cues.isEmpty {
                        subtitleOverlayConcatURL = try prepareSubtitleOverlayConcatFile(
                            cues: cues,
                            videoWidth: targetWidth,
                            videoHeight: targetHeight,
                            in: tempRoot
                        )
                    }
                }
            }

            let args = try buildMultiClipConcatFilterArgumentsInternal(
                inputURLs: request.clipURLs,
                outputURL: tempOutputURL,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                hasAudioPerClip: infos.map(\.hasAudio),
                clipDurations: infos.map { max(0.1, $0.duration) },
                audioProcessing: request.audioProcessing,
                subtitleURL: subtitleOverlayConcatURL == nil ? request.subtitleURL : nil,
                subtitleOverlayConcatURL: subtitleOverlayConcatURL,
                includeProgressPipe: true
            )
            progress(.determinate(0.15, message: "Joining and encoding clips..."))
            try await runFFmpegWithProgress(
                ffmpegPath: resolvedFFmpeg,
                arguments: args,
                totalDuration: totalDuration,
                timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
                progress: progress
            )
        }

        try Task.checkCancellation()
        progress(.determinate(0.96, message: "Validating joined video..."))

        let expectedFormat = FileFormat.from(extension: finalDestinationURL.pathExtension) ?? .mp4
        _ = try await MediaProbe.validate(
            outputURL: tempOutputURL,
            expectedFormat: expectedFormat,
            ffprobePath: resolvedFFprobe
        )

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempOutputURL,
            to: finalDestinationURL,
            policy: request.existingFileHandling
        )
        progress(.determinate(1.0, message: "Join complete"))
        return committedURL
    }

    static func extractAudio(
        from inputURL: URL,
        to destinationURL: URL,
        format: VideoExtractAudioFormat,
        segments: [VideoSegment]? = nil,
        speedMultiplier: Double = 1.0,
        audioProcessing: VideoAudioProcessingOptions = VideoAudioProcessingOptions(),
        existingFileHandling: ExistingFileHandling = .createUnique,
        ffmpegPath: String? = nil,
        ffprobePath: String? = nil,
        progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }

        let inputStd = inputURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destStd = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard inputStd != destStd else {
            throw ConversionError.invalidInput("Audio output destination must not overwrite the source video.")
        }

        let outputDir = destinationURL.deletingLastPathComponent()
        try OutputReservationCoordinator.validateWritableDirectory(outputDir)

        let (resolvedFFmpeg, resolvedFFprobe) = try await resolveFFmpegAndFFprobe(
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath
        )

        try Task.checkCancellation()
        progress(.determinate(0.08, message: "Inspecting audio stream..."))

        let inputInfo = try await MediaProbe.probe(url: inputURL, ffprobePath: resolvedFFprobe)
        guard inputInfo.hasAudio else {
            throw ConversionError.invalidInput("This video does not contain an audio stream to extract.")
        }

        let keptSegments: [VideoSegment]?
        if let segments, !segments.isEmpty {
            keptSegments = try normalizedKeptSegments(from: segments, totalDuration: inputInfo.duration)
        } else {
            keptSegments = nil
        }

        let finalDestinationURL: URL
        if existingFileHandling == .createUnique {
            let base = FileFormat.baseNameByStrippingExtension(from: destinationURL)
            finalDestinationURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: outputDir,
                baseName: base,
                extension: format.fileExtension,
                sourceURL: inputURL,
                policy: .createUnique
            )
        } else {
            finalDestinationURL = destinationURL
        }
        defer {
            if existingFileHandling == .createUnique {
                OutputReservationCoordinator.releaseReservedOutputURL(finalDestinationURL)
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-VideoCutter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let tempAudioURL = tempRoot.appendingPathComponent("extracted.\(format.fileExtension)")
        let args = try buildExtractAudioArguments(
            inputURL: inputURL,
            outputURL: tempAudioURL,
            format: format,
            segments: keptSegments,
            speedMultiplier: speedMultiplier,
            audioProcessing: audioProcessing,
            includeProgressPipe: true
        )

        let baseDuration = keptSegments.map { totalKeptDurationSeconds(in: $0) } ?? inputInfo.duration
        let expectedDuration = max(0.1, baseDuration / clampedSpeed(speedMultiplier))
        progress(.determinate(0.20, message: "Extracting \(format.rawValue) audio..."))
        try await runFFmpegWithProgress(
            ffmpegPath: resolvedFFmpeg,
            arguments: args,
            totalDuration: expectedDuration,
            timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
            progress: progress
        )

        try Task.checkCancellation()
        progress(.determinate(0.95, message: "Validating extracted audio..."))

        _ = try await MediaProbe.validate(
            outputURL: tempAudioURL,
            expectedFormat: format.fileFormat,
            ffprobePath: resolvedFFprobe
        )

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempAudioURL,
            to: finalDestinationURL,
            policy: existingFileHandling
        )
        progress(.determinate(1.0, message: "Audio extracted"))
        return committedURL
    }

    static func generateContactSheet(
        from inputURL: URL,
        to destinationURL: URL,
        rotation: QuickVideoRotation = .deg0,
        cropConfiguration: VideoCropConfiguration = VideoCropConfiguration(),
        tileWidth: Int = 480,
        existingFileHandling: ExistingFileHandling = .createUnique,
        ffmpegPath: String? = nil,
        ffprobePath: String? = nil,
        progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }

        let inputStd = inputURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destStd = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard inputStd != destStd else {
            throw ConversionError.invalidInput("Contact sheet destination must not overwrite the source video.")
        }

        let outputDir = destinationURL.deletingLastPathComponent()
        try OutputReservationCoordinator.validateWritableDirectory(outputDir)

        let (resolvedFFmpeg, resolvedFFprobe) = try await resolveFFmpegAndFFprobe(
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath
        )

        try Task.checkCancellation()
        progress(.determinate(0.10, message: "Inspecting video for contact sheet..."))

        let inputInfo = try await MediaProbe.probe(url: inputURL, ffprobePath: resolvedFFprobe)
        guard inputInfo.hasRealVideo else {
            throw ConversionError.invalidInput("The source file does not contain a video stream.")
        }

        let finalDestinationURL: URL
        if existingFileHandling == .createUnique {
            let base = FileFormat.baseNameByStrippingExtension(from: destinationURL)
            finalDestinationURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: outputDir,
                baseName: base,
                extension: "png",
                sourceURL: inputURL,
                policy: .createUnique
            )
        } else {
            finalDestinationURL = destinationURL
        }
        defer {
            if existingFileHandling == .createUnique {
                OutputReservationCoordinator.releaseReservedOutputURL(finalDestinationURL)
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-VideoCutter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let tempPNGURL = tempRoot.appendingPathComponent("contact_sheet.png")
        let args = buildContactSheetArguments(
            inputURL: inputURL,
            outputURL: tempPNGURL,
            durationSeconds: inputInfo.duration,
            rotation: rotation,
            cropConfiguration: cropConfiguration,
            sourceWidth: inputInfo.primaryVideoStream?.width,
            sourceHeight: inputInfo.primaryVideoStream?.height,
            tileWidth: tileWidth,
            includeProgressPipe: true
        )

        progress(.determinate(0.30, message: "Rendering 3×3 contact sheet..."))
        try await runFFmpegWithProgress(
            ffmpegPath: resolvedFFmpeg,
            arguments: args,
            totalDuration: max(0.5, inputInfo.duration),
            timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
            progress: progress
        )

        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: tempPNGURL.path),
              let imageSource = CGImageSourceCreateWithURL(tempPNGURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              cgImage.width > 0,
              cgImage.height > 0 else {
            throw ConversionError.engineExecutionFailed(
                "FFmpeg finished, but the 3×3 contact sheet PNG could not be verified.",
                underlyingError: nil
            )
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempPNGURL,
            to: finalDestinationURL,
            policy: existingFileHandling
        )
        progress(.determinate(1.0, message: "Contact sheet saved"))
        return committedURL
    }

    private static func resolveFFmpegAndFFprobe(
        ffmpegPath: String?,
        ffprobePath: String?
    ) async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
        let resolvedFFmpeg: String
        if let ffmpegPath {
            resolvedFFmpeg = ffmpegPath
        } else if let found = await provider.findFFmpegPath() {
            resolvedFFmpeg = found
        } else {
            throw ConversionError.engineNotAvailable("Bundled FFmpeg is required for video export.")
        }

        let resolvedFFprobe: String
        if let ffprobePath {
            resolvedFFprobe = ffprobePath
        } else if let found = await provider.findFFprobePath() {
            resolvedFFprobe = found
        } else {
            throw ConversionError.engineNotAvailable("Bundled FFprobe is required to inspect and verify video exports.")
        }
        return (resolvedFFmpeg, resolvedFFprobe)
    }

    static func supportsVideoFilter(_ filterName: String, ffmpegPath: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-hide_banner", "-filters"]
        do {
            let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 10.0)
            guard output.terminationStatus == 0,
                  let listing = String(data: output.stdout, encoding: .utf8) else {
                return false
            }
            for line in listing.split(whereSeparator: \.isNewline) {
                let tokens = line.split(whereSeparator: \.isWhitespace)
                if tokens.count >= 2, tokens[1] == filterName {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }

    private static func effectiveOutputDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        rotation: QuickVideoRotation,
        cropConfiguration: VideoCropConfiguration
    ) -> (width: Int, height: Int) {
        let rotated = rotatedPixelDimensions(width: sourceWidth, height: sourceHeight, rotation: rotation)
        let rotW = max(2, ((rotated.width ?? 1280) / 2) * 2)
        let rotH = max(2, ((rotated.height ?? 720) / 2) * 2)
        if let px = pixelCropRect(from: cropConfiguration, sourceWidth: rotW, sourceHeight: rotH) {
            return (px.width, px.height)
        }
        return (rotW, rotH)
    }

    private static func prepareSubtitleOverlayConcatFile(
        cues: [SRTSubtitleCue],
        videoWidth: Int,
        videoHeight: Int,
        in tempRoot: URL
    ) throws -> URL {
        let safeW = max(64, (videoWidth / 2) * 2)
        let stripH = max(48, min(max(64, (videoHeight / 2) * 2), max(80, (videoHeight / 4 / 2) * 2)))

        let blankURL = tempRoot.appendingPathComponent("sub_blank.png")
        try writeSubtitleOverlayPNG(text: nil, width: safeW, height: stripH, to: blankURL)

        var lines: [String] = ["ffconcat version 1.0"]
        var cursor = 0.0

        func concatPath(_ url: URL) -> String {
            url.path.replacingOccurrences(of: "'", with: "'\\''")
        }

        for (index, cue) in cues.sorted(by: { $0.startSeconds < $1.startSeconds }).enumerated() {
            let effectiveStart = max(cursor, cue.startSeconds)
            if effectiveStart > cursor + 0.01 {
                lines.append("file '\(concatPath(blankURL))'")
                lines.append(String(format: "duration %.3f", effectiveStart - cursor))
            }
            let cueDur = max(0.05, cue.endSeconds - effectiveStart)
            let cueURL = tempRoot.appendingPathComponent("sub_cue_\(index).png")
            try writeSubtitleOverlayPNG(text: cue.text, width: safeW, height: stripH, to: cueURL)
            lines.append("file '\(concatPath(cueURL))'")
            lines.append(String(format: "duration %.3f", cueDur))
            cursor = effectiveStart + cueDur
        }

        lines.append("file '\(concatPath(blankURL))'")
        lines.append("duration 0.100")
        lines.append("file '\(concatPath(blankURL))'")

        let concatURL = tempRoot.appendingPathComponent("subs_concat.txt")
        try (lines.joined(separator: "\n") + "\n").write(to: concatURL, atomically: true, encoding: .utf8)
        return concatURL
    }

    private static func writeSubtitleOverlayPNG(
        text: String?,
        width: Int,
        height: Int,
        to url: URL
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate subtitle overlay graphics context.", underlyingError: nil)
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fontSize = CGFloat(max(14.0, min(40.0, Double(height) * 0.20)))
            let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
            var alignment = CTTextAlignment.center
            let alignSetting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: &alignment
            )
            let paragraphStyle = CTParagraphStyleCreate([alignSetting], 1)

            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                kCTParagraphStyleAttributeName: paragraphStyle
            ]
            guard let attrString = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary) else {
                throw ConversionError.engineExecutionFailed("Failed to construct subtitle attributed string.", underlyingError: nil)
            }
            let framesetter = CTFramesetterCreateWithAttributedString(attrString)
            let maxTextWidth = CGFloat(max(32, width - 32))
            let maxTextHeight = CGFloat(max(24, height - 16))
            let measuredSize = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: CFAttributedStringGetLength(attrString)),
                nil,
                CGSize(width: maxTextWidth, height: maxTextHeight),
                nil
            )

            let boxW = min(CGFloat(width - 16), ceil(measuredSize.width) + 24)
            let boxH = min(CGFloat(height - 8), ceil(measuredSize.height) + 12)
            let boxX = (CGFloat(width) - boxW) / 2.0
            let boxY: CGFloat = 10.0
            let bgRect = CGRect(x: boxX, y: boxY, width: boxW, height: boxH)
            let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
            context.addPath(bgPath)
            context.fillPath()

            let textRect = bgRect.insetBy(dx: 10, dy: 5)
            let textPath = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: CFAttributedStringGetLength(attrString)),
                textPath,
                nil
            )
            CTFrameDraw(frame, context)
        }

        guard let cgImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to encode subtitle overlay PNG.", underlyingError: nil)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize subtitle overlay PNG.", underlyingError: nil)
        }
    }

    private static func executeLosslessCut(
        inputURL: URL,
        tempOutputURL: URL,
        tempRoot: URL,
        segments: [VideoSegment],
        isMuted: Bool,
        totalKeptDuration: Double,
        ffmpegPath: String,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        if segments.count == 1 {
            let args = buildSingleSegmentLosslessCutArguments(
                inputURL: inputURL,
                outputURL: tempOutputURL,
                segment: segments[0],
                isMuted: isMuted,
                includeProgressPipe: true
            )
            try await runFFmpegWithProgress(
                ffmpegPath: ffmpegPath,
                arguments: args,
                totalDuration: totalKeptDuration,
                timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
                progress: progress
            )
            return
        }

        let segExt = tempOutputURL.pathExtension.isEmpty ? "mp4" : tempOutputURL.pathExtension
        var partURLs: [URL] = []
        partURLs.reserveCapacity(segments.count)

        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let partURL = tempRoot.appendingPathComponent("segment_\(index).\(segExt)")
            let partArgs = buildSingleSegmentLosslessCutArguments(
                inputURL: inputURL,
                outputURL: partURL,
                segment: segment,
                isMuted: isMuted,
                includeProgressPipe: false
            )
            let frac = 0.1 + (0.65 * (Double(index) / Double(segments.count)))
            progress(.determinate(frac, message: "Cutting segment \(index + 1) of \(segments.count)..."))

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = partArgs
            let output = try await AsyncProcessRunner.run(
                proc,
                stdin: .nullDevice,
                timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds
            )
            guard output.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: partURL.path) else {
                let err = String(data: output.stderr, encoding: .utf8)
                throw ConversionError.engineExecutionFailed(
                    "Failed to cut video segment \(index + 1).",
                    underlyingError: err
                )
            }
            partURLs.append(partURL)
        }

        let concatListURL = tempRoot.appendingPathComponent("concat.txt")
        let concatContents = formatConcatListFile(segmentURLs: partURLs)
        try concatContents.write(to: concatListURL, atomically: true, encoding: .utf8)

        progress(.determinate(0.80, message: "Joining kept segments..."))
        let concatArgs = buildLosslessConcatArguments(
            concatListURL: concatListURL,
            outputURL: tempOutputURL,
            isMuted: isMuted,
            includeProgressPipe: true
        )
        try await runFFmpegWithProgress(
            ffmpegPath: ffmpegPath,
            arguments: concatArgs,
            totalDuration: totalKeptDuration,
            timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds,
            progress: progress
        )
    }

    private static func runFFmpegWithProgress(
        ffmpegPath: String,
        arguments: [String],
        totalDuration: Double,
        timeout: TimeInterval,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
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
                    if line.hasPrefix("out_time_us="),
                       let us = Double(line.dropFirst("out_time_us=".count)) {
                        let seconds = us / 1_000_000.0
                        let fraction = min(0.94, max(0.10, (seconds / max(0.1, totalDuration)) * 0.94))
                        progress(.determinate(fraction, message: "Exporting video (\(Int(fraction * 100))%)..."))
                    } else if line == "progress=end" {
                        progress(.determinate(0.95, message: "Finalizing output..."))
                    }
                }
            }
        } catch let timeoutErr as ProcessTimeoutError {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stderrTask.value
            throw ConversionError.engineExecutionFailed(
                "Video export timed out after \(Int(timeoutErr.timeoutSeconds)) seconds.",
                underlyingError: timeoutErr.localizedDescription
            )
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stderrTask.value
            throw error
        }

        let errData = await stderrTask.value
        let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ConversionError.engineExecutionFailed(
                "FFmpeg failed while exporting the edited video.",
                underlyingError: errString
            )
        }
    }

    // MARK: - Frame Snapshot & Clipboard

    static func extractFrameCGImage(
        from inputURL: URL,
        atSeconds: Double,
        rotation: QuickVideoRotation = .deg0,
        maxDimension: Int = 4096
    ) async throws -> CGImage {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }

        let safeTime = max(0, atSeconds.isFinite ? atSeconds : 0)
        let safeMax = min(max(maxDimension, 128), 8192)
        var extracted: CGImage?

        if VideoPreviewService.supportsNativeAVPlayer(url: inputURL) {
            let asset = AVURLAsset(url: inputURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: safeMax, height: safeMax)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cmTime = CMTime(seconds: safeTime, preferredTimescale: 600)
            if let result = try? await generator.image(at: cmTime) {
                extracted = result.image
            }
        }

        if extracted == nil {
            extracted = try await VideoPreviewService.extractFrame(
                url: inputURL,
                atSeconds: safeTime,
                maxWidth: min(safeMax, 1280)
            )
        }

        guard let baseImage = extracted else {
            throw ConversionError.engineExecutionFailed(
                "Could not extract video frame at \(VideoTrimTimestamp.formatDisplay(seconds: safeTime)).",
                underlyingError: nil
            )
        }

        if rotation == .deg0 {
            return baseImage
        }
        return rotateCGImage(baseImage, by: rotation) ?? baseImage
    }

    static func rotateCGImage(_ image: CGImage, by rotation: QuickVideoRotation) -> CGImage? {
        guard rotation != .deg0 else { return image }
        let width = image.width
        let height = image.height
        let targetWidth = (rotation == .deg90 || rotation == .deg270) ? height : width
        let targetHeight = (rotation == .deg90 || rotation == .deg270) ? width : height

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.translateBy(x: CGFloat(targetWidth) / 2.0, y: CGFloat(targetHeight) / 2.0)
        let radians = -CGFloat(rotation.rawValue) * (.pi / 180.0)
        context.rotate(by: radians)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(width) / 2.0,
                y: -CGFloat(height) / 2.0,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )
        return context.makeImage()
    }

    static func encodeImageData(
        _ image: CGImage,
        format: QuickVideoSnapshotFormat,
        jpegQuality: Double = 0.92
    ) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to initialize image encoder for \(format.rawValue).",
                underlyingError: nil
            )
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(jpegQuality, 0.1), 1.0)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to encode frame snapshot as \(format.rawValue).",
                underlyingError: nil
            )
        }
        return mutableData as Data
    }

    static func exportFrameSnapshot(
        from inputURL: URL,
        atSeconds: Double,
        to destinationURL: URL,
        format: QuickVideoSnapshotFormat,
        rotation: QuickVideoRotation = .deg0,
        existingFileHandling: ExistingFileHandling = .createUnique
    ) async throws -> URL {
        let inputStd = inputURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destStd = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard inputStd != destStd else {
            throw ConversionError.invalidInput("Frame snapshot destination must not overwrite the source video.")
        }

        let outputDir = destinationURL.deletingLastPathComponent()
        try OutputReservationCoordinator.validateWritableDirectory(outputDir)

        let cgImage = try await extractFrameCGImage(
            from: inputURL,
            atSeconds: atSeconds,
            rotation: rotation
        )
        let imageData = try encodeImageData(cgImage, format: format)

        let finalURL: URL
        if existingFileHandling == .createUnique {
            let base = FileFormat.baseNameByStrippingExtension(from: destinationURL)
            finalURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: outputDir,
                baseName: base,
                extension: format.fileExtension,
                sourceURL: inputURL,
                policy: .createUnique
            )
        } else {
            finalURL = destinationURL
        }
        defer {
            if existingFileHandling == .createUnique {
                OutputReservationCoordinator.releaseReservedOutputURL(finalURL)
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-VideoCutter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let tempImageURL = tempRoot.appendingPathComponent("snapshot.\(format.fileExtension)")
        try imageData.write(to: tempImageURL, options: .atomic)

        return try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempImageURL,
            to: finalURL,
            policy: existingFileHandling
        )
    }

    @MainActor
    @discardableResult
    static func copyFrameToClipboard(
        from inputURL: URL,
        atSeconds: Double,
        rotation: QuickVideoRotation = .deg0
    ) async throws -> NSImage {
        let cgImage = try await extractFrameCGImage(
            from: inputURL,
            atSeconds: atSeconds,
            rotation: rotation
        )
        let nsImage = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        return nsImage
    }
}

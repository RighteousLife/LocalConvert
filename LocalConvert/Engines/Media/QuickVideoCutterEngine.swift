import Foundation
import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
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
        gifMaxWidth: Int = 640
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

    static func buildCompressedMP4Arguments(
        inputURL: URL,
        outputURL: URL,
        segments: [VideoSegment],
        hasAudio: Bool = true,
        isMuted: Bool = false,
        rotation: QuickVideoRotation = .deg0,
        speedMultiplier: Double = 1.0,
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
        if abs(speed - 1.0) > 0.001 {
            let ptsScale = String(format: "%.6f", 1.0 / speed)
            videoTransformFilters.append("setpts=\(ptsScale)*PTS")
        }
        videoTransformFilters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        filterParts.append("\(videoSourcePad)\(videoTransformFilters.joined(separator: ","))[vout]")

        if let audioSourcePad {
            let audioFilter: String
            if abs(speed - 1.0) > 0.001 {
                audioFilter = buildAtempoFilterChain(speed: speed)
            } else {
                audioFilter = "anull"
            }
            filterParts.append("\(audioSourcePad)\(audioFilter)[aout]")
        }

        let filterGraph = filterParts.joined(separator: ";")
        var args: [String] = ["-y", "-i", inputURL.path]
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

        let inputStd = request.inputURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destStd = request.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard inputStd != destStd else {
            throw ConversionError.invalidInput("Export destination must not overwrite the source video file.")
        }

        let outputDir = request.destinationURL.deletingLastPathComponent()
        try OutputReservationCoordinator.validateWritableDirectory(outputDir)

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

        try Task.checkCancellation()
        progress(.determinate(0.05, message: "Inspecting source video..."))

        let inputInfo = try await MediaProbe.probe(url: request.inputURL, ffprobePath: resolvedFFprobe)
        guard inputInfo.hasRealVideo else {
            throw ConversionError.invalidInput("The source file does not contain a video stream.")
        }

        let kept = try normalizedKeptSegments(from: request.segments, totalDuration: inputInfo.duration)
        let totalKeptDuration = max(0.1, totalKeptDurationSeconds(in: kept))

        // Resolve collision-safe destination when creating unique outputs
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
            let args = try buildCompressedMP4Arguments(
                inputURL: request.inputURL,
                outputURL: tempOutputURL,
                segments: kept,
                hasAudio: inputInfo.hasAudio,
                isMuted: request.isMuted,
                rotation: request.rotation,
                speedMultiplier: request.speedMultiplier,
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

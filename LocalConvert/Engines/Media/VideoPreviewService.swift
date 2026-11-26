import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO

// MARK: - Video Preview Thumbnail

struct VideoPreviewThumbnail: Identifiable, Sendable {
    let id: Int
    let timestampSeconds: Double
    let cgImage: CGImage
}

// MARK: - Video Preview & Filmstrip Service

enum VideoPreviewService: Sendable {

    static let nativeAVFoundationExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func supportsNativeAVPlayer(url: URL) -> Bool {
        nativeAVFoundationExtensions.contains(url.pathExtension.lowercased())
    }

    static func extractFilmstrip(
        url: URL,
        duration: Double,
        count: Int = 10,
        maxWidth: Int = 200,
        ffmpegPath: String? = nil
    ) async throws -> [VideoPreviewThumbnail] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }

        let safeCount = min(max(count, 1), 12)
        let safeWidth = min(max(maxWidth, 80), 320)
        let safeDuration = max(duration, 0.1)

        if supportsNativeAVPlayer(url: url),
           let nativeThumbs = try await extractNativeFilmstrip(
               url: url,
               duration: safeDuration,
               count: safeCount,
               maxWidth: safeWidth
           ),
           !nativeThumbs.isEmpty {
            return nativeThumbs
        }

        let resolvedFFmpeg: String
        if let ffmpegPath {
            resolvedFFmpeg = ffmpegPath
        } else if let found = await BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback).findFFmpegPath() {
            resolvedFFmpeg = found
        } else {
            throw ConversionError.engineNotAvailable("FFmpeg is required to generate video preview frames.")
        }

        var thumbnails: [VideoPreviewThumbnail] = []
        thumbnails.reserveCapacity(safeCount)

        for idx in 0..<safeCount {
            try Task.checkCancellation()
            let t = sampleTimestamp(index: idx, count: safeCount, duration: safeDuration)
            if let frame = try await extractFrameWithFFmpeg(
                url: url,
                atSeconds: t,
                maxWidth: safeWidth,
                ffmpegPath: resolvedFFmpeg
            ) {
                thumbnails.append(VideoPreviewThumbnail(id: idx, timestampSeconds: t, cgImage: frame))
            }
        }
        return thumbnails
    }

    static func extractFrame(
        url: URL,
        atSeconds: Double,
        maxWidth: Int = 640,
        ffmpegPath: String? = nil
    ) async throws -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }

        let safeTime = max(0, atSeconds.isFinite ? atSeconds : 0)
        let safeWidth = min(max(maxWidth, 120), 1280)

        if supportsNativeAVPlayer(url: url) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: safeWidth, height: safeWidth)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
            let cmTime = CMTime(seconds: safeTime, preferredTimescale: 600)
            if let result = try? await generator.image(at: cmTime) {
                return result.image
            }
        }

        let resolvedFFmpeg: String
        if let ffmpegPath {
            resolvedFFmpeg = ffmpegPath
        } else if let found = await BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback).findFFmpegPath() {
            resolvedFFmpeg = found
        } else {
            return nil
        }

        return try await extractFrameWithFFmpeg(
            url: url,
            atSeconds: safeTime,
            maxWidth: safeWidth,
            ffmpegPath: resolvedFFmpeg
        )
    }

    // MARK: - Private Helpers

    private static func sampleTimestamp(index: Int, count: Int, duration: Double) -> Double {
        guard count > 1 else { return min(duration * 0.5, max(0, duration - 0.05)) }
        let step = duration / Double(count)
        let raw = (Double(index) + 0.5) * step
        return min(max(0, raw), max(0, duration - 0.05))
    }

    private static func extractNativeFilmstrip(
        url: URL,
        duration: Double,
        count: Int,
        maxWidth: Int
    ) async throws -> [VideoPreviewThumbnail]? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var results: [VideoPreviewThumbnail] = []
        results.reserveCapacity(count)

        for idx in 0..<count {
            try Task.checkCancellation()
            let t = sampleTimestamp(index: idx, count: count, duration: duration)
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            if let generated = try? await generator.image(at: cmTime) {
                results.append(VideoPreviewThumbnail(id: idx, timestampSeconds: t, cgImage: generated.image))
            }
        }
        return results
    }

    private static func extractFrameWithFFmpeg(
        url: URL,
        atSeconds: Double,
        maxWidth: Int,
        ffmpegPath: String
    ) async throws -> CGImage? {
        try Task.checkCancellation()

        let ms = Int64((max(0, atSeconds) * 1000.0).rounded())
        let ts = VideoTrimTimestamp.formatFFmpeg(milliseconds: ms)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-ss", ts,
            "-i", url.path,
            "-frames:v", "1",
            "-vf", "scale=\(maxWidth):-1",
            "-f", "image2pipe",
            "-vcodec", "png",
            "-"
        ]

        let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 15)
        guard output.terminationStatus == 0, !output.stdout.isEmpty else {
            return nil
        }

        guard let source = CGImageSourceCreateWithData(output.stdout as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return cgImage
    }
}

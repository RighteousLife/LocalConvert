import Foundation
import AVFoundation
import CryptoKit

// MARK: - Format Capability Boundaries (Aligned with Bundled Dependencies)

enum AudioLibraryFormatSupport {
    /// Formats opened directly via `AVAudioFile` for PCM decode & sample-frame exact seeking on macOS 15+.
    static let nativePlaybackFormats: Set<FileFormat> = [
        .wav, .aiff, .caf, .mp3, .m4a, .m4b, .aac, .alac, .flac
    ]

    /// Additional audio containers decoded via bundled FFmpeg 9.0.2 (`verify-dependencies.sh` / `-decoders`).
    static let ffmpegPlaybackFormats: Set<FileFormat> = [
        .ogg, .opus, .wv, .wma, .mka, .ac3, .eac3, .dts, .au, .amr, .ape
    ]

    static let allSupportedAudioFormats: Set<FileFormat> = nativePlaybackFormats.union(ffmpegPlaybackFormats)

    static let losslessAudioFormats: Set<FileFormat> = [
        .wav, .aiff, .caf, .flac, .alac, .wv, .ape
    ]

    static func resolveAudioFormat(for url: URL) -> FileFormat? {
        if let detected = FileDetector.detectFormat(url: url),
           detected.category == .audio,
           allSupportedAudioFormats.contains(detected) {
            return detected
        }
        let ext = url.pathExtension.lowercased()
        if ext == "aif" || ext == "aifc" { return .aiff }
        if let fromExt = FileFormat.from(extension: ext),
           fromExt.category == .audio,
           allSupportedAudioFormats.contains(fromExt) {
            return fromExt
        }
        return nil
    }
}

struct ExtractedAudioRecord: Sendable {
    let asset: AudioAsset
    let metadata: AudioMetadata
    let artworkData: Data?
}

enum AudioMetadataExtractionError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case unsupportedAudioFormat(String)
    case unreadableAudioStream(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "Audio file not found: \(name)"
        case .unsupportedAudioFormat(let ext):
            return "Unsupported audio format: .\(ext)"
        case .unreadableAudioStream(let detail):
            return "Unable to inspect audio stream: \(detail)"
        }
    }
}

// MARK: - Read-Only Audio Metadata & Technical Extractor

actor AudioMetadataExtractor {
    private let metadataProvider = AudioMetadataProvider()
    private let ffmpegProvider = BundledFFmpegProvider(fallbackToSystem: false)

    /// Extracts real technical properties and embedded tags without mutating the source audio file.
    /// Missing metadata fields remain `nil` rather than synthesized from filenames.
    func extract(
        url: URL,
        canonicalPath: String,
        bookmarkData: Data? = nil,
        existingID: UUID? = nil,
        existingPlayCount: Int = 0,
        existingLastPlayedAt: Date? = nil,
        existingIsFavorite: Bool = false,
        existingRating: Int = 0,
        existingDateAdded: Date? = nil,
        artworkProvider: AudioArtworkProvider? = nil
    ) async throws -> ExtractedAudioRecord {
        try Task.checkCancellation()

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw AudioMetadataExtractionError.fileNotFound(url.lastPathComponent)
        }

        guard let format = AudioLibraryFormatSupport.resolveAudioFormat(for: url) else {
            throw AudioMetadataExtractionError.unsupportedAudioFormat(url.pathExtension)
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard resourceValues.isRegularFile ?? true else {
            throw AudioMetadataExtractionError.unsupportedAudioFormat(url.pathExtension)
        }
        let fileSizeBytes = Int64(max(0, resourceValues.fileSize ?? 0))
        let modTime = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let partialHash = Self.computePartialSHA256(url: url)

        // 1. Probe native stream parameters (non-loading header open only)
        let nativeInfo = Self.probeNativeAudioFile(url: url, format: format)

        // 2. Fallback / supplement via bundled ffprobe if native header couldn't open or lacks fields
        var ffprobeInfo: ProbeStreamInfo?
        if nativeInfo == nil || nativeInfo?.bitDepth == nil || nativeInfo?.bitrateBps == nil || format == .flac || format == .m4a || format == .alac {
            ffprobeInfo = await probeViaFFprobe(url: url)
        }

        try Task.checkCancellation()

        // 3. Reconcile exact technical stream values cleanly
        guard let sampleRateHz = nativeInfo?.sampleRateHz ?? ffprobeInfo?.sampleRateHz,
              let sampleRate = try? SampleRate(sampleRateHz) else {
            throw AudioMetadataExtractionError.unreadableAudioStream("Missing or invalid sample rate")
        }

        let channelCount = max(1, nativeInfo?.channelCount ?? ffprobeInfo?.channelCount ?? 2)
        let bitDepth = nativeInfo?.bitDepth ?? ffprobeInfo?.bitDepth
        let bitrateBps = ffprobeInfo?.bitrateBps ?? nativeInfo?.bitrateBps

        let frameCount: Int64
        let durationSeconds: Double
        if let native = nativeInfo, native.frameCount > 0 {
            frameCount = native.frameCount
            durationSeconds = Double(frameCount) / Double(sampleRate.hz)
        } else if let ffprobe = ffprobeInfo, ffprobe.durationSeconds.isFinite && ffprobe.durationSeconds > 0 {
            durationSeconds = ffprobe.durationSeconds
            frameCount = max(0, Int64((durationSeconds * Double(sampleRate.hz)).rounded()))
        } else {
            frameCount = 0
            durationSeconds = 0
        }

        let codecName = Self.resolveCodecName(
            ffprobeCodec: ffprobeInfo?.codecName,
            format: format
        )
        let isLossless = AudioLibraryFormatSupport.losslessAudioFormats.contains(format)
            || codecName.lowercased() == "alac"
            || codecName.lowercased() == "flac"

        // 4. Reuse existing AudioMetadataProvider (AVURLAsset + ffprobe/ffmpeg artwork copy)
        let doc = try? await metadataProvider.readMetadata(from: url)
        try Task.checkCancellation()

        let trackParsed = Self.parseFractionPair(doc?.common.trackNumber)
        let discParsed = Self.parseFractionPair(doc?.common.discNumber)

        var artworkData = doc?.artwork?.data
        if let rawArt = artworkData, AudioArtworkProvider.normalizeArtworkData(rawArt) == nil {
            artworkData = nil
        }
        var artworkKey: String?
        if let artProvider = artworkProvider, let validArtData = artworkData {
            artworkKey = await artProvider.storeArtwork(data: validArtData)
        }

        let metadata = AudioMetadata(
            title: Self.cleanTagString(doc?.common.title),
            artist: Self.cleanTagString(doc?.common.artist),
            album: Self.cleanTagString(doc?.common.album),
            albumArtist: Self.cleanTagString(doc?.common.albumArtist),
            genre: Self.cleanTagString(doc?.common.genre),
            year: doc?.common.year,
            trackNumber: trackParsed.number,
            trackTotal: trackParsed.total,
            discNumber: discParsed.number,
            discTotal: discParsed.total,
            composer: Self.cleanTagString(doc?.common.composer),
            comment: Self.cleanTagString(doc?.common.comment),
            lyrics: Self.cleanTagString(doc?.common.lyrics),
            copyright: Self.cleanTagString(doc?.common.copyright),
            encoder: Self.cleanTagString(doc?.common.encoder),
            hasEmbeddedArtwork: artworkData != nil,
            artworkCacheKey: artworkKey,
            metadataOrigin: .embeddedAndIndexed
        )

        let now = Date()
        let asset = try AudioAsset(
            id: existingID ?? UUID(),
            canonicalPath: canonicalPath,
            bookmarkData: bookmarkData,
            displayFilename: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(),
            formatRawValue: format.rawValue,
            fileSizeBytes: fileSizeBytes,
            modificationTime: modTime,
            partialHashSHA256: partialHash,
            contentSHA256: nil,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth,
            bitrateBps: bitrateBps,
            frameCount: frameCount,
            durationSeconds: durationSeconds,
            isLosslessCodec: isLossless,
            codecName: codecName,
            status: .ok,
            dateAdded: existingDateAdded ?? now,
            dateModified: Date(timeIntervalSince1970: modTime),
            playCount: existingPlayCount,
            lastPlayedAt: existingLastPlayedAt,
            isFavorite: existingIsFavorite,
            rating: existingRating
        )

        return ExtractedAudioRecord(asset: asset, metadata: metadata, artworkData: artworkData)
    }

    // MARK: - Helpers

    private struct ProbeStreamInfo {
        var sampleRateHz: Int32
        var channelCount: Int
        var bitDepth: Int?
        var bitrateBps: Int?
        var frameCount: Int64
        var durationSeconds: Double
        var codecName: String?
    }

    private static func probeNativeAudioFile(url: URL, format: FileFormat) -> ProbeStreamInfo? {
        guard AudioLibraryFormatSupport.nativePlaybackFormats.contains(format) else {
            return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let settings = file.fileFormat.settings
        let sr = Int32(file.fileFormat.sampleRate.rounded())
        guard SampleRate.validRange.contains(sr) else { return nil }

        let ch = Int(file.fileFormat.channelCount)
        guard ch >= 1 else { return nil }

        let frames = max(0, file.length)
        let bitDepth = (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue
        var bitrate = (settings[AVEncoderBitRateKey] as? NSNumber)?.intValue
        if bitrate == nil, let bitDepth, bitDepth > 0, [.wav, .aiff, .caf].contains(format) {
            let (srTimesCh, ov1) = Int(sr).multipliedReportingOverflow(by: ch)
            let (pcmBps, ov2) = srTimesCh.multipliedReportingOverflow(by: bitDepth)
            if !ov1, !ov2, pcmBps > 0 {
                bitrate = pcmBps
            }
        }
        let duration = frames > 0 ? Double(frames) / Double(sr) : 0.0

        return ProbeStreamInfo(
            sampleRateHz: sr,
            channelCount: ch,
            bitDepth: bitDepth,
            bitrateBps: bitrate,
            frameCount: frames,
            durationSeconds: duration,
            codecName: nil
        )
    }

    private func probeViaFFprobe(url: URL) async -> ProbeStreamInfo? {
        guard let ffprobePath = await ffmpegProvider.findFFprobePath() else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "format=duration,bit_rate:stream=codec_name,sample_rate,channels,bits_per_raw_sample,bits_per_sample,bit_rate,duration",
            "-of", "json",
            url.path
        ]
        guard let output = try? await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 15),
              output.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first else {
            return nil
        }

        let srString = stream["sample_rate"] as? String
        let srNum = srString.flatMap { Int32($0) } ?? (stream["sample_rate"] as? Int).map { Int32($0) }
        guard let sampleRateHz = srNum, SampleRate.validRange.contains(sampleRateHz) else {
            return nil
        }

        let channels = max(1, (stream["channels"] as? Int) ?? 2)
        let bitsRaw = (stream["bits_per_raw_sample"] as? String).flatMap { Int($0) }
            ?? (stream["bits_per_raw_sample"] as? Int)
            ?? (stream["bits_per_sample"] as? Int)
        let bitDepth = (bitsRaw ?? 0) > 0 ? bitsRaw : nil

        let formatDict = json["format"] as? [String: Any]
        let streamBitrate = (stream["bit_rate"] as? String).flatMap { Int($0) } ?? (stream["bit_rate"] as? Int)
        let formatBitrate = (formatDict?["bit_rate"] as? String).flatMap { Int($0) } ?? (formatDict?["bit_rate"] as? Int)
        let bitrate = streamBitrate ?? formatBitrate

        let streamDur = (stream["duration"] as? String).flatMap { Double($0) } ?? (stream["duration"] as? Double)
        let formatDur = (formatDict?["duration"] as? String).flatMap { Double($0) } ?? (formatDict?["duration"] as? Double)
        let duration = max(0.0, streamDur ?? formatDur ?? 0.0)
        let frames = duration.isFinite ? Int64((duration * Double(sampleRateHz)).rounded()) : 0
        let codecName = stream["codec_name"] as? String

        return ProbeStreamInfo(
            sampleRateHz: sampleRateHz,
            channelCount: channels,
            bitDepth: bitDepth,
            bitrateBps: (bitrate ?? 0) > 0 ? bitrate : nil,
            frameCount: max(0, frames),
            durationSeconds: duration,
            codecName: codecName
        )
    }

    private static func resolveCodecName(ffprobeCodec: String?, format: FileFormat) -> String {
        if let ffprobeCodec, !ffprobeCodec.isEmpty {
            return ffprobeCodec.lowercased()
        }
        return format.rawValue.lowercased()
    }

    private static func cleanTagString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseFractionPair(_ raw: String?) -> (number: Int?, total: Int?) {
        guard let cleaned = cleanTagString(raw) else {
            return (nil, nil)
        }
        let parts = cleaned.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let number = parts.first.flatMap { Int($0) }
        let total = parts.count > 1 ? Int(parts[1]) : nil
        return (number, total)
    }

    /// Reads up to the first 64 KB to produce a fast partial SHA-256 without loading entire large audio files.
    private static func computePartialSHA256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: 65_536)) ?? Data()
        let digest = SHA256.hash(data: chunk)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

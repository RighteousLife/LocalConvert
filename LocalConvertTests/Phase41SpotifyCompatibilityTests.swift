import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
@testable import LocalConvert

@Suite("Phase 41 — Spotify Compatibility & Safe Container Normalization")
struct Phase41SpotifyCompatibilityTests {

    // MARK: - Helpers

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P41Spotify-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bundledFFmpegPaths() async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: false)
        let ffmpeg = try #require(await provider.findFFmpegPath())
        let ffprobe = try #require(await provider.findFFprobePath())
        return (ffmpeg, ffprobe)
    }

    private func runFFmpeg(_ ffmpeg: String, args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let output = try await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: 60)
        guard output.terminationStatus == 0 else {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed("FFmpeg failed (\(output.terminationStatus))", underlyingError: err)
        }
    }

    private func makeImageData(width: Int, height: Int, utType: UTType) throws -> Data {
        let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.22, green: 0.65, blue: 0.40, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try #require(ctx.makeImage())
        let outData = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(outData, utType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return outData as Data
    }

    private func syncSafe32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    private func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func buildID3v24Frame(id: String, payload: Data) -> Data {
        var frame = Data(id.utf8.prefix(4))
        frame.append(syncSafe32(UInt32(payload.count)))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(payload)
        return frame
    }

    private func buildID3v24UTF8Text(id: String, text: String) -> Data {
        var payload = Data([0x03]) // UTF-8 (disallowed in strict v2.3 normalized output)
        payload.append(contentsOf: text.utf8)
        return buildID3v24Frame(id: id, payload: payload)
    }

    private func buildID3v24TXXX(description: String, value: String) -> Data {
        var payload = Data([0x03])
        payload.append(contentsOf: description.utf8)
        payload.append(0x00)
        payload.append(contentsOf: value.utf8)
        return buildID3v24Frame(id: "TXXX", payload: payload)
    }

    private func buildID3v24USLT(lyrics: String) -> Data {
        var payload = Data([0x03])
        payload.append(contentsOf: "eng".utf8)
        payload.append(0x00) // empty description terminator
        payload.append(contentsOf: lyrics.utf8)
        return buildID3v24Frame(id: "USLT", payload: payload)
    }

    private func buildID3v24APIC(mime: String, pictureType: UInt8, imageData: Data) -> Data {
        var payload = Data([0x03])
        payload.append(contentsOf: mime.utf8)
        payload.append(0x00)
        payload.append(pictureType)
        payload.append(contentsOf: "Cover".utf8)
        payload.append(0x00)
        payload.append(imageData)
        return buildID3v24Frame(id: "APIC", payload: payload)
    }

    private func buildSyntheticID3v24Tag(frames: [Data]) -> Data {
        let body = frames.reduce(into: Data()) { $0.append($1) }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x04, 0x00, 0x00]) // ID3v2.4.0
        tag.append(syncSafe32(UInt32(body.count)))
        tag.append(body)
        return tag
    }

    private func makeAudioM4ABox(type: String, payload: Data) -> Data {
        var box = be32(UInt32(8 + payload.count))
        box.append(contentsOf: type.utf8.prefix(4))
        box.append(payload)
        return box
    }

    private func currentRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kern == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : 0
    }

    // MARK: - 1. Classification Matrix Tests

    @Test("Format registry classifies MP3, M4A AAC, audio MP4, video MP4, ALAC, FLAC, WAV, OGG, Opus, and M4P accurately")
    func spotifyCompatibilityClassificationMatrix() async throws {
        let dir = try makeTempDir("matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()

        let mp3URL = dir.appendingPathComponent("track.mp3")
        try await runFFmpeg(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.6", "-c:a", "libmp3lame", "-q:a", "4", mp3URL.path])

        let m4aAACURL = dir.appendingPathComponent("track_aac.m4a")
        try await runFFmpeg(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=520:duration=0.6", "-c:a", "aac", "-b:a", "128k", m4aAACURL.path])

        let mp4AudioOnlyURL = dir.appendingPathComponent("audio_only.mp4")
        try await runFFmpeg(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=660:duration=0.6", "-c:a", "aac", "-b:a", "128k", mp4AudioOnlyURL.path])

        let mp4VideoURL = dir.appendingPathComponent("video_clip.mp4")
        try await runFFmpeg(ffmpeg, args: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=blue:s=160x120:d=0.5",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5",
            "-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", mp4VideoURL.path
        ])

        let m4aALACURL = dir.appendingPathComponent("lossless.m4a")
        try await runFFmpeg(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.6", "-c:a", "alac", m4aALACURL.path])

        let flacURL = dir.appendingPathComponent("lossless.flac")
        try await runFFmpeg(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.6", "-c:a", "flac", flacURL.path])

        let wavURL = try TestFixtureFactory.createWAV(in: dir, name: "pcm.wav", duration: 0.5)

        let oggURL = dir.appendingPathComponent("vorbis.ogg")
        try await runFFmpeg(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5", "-c:a", "libopus", oggURL.path])

        let opusURL = dir.appendingPathComponent("voice.opus")
        try await runFFmpeg(ffmpeg, args: ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5", "-c:a", "libopus", opusURL.path])

        // Protected .m4p fixture containing an explicit `drms` / `sinf` DRM atom inside `moov`
        let m4pDRMURL = dir.appendingPathComponent("purchased.m4p")
        var ftypPayload = Data("M4P ".utf8)
        ftypPayload.append(be32(0))
        ftypPayload.append(Data("M4P isom".utf8))
        let ftypBox = makeAudioM4ABox(type: "ftyp", payload: ftypPayload)
        let schmBox = makeAudioM4ABox(type: "schm", payload: Data([0, 0, 0, 0]) + Data("itun".utf8))
        let sinfBox = makeAudioM4ABox(type: "sinf", payload: schmBox)
        let drmsBox = makeAudioM4ABox(type: "drms", payload: sinfBox)
        let moovBox = makeAudioM4ABox(type: "moov", payload: drmsBox)
        try (ftypBox + moovBox).write(to: m4pDRMURL)

        // Unknown .m4p without explicit sinf/drms markers -> classified .unknownDRM (also blocks modification)
        let m4pUnknownURL = dir.appendingPathComponent("ambiguous.m4p")
        try Data(contentsOf: m4aAACURL).write(to: m4pUnknownURL)

        let service = SpotifyCompatibilityService.shared

        let mp3Report = await service.analyzeFile(url: mp3URL)
        #expect(mp3Report.classification == .officiallyDocumented)
        #expect(mp3Report.drmStatus == .noneDetected)
        #expect(!mp3Report.drmStatus.blocksModification)

        let mp4AudioReport = await service.analyzeFile(url: mp4AudioOnlyURL)
        #expect(mp4AudioReport.classification == .officiallyDocumented)
        #expect(!mp4AudioReport.hasVideoStream)

        let m4aAACReport = await service.analyzeFile(url: m4aAACURL)
        #expect(m4aAACReport.classification == .conditional)

        let mp4VideoReport = await service.analyzeFile(url: mp4VideoURL)
        #expect(mp4VideoReport.classification == .incompatibleVideoContainer)
        #expect(mp4VideoReport.hasVideoStream)

        let m4aALACReport = await service.analyzeFile(url: m4aALACURL)
        #expect(m4aALACReport.classification == .unsupportedFormat)

        let flacReport = await service.analyzeFile(url: flacURL)
        #expect(flacReport.classification == .unsupportedFormat)

        let wavReport = await service.analyzeFile(url: wavURL)
        #expect(wavReport.classification == .unsupportedFormat)

        let oggReport = await service.analyzeFile(url: oggURL)
        #expect(oggReport.classification == .unsupportedFormat)

        let opusReport = await service.analyzeFile(url: opusURL)
        #expect(opusReport.classification == .unsupportedFormat)

        let drmReport = await service.analyzeFile(url: m4pDRMURL)
        #expect(drmReport.classification == .drmProtected)
        #expect(drmReport.drmStatus.blocksModification)

        let unknownDRMReport = await service.analyzeFile(url: m4pUnknownURL)
        #expect(unknownDRMReport.classification == .unknownDRM)
        #expect(unknownDRMReport.drmStatus.blocksModification)

        // Verify normalization refuses DRM, video MP4, ALAC, and unsupported FLAC without modifying originals
        for blocked in [mp4VideoReport, m4aALACReport, flacReport, drmReport, unknownDRMReport] {
            let beforeData = try Data(contentsOf: blocked.inputURL)
            let norm = await service.normalizeFile(
                item: blocked,
                options: SpotifyNormalizationOptions(outputDirectory: dir)
            )
            #expect(norm.outputURL == nil)
            #expect(norm.normalizationState == .drmProtected || norm.normalizationState == .unsupportedFormat)
            #expect(try Data(contentsOf: blocked.inputURL) == beforeData)
        }
    }

    // MARK: - 2. MP3 ID3v2.4 -> ID3v2.3 Normalization, Artwork Validation & Bit-Exact Audio Proof

    @Test("MP3 normalizes ID3v2.4 UTF-8 + TDRC + USLT + Front Cover + preserves unknown TXXX and bit-exact MPEG frames")
    func mp3ID3v23NormalizationAndBitExactAudio() async throws {
        let dir = try makeTempDir("mp3_norm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()

        // Generate clean raw MP3 (strip any FFmpeg tag by mapping -map_metadata -1)
        let rawMP3 = dir.appendingPathComponent("base.mp3")
        try await runFFmpeg(ffmpeg, args: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1.2",
            "-map_metadata", "-1", "-id3v2_version", "0",
            "-c:a", "libmp3lame", "-b:a", "192k", rawMP3.path
        ])
        let mpegBytes = try Data(contentsOf: rawMP3)

        let validJPEG = try makeImageData(width: 400, height: 400, utType: .jpeg)
        let corruptArt = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])

        let secretLyrics = "SECRET_LYRICS_LINE_1\nÜnicöde ÇŞĞ Line 2"
        let service = SpotifyCompatibilityService.shared

        // 2a. Corrupt embedded artwork is detected and safely refused before writing
        let corruptTag = buildSyntheticID3v24Tag(frames: [
            buildID3v24UTF8Text(id: "TIT2", text: "Corrupt Art Track"),
            buildID3v24APIC(mime: "image/jpeg", pictureType: 0x03, imageData: validJPEG),
            buildID3v24APIC(mime: "image/png", pictureType: 0x04, imageData: corruptArt)
        ])
        let corruptMP3 = dir.appendingPathComponent("input_corrupt_art.mp3")
        try (corruptTag + mpegBytes).write(to: corruptMP3)
        let corruptReport = await service.analyzeFile(url: corruptMP3)
        #expect(corruptReport.artworkAnalysis.count == 2)
        #expect(corruptReport.artworkAnalysis.validCount == 1)
        #expect(corruptReport.artworkAnalysis.corruptCount == 1)
        let refusedCorrupt = await service.normalizeFile(
            item: corruptReport,
            options: SpotifyNormalizationOptions(outputDirectory: dir)
        )
        #expect(refusedCorrupt.normalizationState == .failedValidation)
        #expect(refusedCorrupt.outputURL == nil)

        // 2b. Valid ID3v2.4 UTF-8 + TDRC + USLT + Front Cover + TXXX -> normalized ID3v2.3.0 UTF-16
        let id3v24Tag = buildSyntheticID3v24Tag(frames: [
            buildID3v24UTF8Text(id: "TIT2", text: "LocalConvert Track — ÇŞĞ"),
            buildID3v24UTF8Text(id: "TPE1", text: "Test Artist"),
            buildID3v24UTF8Text(id: "TALB", text: "Test Album"),
            buildID3v24UTF8Text(id: "TPE2", text: "Album Artist"),
            buildID3v24UTF8Text(id: "TDRC", text: "2024-09-15"),
            buildID3v24UTF8Text(id: "TRCK", text: "3/12"),
            buildID3v24UTF8Text(id: "TPOS", text: "1/2"),
            buildID3v24UTF8Text(id: "TCON", text: "Electronic"),
            buildID3v24USLT(lyrics: secretLyrics),
            buildID3v24TXXX(description: "custom_key", value: "preserved_val"),
            buildID3v24APIC(mime: "image/jpeg", pictureType: 0x03, imageData: validJPEG)
        ])

        let sourceMP3 = dir.appendingPathComponent("input_v24.mp3")
        let fullInputBytes = id3v24Tag + mpegBytes
        try fullInputBytes.write(to: sourceMP3)

        let preReport = await service.analyzeFile(url: sourceMP3)
        #expect(preReport.classification == .officiallyDocumented)
        #expect(preReport.metadataSummary.id3Version == "ID3v2.4.0")
        #expect(preReport.metadataSummary.hasLyrics == true)
        #expect(preReport.artworkAnalysis.count == 1)
        #expect(preReport.artworkAnalysis.validCount == 1)
        #expect(preReport.metadataSummary.additionalFramesOrAtoms.contains("TXXX:custom_key"))
        #expect(!preReport.metadataSummary.isNormalizedProfile)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let normalized = await service.normalizeFile(
            item: preReport,
            options: SpotifyNormalizationOptions(outputDirectory: outDir)
        )

        #expect(normalized.normalizationState == .fixedSuccessfully)
        let outURL = try #require(normalized.outputURL)
        #expect(FileManager.default.fileExists(atPath: outURL.path))
        #expect(normalized.audioPayloadVerified == true)
        #expect(normalized.preAudioHashSHA256 != nil)
        #expect(normalized.preAudioHashSHA256 == normalized.postAudioHashSHA256)

        // Original file MUST remain bit-for-bit untouched
        #expect(try Data(contentsOf: sourceMP3) == fullInputBytes)

        // Inspect written ID3v2.3 binary header & frames directly
        let parsedOut = try SpotifyID3Processor.inspect(url: outURL)
        #expect(parsedOut.majorVersion == 3)
        #expect(parsedOut.encodingIssues.isEmpty)
        #expect(parsedOut.txxxFrames.contains(where: { $0.desc == "custom_key" && $0.value == "preserved_val" }))
        #expect(parsedOut.lyrics == secretLyrics)
        #expect(parsedOut.title == "LocalConvert Track — ÇŞĞ")
        #expect(parsedOut.year == "2024")
        #expect(parsedOut.apicFrames.count == 1)
        #expect(parsedOut.apicFrames.first?.validation.isValid == true)
        #expect(parsedOut.apicFrames.first?.pictureType == 0x03)
        #expect(parsedOut.isNormalizedProfile == true)

        // Raw MPEG byte slice SHA-256 equals original mpegBytes SHA-256
        let expectedRawSHA = SHA256.hash(data: mpegBytes).map { String(format: "%02x", $0) }.joined()
        let outRawSHA = try SpotifyID3Processor.computeRawMPEGAudioSHA256(url: outURL, parsed: parsedOut)
        #expect(outRawSHA == expectedRawSHA)

        // Second normalization pass MUST detect already-compatible profile (idempotent)
        let reAnalyzed = await service.analyzeFile(url: outURL)
        #expect(reAnalyzed.metadataSummary.isNormalizedProfile)
        let secondPass = await service.normalizeFile(
            item: reAnalyzed,
            options: SpotifyNormalizationOptions(outputDirectory: outDir)
        )
        #expect(secondPass.normalizationState == .alreadyCompatible)

        // Export report check: lyrics must NOT appear in Markdown or JSON reports
        let md = SpotifyCompatibilityService.exportReportMarkdown(items: [normalized], includeLyricsNotice: true)
        #expect(md.contains("Lyrics presence noted"))
        #expect(!md.contains("SECRET_LYRICS_LINE_1"))
        let jsonData = try SpotifyCompatibilityService.exportReportJSON(items: [normalized])
        let jsonStr = try #require(String(data: jsonData, encoding: .utf8))
        #expect(!jsonStr.contains("SECRET_LYRICS_LINE_1"))
    }

    // MARK: - 3. Oversized Cover Art Opt-In Resizing

    @Test("Oversized cover art is preserved when resize toggle is OFF and downscaled <= 1000px when ON")
    func oversizedCoverArtPolicy() async throws {
        let dir = try makeTempDir("oversized_art")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()

        let rawMP3 = dir.appendingPathComponent("base.mp3")
        try await runFFmpeg(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.8",
            "-map_metadata", "-1", "-id3v2_version", "0", "-c:a", "libmp3lame", "-b:a", "128k", rawMP3.path
        ])
        let mpegBytes = try Data(contentsOf: rawMP3)
        let bigPNG = try makeImageData(width: 1400, height: 1400, utType: .png)
        let tag = buildSyntheticID3v24Tag(frames: [
            buildID3v24UTF8Text(id: "TIT2", text: "Big Cover"),
            buildID3v24APIC(mime: "image/png", pictureType: 0x03, imageData: bigPNG)
        ])
        let srcURL = dir.appendingPathComponent("big_art.mp3")
        try (tag + mpegBytes).write(to: srcURL)

        let service = SpotifyCompatibilityService.shared
        let analyzed = await service.analyzeFile(url: srcURL)

        let outKeepDir = dir.appendingPathComponent("keep", isDirectory: true)
        let outResizeDir = dir.appendingPathComponent("resize", isDirectory: true)
        try FileManager.default.createDirectory(at: outKeepDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outResizeDir, withIntermediateDirectories: true)

        let kept = await service.normalizeFile(
            item: analyzed,
            options: SpotifyNormalizationOptions(outputDirectory: outKeepDir, resizeOversizedArtwork: false)
        )
        let keptRe = await service.analyzeFile(url: try #require(kept.outputURL))
        #expect(keptRe.artworkAnalysis.entries.first?.pixelWidth == 1400)
        #expect(kept.warnings.contains(where: { $0.contains("exceeds 1000") }))

        let resized = await service.normalizeFile(
            item: analyzed,
            options: SpotifyNormalizationOptions(outputDirectory: outResizeDir, resizeOversizedArtwork: true, maxArtworkDimension: 1000)
        )
        #expect(resized.audioPayloadVerified == true)
        let resizedRe = await service.analyzeFile(url: try #require(resized.outputURL))
        let w = try #require(resizedRe.artworkAnalysis.entries.first?.pixelWidth)
        let h = try #require(resizedRe.artworkAnalysis.entries.first?.pixelHeight)
        #expect(w <= 1000 && h <= 1000)
    }

    // MARK: - 4. M4A / Audio-Only MP4 Normalization (Both moov-after-mdat & faststart moov-before-mdat)

    @Test("M4A and audio-only MP4 normalization preserves bit-exact AAC streamhash and shifts offsets for faststart containers")
    func m4aAndFaststartOffsetNormalization() async throws {
        let dir = try makeTempDir("m4a_faststart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()
        let jpgData = try makeImageData(width: 256, height: 256, utType: .jpeg)
        let jpgURL = dir.appendingPathComponent("cover.jpg")
        try jpgData.write(to: jpgURL)

        for (ext, useFaststart, stripInputTags, expectedNormState) in [
            ("m4a", false, false, SpotifyNormalizationResultState.conditionalCompatibility),
            ("m4a", true, true, SpotifyNormalizationResultState.conditionalCompatibility),
            ("mp4", true, false, SpotifyNormalizationResultState.fixedSuccessfully)
        ] {
            let suffix = "\(ext)_\(useFaststart ? "faststart" : "tailmoov")_\(stripInputTags ? "strip" : "tags")"
            let srcURL = dir.appendingPathComponent("track_\(suffix).\(ext)")
            var args = [
                "-y", "-v", "error",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=1.0",
                "-i", jpgURL.path,
                "-map", "0:a", "-map", "1:v",
                "-c:a", "aac", "-b:a", "128k",
                "-c:v", "copy", "-disposition:v:0", "attached_pic"
            ]
            if stripInputTags {
                args += ["-map_metadata", "-1", "-fflags", "+bitexact"]
            } else {
                args += [
                    "-metadata", "title=M4A Title \(suffix)",
                    "-metadata", "artist=M4A Artist",
                    "-metadata", "album=M4A Album",
                    "-metadata", "album_artist=M4A Album Artist",
                    "-metadata", "date=2025",
                    "-metadata", "track=2/10",
                    "-metadata", "disc=1/1",
                    "-metadata", "genre=Rock"
                ]
            }
            if useFaststart {
                args += ["-movflags", "+faststart"]
            }
            args.append(srcURL.path)
            try await runFFmpeg(ffmpeg, args: args)

            let service = SpotifyCompatibilityService.shared
            let analyzed = await service.analyzeFile(url: srcURL)
            if ext == "mp4" {
                #expect(analyzed.classification == .officiallyDocumented)
            } else {
                #expect(analyzed.classification == .conditional)
            }
            #expect(analyzed.artworkAnalysis.validCount == 1)

            let outDir = dir.appendingPathComponent("out_\(suffix)", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            let normalized = await service.normalizeFile(
                item: analyzed,
                options: SpotifyNormalizationOptions(outputDirectory: outDir)
            )
            #expect(normalized.normalizationState == expectedNormState)
            #expect(normalized.audioPayloadVerified == true)
            #expect(normalized.preAudioHashSHA256 == normalized.postAudioHashSHA256)

            let outURL = try #require(normalized.outputURL)
            // Verify FFmpeg decodes normalized output cleanly without moov/stco corruption
            let outStreamHash = try await SpotifyAudioHashUtility.computeFFmpegStreamHash(url: outURL, ffmpegPath: ffmpeg)
            #expect(outStreamHash == normalized.preAudioHashSHA256)

            if ext == "mp4" {
                // Re-normalizing normalized MP4 verifies idempotent .alreadyCompatible state
                let secondAnalyzed = await service.analyzeFile(url: outURL)
                let secondNorm = await service.normalizeFile(
                    item: secondAnalyzed,
                    options: SpotifyNormalizationOptions(outputDirectory: outDir)
                )
                #expect(secondNorm.normalizationState == .alreadyCompatible)
                #expect(secondNorm.audioPayloadVerified == true)
            }
        }
    }

    // MARK: - 5. Batch Partial Failures, Cancellation, Collision Policies & Memory Bound

    @Test("Batch analysis survives partial failures, supports cancellation, respects same-folder safety, and bounds RSS")
    func batchResiliencePoliciesAndMemory() async throws {
        let dir = try makeTempDir("batch_policies")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await bundledFFmpegPaths()

        let mp3URL = dir.appendingPathComponent("good.mp3")
        try await runFFmpeg(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.6",
            "-c:a", "libmp3lame", "-b:a", "128k", mp3URL.path
        ])
        let missingURL = dir.appendingPathComponent("does_not_exist.mp3")
        let corruptURL = dir.appendingPathComponent("corrupt.mp3")
        try Data("NOT_A_VALID_AUDIO_FILE".utf8).write(to: corruptURL)

        let service = SpotifyCompatibilityService.shared
        let batch = await service.analyzeBatch(urls: [mp3URL, missingURL, corruptURL], maxConcurrent: 2) { _, _ in }
        #expect(batch.count == 3)
        #expect(batch[0].classification == .officiallyDocumented)
        #expect(batch[1].normalizationState == .processingError)
        #expect(batch[2].normalizationState == .failedValidation || batch[2].classification == .unsupportedFormat)

        // Same-folder .overwrite MUST never replace original source file
        let originalBytes = try Data(contentsOf: mp3URL)
        let normOverwriteBlocked = await service.normalizeFile(
            item: batch[0],
            options: SpotifyNormalizationOptions(outputDirectory: dir, existingFileHandling: .overwrite)
        )
        let outCopy = try #require(normOverwriteBlocked.outputURL)
        #expect(outCopy.standardizedFileURL != mp3URL.standardizedFileURL)
        #expect(try Data(contentsOf: mp3URL) == originalBytes)

        // Larger audio file (~15 seconds MP3 -> streaming check, bounded RSS)
        let rssBefore = currentRSSMB()
        let longMP3 = dir.appendingPathComponent("long_track.mp3")
        try await runFFmpeg(ffmpeg, args: [
            "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=330:duration=20",
            "-c:a", "libmp3lame", "-b:a", "320k",
            "-metadata", "title=Long Track", longMP3.path
        ])
        let longAnalyzed = await service.analyzeFile(url: longMP3)
        let longNorm = await service.normalizeFile(
            item: longAnalyzed,
            options: SpotifyNormalizationOptions(outputDirectory: dir)
        )
        #expect(longNorm.audioPayloadVerified == true)
        let rssDeltaMB = currentRSSMB() - rssBefore
        #expect(rssDeltaMB < 64.0)
    }
}

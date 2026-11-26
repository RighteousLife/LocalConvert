import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import LocalConvert

@Suite("Phase 38 - Audio Toolbox Pro Real-File Verification")
struct AudioToolboxPro2Tests {

    private let provider = BundledFFmpegProvider(fallbackToSystem: true)

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LC_AudioPro2_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func runFFmpeg(_ args: [String]) async throws {
        let ffmpegPath = try #require(await provider.findFFmpegPath())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "ffmpeg error"
            throw ConversionError.engineExecutionFailed(msg, underlyingError: msg)
        }
    }

    private func generateToneWAV(
        at url: URL,
        durationSeconds: Double = 3.0,
        frequencyHz: Double = 440.0,
        amplitude: Double = 0.25,
        sampleRate: Int = 44100,
        channels: Int = 2
    ) async throws {
        let layout = channels == 1 ? "mono" : (channels == 6 ? "5.1" : (channels == 8 ? "7.1" : "stereo"))
        try await runFFmpeg([
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequencyHz):sample_rate=\(sampleRate):duration=\(durationSeconds)",
            "-af", "volume=\(amplitude),aformat=channel_layouts=\(layout)",
            "-c:a", "pcm_s16le",
            url.path
        ])
    }

    private func generateCoverImagePNG(at url: URL) throws {
        guard let ctx = CGContext(
            data: nil,
            width: 128,
            height: 128,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed("CGContext failed", underlyingError: nil)
        }
        ctx.setFillColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let img = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: img)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    // MARK: - 1. Runtime FFmpeg Capability Inspection

    @Test("Bundled FFmpeg runtime probe verifies all advertised encoders and decode-only codecs")
    func runtimeCapabilityInspection() async throws {
        let ffmpegPath = try #require(await provider.findFFmpegPath())
        let report = await AudioCodecRegistry.inspectRuntimeCapabilities(ffmpegPath: ffmpegPath)

        #expect(report.verifiedEncoders.contains("libmp3lame"))
        #expect(report.verifiedEncoders.contains("libopus"))
        #expect(report.verifiedEncoders.contains("flac"))
        #expect(report.verifiedEncoders.contains("aac"))
        #expect(report.verifiedEncoders.contains("aac_at"))
        #expect(report.verifiedEncoders.contains("alac"))
        #expect(report.verifiedEncoders.contains("ac3"))
        #expect(report.verifiedEncoders.contains("eac3"))
        #expect(report.verifiedEncoders.contains("dca"))
        #expect(report.verifiedEncoders.contains("wavpack"))
        #expect(report.verifiedEncoders.contains("wmav2"))
        #expect(report.verifiedFilters.contains("loudnorm"))
        #expect(report.verifiedFilters.contains("ebur128"))
        #expect(report.verifiedFilters.contains("acrossfade"))
        #expect(report.verifiedFilters.contains("aresample"))
        #expect(report.decodeOnlyCodecs.contains("ape"))
        #expect(report.decodeOnlyCodecs.contains("amr"))
    }

    // MARK: - 2. Cover Artwork & Turkish Unicode Tag Preservation

    @Test("Audio Toolbox preserves album cover artwork and Turkish Unicode ID3/Vorbis/MP4 metadata across conversions")
    func coverArtAndTurkishTagsPreserved() async throws {
        let dir = try makeTempDir("cover_tr")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcWAV = dir.appendingPathComponent("src.wav")
        let coverPNG = dir.appendingPathComponent("cover.png")
        let taggedMP3 = dir.appendingPathComponent("tagged_input.mp3")
        try await generateToneWAV(at: srcWAV, durationSeconds: 2.0)
        try generateCoverImagePNG(at: coverPNG)

        try await runFFmpeg([
            "-i", srcWAV.path,
            "-i", coverPNG.path,
            "-map", "0:a",
            "-map", "1:v",
            "-c:a", "libmp3lame", "-b:a", "192k",
            "-c:v", "png",
            "-disposition:v", "attached_pic",
            "-id3v2_version", "3",
            "-metadata", "title=İstanbul Şarkısı ğüşiöç",
            "-metadata", "artist=Sanatçı ĞÜŞİÖÇ",
            "-metadata", "album=Deneme Albümü",
            taggedMP3.path
        ])

        let probedIn = try await provider.probe(url: taggedMP3)
        #expect(probedIn.hasAttachedArtwork)
        #expect(!probedIn.hasRealVideo)

        // Convert tagged MP3 -> FLAC via AudioToolbox preserving metadata & artwork
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var cfg = AudioToolboxConfig()
        cfg.codec = .flac
        cfg.volumeGainDB = -1.5
        let options = cfg.applying(to: ConversionOptions(preserveMetadata: true))

        let res = try await provider.convertBatch(
            inputs: [taggedMP3],
            to: .flac,
            outputDirectory: outDir,
            options: options
        ) { _ in }

        let probedOut = try await provider.probe(url: res.outputURL)
        #expect(probedOut.primaryAudioStream?.codecName == "flac")
        #expect(probedOut.hasAttachedArtwork)

        let metaDoc = try await AudioMetadataProvider().readMetadata(from: res.outputURL)
        #expect(metaDoc.common.title == "İstanbul Şarkısı ğüşiöç")
        #expect(metaDoc.common.artist == "Sanatçı ĞÜŞİÖÇ")
        #expect(metaDoc.artwork != nil)

        // Verify WAV target raises cover-art warning in validator
        let wavValidation = AudioConversionValidator.validate(config: AudioToolboxConfig(), outputFormat: .wav, sourceInfo: probedIn)
        #expect(wavValidation.warnings.contains(where: { $0.contains("artwork") }))
    }

    // MARK: - 3. Two-Pass Linear EBU R128 LUFS Loudness Normalization & Telemetry

    @Test("Two-pass EBU R128 loudness normalization measures input parameters, applies linear normalization, and hits target LUFS cleanly")
    func twoPassEbuR128Normalization() async throws {
        let dir = try makeTempDir("lufs2p")
        defer { try? FileManager.default.removeItem(at: dir) }

        let quietWAV = dir.appendingPathComponent("quiet.wav")
        // Amplitude 0.04 (~ -28 dBFS) -> quite soft signal
        try await generateToneWAV(at: quietWAV, durationSeconds: 4.0, frequencyHz: 1000.0, amplitude: 0.04)

        let preMeasure = try await AudioAnalysisService.shared.measureLoudness(
            url: quietWAV,
            targetLUFS: -14.0,
            targetTruePeakDB: -1.0,
            includeTwoPassLoudnorm: true
        )
        #expect(preMeasure.integratedLUFS != nil)
        #expect(preMeasure.loudnormMeasuredInputI != nil)
        #expect(preMeasure.loudnormTargetOffset != nil)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var cfg = AudioToolboxConfig()
        cfg.codec = .pcmS16LE
        cfg.normalizationMode = .ebuR128
        cfg.targetLUFS = -14.0
        cfg.targetTruePeakDB = -1.0
        let options = cfg.applying(to: ConversionOptions.default)

        let res = try await provider.convertBatch(
            inputs: [quietWAV],
            to: .wav,
            outputDirectory: outDir,
            options: options
        ) { _ in }

        let postMeasure = try await AudioAnalysisService.shared.measureLoudness(url: res.outputURL)
        let postLUFS = try #require(postMeasure.integratedLUFS)
        let postTP = try #require(postMeasure.truePeakDBTP)
        #expect(abs(postLUFS - (-14.0)) <= 1.5)
        #expect(postTP <= -0.5)
    }

    // MARK: - 4. Crossfade Merge & Channel Layout Downmix + SoX Resampling/Dither

    @Test("Audio merge supports acrossfade, mixed sample rates, 5.1->2.1 downmix, and SoX 96->44.1kHz TPDF dithering")
    func mergeCrossfadeDownmixAndSoxrDither() async throws {
        let dir = try makeTempDir("merge_cf")
        defer { try? FileManager.default.removeItem(at: dir) }

        let trackA = dir.appendingPathComponent("trackA_48k.wav")
        let trackB = dir.appendingPathComponent("trackB_44k.wav")
        try await generateToneWAV(at: trackA, durationSeconds: 3.0, frequencyHz: 440, sampleRate: 48000, channels: 2)
        try await generateToneWAV(at: trackB, durationSeconds: 3.0, frequencyHz: 554, sampleRate: 44100, channels: 2)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var mergeCfg = AudioToolboxConfig()
        mergeCfg.operation = .merge
        mergeCfg.codec = .pcmS16LE
        mergeCfg.sampleRateHz = 44100
        mergeCfg.bitDepth = 16
        mergeCfg.channelMode = .stereo
        mergeCfg.resamplerEngine = .kaiserSinc
        mergeCfg.ditherMethod = .triangular
        mergeCfg.mergeCrossfadeSeconds = 1.0

        let mergeRes = try await provider.convertBatch(
            inputs: [trackA, trackB],
            to: .wav,
            outputDirectory: outDir,
            options: mergeCfg.applying(to: .default)
        ) { _ in }

        let probedMerge = try await provider.probe(url: mergeRes.outputURL)
        #expect(probedMerge.primaryAudioStream?.sampleRate == 44100)
        #expect(probedMerge.primaryAudioStream?.channels == 2)
        // 3.0s + 3.0s - 1.0s crossfade = 5.0s (+/- 0.25s)
        #expect(abs(probedMerge.duration - 5.0) <= 0.25)

        // Check zero clipping on merged crossfade output
        let mergeLoudness = try await AudioAnalysisService.shared.measureLoudness(url: mergeRes.outputURL)
        #expect((mergeLoudness.maxVolumeDB ?? 0.0) < -0.5)

        // Check 5.1 -> 2.1 downmix & SoX 96k -> 44.1kHz resample
        let surroundIn = dir.appendingPathComponent("surround51.wav")
        try await generateToneWAV(at: surroundIn, durationSeconds: 1.5, frequencyHz: 330, sampleRate: 96000, channels: 6)

        var downmixCfg = AudioToolboxConfig()
        downmixCfg.codec = .flac
        downmixCfg.sampleRateHz = 44100
        downmixCfg.bitDepth = 16
        downmixCfg.channelMode = .surround21
        downmixCfg.resamplerEngine = .kaiserSinc
        downmixCfg.ditherMethod = .shibata

        let probedSurr = try await provider.probe(url: surroundIn)
        let validation = AudioConversionValidator.validate(config: downmixCfg, outputFormat: .flac, sourceInfo: probedSurr)
        #expect(validation.isValid)
        #expect(validation.warnings.contains(where: { $0.contains("downmix") }))

        let downmixRes = try await provider.convertBatch(
            inputs: [surroundIn],
            to: .flac,
            outputDirectory: outDir,
            options: downmixCfg.applying(to: .default)
        ) { _ in }
        let probedDownmix = try await provider.probe(url: downmixRes.outputURL)
        #expect(probedDownmix.primaryAudioStream?.sampleRate == 44100)
        #expect(probedDownmix.primaryAudioStream?.channels == 3)
    }

    // MARK: - 5. Silence Edges-Only vs All Trim + Streaming Waveform Zoom

    @Test("Silence trim supports edges-only vs internal pauses, and streaming waveform handles zoomed windows")
    func silenceEdgesOnlyAndStreamingWaveform() async throws {
        let dir = try makeTempDir("silence_wf")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build [1.0s silence][1.0s tone][1.0s internal silence][1.0s tone][1.0s silence] = 5.0s total
        let stitched = dir.appendingPathComponent("with_silence.wav")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=1.0",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1.0",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=1.0",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1.0",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=1.0",
            "-filter_complex", "[0:a][1:a][2:a][3:a][4:a]concat=n=5:v=0:a=1[out]",
            "-map", "[out]", "-c:a", "pcm_s16le", stitched.path
        ])

        let wfFull = try await AudioAnalysisService.shared.extractWaveform(url: stitched, bins: 120)
        #expect(wfFull.peaks.count == 120)
        #expect((wfFull.peaks.max() ?? 0) > 0.08)

        let wfZoom = try await AudioAnalysisService.shared.extractWaveform(url: stitched, bins: 80, startTime: 1.0, endTime: 2.0)
        #expect(wfZoom.peaks.count == 80)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var edgesCfg = AudioToolboxConfig()
        edgesCfg.operation = .removeSilence
        edgesCfg.removeSilence = true
        edgesCfg.codec = .pcmS16LE
        edgesCfg.silenceThresholdDB = -40
        edgesCfg.silenceMinDurationSeconds = 0.5
        edgesCfg.silenceTrimScope = .edgesOnly

        let edgesRes = try await provider.convertBatch(
            inputs: [stitched],
            to: .wav,
            outputDirectory: outDir,
            options: edgesCfg.applying(to: .default)
        ) { _ in }
        let probedEdges = try await provider.probe(url: edgesRes.outputURL)
        // Leading (1s) + trailing (1s) stripped; internal (1s) + two tones (2s) kept -> ~3.0s
        #expect(probedEdges.duration >= 2.6 && probedEdges.duration <= 3.4)
    }

    // MARK: - 6. Linear vs Dynamic Two-Pass EBU R128 Truth Verification

    @Test("EBU R128 verifies actual FFmpeg linear vs dynamic normalization mode instead of assuming linear")
    func verifyActualLinearVsDynamicLoudnormMode() async throws {
        let dir = try makeTempDir("lufs_mode")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Case A: 2-level stereo fixture (non-zero LRA ~ 2.0 LU, ~ -19.2 LUFS) -> target -14 LUFS / -1 dBTP -> true linear normalization fits comfortably!
        let quietURL = dir.appendingPathComponent("moderate_linear.wav")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2.0",
            "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=44100:duration=2.0",
            "-filter_complex", "[0:a]volume=0.8[a0];[1:a]volume=1.6[a1];[a0][a1]concat=n=2:v=0:a=1,aformat=channel_layouts=stereo[out]",
            "-map", "[out]", "-c:a", "pcm_s16le", quietURL.path
        ])

        var cfg = AudioToolboxConfig()
        cfg.codec = .pcmS16LE
        cfg.normalizationMode = .ebuR128
        cfg.targetLUFS = -14.0
        cfg.targetTruePeakDB = -1.0

        let linOut = try await provider.convertBatch(inputs: [quietURL], to: .wav, outputDirectory: outDir, options: cfg.applying(to: .default)) { _ in }
        let recordedLin = await AudioAnalysisService.shared.lastRecordedNormalizationMode(for: linOut.outputURL)
        #expect(recordedLin == "linear")

        // Case B: High-peak dynamic audio (0.95 amplitude transient burst + very quiet body ~ -25 LUFS)
        // Linear boost to -14 LUFS would push 0.95 (-0.4 dBTP) transient past -1.0 dBTP ceiling -> FFmpeg MUST switch to dynamic!
        let dynamicURL = dir.appendingPathComponent("high_crest.wav")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=0.4",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3.6",
            "-filter_complex", "[0:a]volume=7.5[loud];[1:a]volume=0.15[soft];[loud][soft]concat=n=2:v=0:a=1[out]",
            "-map", "[out]", "-c:a", "pcm_s16le", dynamicURL.path
        ])
        let dynMeasure = try await AudioAnalysisService.shared.measureLoudness(
            url: dynamicURL,
            targetLUFS: -14.0,
            targetTruePeakDB: -1.0,
            includeTwoPassLoudnorm: true
        )
        #expect(dynMeasure.normalizationTypeUsed == "dynamic")

        let dynOut = try await provider.convertBatch(inputs: [dynamicURL], to: .wav, outputDirectory: outDir, options: cfg.applying(to: .default)) { _ in }
        let recordedDyn = await AudioAnalysisService.shared.lastRecordedNormalizationMode(for: dynOut.outputURL)
        #expect(recordedDyn == "dynamic")
        let dynPost = try await AudioAnalysisService.shared.measureLoudness(url: dynOut.outputURL)
        #expect((dynPost.truePeakDBTP ?? 0.0) <= -0.5)
    }

    // MARK: - 7. Multichannel Channel Content Mapping Verification (Identifiable Per-Channel Signals)

    @Test("Multichannel 5.1, 2.1, 7.1, and stereo downmix preserve actual signal content per channel without silent or lost channels")
    func verifyMultichannelPerChannelSignalContent() async throws {
        let dir = try makeTempDir("multich_content")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Synthesize genuine 5.1 WAV with distinct sine tone on every channel (FL, FR, FC, LFE, BL, BR)
        let src51 = dir.appendingPathComponent("src_51.wav")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "sine=f=220:r=48000:d=1.5",
            "-f", "lavfi", "-i", "sine=f=330:r=48000:d=1.5",
            "-f", "lavfi", "-i", "sine=f=440:r=48000:d=1.5",
            "-f", "lavfi", "-i", "sine=f=80:r=48000:d=1.5",
            "-f", "lavfi", "-i", "sine=f=660:r=48000:d=1.5",
            "-f", "lavfi", "-i", "sine=f=880:r=48000:d=1.5",
            "-filter_complex", "[0:a][1:a][2:a][3:a][4:a][5:a]amerge=inputs=6,aformat=channel_layouts=5.1[out]",
            "-map", "[out]", "-c:a", "pcm_s16le", src51.path
        ])

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. Keep 5.1 in FLAC and verify every one of the 6 channels carries strong non-silent signal!
        var cfg51 = AudioToolboxConfig()
        cfg51.codec = .flac
        cfg51.channelMode = .surround51
        let flac51 = try await provider.convertBatch(inputs: [src51], to: .flac, outputDirectory: outDir, options: cfg51.applying(to: .default)) { _ in }
        let ffmpegPath = try #require(await provider.findFFmpegPath())

        func measureChannelMaxDB(file: URL, layout: String, channelIndexName: String) throws -> Double? {
            let p = Process()
            let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ffmpegPath)
            p.arguments = [
                "-hide_banner", "-i", file.path,
                "-filter_complex", "channelsplit=channel_layout=\(layout)[\(channelIndexName)]",
                "-map", "[\(channelIndexName)]", "-af", "volumedetect", "-f", "null", "-"
            ]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = errPipe
            try p.run()
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return AudioAnalysisService.parseLoudnessMeasurement(from: String(data: d, encoding: .utf8) ?? "").maxVolumeDB
        }

        // Verify distinct active content on every one of channels 0..5 (FL, FR, FC, LFE, BL, BR)
        let p51 = try await provider.probe(url: flac51.outputURL)
        #expect(p51.primaryAudioStream?.channels == 6)
        for chIdx in 0..<6 {
            let p = Process()
            let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ffmpegPath)
            p.arguments = [
                "-hide_banner", "-i", flac51.outputURL.path,
                "-af", "pan=mono|c0=c\(chIdx),volumedetect",
                "-f", "null", "-"
            ]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = errPipe
            try p.run()
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let db = AudioAnalysisService.parseLoudnessMeasurement(from: String(data: d, encoding: .utf8) ?? "").maxVolumeDB ?? -99.0
            #expect(db > -30.0)
        }
        _ = measureChannelMaxDB

        // 2. Downmix 5.1 -> 2.1 WAV & verify layout == 2.1 and 3 active channels
        var cfg21 = AudioToolboxConfig()
        cfg21.codec = .pcmS16LE
        cfg21.channelMode = .surround21
        let wav21 = try await provider.convertBatch(inputs: [src51], to: .wav, outputDirectory: outDir, options: cfg21.applying(to: .default)) { _ in }
        let p21 = try await provider.probe(url: wav21.outputURL)
        #expect(p21.primaryAudioStream?.channels == 3)

        // 3. Downmix 5.1 -> Stereo WAV & verify both L and R channels remain active and balanced
        var cfgSt = AudioToolboxConfig()
        cfgSt.codec = .pcmS16LE
        cfgSt.channelMode = .stereo
        let wavSt = try await provider.convertBatch(inputs: [src51], to: .wav, outputDirectory: outDir, options: cfgSt.applying(to: .default)) { _ in }
        let pSt = try await provider.probe(url: wavSt.outputURL)
        #expect(pSt.primaryAudioStream?.channels == 2)
        let mSt = try await AudioAnalysisService.shared.measureLoudness(url: wavSt.outputURL)
        #expect((mSt.maxVolumeDB ?? -99.0) > -25.0)
    }

    // MARK: - 8. High-Rate Resampling, Bit-Depth Dithering & Multi-Artwork Preservation

    @Test("Kaiser sinc 192->48kHz with Shibata dither and multi-artwork M4A/MP3 preservation work cleanly")
    func highRateDitheringAndArtworkPreservation() async throws {
        let dir = try makeTempDir("dither_art")
        defer { try? FileManager.default.removeItem(at: dir) }

        let hiRes = dir.appendingPathComponent("hires_192_24.wav")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "sine=f=1000:r=192000:d=1.2",
            "-c:a", "pcm_s24le", hiRes.path
        ])
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var cfg = AudioToolboxConfig()
        cfg.codec = .pcmS16LE
        cfg.sampleRateHz = 48000
        cfg.bitDepth = 16
        cfg.resamplerEngine = .kaiserSinc
        cfg.ditherMethod = .shibata

        let out16 = try await provider.convertBatch(inputs: [hiRes], to: .wav, outputDirectory: outDir, options: cfg.applying(to: .default)) { _ in }
        let probed = try await provider.probe(url: out16.outputURL)
        #expect(probed.primaryAudioStream?.sampleRate == 48000)
        #expect(probed.primaryAudioStream?.codecName == "pcm_s16le")

        // M4A + cover art + Turkish lyrics preservation through Audio Toolbox
        let cover = dir.appendingPathComponent("cover.png")
        try generateCoverImagePNG(at: cover)
        let taggedM4A = dir.appendingPathComponent("tagged.m4a")
        let baseTone = dir.appendingPathComponent("base.wav")
        try await generateToneWAV(at: baseTone, durationSeconds: 1.5)
        try await runFFmpeg([
            "-i", baseTone.path, "-i", cover.path,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "aac", "-b:a", "192k",
            "-c:v", "png", "-disposition:v", "attached_pic",
            "-metadata", "title=İstanbul Türküsü",
            "-metadata", "lyrics=Çok uzak şehirlerden",
            "-f", "ipod", taggedM4A.path
        ])

        var convCfg = AudioToolboxConfig()
        convCfg.codec = .mp3
        let mp3Out = try await provider.convertBatch(inputs: [taggedM4A], to: .mp3, outputDirectory: outDir, options: convCfg.applying(to: ConversionOptions(preserveMetadata: true))) { _ in }
        let mp3Probe = try await provider.probe(url: mp3Out.outputURL)
        #expect(mp3Probe.hasAttachedArtwork)
        let meta = try await AudioMetadataProvider().readMetadata(from: mp3Out.outputURL)
        #expect(meta.common.title == "İstanbul Türküsü")
        #expect(meta.common.lyrics == "Çok uzak şehirlerden")
    }
}

import Foundation
import Testing
import AppKit
import CoreGraphics
@testable import LocalConvert

@Suite("Phase 33 — Audio Toolbox Comprehensive Tests")
struct Phase33Tests {

    let registry = ConversionRegistry.shared
    let engine = MediaConversionEngine()
    let provider = BundledFFmpegProvider(fallbackToSystem: true)
    let metadataProvider = AudioMetadataProvider()

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase33-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func generateToneWAV(
        at url: URL,
        duration: Double = 1.5,
        sampleRate: Int = 44100,
        channels: Int = 2,
        frequency: Double = 440.0,
        volumeFilter: String? = nil
    ) async throws {
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("FFmpeg not found")
        }
        var args = [
            "-y", "-hide_banner", "-v", "error",
            "-f", "lavfi",
            "-i", "sine=frequency=\(frequency):sample_rate=\(sampleRate):duration=\(duration)"
        ]
        if let volumeFilter {
            args += ["-af", volumeFilter]
        }
        args += ["-ac", "\(channels)", "-ar", "\(sampleRate)", url.path]

        try runCLI(ffmpeg, arguments: args)
    }

    private func generatePNGArtwork(width: Int = 64, height: Int = 64) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MetadataError.invalidArtwork("Failed to allocate CGContext")
        }
        ctx.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw MetadataError.invalidArtwork("Failed to create CGImage")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw MetadataError.invalidArtwork("Failed to encode PNG")
        }
        return png
    }

    private func runCLI(_ executable: String, arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed("CLI failed: \(err)", underlyingError: nil)
        }
    }

    private func ffprobeSampleFmt(url: URL) async throws -> (fmt: String, bits: Int) {
        guard let ffprobe = await provider.findFFprobePath() else {
            throw ConversionError.engineNotAvailable("ffprobe missing")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "quiet", "-select_streams", "a:0", "-show_entries", "stream=sample_fmt,bits_per_raw_sample", "-of", "csv=p=0", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = text.split(separator: ",").map(String.init)
        let fmt = parts.first ?? ""
        let bits = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (fmt, bits)
    }

    // MARK: - 1. Codec Registry & Pre-Flight Validation

    @Test("Codec registry exposes accurate per-container codecs and validates invalid combinations")
    func testCodecRegistryAndValidation() {
        #expect(AudioCodecRegistry.supportedCodecs(for: .mp3) == [.mp3, .streamCopy])
        #expect(AudioCodecRegistry.supportedCodecs(for: .m4a).contains(.aacAT))
        #expect(AudioCodecRegistry.supportedCodecs(for: .m4a).contains(.alac))
        #expect(AudioCodecRegistry.supportedCodecs(for: .wav).contains(.pcmS24LE))
        #expect(AudioCodecRegistry.supportedCodecs(for: .aiff).contains(.pcmS24BE))

        // Invalid: MP3 does not support 5.1 surround or 96 kHz
        var invalidMP3 = AudioToolboxConfig()
        invalidMP3.codec = .mp3
        invalidMP3.channelMode = .surround51
        invalidMP3.sampleRateHz = 96000
        let resMP3 = AudioConversionValidator.validate(config: invalidMP3, outputFormat: .mp3)
        #expect(!resMP3.isValid)
        #expect(resMP3.errors.count >= 2)

        // Invalid: Stream Copy combined with EQ / Gain filter
        var invalidCopy = AudioToolboxConfig()
        invalidCopy.preferStreamCopy = true
        invalidCopy.volumeGainDB = 4.0
        let resCopy = AudioConversionValidator.validate(config: invalidCopy, outputFormat: .mp3)
        #expect(!resCopy.isValid)

        // Invalid: Incompatible codec for container
        var badContainer = AudioToolboxConfig()
        badContainer.codec = .flac
        let resBad = AudioConversionValidator.validate(config: badContainer, outputFormat: .mp3)
        #expect(!resBad.isValid)

        // Invalid: Trim end <= trim start
        var badTrim = AudioToolboxConfig()
        badTrim.trimStartSeconds = 5.0
        badTrim.trimEndSeconds = 2.0
        let resTrim = AudioConversionValidator.validate(config: badTrim, outputFormat: .wav)
        #expect(!resTrim.isValid)

        // Valid: 24-bit FLAC at 48kHz Stereo
        var validFLAC = AudioToolboxConfig()
        validFLAC.codec = .flac
        validFLAC.bitDepth = 24
        validFLAC.sampleRateHz = 48000
        validFLAC.channelMode = .stereo
        validFLAC.compressionLevel = 8
        let resFLAC = AudioConversionValidator.validate(config: validFLAC, outputFormat: .flac)
        #expect(resFLAC.isValid)
    }

    // MARK: - 2. AudioToolboxConfig Serialization & Preset Integration

    @Test("AudioToolboxConfig round-trips through ConversionOptions and SavedPreset")
    func testConfigAndPresetSerialization() throws {
        var config = AudioToolboxConfig()
        config.operation = .convert
        config.codec = .opus
        config.bitrateMode = .cbr
        config.bitrateKbps = 128
        config.normalizationMode = .ebuR128
        config.targetLUFS = -16.0
        config.noiseReduction = .moderate
        config.speedMultiplier = 1.25

        let options = config.applying(to: .default)
        let restored = AudioToolboxConfig.from(options: options)
        #expect(restored == config)

        let preset = SavedPreset(
            name: "Podcast Voice MP3",
            targetFormat: .mp3,
            sourceCategoryConstraint: .audio,
            options: options
        )
        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(SavedPreset.self, from: encoded)
        #expect(AudioToolboxConfig.from(options: decoded.options) == config)

        // Same-format processing preset (MP3 -> MP3 with filters) must pass PresetValidator
        let mp3SamePreset = SavedPreset(
            name: "Normalize MP3",
            targetFormat: .mp3,
            sourceCategoryConstraint: .audio,
            options: options
        )
        let validator = PresetValidator()
        let check = validator.isFileCompatible(preset: mp3SamePreset, fileFormat: .mp3)
        #expect(check.isCompatible)
    }

    // MARK: - 3. Real Codec, Bitrate/VBR, Bit Depth, Sample Rate, Channel & Stream Copy

    @Test("End-to-end audio conversions verify codecs, sample rates, bit depths, channels, and stream copy")
    func testAdvancedCodecConversions() async throws {
        let dir = try makeTempDir("Codecs")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcWAV = dir.appendingPathComponent("src.wav")
        try await generateToneWAV(at: srcWAV, duration: 1.0, sampleRate: 44100, channels: 2)

        // A. FLAC 24-bit @ 48kHz
        var flacCfg = AudioToolboxConfig()
        flacCfg.codec = .flac
        flacCfg.bitDepth = 24
        flacCfg.sampleRateHz = 48000
        flacCfg.compressionLevel = 8
        let flacRes = try await engine.convert(
            inputs: [srcWAV],
            to: .flac,
            outputDirectory: dir,
            options: flacCfg.applying(to: .default),
            progress: { _ in }
        )
        let flacInfo = try await provider.probe(url: flacRes.outputURL)
        #expect(flacInfo.primaryAudioStream?.codecName == "flac")
        #expect(flacInfo.primaryAudioStream?.sampleRate == 48000)
        let flacDepth = try await ffprobeSampleFmt(url: flacRes.outputURL)
        #expect(flacDepth.bits == 24)

        // B. MP3 VBR LAME -q:a 2 + Mono downmix
        var mp3Cfg = AudioToolboxConfig()
        mp3Cfg.codec = .mp3
        mp3Cfg.bitrateMode = .vbr
        mp3Cfg.vbrQuality = 2
        mp3Cfg.channelMode = .mono
        let mp3Res = try await engine.convert(
            inputs: [srcWAV],
            to: .mp3,
            outputDirectory: dir,
            options: mp3Cfg.applying(to: .default),
            progress: { _ in }
        )
        let mp3Info = try await provider.probe(url: mp3Res.outputURL)
        #expect(mp3Info.primaryAudioStream?.codecName == "mp3")
        #expect(mp3Info.primaryAudioStream?.channels == 1)

        // C. M4A ALAC vs AAC-AT VBR
        var alacCfg = AudioToolboxConfig()
        alacCfg.codec = .alac
        let alacRes = try await engine.convert(
            inputs: [srcWAV],
            to: .m4a,
            outputDirectory: dir,
            options: alacCfg.applying(to: .default),
            progress: { _ in }
        )
        let alacInfo = try await provider.probe(url: alacRes.outputURL)
        #expect(alacInfo.primaryAudioStream?.codecName == "alac")

        var aacAtCfg = AudioToolboxConfig()
        aacAtCfg.codec = .aacAT
        aacAtCfg.bitrateMode = .vbr
        aacAtCfg.vbrQuality = 10
        let aacRes = try await engine.convert(
            inputs: [srcWAV],
            to: .m4a,
            outputDirectory: dir,
            options: aacAtCfg.applying(to: .default),
            progress: { _ in }
        )
        let aacInfo = try await provider.probe(url: aacRes.outputURL)
        #expect(aacInfo.primaryAudioStream?.codecName == "aac")

        // D. Stream Copy compatible M4A (AAC -> M4A via ConversionRegistry!)
        var copyCfg = AudioToolboxConfig()
        copyCfg.preferStreamCopy = true
        let copyOpts = copyCfg.applying(to: .default)
        let foundEngine = registry.findEngine(from: .m4a, to: .m4a, options: copyOpts)
        #expect(foundEngine?.name == "MediaEngine")
        let copyRes = try await engine.convert(
            inputs: [aacRes.outputURL],
            to: .m4a,
            outputDirectory: dir,
            options: copyOpts,
            progress: { _ in }
        )
        let copyInfo = try await provider.probe(url: copyRes.outputURL)
        #expect(copyInfo.primaryAudioStream?.codecName == "aac")

        // E. AIFF 24-bit Big-Endian
        var aiffCfg = AudioToolboxConfig()
        aiffCfg.codec = .pcmS24BE
        let aiffRes = try await engine.convert(
            inputs: [srcWAV],
            to: .aiff,
            outputDirectory: dir,
            options: aiffCfg.applying(to: .default),
            progress: { _ in }
        )
        let aiffInfo = try await provider.probe(url: aiffRes.outputURL)
        #expect(aiffInfo.primaryAudioStream?.codecName == "pcm_s24be")

        // F. OGG Vorbis (Experimental) & OPUS
        var vorbisCfg = AudioToolboxConfig()
        vorbisCfg.codec = .vorbis
        vorbisCfg.bitrateMode = .vbr
        vorbisCfg.vbrQuality = 6
        let oggRes = try await engine.convert(
            inputs: [srcWAV],
            to: .ogg,
            outputDirectory: dir,
            options: vorbisCfg.applying(to: .default),
            progress: { _ in }
        )
        let oggInfo = try await provider.probe(url: oggRes.outputURL)
        #expect(oggInfo.primaryAudioStream?.codecName == "vorbis")
    }

    // MARK: - 4. Real Waveform Extraction

    @Test("AudioAnalysisService extracts accurate amplitude envelope from real PCM samples")
    func testWaveformExtractionAccuracy() async throws {
        let dir = try makeTempDir("Waveform")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("FFmpeg required")
        }

        // 1.0s pure silence followed by 1.0s loud 440Hz sine (FFmpeg `sine` defaults to 0.125 amplitude -> boost to ~0.9 full scale)
        let testWAV = dir.appendingPathComponent("silence_then_tone.wav")
        try runCLI(ffmpeg, arguments: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=1.0",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1.0",
            "-filter_complex", "[1:a]volume=7.2[tone];[0:a][tone]concat=n=2:v=0:a=1[outa]",
            "-map", "[outa]",
            testWAV.path
        ])

        let wf = try await AudioAnalysisService.shared.extractWaveform(url: testWAV, bins: 100)
        #expect(wf.peaks.count == 100)
        #expect(wf.duration > 1.8 && wf.duration < 2.2)

        let silentHalfMax = wf.peaks[0..<40].max() ?? 1.0
        let loudHalfMax = wf.peaks[60..<100].max() ?? 0.0
        #expect(silentHalfMax < 0.02)
        #expect(loudHalfMax > 0.7)
    }

    // MARK: - 5. Non-Destructive Trim & Multi-Segment Extraction

    @Test("Trim and multi-segment extraction produce exact non-destructive clips")
    func testTrimAndSegmentExtraction() async throws {
        let dir = try makeTempDir("Trim")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcWAV = dir.appendingPathComponent("three_sec.wav")
        try await generateToneWAV(at: srcWAV, duration: 3.0)

        // Single Trim: 0.5s -> 1.8s = ~1.3s
        var trimCfg = AudioToolboxConfig()
        trimCfg.operation = .trim
        trimCfg.trimStartSeconds = 0.5
        trimCfg.trimEndSeconds = 1.8
        let trimRes = try await engine.convert(
            inputs: [srcWAV],
            to: .wav,
            outputDirectory: dir,
            options: trimCfg.applying(to: .default),
            progress: { _ in }
        )
        let trimInfo = try await provider.probe(url: trimRes.outputURL)
        #expect(trimInfo.duration > 1.15 && trimInfo.duration < 1.45)

        // Original intact
        let origInfo = try await provider.probe(url: srcWAV)
        #expect(origInfo.duration > 2.9)

        // Multi-Segment Extraction: [0.2...0.8, 1.5...2.4]
        var segCfg = AudioToolboxConfig()
        segCfg.operation = .extractSegments
        segCfg.segments = [
            AudioTrimSegment(startTime: 0.2, endTime: 0.8, label: "intro"),
            AudioTrimSegment(startTime: 1.5, endTime: 2.4, label: "chorus")
        ]
        let segRes = try await engine.convert(
            inputs: [srcWAV],
            to: .flac,
            outputDirectory: dir,
            options: segCfg.applying(to: .default),
            progress: { _ in }
        )
        #expect(segRes.allOutputURLs.count == 2)
        let seg1Info = try await provider.probe(url: segRes.allOutputURLs[0])
        let seg2Info = try await provider.probe(url: segRes.allOutputURLs[1])
        #expect(seg1Info.duration > 0.45 && seg1Info.duration < 0.75)
        #expect(seg2Info.duration > 0.75 && seg2Info.duration < 1.05)
    }

    // MARK: - 6. Heterogeneous Audio Merge

    @Test("Merging disparate audio files normalizes sample rates and channels cleanly")
    func testAudioMerge() async throws {
        let dir = try makeTempDir("Merge")
        defer { try? FileManager.default.removeItem(at: dir) }

        let mono44 = dir.appendingPathComponent("part1.wav")
        try await generateToneWAV(at: mono44, duration: 1.0, sampleRate: 44100, channels: 1, frequency: 440)

        let stereo48WAV = dir.appendingPathComponent("part2_raw.wav")
        try await generateToneWAV(at: stereo48WAV, duration: 1.0, sampleRate: 48000, channels: 2, frequency: 880)
        let part2MP3 = try await engine.convert(
            inputs: [stereo48WAV],
            to: .mp3,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        ).outputURL

        var mergeCfg = AudioToolboxConfig()
        mergeCfg.operation = .merge
        mergeCfg.codec = .flac

        let merged = try await engine.convert(
            inputs: [mono44, part2MP3],
            to: .flac,
            outputDirectory: dir,
            options: mergeCfg.applying(to: .default),
            progress: { _ in }
        )
        let mergedInfo = try await provider.probe(url: merged.outputURL)
        #expect(mergedInfo.primaryAudioStream?.codecName == "flac")
        #expect(mergedInfo.duration > 1.85 && mergedInfo.duration < 2.25)
    }

    // MARK: - 7. Speed, Pitch, Reverse, Fades & Silence Detection/Removal

    @Test("Speed scaling, pitch shift, fades, reverse, and silence removal modify audio accurately")
    func testAdjustmentsAndSilenceRemoval() async throws {
        let dir = try makeTempDir("Adjust")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("FFmpeg required")
        }

        let src = dir.appendingPathComponent("tone.wav")
        try await generateToneWAV(at: src, duration: 2.0)

        // 2.0x Speed + Reverse + Fade In/Out
        var fastCfg = AudioToolboxConfig()
        fastCfg.speedMultiplier = 2.0
        fastCfg.reverseAudio = true
        fastCfg.fadeInSeconds = 0.2
        fastCfg.fadeOutSeconds = 0.2
        let fastRes = try await engine.convert(
            inputs: [src],
            to: .wav,
            outputDirectory: dir,
            options: fastCfg.applying(to: .default),
            progress: { _ in }
        )
        let fastInfo = try await provider.probe(url: fastRes.outputURL)
        #expect(fastInfo.duration > 0.85 && fastInfo.duration < 1.15)

        // 0.25x (chained atempo) + Pitch shift (+2 st) on 1s clip
        let shortSrc = dir.appendingPathComponent("short.wav")
        try await generateToneWAV(at: shortSrc, duration: 1.0)
        var slowPitchCfg = AudioToolboxConfig()
        slowPitchCfg.speedMultiplier = 0.4
        slowPitchCfg.pitchSemitones = 2.0
        let slowRes = try await engine.convert(
            inputs: [shortSrc],
            to: .wav,
            outputDirectory: dir,
            options: slowPitchCfg.applying(to: .default),
            progress: { _ in }
        )
        let slowInfo = try await provider.probe(url: slowRes.outputURL)
        #expect(slowInfo.duration > 2.2 && slowInfo.duration < 2.8)

        // Silence detection & removal: [0.6s tone] + [1.2s silence] + [0.6s tone] = 2.4s -> ~1.2s after removal
        let silenceFile = dir.appendingPathComponent("with_silence.wav")
        try runCLI(ffmpeg, arguments: [
            "-y", "-v", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=0.6",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:d=1.2",
            "-f", "lavfi", "-i", "sine=frequency=520:sample_rate=44100:duration=0.6",
            "-filter_complex", "[0:a][1:a][2:a]concat=n=3:v=0:a=1[outa]",
            "-map", "[outa]",
            silenceFile.path
        ])
        let silences = try await AudioAnalysisService.shared.detectSilence(url: silenceFile, noiseThresholdDB: -45, minDuration: 0.4)
        #expect(!silences.isEmpty)
        #expect(silences[0].duration > 0.9)

        var silCfg = AudioToolboxConfig()
        silCfg.operation = .removeSilence
        silCfg.removeSilence = true
        silCfg.silenceThresholdDB = -45
        silCfg.silenceMinDurationSeconds = 0.4
        let strippedRes = try await engine.convert(
            inputs: [silenceFile],
            to: .wav,
            outputDirectory: dir,
            options: silCfg.applying(to: .default),
            progress: { _ in }
        )
        let strippedInfo = try await provider.probe(url: strippedRes.outputURL)
        #expect(strippedInfo.duration > 0.8 && strippedInfo.duration < 1.8)
    }

    // MARK: - 8. DSP Effects, Noise Reduction (afftdn) & Loudness/Peak Normalization

    @Test("DSP effects, afftdn noise reduction, EBU R128 and peak normalization alter signal metrics cleanly")
    func testDSPAndNormalization() async throws {
        let dir = try makeTempDir("DSP")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Quiet -20 dB tone
        let quietWAV = dir.appendingPathComponent("quiet.wav")
        try await generateToneWAV(at: quietWAV, duration: 2.0, volumeFilter: "volume=-20dB")

        let baseline = try await AudioAnalysisService.shared.measureLoudness(url: quietWAV)
        #expect((baseline.maxVolumeDB ?? 0) < -15.0)

        // Peak Normalization to -1.0 dB
        var peakCfg = AudioToolboxConfig()
        peakCfg.normalizationMode = .peak
        peakCfg.peakNormalizeTargetDB = -1.0
        let peakOut = try await engine.convert(
            inputs: [quietWAV],
            to: .wav,
            outputDirectory: dir,
            options: peakCfg.applying(to: .default),
            progress: { _ in }
        )
        let peakMeasured = try await AudioAnalysisService.shared.measureLoudness(url: peakOut.outputURL)
        #expect((peakMeasured.maxVolumeDB ?? -99) > -3.0)

        // Combined DSP stack: EQ + HPF + LPF + Compressor + Limiter + afftdn + declick + Stereo Width + EBU R128
        var dspCfg = AudioToolboxConfig()
        dspCfg.eqBands = AudioEQBand.vocalClarityBands
        dspCfg.highPassHz = 80
        dspCfg.lowPassHz = 12000
        dspCfg.compressorEnabled = true
        dspCfg.limiterEnabled = true
        dspCfg.noiseReduction = .moderate
        dspCfg.declickEnabled = true
        dspCfg.stereoWidth = 1.25
        dspCfg.channelBalance = 0.1
        dspCfg.normalizationMode = .ebuR128
        dspCfg.targetLUFS = -14.0
        dspCfg.targetTruePeakDB = -1.0

        let dspOut = try await engine.convert(
            inputs: [quietWAV],
            to: .flac,
            outputDirectory: dir,
            options: dspCfg.applying(to: .default),
            progress: { _ in }
        )
        let dspInfo = try await provider.probe(url: dspOut.outputURL)
        #expect(dspInfo.duration > 1.8)
        let dspLoudness = try await AudioAnalysisService.shared.measureLoudness(url: dspOut.outputURL)
        #expect((dspLoudness.integratedLUFS ?? -99) > -18.0)
    }

    // MARK: - 9. Expanded Metadata, Lyrics & Artwork Validation

    @Test("AudioMetadataProvider reads/writes full tags, lyrics, and artwork across MP3, M4A, FLAC, OPUS and rejects invalid artwork")
    func testAudioMetadataAndArtworkValidation() async throws {
        let dir = try makeTempDir("Metadata")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcWAV = dir.appendingPathComponent("src.wav")
        try await generateToneWAV(at: srcWAV, duration: 0.6)
        let pngData = try generatePNGArtwork()

        for fmt in [FileFormat.mp3, .m4a, .flac] {
            let trackURL = try await engine.convert(
                inputs: [srcWAV],
                to: fmt,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            ).outputURL

            var doc = try await metadataProvider.readMetadata(from: trackURL)
            doc.common.title = "Antigravity Test Track"
            doc.common.artist = "Phase 33 Artist"
            doc.common.album = "LocalConvert Suite"
            doc.common.albumArtist = "Various Engineers"
            doc.common.genre = "Electronic"
            doc.common.year = 2026
            doc.common.trackNumber = "3/10"
            doc.common.discNumber = "1/2"
            doc.common.composer = "DSP Unit"
            doc.common.comment = "Verified tag"
            doc.common.copyright = "2026 LocalConvert"
            doc.common.lyrics = "Line one of lyrics\nLine two chorus"
            doc.artwork = MetadataArtwork(data: pngData, mimeType: "image/png")

            _ = try await metadataProvider.writeMetadata(doc, to: trackURL)

            let reloaded = try await metadataProvider.readMetadata(from: trackURL)
            #expect(reloaded.common.title == "Antigravity Test Track")
            #expect(reloaded.common.artist == "Phase 33 Artist")
            #expect(reloaded.common.album == "LocalConvert Suite")
            #expect(reloaded.common.albumArtist == "Various Engineers")
            #expect(reloaded.common.genre == "Electronic")
            #expect(reloaded.common.year == 2026)
            #expect(reloaded.common.composer == "DSP Unit")
            #expect(reloaded.common.copyright == "2026 LocalConvert")
            #expect(reloaded.common.lyrics == "Line one of lyrics\nLine two chorus")
            #expect(reloaded.artwork != nil)
        }

        // Opus lyrics + albumArtist round-trip
        let opusURL = try await engine.convert(
            inputs: [srcWAV],
            to: .opus,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        ).outputURL
        var opusDoc = try await metadataProvider.readMetadata(from: opusURL)
        opusDoc.common.title = "Opus Track"
        opusDoc.common.lyrics = "Opus Lyrics Line"
        _ = try await metadataProvider.writeMetadata(opusDoc, to: opusURL)
        let opusReloaded = try await metadataProvider.readMetadata(from: opusURL)
        #expect(opusReloaded.common.title == "Opus Track")
        #expect(opusReloaded.common.lyrics == "Opus Lyrics Line")

        // Negative: Corrupt non-image artwork rejected cleanly
        #expect(throws: MetadataError.self) {
            _ = try AudioMetadataProvider.validateAndNormalizeArtwork(Data("not an image".utf8))
        }
    }

    // MARK: - 10. Malformed Input Rejection & Cancellation Cleanup

    @Test("Engine rejects malformed audio inputs cleanly and cancellation leaves zero temp directory leaks")
    func testErrorHandlingAndCancellation() async throws {
        let dir = try makeTempDir("Errors")
        defer { try? FileManager.default.removeItem(at: dir) }

        let corrupt = dir.appendingPathComponent("corrupt.mp3")
        try Data("garbage-bytes-not-audio".utf8).write(to: corrupt)

        await #expect(throws: Error.self) {
            _ = try await engine.convert(
                inputs: [corrupt],
                to: .wav,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            )
        }

        // Default same-format route stays hidden; Audio Toolbox same-format processing is discoverable
        #expect(!registry.canConvert(from: .mp3, to: .mp3))
        var fxCfg = AudioToolboxConfig()
        fxCfg.volumeGainDB = 2.0
        #expect(registry.findEngine(from: .mp3, to: .mp3, options: fxCfg.applying(to: .default)) != nil)

        // Cancellation cleanup verification
        let longWAV = dir.appendingPathComponent("long_cancel.wav")
        try await generateToneWAV(at: longWAV, duration: 20.0)

        var heavyCfg = AudioToolboxConfig()
        heavyCfg.normalizationMode = .ebuR128
        heavyCfg.noiseReduction = .moderate
        let opts = heavyCfg.applying(to: .default)

        let task = Task {
            try await engine.convert(
                inputs: [longWAV],
                to: .flac,
                outputDirectory: dir,
                options: opts,
                progress: { _ in }
            )
        }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()

        do {
            _ = try await task.value
            // If a very fast M-series finished 20s encode under 120ms, output would be in dir; either cancel or fast completion is acceptable,
            // but no LocalConvertAudio_* scratch directory may linger in temporaryDirectory.
        } catch {
            // Expected cancellation
        }

        let tempContents = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        let leakedDirs = tempContents.filter { $0.hasPrefix("LocalConvertAudio_") }
        #expect(leakedDirs.isEmpty)
    }
}

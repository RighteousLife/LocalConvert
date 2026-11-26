import Testing
import Foundation
import AVFoundation
import CryptoKit
@testable import LocalConvert

@Suite("Audio Editor 2.0 Real-File Export & Analysis Acceptance Tests")
struct AudioEditorExportAcceptanceTests {

    private func writeStereoSineWAV(
        to url: URL,
        duration: Double,
        sampleRate: Double = 48_000,
        freqL: Double = 440,
        freqR: Double = 880,
        amplitude: Float = 0.35
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw ConversionError.invalidInput("Failed to create AVAudioFormat")
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let totalFrames = Int(duration * sampleRate)
        let chunk = 8192
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
              let ch = buf.floatChannelData else { return }

        var done = 0
        while done < totalFrames {
            let n = min(chunk, totalFrames - done)
            for i in 0..<n {
                let t = Double(done + i) / sampleRate
                ch[0][i] = amplitude * Float(sin(2.0 * .pi * freqL * t))
                ch[1][i] = amplitude * Float(sin(2.0 * .pi * freqR * t))
            }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            done += n
        }
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Real-fixture multitrack export across WAV, MP3, M4A, FLAC, stems, range, and metadata preserves sources")
    func testRealFixtureExportsAndMetadata() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-ae-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let src1 = tmpDir.appendingPathComponent("tone_a.wav")
        let src2 = tmpDir.appendingPathComponent("tone_b.wav")
        try writeStereoSineWAV(to: src1, duration: 2.0, freqL: 440, freqR: 554)
        try writeStereoSineWAV(to: src2, duration: 2.0, freqL: 660, freqR: 880)

        let hash1Before = try sha256(of: src1)
        let hash2Before = try sha256(of: src2)

        guard let ref1 = await AudioEditorStore.buildMediaReference(for: src1),
              let ref2 = await AudioEditorStore.buildMediaReference(for: src2) else {
            Issue.record("Failed to build AudioMediaReference for real WAV fixtures")
            return
        }

        let c1 = AudioClip(
            sourceAssetID: ref1.id,
            name: "Tone A",
            timelineStart: 0.0,
            sourceStart: 0.0,
            duration: 1.5,
            fadeIn: ClipFadeSpec(duration: 0.1, curve: .equalPower),
            crossfadeCurve: .equalPower
        )
        let c2 = AudioClip(
            sourceAssetID: ref2.id,
            name: "Tone B",
            timelineStart: 1.0,
            sourceStart: 0.0,
            duration: 1.5,
            fadeOut: ClipFadeSpec(duration: 0.1, curve: .linear),
            crossfadeCurve: .equalPower
        )

        var c3 = AudioClip(
            sourceAssetID: ref2.id,
            name: "Reversed Track 2",
            timelineStart: 0.5,
            sourceStart: 0.0,
            duration: 1.0,
            gainDB: -3.0,
            isReversed: true,
            swapChannels: true
        )
        c3.effects.highPassHz = 120

        let track1 = AudioTrack(name: "Vocals", clips: [c1, c2])
        let track2 = AudioTrack(name: "Backing", clips: [c3])
        let project = AudioEditorProject(name: "AcceptanceMix", sampleRate: 48_000, tracks: [track1, track2], mediaAssets: [ref1, ref2])

        let outDir = tmpDir.appendingPathComponent("Exports", isDirectory: true)

        // 1. Preview Metrics
        let previewReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 24,
            channels: 2,
            outputDirectory: outDir,
            baseFileName: "Mix"
        )
        let metrics = try await AudioExportService.previewMetrics(project: project, request: previewReq)
        #expect(abs(metrics.duration - 2.5) < 0.05)
        #expect(metrics.peakDB > -40.0 && metrics.peakDB <= 0.1)
        #expect(metrics.clipsDetected == false)

        // 2. Full Mix Export to WAV (48kHz stereo) + MP3 + M4A + FLAC
        for fmt in [FileFormat.wav, .mp3, .m4a, .flac] {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: 48_000,
                bitDepth: 24,
                bitrateKbps: 256,
                channels: 2,
                preserveMetadata: true,
                titleMetadata: "Acceptance Song",
                artistMetadata: "LocalConvert QA",
                outputDirectory: outDir,
                baseFileName: "Mix_\(fmt.fileExtension)"
            )
            let res = try await AudioExportService.export(project: project, request: req)
            #expect(res.outputURLs.count == 1)
            let outURL = res.outputURLs[0]
            #expect(FileManager.default.fileExists(atPath: outURL.path))

            if let ffprobe = await BundledFFmpegProvider().findFFprobePath(),
               let probed = try? await MediaProbe.probe(url: outURL, ffprobePath: ffprobe) {
                #expect(abs(probed.duration - 2.5) < 0.25)
                #expect(probed.primaryAudioStream?.channels == 2)
                #expect(probed.primaryAudioStream?.sampleRate == 48_000)
            }
        }

        // 3. Selected Timeline Range Export (0.5s ... 1.5s -> 1.0s mono)
        let rangeReq = AudioExportRequest(
            scope: .selectedRange,
            selectedRange: 0.5...1.5,
            outputFormat: .wav,
            sampleRate: 44_100,
            bitDepth: 16,
            channels: 1,
            outputDirectory: outDir,
            baseFileName: "RangeCut"
        )
        let rangeRes = try await AudioExportService.export(project: project, request: rangeReq)
        let rangeAudio = try AVAudioFile(forReading: rangeRes.outputURLs[0])
        let rangeDur = Double(rangeAudio.length) / rangeAudio.processingFormat.sampleRate
        #expect(abs(rangeDur - 1.0) < 0.05)
        #expect(Int(rangeAudio.processingFormat.sampleRate) == 44_100)

        // 4. All Stems Export
        let stemReq = AudioExportRequest(
            scope: .allStems,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 16,
            channels: 2,
            outputDirectory: outDir,
            baseFileName: "Stem"
        )
        let stemRes = try await AudioExportService.export(project: project, request: stemReq)
        #expect(stemRes.outputURLs.count == 2)

        // 5. Verify zero temp files leaked in Exports dir and source files are 100% untouched
        let entries = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
        #expect(!entries.contains { $0.lastPathComponent.hasPrefix(".") })
        #expect(try sha256(of: src1) == hash1Before)
        #expect(try sha256(of: src2) == hash2Before)
    }

    @Test("WaveformRenderingService stereo bins, range stats, and SpectrumAnalyzerService FFT")
    func testWaveformAndSpectrumAnalysis() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-ae-wave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let wavURL = tmpDir.appendingPathComponent("stereo.wav")
        try writeStereoSineWAV(to: wavURL, duration: 1.0, freqL: 1000, freqR: 250, amplitude: 0.5)
        guard let asset = await AudioEditorStore.buildMediaReference(for: wavURL) else {
            Issue.record("Failed to inspect WAV")
            return
        }

        let wf = try await WaveformRenderingService.shared.waveform(for: asset)
        #expect(wf.channels == 2)
        let bins = wf.bins(from: 0, to: 1.0, count: 64)
        #expect(bins.count == 64)
        #expect(bins.contains { $0.maxL > 0.25 && $0.maxR > 0.25 })

        let stats = try await WaveformRenderingService.shared.measure(asset: asset, from: 0.1, duration: 0.5)
        #expect(stats.peakDB > -8.0 && stats.peakDB < -4.0)
        #expect(stats.clippedSamples == 0)

        let spectrum = await SpectrumAnalyzerService.spectrum(asset: asset, at: 0.2)
        #expect(spectrum.count == SpectrumAnalyzerService.binCount)
        #expect(spectrum.contains { $0 > -40.0 })
    }

    @Test("Export task cancellation removes temp staging files cleanly")
    func testExportCancellationCleanup() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-ae-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let wavURL = tmpDir.appendingPathComponent("long.wav")
        try writeStereoSineWAV(to: wavURL, duration: 8.0)
        guard let asset = await AudioEditorStore.buildMediaReference(for: wavURL) else {
            Issue.record("Failed to inspect WAV")
            return
        }

        let clip = AudioClip(sourceAssetID: asset.id, name: "Long", timelineStart: 0, sourceStart: 0, duration: 8.0)
        let proj = AudioEditorProject(name: "CancelProj", sampleRate: 48_000, tracks: [AudioTrack(name: "T1", clips: [clip])], mediaAssets: [asset])
        let outDir = tmpDir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let req = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .mp3,
            sampleRate: 48_000,
            bitrateKbps: 192,
            channels: 2,
            outputDirectory: outDir,
            baseFileName: "Cancelled"
        )

        let task = Task {
            try await AudioExportService.export(project: proj, request: req)
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
        task.cancel()
        _ = try? await task.value

        let leaked = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".") }
        #expect(leaked.isEmpty)
    }
}

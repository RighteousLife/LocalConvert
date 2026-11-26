import Testing
import Foundation
import AVFoundation
import CryptoKit
@testable import LocalConvert

@Suite("Phase 45.4 Audio Export Pro Validation Tests")
struct AudioExportProTests {

    private func writeStereoSineWAV(
        to url: URL,
        duration: Double,
        sampleRate: Double = 48_000,
        freqL: Double = 440,
        freqR: Double = 660,
        amplitude: Float = 0.20
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
                AVLinearPCMBitDepthKey: 24,
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

    private func makeProject(srcURL: URL, duration: Double = 3.0) async -> AudioEditorProject? {
        guard let ref = await AudioEditorStore.buildMediaReference(for: srcURL) else {
            return nil
        }
        let clip = AudioClip(
            sourceAssetID: ref.id,
            name: "Program Tone",
            timelineStart: 0.0,
            sourceStart: 0.0,
            duration: duration
        )
        let track = AudioTrack(name: "Main", clips: [clip])
        return AudioEditorProject(name: "Pro Export Test", sampleRate: 48_000, tracks: [track], mediaAssets: [ref])
    }

    @Test("Two-pass EBU R128 loudness normalization hits target LUFS and true-peak ceiling")
    func twoPassLoudnessNormalizationAccuracy() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-ae-loudnorm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let src = tmpDir.appendingPathComponent("quiet_source.wav")
        try writeStereoSineWAV(to: src, duration: 3.5, amplitude: 0.08)

        guard let project = await makeProject(srcURL: src, duration: 3.5) else {
            Issue.record("Failed to create test project")
            return
        }

        let request = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 24,
            channels: 2,
            preserveMetadata: false,
            loudnessNormalizeEnabled: true,
            targetLUFS: -16.0,
            truePeakCeilingDBTP: -1.0,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: tmpDir,
            baseFileName: "master_norm"
        )

        let result = try await AudioExportService.export(project: project, request: request)
        #expect(result.outputURLs.count == 1)
        #expect(result.reports.count == 1)
        let report = try #require(result.reports.first)
        #expect(report.loudnessNormalizationApplied)
        #expect(report.verifiedSampleRate == 48_000)
        #expect(report.verifiedChannels == 2)
        let lufs = try #require(report.measuredIntegratedLUFS)
        let tp = try #require(report.measuredTruePeakDBTP)
        #expect(abs(lufs - (-16.0)) <= 1.5)
        #expect(tp <= -0.8)
    }

    @Test("Codec, sample-rate, channel, and 16-bit dither verification across WAV, AIFF, FLAC, MP3, M4A")
    func multiFormatExportAndErrorHandling() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-ae-formats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let src = tmpDir.appendingPathComponent("src.wav")
        try writeStereoSineWAV(to: src, duration: 2.0, amplitude: 0.35)

        guard let project = await makeProject(srcURL: src, duration: 2.0) else {
            Issue.record("Failed to create test project")
            return
        }

        let specs: [(FileFormat, Int, Int?, Int, Bool, String)] = [
            (.wav, 44_100, 16, 2, true, "pcm_s16le"),
            (.wav, 48_000, 24, 1, false, "pcm_s24le"),
            (.aiff, 48_000, 16, 2, true, "pcm_s16be"),
            (.flac, 48_000, 24, 2, false, "flac"),
            (.mp3, 44_100, nil, 2, false, "mp3"),
            (.m4a, 48_000, nil, 2, false, "aac")
        ]

        for (idx, (fmt, sr, depth, ch, dither, expectedCodec)) in specs.enumerated() {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: sr,
                bitDepth: depth,
                bitrateKbps: 192,
                channels: ch,
                preserveMetadata: true,
                titleMetadata: "Format Check \(idx)",
                loudnessNormalizeEnabled: false,
                applyDitheringOn16Bit: dither,
                validateOutput: true,
                outputDirectory: tmpDir,
                baseFileName: "fmt_\(idx)_\(fmt.fileExtension)"
            )
            let res = try await AudioExportService.export(project: project, request: req)
            let report = try #require(res.reports.first)
            #expect(report.verifiedCodecName == expectedCodec)
            #expect(report.verifiedSampleRate == sr)
            #expect(report.verifiedChannels == ch)
            #expect(report.verifiedDuration >= 1.7)
            #expect(report.ditheringApplied == dither)
        }

        // Empty project export must fail explicitly
        let emptyProject = AudioEditorProject(name: "Empty", sampleRate: 48_000, tracks: [], mediaAssets: [])
        let emptyReq = AudioExportRequest(outputDirectory: tmpDir, baseFileName: "should_fail")
        var emptyFailed = false
        do {
            _ = try await AudioExportService.export(project: emptyProject, request: emptyReq)
        } catch {
            emptyFailed = true
        }
        #expect(emptyFailed)
    }

    @Test("Batch export generates collision-safe files and cancellation leaves no corrupt final outputs")
    func batchExportCollisionSafetyAndCancellation() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-ae-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let src = tmpDir.appendingPathComponent("batch_src.wav")
        try writeStereoSineWAV(to: src, duration: 1.5, amplitude: 0.25)

        guard let project = await makeProject(srcURL: src, duration: 1.5) else {
            Issue.record("Failed to create test project")
            return
        }

        let item1 = AudioExportBatchItem(
            project: project,
            request: AudioExportRequest(
                outputFormat: .wav,
                sampleRate: 48_000,
                bitDepth: 16,
                channels: 2,
                applyDitheringOn16Bit: true,
                validateOutput: true,
                outputDirectory: tmpDir,
                baseFileName: "shared_name"
            )
        )
        let item2 = AudioExportBatchItem(
            project: project,
            request: AudioExportRequest(
                outputFormat: .wav,
                sampleRate: 48_000,
                bitDepth: 24,
                channels: 2,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: tmpDir,
                baseFileName: "shared_name"
            )
        )

        let outcomes = try await AudioExportService.exportBatch(items: [item1, item2])
        #expect(outcomes.count == 2)
        let urls = outcomes.compactMap { $0.result?.outputURLs.first }
        #expect(urls.count == 2)
        #expect(Set(urls).count == 2)
        for url in urls {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        // Pre-cancelled task must not leave output files behind
        let cancelDir = tmpDir.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelDir, withIntermediateDirectories: true)
        let cancelTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000)
            try Task.checkCancellation()
            return try await AudioExportService.export(
                project: project,
                request: AudioExportRequest(outputDirectory: cancelDir, baseFileName: "aborted")
            )
        }
        cancelTask.cancel()
        var wasCancelled = false
        do {
            _ = try await cancelTask.value
        } catch {
            wasCancelled = true
        }
        #expect(wasCancelled)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: cancelDir.path)
        #expect(remaining.isEmpty)
    }
}

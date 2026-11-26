import XCTest
import AVFoundation
import CryptoKit
import os
@testable import LocalConvert

final class Phase68LosslessExportTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase68StageB-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        StructuredDiagnostics.clearRecentEvents()
    }

    override func tearDownWithError() throws {
        AppStoragePaths.clearTestOverrides()
        StructuredDiagnostics.clearRecentEvents()
        if let sandbox {
            if case .failure(let err) = sandbox.cleanup() {
                XCTFail("Sandbox cleanup failed: \(err.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Helpers

    private func writePCMFile(
        to url: URL,
        formatID: AudioFormatID = kAudioFormatLinearPCM,
        bitDepth: Int = 24,
        isFloat: Bool = false,
        isBigEndian: Bool = false,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        duration: Double = 1.5,
        generator: (Int, Int) -> Float
    ) throws {
        let processingFmt: AVAudioFormat
        if channels <= 2 {
            processingFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            )!
        } else {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            processingFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        }
        var settings: [String: Any] = processingFmt.settings
        settings[AVFormatIDKey] = formatID
        settings[AVSampleRateKey] = sampleRate
        settings[AVNumberOfChannelsKey] = channels
        settings[AVLinearPCMBitDepthKey] = bitDepth
        settings[AVLinearPCMIsFloatKey] = isFloat
        settings[AVLinearPCMIsBigEndianKey] = isBigEndian

        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let totalFrames = Int((duration * sampleRate).rounded())
        let chunk = 8192
        let buf = AVAudioPCMBuffer(pcmFormat: processingFmt, frameCapacity: AVAudioFrameCount(chunk))!
        let chData = buf.floatChannelData!

        var written = 0
        while written < totalFrames {
            let n = min(chunk, totalFrames - written)
            for ch in 0..<channels {
                for i in 0..<n {
                    chData[ch][i] = generator(ch, written + i)
                }
            }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            written += n
        }
    }

    private func readFloatSamples(from url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, Int(file.length))))!
        try file.read(into: buf)
        let chCount = Int(fmt.channelCount)
        let len = Int(buf.frameLength)
        return (0..<chCount).map { ch in
            Array(UnsafeBufferPointer(start: buf.floatChannelData![ch], count: len))
        }
    }

    private func fileSHA256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func ffprobeStream(_ url: URL) async throws -> (codec: String, sampleRate: Int, channels: Int, sampleFmt: String?, bitsPerRaw: Int?, duration: Double) {
        let ffprobePath = await BundledFFmpegProvider().findFFprobePath()
        let ffprobe = try XCTUnwrap(ffprobePath)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "format=duration:stream=codec_name,sample_rate,channels,sample_fmt,bits_per_raw_sample,bits_per_sample",
            "-of", "json",
            url.path
        ]
        let out = try await AsyncProcessRunner.run(proc, stdin: .nullDevice)
        XCTAssertEqual(out.terminationStatus, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: out.stdout) as? [String: Any])
        let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
        let s = try XCTUnwrap(streams.first)
        let fmt = json["format"] as? [String: Any]
        let codec = (s["codec_name"] as? String) ?? ""
        let sr = (s["sample_rate"] as? String).flatMap { Int($0) } ?? (s["sample_rate"] as? Int) ?? 0
        let ch = (s["channels"] as? Int) ?? 0
        let sFmt = s["sample_fmt"] as? String
        let bits = (s["bits_per_raw_sample"] as? String).flatMap { Int($0) }
            ?? (s["bits_per_raw_sample"] as? Int)
            ?? (s["bits_per_sample"] as? Int)
        let dur = (fmt?["duration"] as? String).flatMap { Double($0) } ?? (fmt?["duration"] as? Double) ?? 0
        return (codec, sr, ch, sFmt, (bits ?? 0) > 0 ? bits : nil, dur)
    }

    private func makeProject(from srcURL: URL, rate: SampleRate = .rate48k, channels: Int = 2, duration: Double = 1.5) async throws -> AudioEditorProject {
        let builtAsset = await AudioEditorStore.buildMediaReference(for: srcURL)
        let asset = try XCTUnwrap(builtAsset)
        let frames = Int64((duration * Double(rate.hz)).rounded())
        let clip = AudioClip(
            sourceAssetID: asset.id,
            name: srcURL.lastPathComponent,
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: frames,
            projectRate: rate,
            sourceRate: rate
        )
        let track = AudioTrack(name: "Main", clips: [clip])
        var proj = AudioEditorProject(name: "Phase68Export", sampleRate: Double(rate.hz), tracks: [track], mediaAssets: [asset])
        proj.sampleRate = Double(rate.hz)
        _ = channels
        return proj
    }

    // MARK: - 1. Complete Lossless & Lossy Export Format Matrix (Including Ogg Vorbis & ALAC .m4a & CAF)

    func testExportFormatMatrixWithFFprobeVerification() async throws {
        let srcDir = sandbox.temporaryURL.appendingPathComponent("MatrixSrc", isDirectory: true)
        let outDir = sandbox.temporaryURL.appendingPathComponent("MatrixOut", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let srcURL = srcDir.appendingPathComponent("src48_24.wav")
        try writePCMFile(to: srcURL, bitDepth: 24, sampleRate: 48_000, channels: 2, duration: 1.5) { ch, i in
            Float(0.25 * sin(2.0 * .pi * (ch == 0 ? 440.0 : 660.0) * Double(i) / 48_000.0))
        }
        let project = try await makeProject(from: srcURL, rate: .rate48k, duration: 1.5)

        struct CaseSpec {
            let format: FileFormat
            let rate: Int
            let bitDepth: Int?
            let dither: Bool
            let mode: AudioExportMode
            let expectedExt: String
            let expectedCodec: String
            let expectedBits: Int?
        }

        let cases: [CaseSpec] = [
            .init(format: .wav, rate: 48_000, bitDepth: 16, dither: true, mode: .losslessFormatReRender, expectedExt: "wav", expectedCodec: "pcm_s16le", expectedBits: 16),
            .init(format: .wav, rate: 48_000, bitDepth: 24, dither: false, mode: .losslessFormatReRender, expectedExt: "wav", expectedCodec: "pcm_s24le", expectedBits: 24),
            .init(format: .wav, rate: 48_000, bitDepth: 32, dither: false, mode: .losslessFormatReRender, expectedExt: "wav", expectedCodec: "pcm_f32le", expectedBits: 32),
            .init(format: .aiff, rate: 48_000, bitDepth: 16, dither: true, mode: .losslessFormatReRender, expectedExt: "aiff", expectedCodec: "pcm_s16be", expectedBits: 16),
            .init(format: .aiff, rate: 48_000, bitDepth: 24, dither: false, mode: .losslessFormatReRender, expectedExt: "aiff", expectedCodec: "pcm_s24be", expectedBits: 24),
            .init(format: .alac, rate: 48_000, bitDepth: 16, dither: true, mode: .losslessFormatReRender, expectedExt: "m4a", expectedCodec: "alac", expectedBits: 16),
            .init(format: .alac, rate: 48_000, bitDepth: 24, dither: false, mode: .losslessFormatReRender, expectedExt: "m4a", expectedCodec: "alac", expectedBits: 24),
            .init(format: .flac, rate: 44_100, bitDepth: 16, dither: true, mode: .losslessFormatReRender, expectedExt: "flac", expectedCodec: "flac", expectedBits: 16),
            .init(format: .flac, rate: 48_000, bitDepth: 24, dither: false, mode: .losslessFormatReRender, expectedExt: "flac", expectedCodec: "flac", expectedBits: 24),
            .init(format: .caf, rate: 48_000, bitDepth: 24, dither: false, mode: .losslessFormatReRender, expectedExt: "caf", expectedCodec: "pcm_s24le", expectedBits: 24),
            .init(format: .caf, rate: 48_000, bitDepth: 32, dither: false, mode: .losslessFormatReRender, expectedExt: "caf", expectedCodec: "pcm_f32le", expectedBits: 32),
            .init(format: .mp3, rate: 44_100, bitDepth: nil, dither: false, mode: .lossyFormatReRender, expectedExt: "mp3", expectedCodec: "mp3", expectedBits: nil),
            .init(format: .m4a, rate: 48_000, bitDepth: nil, dither: false, mode: .lossyFormatReRender, expectedExt: "m4a", expectedCodec: "aac", expectedBits: nil),
            .init(format: .opus, rate: 48_000, bitDepth: nil, dither: false, mode: .lossyFormatReRender, expectedExt: "opus", expectedCodec: "opus", expectedBits: nil),
            .init(format: .ogg, rate: 48_000, bitDepth: nil, dither: false, mode: .lossyFormatReRender, expectedExt: "ogg", expectedCodec: "vorbis", expectedBits: nil)
        ]

        for (idx, c) in cases.enumerated() {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: c.format,
                sampleRate: c.rate,
                bitDepth: c.bitDepth,
                bitrateKbps: 192,
                channels: 2,
                preserveMetadata: true,
                titleMetadata: "Matrix \(idx)",
                loudnessNormalizeEnabled: false,
                applyDitheringOn16Bit: c.dither,
                validateOutput: true,
                outputDirectory: outDir,
                baseFileName: "matrix_\(idx)_\(c.format.rawValue)",
                exportMode: c.mode
            )

            let res = try await AudioExportService.export(project: project, request: req)
            let outURL = try XCTUnwrap(res.outputURLs.first)
            let report = try XCTUnwrap(res.reports.first)

            XCTAssertEqual(outURL.pathExtension.lowercased(), c.expectedExt)
            XCTAssertEqual(report.exportModeUsed, c.mode)
            XCTAssertEqual(report.verifiedCodecName, c.expectedCodec)
            XCTAssertEqual(report.verifiedSampleRate, c.rate)
            XCTAssertEqual(report.verifiedChannels, 2)
            XCTAssertEqual(report.ditheringApplied, c.dither)
            XCTAssertGreaterThan(report.verifiedDuration, 1.3)

            let probed = try await ffprobeStream(outURL)
            XCTAssertEqual(probed.codec, c.expectedCodec)
            XCTAssertEqual(probed.sampleRate, c.rate)
            XCTAssertEqual(probed.channels, 2)
            if let expBits = c.expectedBits {
                XCTAssertEqual(probed.bitsPerRaw, expBits, "Bit depth mismatch for \(c.format.rawValue) \(expBits)-bit")
                XCTAssertEqual(report.verifiedBitsPerSample, expBits)
            }
        }
    }

    // MARK: - 2. BitExactPassThrough Payload SHA-256 Identity & Rejection Matrix

    func testBitExactPassThroughPayloadSHA256AndEligibilityRejections() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("PassThrough", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // WAV 24-bit pass-through
        let wavSrc = dir.appendingPathComponent("clean_24.wav")
        try writePCMFile(to: wavSrc, bitDepth: 24, sampleRate: 48_000, channels: 2, duration: 1.5) { _, i in
            Float(0.4 * sin(2.0 * .pi * 523.25 * Double(i) / 48_000.0))
        }
        let wavFileSHA = try fileSHA256(wavSrc)
        let wavProj = try await makeProject(from: wavSrc, rate: .rate48k, duration: 1.5)

        let wavPassReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 24,
            channels: 2,
            preserveMetadata: true,
            titleMetadata: "PassThrough Tag",
            loudnessNormalizeEnabled: false,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: outDir,
            baseFileName: "pt_wav",
            exportMode: .bitExactPassThrough
        )
        XCTAssertTrue(AudioExportService.evaluatePassThroughEligibility(project: wavProj, request: wavPassReq).isEligible)
        let wavRes = try await AudioExportService.export(project: wavProj, request: wavPassReq)
        let wavReport = try XCTUnwrap(wavRes.reports.first)
        XCTAssertEqual(wavReport.exportModeUsed, .bitExactPassThrough)
        XCTAssertFalse(wavReport.ditheringApplied)
        XCTAssertNotNil(wavReport.sourceAudioPayloadSHA256)
        XCTAssertEqual(wavReport.sourceAudioPayloadSHA256, wavReport.outputAudioPayloadSHA256)
        XCTAssertEqual(try fileSHA256(wavSrc), wavFileSHA, "Source file must never be mutated")

        // AIFF 16-bit pass-through
        let aiffSrc = dir.appendingPathComponent("clean_16.aiff")
        try writePCMFile(to: aiffSrc, bitDepth: 16, isBigEndian: true, sampleRate: 48_000, channels: 2, duration: 1.5) { _, i in
            Float(0.35 * sin(2.0 * .pi * 330.0 * Double(i) / 48_000.0))
        }
        let aiffProj = try await makeProject(from: aiffSrc, rate: .rate48k, duration: 1.5)
        let aiffPassReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .aiff,
            sampleRate: 48_000,
            bitDepth: 16,
            channels: 2,
            preserveMetadata: false,
            loudnessNormalizeEnabled: false,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: outDir,
            baseFileName: "pt_aiff",
            exportMode: .bitExactPassThrough
        )
        let aiffRes = try await AudioExportService.export(project: aiffProj, request: aiffPassReq)
        let aiffReport = try XCTUnwrap(aiffRes.reports.first)
        XCTAssertEqual(aiffReport.exportModeUsed, .bitExactPassThrough)
        XCTAssertEqual(aiffReport.sourceAudioPayloadSHA256, aiffReport.outputAudioPayloadSHA256)

        // Eligibility rejection cases
        var gainProj = wavProj
        gainProj.tracks[0].clips[0].gainDB = -2.0
        XCTAssertFalse(AudioExportService.evaluatePassThroughEligibility(project: gainProj, request: wavPassReq).isEligible)

        var fadeProj = wavProj
        fadeProj.tracks[0].clips[0].fadeInFrames = ClipFadeSpecFrames(durationFrames: 480, curve: .linear)
        XCTAssertFalse(AudioExportService.evaluatePassThroughEligibility(project: fadeProj, request: wavPassReq).isEligible)

        var fxProj = wavProj
        fxProj.tracks[0].clips[0].effectSlots = [AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams())]
        XCTAssertFalse(AudioExportService.evaluatePassThroughEligibility(project: fxProj, request: wavPassReq).isEligible)

        var normReq = wavPassReq
        normReq.loudnessNormalizeEnabled = true
        XCTAssertFalse(AudioExportService.evaluatePassThroughEligibility(project: wavProj, request: normReq).isEligible)

        var srReq = wavPassReq
        srReq.sampleRate = 44_100
        XCTAssertFalse(AudioExportService.evaluatePassThroughEligibility(project: wavProj, request: srReq).isEligible)

        var dither16Req = aiffPassReq
        dither16Req.applyDitheringOn16Bit = true
        XCTAssertFalse(AudioExportService.evaluatePassThroughEligibility(project: aiffProj, request: dither16Req).isEligible)

        do {
            _ = try await AudioExportService.export(project: gainProj, request: wavPassReq)
            XCTFail("Ineligible pass-through must throw explicitly")
        } catch {}
    }

    // MARK: - 3. Strict TPDF Dithering Rules

    func testTPDFDitheringRulesAcross16BitAndHighPrecisionFormats() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("Dither", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Quiet high-precision 32-bit float sine where 16-bit TPDF dither leaves quantifiable low-level LSB difference
        let srcURL = dir.appendingPathComponent("quiet_32f.wav")
        try writePCMFile(to: srcURL, bitDepth: 32, isFloat: true, sampleRate: 48_000, channels: 2, duration: 1.5) { _, i in
            Float(0.0005 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
        }
        let project = try await makeProject(from: srcURL, rate: .rate48k, duration: 1.5)

        // Enabled on 16-bit WAV, AIFF, FLAC, ALAC
        for fmt in [FileFormat.wav, .aiff, .flac, .alac] {
            let ditherReq = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: 48_000,
                bitDepth: 16,
                channels: 2,
                applyDitheringOn16Bit: true,
                validateOutput: true,
                outputDirectory: outDir,
                baseFileName: "dither_on_\(fmt.rawValue)",
                exportMode: .losslessFormatReRender
            )
            let ditherRes = try await AudioExportService.export(project: project, request: ditherReq)
            let rOn = try XCTUnwrap(ditherRes.reports.first)
            XCTAssertTrue(rOn.ditheringApplied, "16-bit \(fmt.rawValue) with dithering enabled must apply TPDF dither")

            var noDitherReq = ditherReq
            noDitherReq.applyDitheringOn16Bit = false
            noDitherReq.baseFileName = "dither_off_\(fmt.rawValue)"
            let noDitherRes = try await AudioExportService.export(project: project, request: noDitherReq)
            let rOff = try XCTUnwrap(noDitherRes.reports.first)
            XCTAssertFalse(rOff.ditheringApplied)

            if fmt == .wav {
                let sOn = try readFloatSamples(from: ditherRes.outputURLs[0])[0]
                let sOff = try readFloatSamples(from: noDitherRes.outputURLs[0])[0]
                XCTAssertNotEqual(sOn, sOff, "TPDF dither must measurably affect 16-bit LSBs vs truncated export")
            }
        }

        // Strictly forbidden on 32f, 24-bit lossless, and lossy formats even if flag is true
        for (fmt, depth, mode): (FileFormat, Int?, AudioExportMode) in [
            (.wav, 32, .losslessFormatReRender),
            (.wav, 24, .losslessFormatReRender),
            (.flac, 24, .losslessFormatReRender),
            (.alac, 24, .losslessFormatReRender),
            (.mp3, nil, .lossyFormatReRender),
            (.ogg, nil, .lossyFormatReRender)
        ] {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: 48_000,
                bitDepth: depth,
                bitrateKbps: 192,
                channels: 2,
                applyDitheringOn16Bit: true,
                validateOutput: true,
                outputDirectory: outDir,
                baseFileName: "nodither_\(fmt.rawValue)_\(depth ?? 0)",
                exportMode: mode
            )
            let res = try await AudioExportService.export(project: project, request: req)
            let report = try XCTUnwrap(res.reports.first)
            XCTAssertFalse(report.ditheringApplied, "Dithering must NEVER apply to \(fmt.rawValue) bitDepth=\(depth ?? -1)")
        }
    }

    // MARK: - 4. True-Peak Ceiling Protection (-1.0 dBTP on Inter-Sample Peaks)

    private func measureFileTruePeak4x(url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let chCount = Int(fmt.channelCount)
        let cap = 8192
        let overlapRadius = 12
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cap))!
        var maxDBTP = -120.0
        var previousTail = [Float](repeating: 0, count: chCount * overlapRadius)
        var previousTailCount = 0
        var seamScratch = [Float](repeating: 0, count: chCount * overlapRadius * 2)

        while file.framePosition < file.length {
            buf.frameLength = 0
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            if let chData = buf.floatChannelData {
                let tp = AudioNormalizer.measureTruePeakDBTP(channels: chData, channelCount: chCount, frameCount: n)
                maxDBTP = max(maxDBTP, tp)

                if previousTailCount > 0 {
                    let headCount = min(overlapRadius, n)
                    let seamCount = previousTailCount + headCount
                    seamScratch.withUnsafeMutableBufferPointer { seamBuf in
                        guard let base = seamBuf.baseAddress else { return }
                        let ptrArray = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: chCount)
                        defer { ptrArray.deallocate() }
                        for ch in 0..<chCount {
                            let chBase = base.advanced(by: ch * seamCount)
                            previousTail.withUnsafeBufferPointer { tailBuf in
                                if let tailSrc = tailBuf.baseAddress {
                                    chBase.update(from: tailSrc.advanced(by: ch * overlapRadius), count: previousTailCount)
                                }
                            }
                            chBase.advanced(by: previousTailCount).update(from: chData[ch], count: headCount)
                            ptrArray[ch] = chBase
                        }
                        let seamTP = AudioNormalizer.measureTruePeakDBTP(
                            channels: UnsafePointer(ptrArray),
                            channelCount: chCount,
                            frameCount: seamCount
                        )
                        maxDBTP = max(maxDBTP, seamTP)
                    }
                }

                let newTailCount = min(overlapRadius, n)
                let tailStart = max(0, n - newTailCount)
                previousTail.withUnsafeMutableBufferPointer { tailBuf in
                    guard let base = tailBuf.baseAddress else { return }
                    for ch in 0..<chCount {
                        base.advanced(by: ch * overlapRadius).update(
                            from: chData[ch].advanced(by: tailStart),
                            count: newTailCount
                        )
                    }
                }
                previousTailCount = newTailCount
            }
        }
        return maxDBTP
    }

    func testTruePeakCeilingProtectionOnInterSamplePeaks() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("TruePeak", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1) High-crest ISP signal + loudness normalization (-14 LUFS, -1.0 dBTP ceiling):
        // Integrated loudness ~ -19 LUFS with +0.26 dBTP sparse 12 kHz bursts forces +5 dB gain
        // into the -1.0 dBTP true-peak ceiling limiter (previously never engaged by Stage B test).
        let hcURL = dir.appendingPathComponent("high_crest_isp.wav")
        try writePCMFile(to: hcURL, bitDepth: 32, isFloat: true, sampleRate: 48_000, channels: 2, duration: 4.0) { _, i in
            let sr = 48_000.0
            let bed = 0.08 * sin(2.0 * .pi * 1000.0 * Double(i) / sr)
            let tMod = Double(i % 48_000) / sr
            let burst = (tMod >= 0.200 && tMod < 0.203)
                ? 0.95 * sin(2.0 * .pi * 12_000.0 * Double(i) / sr + .pi / 4.0)
                : 0.0
            return Float(max(-1.0, min(1.0, bed + burst)))
        }
        let hcInputMetrics = try await AudioAnalysisService.shared.measureLoudness(url: hcURL)
        let hcInLUFS = try XCTUnwrap(hcInputMetrics.integratedLUFS)
        let hcInTP = try XCTUnwrap(hcInputMetrics.truePeakDBTP)
        let hcProject = try await makeProject(from: hcURL, rate: .rate48k, duration: 4.0)
        let hcReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 24,
            channels: 2,
            loudnessNormalizeEnabled: true,
            targetLUFS: -14.0,
            truePeakCeilingDBTP: -1.0,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: outDir,
            baseFileName: "hc_loudnorm_tp_protected",
            exportMode: .losslessFormatReRender
        )
        let hcRes = try await AudioExportService.export(project: hcProject, request: hcReq)
        let hcReport = try XCTUnwrap(hcRes.reports.first)
        let hcOutTP = try XCTUnwrap(hcReport.measuredTruePeakDBTP)
        let hcOutLUFS = try XCTUnwrap(hcReport.measuredIntegratedLUFS)
        print(String(format: "[TPReport] Case1_Loudnorm_HighCrest inLUFS=%.2f inTP=%.2f -> outLUFS=%.2f outTP=%.2f",
                     hcInLUFS, hcInTP, hcOutLUFS, hcOutTP))
        XCTAssertGreaterThan(hcOutLUFS, hcInLUFS + 2.0, "Normalization must raise integrated loudness toward -14 LUFS")
        XCTAssertLessThanOrEqual(hcOutTP, -0.95, "True-peak limiter must hold <= -1.0 dBTP ceiling")
        XCTAssertGreaterThanOrEqual(hcOutTP, -2.5, "True-peak ceiling must actively engage near -1.0 dBTP rather than over-attenuating")

        // 2) Un-normalized signal with discrete sample peak BELOW -1.0 dBFS (-1.43 dBFS)
        // whose 4x oversampled inter-sample true peak EXCEEDS -1.0 dBTP (+1.58 dBTP).
        for (srHz, rateEnum, label) in [
            (44_100, SampleRate.rate44_1k, "44k"),
            (48_000, SampleRate.rate48k, "48k"),
            (96_000, SampleRate.rate96k, "96k")
        ] {
            let ispURL = dir.appendingPathComponent("sub1dbfs_isp_\(label).wav")
            let srDouble = Double(srHz)
            let quarterFreq = srDouble / 4.0
            try writePCMFile(to: ispURL, bitDepth: 32, isFloat: true, sampleRate: srDouble, channels: 2, duration: 1.5) { _, i in
                // Sample peak = 1.20 * sin(pi/4) = 0.8485 (-1.43 dBFS < -1.0 dBFS); true peak = 1.20 (+1.58 dBTP > -1.0 dBTP)
                Float(1.20 * sin(2.0 * .pi * quarterFreq * Double(i) / srDouble + .pi / 4.0))
            }
            let inTP4x = try measureFileTruePeak4x(url: ispURL)
            XCTAssertGreaterThan(inTP4x, 0.5, "Input ISP must genuinely exceed +0.5 dBTP at \(label)")

            let ispProject = try await makeProject(from: ispURL, rate: rateEnum, duration: 1.5)
            let ispReq = AudioExportRequest(
                scope: .entireProject,
                outputFormat: .wav,
                sampleRate: srHz,
                bitDepth: 32,
                channels: 2,
                loudnessNormalizeEnabled: false,
                targetLUFS: -14.0,
                truePeakCeilingDBTP: -1.0,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: outDir,
                baseFileName: "unnorm_isp_\(label)",
                exportMode: .losslessFormatReRender
            )
            let ispRes = try await AudioExportService.export(project: ispProject, request: ispReq)
            let ispReport = try XCTUnwrap(ispRes.reports.first)
            let ispOutEbuTP = try XCTUnwrap(ispReport.measuredTruePeakDBTP)
            let ispOut4xTP = try measureFileTruePeak4x(url: ispRes.outputURLs[0])
            print(String(format: "[TPReport] Case2_Unnorm_%@ inTP4x=%.2f -> outEbuTP=%.2f out4xTP=%.2f",
                         label, inTP4x, ispOutEbuTP, ispOut4xTP))
            XCTAssertLessThanOrEqual(ispOutEbuTP, -0.95, "EBU R128 true peak must stay <= -1.0 dBTP at \(label)")
            XCTAssertLessThanOrEqual(ispOut4xTP, -0.90, "4x oversampled true peak must stay <= -0.9 dBTP at \(label)")
            XCTAssertGreaterThanOrEqual(ispOut4xTP, -3.5, "4x oversampled limiter must trim excess ISP without crushing signal")
        }

        // 3) Un-normalized signal ALREADY below -1.0 dBTP (-6.0 dBFS sine): must remain untouched
        let quietURL = dir.appendingPathComponent("below_ceiling.wav")
        try writePCMFile(to: quietURL, bitDepth: 32, isFloat: true, sampleRate: 48_000, channels: 2, duration: 1.0) { _, i in
            Float(0.5 * sin(2.0 * .pi * 1000.0 * Double(i) / 48_000.0)) // -6.02 dBFS / -6.02 dBTP
        }
        let quietIn4xTP = try measureFileTruePeak4x(url: quietURL)
        let quietProj = try await makeProject(from: quietURL, rate: .rate48k, duration: 1.0)
        let quietReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 32,
            channels: 2,
            loudnessNormalizeEnabled: false,
            targetLUFS: -14.0,
            truePeakCeilingDBTP: -1.0,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: outDir,
            baseFileName: "below_ceiling_untouched",
            exportMode: .losslessFormatReRender
        )
        let quietRes = try await AudioExportService.export(project: quietProj, request: quietReq)
        let quietReport = try XCTUnwrap(quietRes.reports.first)
        let quietOutTP = try XCTUnwrap(quietReport.measuredTruePeakDBTP)
        let quietOut4xTP = try measureFileTruePeak4x(url: quietRes.outputURLs[0])
        let quietInPlanes = try readFloatSamples(from: quietURL)
        let quietOutPlanes = try readFloatSamples(from: quietRes.outputURLs[0])
        var maxSampleDelta: Float = 0
        for (a, b) in zip(quietInPlanes[0], quietOutPlanes[0]) {
            maxSampleDelta = max(maxSampleDelta, abs(a - b))
        }
        print(String(format: "[TPReport] Case3_BelowCeiling in4xTP=%.2f outEbuTP=%.2f out4xTP=%.2f maxDelta=%.6f",
                     quietIn4xTP, quietOutTP, quietOut4xTP, maxSampleDelta))
        XCTAssertEqual(quietOutTP, -6.0, accuracy: 0.25, "Signal already below -1.0 dBTP must not be attenuated")
        XCTAssertEqual(quietOut4xTP, quietIn4xTP, accuracy: 0.05)
        XCTAssertLessThan(maxSampleDelta, 1e-5, "Below-ceiling export without normalization must pass through unattenuated")

        // 4) 6-channel multichannel (5.1) un-normalized ISP protection
        let multiURL = dir.appendingPathComponent("multi_6ch_isp.wav")
        try writePCMFile(to: multiURL, bitDepth: 32, isFloat: true, sampleRate: 48_000, channels: 6, duration: 1.5) { ch, i in
            let amp = (ch == 0 || ch == 3) ? 1.20 : 0.40
            return Float(amp * sin(2.0 * .pi * 12_000.0 * Double(i) / 48_000.0 + .pi / 4.0))
        }
        let multiProj = try await makeProject(from: multiURL, rate: .rate48k, channels: 6, duration: 1.5)
        let multiReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 24,
            channels: 6,
            loudnessNormalizeEnabled: false,
            targetLUFS: -14.0,
            truePeakCeilingDBTP: -1.0,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: outDir,
            baseFileName: "multi_6ch_tp_protected",
            exportMode: .losslessFormatReRender
        )
        let multiRes = try await AudioExportService.export(project: multiProj, request: multiReq)
        let multiReport = try XCTUnwrap(multiRes.reports.first)
        let multiOutTP = try XCTUnwrap(multiReport.measuredTruePeakDBTP)
        let multiOut4xTP = try measureFileTruePeak4x(url: multiRes.outputURLs[0])
        print(String(format: "[TPReport] Case4_Multi6ch outCh=%d outEbuTP=%.2f out4xTP=%.2f",
                     multiReport.verifiedChannels, multiOutTP, multiOut4xTP))
        XCTAssertEqual(multiReport.verifiedChannels, 6)
        XCTAssertLessThanOrEqual(multiOutTP, -0.95)
        XCTAssertLessThanOrEqual(multiOut4xTP, -0.90)

        // 5) BitExactPassThrough mode must remain completely untouched (bit-exact audio SHA-256)
        let passURL = dir.appendingPathComponent("hot_passthrough.wav")
        try writePCMFile(to: passURL, bitDepth: 24, isFloat: false, sampleRate: 48_000, channels: 2, duration: 1.0) { _, i in
            Float(0.96 * sin(2.0 * .pi * 12_000.0 * Double(i) / 48_000.0)) // -0.35 dBFS (> -1.0 dBTP)
        }
        let passProj = try await makeProject(from: passURL, rate: .rate48k, channels: 2, duration: 1.0)
        let passReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 24,
            channels: 2,
            loudnessNormalizeEnabled: false,
            targetLUFS: -14.0,
            truePeakCeilingDBTP: -1.0,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: outDir,
            baseFileName: "passthrough_untouched",
            exportMode: .bitExactPassThrough
        )
        let passRes = try await AudioExportService.export(project: passProj, request: passReq)
        let passReport = try XCTUnwrap(passRes.reports.first)
        print("[TPReport] Case5_PassThrough mode=\(passReport.exportModeUsed.rawValue) tp=\(passReport.measuredTruePeakDBTP ?? 0) shaMatch=\(passReport.sourceAudioPayloadSHA256 == passReport.outputAudioPayloadSHA256)")
        XCTAssertEqual(passReport.exportModeUsed, .bitExactPassThrough)
        XCTAssertNotNil(passReport.sourceAudioPayloadSHA256)
        XCTAssertEqual(passReport.sourceAudioPayloadSHA256, passReport.outputAudioPayloadSHA256)
        XCTAssertGreaterThan(passReport.measuredTruePeakDBTP ?? -99, -0.6)
    }

    // MARK: - 5. Pre-flight .ape Rejection

    func testAPEExportRejectedPreFlightBeforeCreatingFiles() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("APEReject", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let srcURL = dir.appendingPathComponent("src.wav")
        try writePCMFile(to: srcURL, bitDepth: 24, sampleRate: 48_000, channels: 2, duration: 1.0) { _, i in
            Float(0.2 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
        }
        let project = try await makeProject(from: srcURL, rate: .rate48k, duration: 1.0)

        let req = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .ape,
            sampleRate: 48_000,
            bitDepth: 24,
            channels: 2,
            outputDirectory: outDir,
            baseFileName: "should_not_exist"
        )
        do {
            _ = try await AudioExportService.export(project: project, request: req)
            XCTFail("APE export must throw ConversionError.unsupportedConversion")
        } catch let err as ConversionError {
            XCTAssertEqual(err, .unsupportedConversion(from: .wav, to: .ape))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - 6. Multichannel Export (1 / 2 / 6 Channels) & Unsupported Channel Rejection

    func testMultichannelExportAndUnsupportedChannelRejection() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("Multichannel", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let src6URL = dir.appendingPathComponent("src_51.wav")
        try writePCMFile(to: src6URL, bitDepth: 24, sampleRate: 48_000, channels: 6, duration: 1.0) { ch, i in
            let freq = 220.0 * Double(ch + 1)
            return Float(0.18 * sin(2.0 * .pi * freq * Double(i) / 48_000.0))
        }
        let project = try await makeProject(from: src6URL, rate: .rate48k, channels: 6, duration: 1.0)

        for (fmt, chCount): (FileFormat, Int) in [
            (.wav, 1),
            (.wav, 2),
            (.wav, 6),
            (.flac, 6)
        ] {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: 48_000,
                bitDepth: 24,
                channels: chCount,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: outDir,
                baseFileName: "mc_\(fmt.rawValue)_\(chCount)ch",
                exportMode: .losslessFormatReRender
            )
            let res = try await AudioExportService.export(project: project, request: req)
            let report = try XCTUnwrap(res.reports.first)
            XCTAssertEqual(report.verifiedChannels, chCount)
            let probed = try await ffprobeStream(res.outputURLs[0])
            XCTAssertEqual(probed.channels, chCount)
        }

        // Unsupported channel mappings for MP3 (>2 ch) and Ogg Vorbis (non-stereo) must throw clearly
        for (fmt, chCount): (FileFormat, Int) in [(.mp3, 6), (.ogg, 6), (.ogg, 1)] {
            let badReq = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: 48_000,
                bitDepth: nil,
                channels: chCount,
                outputDirectory: outDir,
                baseFileName: "bad_\(fmt.rawValue)_\(chCount)ch",
                exportMode: .lossyFormatReRender
            )
            do {
                _ = try await AudioExportService.export(project: project, request: badReq)
                XCTFail("Expected rejection for \(fmt.rawValue) with \(chCount) channels")
            } catch ConversionError.invalidInput {
                // Expected clear rejection
            }
        }
    }

    // MARK: - 7. Staging Directory Isolation & Mid-Export Cancellation Cleanup

    func testStagingIsolationAndMidExportCancellationCleanup() async throws {
        // Verify export staging directory points inside sandboxed Application Support, never /tmp
        let stagingDir = AppStoragePaths.audioExportStagingDirectory
        XCTAssertTrue(stagingDir.path.contains(sandbox.rootURL.path))
        XCTAssertFalse(stagingDir.path.hasPrefix("/tmp"))

        let dir = sandbox.temporaryURL.appendingPathComponent("CancelExport", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let srcURL = dir.appendingPathComponent("long_src.wav")
        try writePCMFile(to: srcURL, bitDepth: 24, sampleRate: 48_000, channels: 2, duration: 5.0) { _, i in
            Float(0.25 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
        }
        let project = try await makeProject(from: srcURL, rate: .rate48k, duration: 5.0)

        let task = Task {
            try await AudioExportService.export(
                project: project,
                request: AudioExportRequest(
                    scope: .entireProject,
                    outputFormat: .flac,
                    sampleRate: 48_000,
                    bitDepth: 24,
                    channels: 2,
                    loudnessNormalizeEnabled: true,
                    validateOutput: true,
                    outputDirectory: outDir,
                    baseFileName: "cancelled_master",
                    exportMode: .losslessFormatReRender
                )
            )
        }
        try await Task.sleep(for: .milliseconds(35))
        task.cancel()

        do {
            _ = try await task.value
            // If fast machine completed before cancel, that's only possible if extremely quick; verify cleanup either way
        } catch {
            // Cancelled cleanly
        }

        // Brief yield for defer cleanup on cancelled child task
        try? await Task.sleep(for: .milliseconds(50))

        if FileManager.default.fileExists(atPath: stagingDir.path) {
            let leftoverStaging = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
            XCTAssertTrue(leftoverStaging.isEmpty, "Staging directory must have zero leftover files after cancel/finish: \(leftoverStaging)")
        }
    }

    // MARK: - 8. Stage B.2: Lossy Post-Codec True-Peak Protection & Compatible Measurement

    func testStageB2LossyPostCodecTruePeakComplianceAndCompatibleMeasurement() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("LossyTruePeak", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Inter-sample-peak rich stereo mix whose continuous EBU R128 true peak exceeds +1.0 dBTP
        // even though discrete sample peak sits below 0 dBFS.
        let srcURL = dir.appendingPathComponent("hot_lossy_isp.wav")
        try writePCMFile(to: srcURL, bitDepth: 32, isFloat: true, sampleRate: 48_000, channels: 2, duration: 2.0) { ch, i in
            let sr = 48_000.0
            let quarter = 1.18 * sin(2.0 * .pi * 12_000.0 * Double(i) / sr + .pi / 4.0)
            let body = 0.25 * sin(2.0 * .pi * (ch == 0 ? 440.0 : 880.0) * Double(i) / sr)
            return Float(max(-1.0, min(1.0, 0.8 * quarter + body)))
        }

        // Measure source using the exact same authoritative FFmpeg EBU R128 path as post-encode validation.
        let sourceEBU = try await AudioAnalysisService.shared.measureLoudness(url: srcURL)
        let sourceTP = try XCTUnwrap(sourceEBU.truePeakDBTP)
        XCTAssertGreaterThan(sourceTP, 0.0, "Input fixture must exceed 0 dBTP on compatible EBU R128 measurement")

        let project = try await makeProject(from: srcURL, rate: .rate48k, duration: 2.0)

        for (fmt, loudnessOn, label): (FileFormat, Bool, String) in [
            (.mp3, false, "mp3_unnorm"),
            (.m4a, false, "aac_unnorm"),
            (.opus, false, "opus_unnorm"),
            (.ogg, false, "ogg_unnorm"),
            (.mp3, true, "mp3_loudnorm"),
            (.m4a, true, "aac_loudnorm"),
            (.ogg, true, "ogg_loudnorm")
        ] {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: 48_000,
                bitDepth: nil,
                bitrateKbps: 192,
                channels: 2,
                loudnessNormalizeEnabled: loudnessOn,
                targetLUFS: -14.0,
                truePeakCeilingDBTP: -1.0,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: outDir,
                baseFileName: "lossy_\(label)",
                exportMode: .lossyFormatReRender
            )
            let res = try await AudioExportService.export(project: project, request: req)
            let report = try XCTUnwrap(res.reports.first)
            let reportedTP = try XCTUnwrap(report.measuredTruePeakDBTP)

            // Cross-check decoded output via the same compatible post-codec EBU R128 measurement path.
            let independentEBU = try await AudioAnalysisService.shared.measureLoudness(url: res.outputURLs[0])
            let independentTP = try XCTUnwrap(independentEBU.truePeakDBTP)

            XCTAssertEqual(reportedTP, independentTP, accuracy: 0.1, "Report and post-codec EBU R128 meter must agree for \(label)")
            XCTAssertLessThanOrEqual(independentTP, -1.00, "Lossy \(label) post-codec true peak (\(independentTP) dBTP) exceeded -1.00 dBTP ceiling")
            if loudnessOn {
                let measuredLUFS = try XCTUnwrap(independentEBU.integratedLUFS)
                XCTAssertEqual(measuredLUFS, -14.0, accuracy: 1.5, "Lossy \(label) should normalize to -14.0 LUFS")
            } else {
                XCTAssertGreaterThanOrEqual(independentTP, -5.0, "Lossy \(label) should enforce ceiling without crushing audio")
            }
        }
    }

    func testStageB2LossyTruePeakComplianceEnforcedWhenValidateOutputDisabled() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("LossyNoValidate", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let srcURL = dir.appendingPathComponent("hot_lossy_isp.wav")
        try writePCMFile(to: srcURL, bitDepth: 32, isFloat: true, sampleRate: 48_000, channels: 2, duration: 2.0) { ch, i in
            let sr = 48_000.0
            let quarter = 1.18 * sin(2.0 * .pi * 12_000.0 * Double(i) / sr + .pi / 4.0)
            let body = 0.25 * sin(2.0 * .pi * (ch == 0 ? 440.0 : 880.0) * Double(i) / sr)
            return Float(max(-1.0, min(1.0, 0.8 * quarter + body)))
        }
        let project = try await makeProject(from: srcURL, rate: .rate48k, duration: 2.0)

        for (fmt, label): (FileFormat, String) in [
            (.mp3, "mp3"),
            (.m4a, "aac"),
            (.opus, "opus"),
            (.ogg, "ogg")
        ] {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: fmt,
                sampleRate: 48_000,
                bitDepth: nil,
                bitrateKbps: 192,
                channels: 2,
                loudnessNormalizeEnabled: false,
                targetLUFS: -14.0,
                truePeakCeilingDBTP: -1.0,
                applyDitheringOn16Bit: false,
                validateOutput: false,
                outputDirectory: outDir,
                baseFileName: "lossy_novalidate_\(label)",
                exportMode: .lossyFormatReRender
            )
            let res = try await AudioExportService.export(project: project, request: req)
            XCTAssertTrue(res.reports.isEmpty, "validateOutput == false should skip full AudioExportReport generation")
            let independentEBU = try await AudioAnalysisService.shared.measureLoudness(url: res.outputURLs[0])
            let independentTP = try XCTUnwrap(independentEBU.truePeakDBTP)
            XCTAssertLessThanOrEqual(
                independentTP,
                -1.00,
                "Lossy \(label) with validateOutput=false still must enforce <= -1.00 dBTP (measured \(independentTP))"
            )
        }
    }

    func testStageB2UnresolvableLossyTruePeakOvershootFailsExplicitlyAndCleansStaging() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("LossyOvershootFail", isDirectory: true)
        let outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let srcURL = dir.appendingPathComponent("hot_lossy_fail.wav")
        try writePCMFile(to: srcURL, bitDepth: 32, isFloat: true, sampleRate: 48_000, channels: 2, duration: 1.5) { ch, i in
            let sr = 48_000.0
            let quarter = 1.15 * sin(2.0 * .pi * 12_000.0 * Double(i) / sr + .pi / 4.0)
            let body = 0.20 * sin(2.0 * .pi * (ch == 0 ? 440.0 : 880.0) * Double(i) / sr)
            return Float(max(-1.0, min(1.0, 0.8 * quarter + body)))
        }
        let project = try await makeProject(from: srcURL, rate: .rate48k, duration: 1.5)

        let req = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .mp3,
            sampleRate: 48_000,
            bitDepth: nil,
            bitrateKbps: 192,
            channels: 2,
            loudnessNormalizeEnabled: false,
            targetLUFS: -14.0,
            truePeakCeilingDBTP: -1.0,
            applyDitheringOn16Bit: false,
            validateOutput: true,
            outputDirectory: outDir,
            baseFileName: "should_fail_overshoot",
            exportMode: .lossyFormatReRender
        )

        let measureCalls = OSAllocatedUnfairLock(initialState: 0)
        do {
            _ = try await AudioExportService.export(
                project: project,
                request: req,
                lossyTruePeakMeasurer: { _ in
                    measureCalls.withLock { $0 += 1 }
                    return 0.35
                }
            )
            XCTFail("Unresolvable post-codec overshoot after corrective retries must throw explicitly")
        } catch let ConversionError.engineExecutionFailed(message, _) {
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("true-peak") || message.localizedCaseInsensitiveContains("ceiling"),
                "Unexpected error message: \(message)"
            )
        }

        XCTAssertEqual(measureCalls.withLock { $0 }, 3, "Expected initial validation + 2 corrective retries (3 measurements)")
        let remainingOutputs = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        XCTAssertTrue(remainingOutputs.isEmpty, "Failed overshoot export must not publish output file")
        let stagingDir = AppStoragePaths.audioExportStagingDirectory
        if FileManager.default.fileExists(atPath: stagingDir.path) {
            let leftover = try FileManager.default.contentsOfDirectory(atPath: stagingDir.path)
            XCTAssertTrue(leftover.isEmpty, "Staging directory must be empty after overshoot failure: \(leftover)")
        }
    }

    func testAtomicExportPublishPreservesExistingDestinationOnFailure() throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("AtomicPublish", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let destURL = dir.appendingPathComponent("master.wav")
        let tmpURL = dir.appendingPathComponent("staged.wav")
        let originalData = Data("ORIGINAL_EXISTING_AUDIO_DATA".utf8)
        let newData = Data("NEW_STAGED_AUDIO_DATA".utf8)
        try originalData.write(to: destURL)
        try newData.write(to: tmpURL)

        let failingOps = OutputReservationCoordinator.AtomicPublishFileOperations(
            fileExists: OutputReservationCoordinator.AtomicPublishFileOperations.live.fileExists,
            isSameVolume: OutputReservationCoordinator.AtomicPublishFileOperations.live.isSameVolume,
            copyItem: OutputReservationCoordinator.AtomicPublishFileOperations.live.copyItem,
            moveItem: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            },
            replaceItemAt: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            },
            removeItem: OutputReservationCoordinator.AtomicPublishFileOperations.live.removeItem
        )

        XCTAssertThrowsError(
            try AudioExportService.publishExportedFile(tmpURL, to: destURL, operations: failingOps)
        )
        XCTAssertEqual(try Data(contentsOf: destURL), originalData, "Existing destination file must remain intact on publish failure")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpURL.path), "Staged temp file should remain available or untouched on atomic failure")

        _ = try AudioExportService.publishExportedFile(tmpURL, to: destURL)
        XCTAssertEqual(try Data(contentsOf: destURL), newData, "Live atomic publish should replace destination cleanly")
    }
}

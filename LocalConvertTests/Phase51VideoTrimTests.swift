import XCTest
import Foundation
import CryptoKit
import CoreGraphics
@testable import LocalConvert

@MainActor
final class Phase51VideoTrimTests: XCTestCase {

    // MARK: - Helpers

    private struct Sandbox {
        let root: URL
        let workDir: URL
        let outDir: URL
        let journalDir: URL
        let artifactsDir: URL
    }

    private func makeSandbox(name: String) throws -> Sandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P51VideoTrim-\(name)-\(UUID().uuidString)", isDirectory: true)
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        let journalDir = root.appendingPathComponent("journal", isDirectory: true)
        let artifactsDir = root.appendingPathComponent("artifacts", isDirectory: true)
        for d in [workDir, outDir, journalDir, artifactsDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return Sandbox(root: root, workDir: workDir, outDir: outDir, journalDir: journalDir, artifactsDir: artifactsDir)
    }

    private func bundledPaths() async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpeg = await provider.findFFmpegPath(),
              let ffprobe = await provider.findFFprobePath() else {
            throw XCTSkip("Bundled FFmpeg/FFprobe binaries unavailable in test environment.")
        }
        return (ffmpeg, ffprobe)
    }

    private func runFFmpeg(_ ffmpeg: String, args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let output = try await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: 60)
        guard output.terminationStatus == 0 else {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed("Synthetic fixture FFmpeg failed (\(output.terminationStatus))", underlyingError: err)
        }
    }

    private func makeSyntheticMP4(
        in dir: URL,
        name: String = "sample.mp4",
        durationSeconds: Double = 10.0,
        fps: Int = 30,
        gopFrames: Int = 30,
        audioStreams: Int = 1
    ) async throws -> URL {
        let (ffmpeg, _) = try await bundledPaths()
        let outURL = dir.appendingPathComponent(name)
        let durStr = String(format: "%.2f", durationSeconds)

        var args: [String] = [
            "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=\(fps):duration=\(durStr)",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(durStr)"
        ]
        if audioStreams >= 2 {
            args += ["-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000:duration=\(durStr)"]
            args += ["-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0"]
        }
        args += [
            "-c:v", "h264_videotoolbox",
            "-pix_fmt", "yuv420p",
            "-b:v", "600k",
            "-g", "\(gopFrames)",
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            outURL.path
        ]
        try await runFFmpeg(ffmpeg, args: args)
        return outURL
    }

    private func makeSyntheticWebM(
        in dir: URL,
        name: String = "sample.webm",
        durationSeconds: Double = 6.0
    ) async throws -> URL {
        let (ffmpeg, _) = try await bundledPaths()
        let outURL = dir.appendingPathComponent(name)
        let durStr = String(format: "%.2f", durationSeconds)

        let args: [String] = [
            "-y",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=\(durStr)",
            "-f", "lavfi", "-i", "sine=frequency=520:sample_rate=48000:duration=\(durStr)",
            "-c:v", "libvpx-vp9",
            "-b:v", "400k",
            "-c:a", "libopus",
            "-b:a", "96k",
            outURL.path
        ]
        try await runFFmpeg(ffmpeg, args: args)
        return outURL
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func activeTempMediaDirs() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory
        let items = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return Set(items.filter { $0.hasPrefix("LocalConvert-Media-") })
    }

    // MARK: - 1. Timestamp Parsing & Formatting

    func testTimestampParsingFormattingAndInvalidRejection() {
        // Plain seconds
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds("0"), 0)
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds("12.5"), 12_500)
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds(".25"), 250)
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds("0.05"), 50)
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds("1.2349"), 1_235) // Exact half-up millisecond rounding

        // MM:SS.mmm & HH:MM:SS.mmm
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds("01:05"), 65_000)
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds("02:15.35"), 135_350)
        XCTAssertEqual(VideoTrimTimestamp.parseMilliseconds("01:02:03.456"), 3_723_456)

        // Formatting
        XCTAssertEqual(VideoTrimTimestamp.formatFFmpeg(milliseconds: 3_723_456), "01:02:03.456")
        XCTAssertEqual(VideoTrimTimestamp.formatFFmpeg(milliseconds: 5_500), "00:00:05.500")
        XCTAssertEqual(VideoTrimTimestamp.formatDisplay(milliseconds: 5_500), "00:05.50")
        XCTAssertEqual(VideoTrimTimestamp.formatDisplay(milliseconds: 3_723_450), "01:02:03.45")

        // Rejected invalid/negative/overflow forms
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds(""))
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds("-5.0"))
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds("+2.0"))
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds("00:65")) // seconds >= 60
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds("01:60:00")) // minutes >= 60
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds("1:2:3:4"))
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds("12."))
        XCTAssertNil(VideoTrimTimestamp.parseMilliseconds("abc"))
    }

    // MARK: - 2, 3, 4. Boundary, Zero-Length & Over-Duration Validation

    func testTrimRangeValidationRejectsZeroLengthNegativeAndExceedingDuration() async throws {
        let sandbox = try makeSandbox(name: "validation")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let srcMP4 = try await makeSyntheticMP4(in: sandbox.workDir, durationSeconds: 5.0)
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        let info = try await provider.probe(url: srcMP4)

        // Negative start
        let neg = VideoTrimRange(startMilliseconds: -100, endMilliseconds: 2000, mode: .frameAccurate)
        XCTAssertFalse(VideoTrimValidator.validate(range: neg, sourceDurationSeconds: info.duration, inputInfo: info, outputFormat: .mp4).isValid)

        // Zero-length range (start == end)
        let zero = VideoTrimRange(startMilliseconds: 2000, endMilliseconds: 2000, mode: .frameAccurate)
        XCTAssertFalse(VideoTrimValidator.validate(range: zero, sourceDurationSeconds: info.duration, inputInfo: info, outputFormat: .mp4).isValid)

        // End before start
        let inverted = VideoTrimRange(startMilliseconds: 3000, endMilliseconds: 1000, mode: .frameAccurate)
        XCTAssertFalse(VideoTrimValidator.validate(range: inverted, sourceDurationSeconds: info.duration, inputInfo: info, outputFormat: .mp4).isValid)

        // Too short (< 0.10s)
        let tiny = VideoTrimRange(startMilliseconds: 1000, endMilliseconds: 1050, mode: .frameAccurate)
        XCTAssertFalse(VideoTrimValidator.validate(range: tiny, sourceDurationSeconds: info.duration, inputInfo: info, outputFormat: .mp4).isValid)

        // Exceeds source duration
        let over = VideoTrimRange(startMilliseconds: 1000, endMilliseconds: 8500, mode: .frameAccurate)
        XCTAssertFalse(VideoTrimValidator.validate(range: over, sourceDurationSeconds: info.duration, inputInfo: info, outputFormat: .mp4).isValid)

        // Execution layer must also reject invalid range cleanly with zero orphaned temp folders
        var badOpts = ConversionOptions.default
        badOpts.videoTrim = over
        let tempsBefore = activeTempMediaDirs()
        do {
            _ = try await provider.convert(input: srcMP4, to: .mp4, outputDirectory: sandbox.outDir, options: badOpts) { _ in }
            XCTFail("Expected ConversionError.invalidInput for over-duration video trim")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
        }
        XCTAssertEqual(activeTempMediaDirs(), tempsBefore)
    }

    // MARK: - 5 & 6. Stream Copy Trimming & Keyframe-Dependent Boundaries

    func testStreamCopyTrimBuildsArgumentsExecutesWithoutReencodingAndDisclosesKeyframeDependence() async throws {
        let sandbox = try makeSandbox(name: "stream-copy")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        // 10s H.264+AAC MP4 with 2.0s keyframe GOP (60 frames @ 30fps)
        let srcMP4 = try await makeSyntheticMP4(in: sandbox.workDir, durationSeconds: 10.0, fps: 30, gopFrames: 60)
        let srcHash = try sha256Hex(of: srcMP4)

        let trim = VideoTrimRange(startSeconds: 1.30, endSeconds: 4.80, mode: .streamCopy)
        var opts = ConversionOptions.default
        opts.videoTrim = trim

        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        let inputInfo = try await provider.probe(url: srcMP4)
        let validation = VideoTrimValidator.validate(range: trim, sourceDurationSeconds: inputInfo.duration, inputInfo: inputInfo, outputFormat: .mp4)
        XCTAssertTrue(validation.isValid)
        XCTAssertTrue(validation.isStreamCopyCompatible)
        XCTAssertNotNil(validation.warningMessage, "Stream Copy must disclose keyframe-dependent cut behavior")
        XCTAssertTrue(validation.warningMessage?.lowercased().contains("keyframe") == true)

        let args = provider.buildFFmpegArguments(
            inputURL: srcMP4,
            outputURL: sandbox.outDir.appendingPathComponent("test.mp4"),
            inputInfo: inputInfo,
            outputFormat: .mp4,
            options: opts
        )
        XCTAssertTrue(args.contains("-c"))
        XCTAssertTrue(args.contains("copy"))
        XCTAssertTrue(args.contains("-avoid_negative_ts"))
        XCTAssertTrue(args.contains("make_zero"))
        XCTAssertTrue(args.contains(trim.ffmpegStartTimestamp))
        XCTAssertTrue(args.contains(trim.ffmpegDurationTimestamp))

        let outURL = try await provider.convert(input: srcMP4, to: .mp4, outputDirectory: sandbox.outDir, options: opts) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        XCTAssertTrue(outURL.lastPathComponent.contains("_trimmed"))
        XCTAssertEqual(try sha256Hex(of: srcMP4), srcHash)

        let outInfo = try await provider.probe(url: outURL)
        XCTAssertEqual(outInfo.primaryVideoStream?.codecName.lowercased(), "h264")
        XCTAssertEqual(outInfo.primaryAudioStream?.codecName.lowercased(), "aac")
        XCTAssertGreaterThan(outInfo.duration, 1.5, "Stream-copy output should contain valid media around the requested range")
        XCTAssertLessThanOrEqual(outInfo.duration, inputInfo.duration + 0.25)
    }

    // MARK: - 7, 8, 9. Frame-Accurate Trimming, A/V Sync, Multi-Audio & Target File Size + Formats

    func testFrameAccurateTrimAccuracyAVSyncMultiAudioAndCrossFormatOutputs() async throws {
        let sandbox = try makeSandbox(name: "frame-accurate")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        // 10.0s 30fps MP4 with 2 audio streams and 2.0s keyframes (tests non-keyframe cut 1.30s -> 4.80s = 3.50s)
        let srcMP4 = try await makeSyntheticMP4(
            in: sandbox.workDir,
            name: "multi.mp4",
            durationSeconds: 10.0,
            fps: 30,
            gopFrames: 60,
            audioStreams: 2
        )
        let srcHash = try sha256Hex(of: srcMP4)

        let trim = VideoTrimRange(startSeconds: 1.30, endSeconds: 4.80, mode: .frameAccurate)
        var opts = ConversionOptions.default
        opts.videoTrim = trim

        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        nonisolated(unsafe) var reportedFractions: [Double] = []
        let outURL = try await provider.convert(input: srcMP4, to: .mp4, outputDirectory: sandbox.outDir, options: opts) { prog in
            if let f = prog.fractionCompleted {
                reportedFractions.append(f)
            }
        }

        let outInfo = try await provider.probe(url: outURL)
        // Expected 3.50s within ±0.08s
        XCTAssertEqual(outInfo.duration, 3.50, accuracy: 0.08, "Frame-accurate trim duration must stay within ±0.08s of 3.50s")
        XCTAssertEqual(outInfo.audioStreams.count, 2, "Frame-accurate trim must preserve all audio streams")
        if let vDur = outInfo.primaryVideoStream?.duration, let aDur = outInfo.primaryAudioStream?.duration {
            XCTAssertLessThanOrEqual(abs(vDur - aDur), 0.12, "Audio/video stream durations must stay synchronized")
        }
        XCTAssertEqual(reportedFractions.last ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(try sha256Hex(of: srcMP4), srcHash)

        // Verify targetFileSizeBytes bitrate math scales against trimmed duration (not full 10s source)
        var sizedOpts = opts
        sizedOpts.targetFileSizeBytes = 350_000
        sizedOpts.targetFileSizeMB = 0.35
        let inputInfo = try await provider.probe(url: srcMP4)
        let sizedArgs = provider.buildFFmpegArguments(
            inputURL: srcMP4,
            outputURL: sandbox.outDir.appendingPathComponent("sized.mp4"),
            inputInfo: inputInfo,
            outputFormat: .mp4,
            options: sizedOpts
        )
        let unclippedArgs = provider.videoEncodingArguments(for: .mp4, options: sizedOpts, duration: inputInfo.duration)
        let trimmedArgs = provider.videoEncodingArguments(for: .mp4, options: sizedOpts, duration: trim.durationSeconds)
        if let bvIdxTrim = sizedArgs.firstIndex(of: "-b:v"),
           let bvIdxFull = unclippedArgs.firstIndex(of: "-b:v"),
           let bvTrim = Int(sizedArgs[bvIdxTrim + 1]),
           let bvFull = Int(unclippedArgs[bvIdxFull + 1]),
           let bvExpectedIdx = trimmedArgs.firstIndex(of: "-b:v"),
           let bvExpected = Int(trimmedArgs[bvExpectedIdx + 1]) {
            XCTAssertEqual(bvTrim, bvExpected)
            XCTAssertGreaterThan(bvTrim, bvFull, "Bitrate for 3.5s trimmed clip must be computed against trimmed duration, not 10s full duration")
        } else {
            XCTFail("Expected -b:v bitrate argument when targetFileSizeBytes is set")
        }

        // Cross-format extraction with trim: GIF and MP3 (Audio Only)
        let gifURL = try await provider.convert(input: srcMP4, to: .gif, outputDirectory: sandbox.outDir, options: opts) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: gifURL.path))
        let gifInfo = try await provider.probe(url: gifURL)
        XCTAssertTrue(gifInfo.hasVideo)

        var audioOpts = ConversionOptions.default
        audioOpts.videoTrim = VideoTrimRange(startSeconds: 1.0, endSeconds: 3.0, mode: .frameAccurate)
        let mp3URL = try await provider.convert(input: srcMP4, to: .mp3, outputDirectory: sandbox.outDir, options: audioOpts) { _ in }
        let mp3Info = try await provider.probe(url: mp3URL)
        XCTAssertTrue(mp3Info.hasAudio)
        XCTAssertFalse(mp3Info.hasRealVideo)
        XCTAssertEqual(mp3Info.duration, 2.0, accuracy: 0.15)
    }

    // MARK: - 10. Unsupported Codec/Container Combinations

    func testUnsupportedStreamCopyContainerRejectedWithActionableError() async throws {
        let sandbox = try makeSandbox(name: "unsupported")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let srcWebM = try await makeSyntheticWebM(in: sandbox.workDir, durationSeconds: 4.0)
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        let webmInfo = try await provider.probe(url: srcWebM)

        // VP9 + Opus WebM cannot stream-copy into MP4
        let badTrim = VideoTrimRange(startSeconds: 0.5, endSeconds: 2.5, mode: .streamCopy)
        let validation = VideoTrimValidator.validate(range: badTrim, sourceDurationSeconds: webmInfo.duration, inputInfo: webmInfo, outputFormat: .mp4)
        XCTAssertFalse(validation.isValid)
        XCTAssertFalse(validation.isStreamCopyCompatible)
        XCTAssertTrue(validation.errorMessage?.contains("Frame-Accurate") == true)

        var badOpts = ConversionOptions.default
        badOpts.videoTrim = badTrim
        do {
            _ = try await provider.convert(input: srcWebM, to: .mp4, outputDirectory: sandbox.outDir, options: badOpts) { _ in }
            XCTFail("Expected ConversionError.invalidInput for VP9 WebM -> MP4 stream copy")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                XCTFail("Unexpected error type: \(error)")
                return
            }
        }

        // Switching the same WebM -> MP4 trim to Frame-Accurate succeeds cleanly
        var okOpts = ConversionOptions.default
        okOpts.videoTrim = VideoTrimRange(startSeconds: 0.5, endSeconds: 2.5, mode: .frameAccurate)
        let mp4URL = try await provider.convert(input: srcWebM, to: .mp4, outputDirectory: sandbox.outDir, options: okOpts) { _ in }
        let mp4Info = try await provider.probe(url: mp4URL)
        XCTAssertEqual(mp4Info.primaryVideoStream?.codecName.lowercased(), "h264")
        XCTAssertEqual(mp4Info.duration, 2.0, accuracy: 0.12)
    }

    // MARK: - 11 & 12. Cancellation, Process Termination & Temp Cleanup

    func testMidFlightCancellationTerminatesProcessAndCleansTempFiles() async throws {
        let sandbox = try makeSandbox(name: "cancel")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let srcMP4 = try await makeSyntheticMP4(in: sandbox.workDir, durationSeconds: 8.0)
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        let tempsBefore = activeTempMediaDirs()

        // VP9 WebM re-encode of 7s video gives reliable in-flight window to cancel mid-execution
        var opts = ConversionOptions.default
        opts.videoTrim = VideoTrimRange(startSeconds: 0.5, endSeconds: 7.5, mode: .frameAccurate)

        let task = Task {
            try await provider.convert(input: srcMP4, to: .webm, outputDirectory: sandbox.outDir, options: opts) { _ in }
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // CancellationError expected when task cancels mid-flight
        }

        // Allow deferred temp cleanup to settle
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(activeTempMediaDirs(), tempsBefore, "Cancelled video trim must remove LocalConvert-Media temp directory")
    }

    // MARK: - 13, 14, 15. Output Collision, Source Preservation & Global Undo/Redo

    func testOutputCollisionSourcePreservationAndGlobalUndoRedoIntegration() async throws {
        let sandbox = try makeSandbox(name: "undo-collision")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let srcMP4 = try await makeSyntheticMP4(in: sandbox.workDir, name: "clip.mp4", durationSeconds: 5.0)
        let srcHash = try sha256Hex(of: srcMP4)

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 100 },
            storageBudgetBytesProvider: { 64_000_000 }
        )

        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: MediaConversionEngine())
        }

        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(conversionManager: manager, undoCoordinator: coordinator)

        var opts = ConversionOptions.default
        opts.overwriteExisting = true // Even if overwrite flag is passed, same-folder same-format trim writes clip_trimmed.mp4 and protects source
        opts.videoTrim = VideoTrimRange(startSeconds: 1.0, endSeconds: 3.0, mode: .frameAccurate)

        // Ensure standard default collision-safe behavior for Undo test
        var safeOpts = opts
        safeOpts.overwriteExisting = false

        let job1 = ConversionJob(
            inputURLs: [srcMP4],
            inputFormat: .mp4,
            outputFormat: .mp4,
            outputDirectory: sandbox.workDir,
            options: safeOpts
        )
        queue.enqueue(job: job1)

        let exp1 = expectation(description: "First trim job finishes")
        queue.onQueueCompleted = { exp1.fulfill() }
        await fulfillment(of: [exp1], timeout: 30.0)
        await queue.flushPendingUndoRecords()

        let out1 = try XCTUnwrap(queue.lastBatchCompletedOutputURLs.first)
        XCTAssertEqual(out1.lastPathComponent, "clip_trimmed.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertEqual(try sha256Hex(of: srcMP4), srcHash)
        let out1Hash = try sha256Hex(of: out1)

        // Second trim into same folder must collide-resolve cleanly to clip_trimmed (1).mp4 without overwriting out1 or source
        let job2 = ConversionJob(
            inputURLs: [srcMP4],
            inputFormat: .mp4,
            outputFormat: .mp4,
            outputDirectory: sandbox.workDir,
            options: safeOpts
        )
        queue.enqueue(job: job2)

        let exp2 = expectation(description: "Second trim job finishes")
        queue.onQueueCompleted = { exp2.fulfill() }
        await fulfillment(of: [exp2], timeout: 30.0)
        await queue.flushPendingUndoRecords()

        let out2 = try XCTUnwrap(queue.lastBatchCompletedOutputURLs.first)
        XCTAssertEqual(out2.lastPathComponent, "clip_trimmed (1).mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertEqual(try sha256Hex(of: srcMP4), srcHash)

        // Undo removes out2 and then out1 while leaving srcMP4 completely untouched
        XCTAssertTrue(coordinator.canUndo(in: .convert))
        await coordinator.undo(in: .convert)
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcMP4.path))
        XCTAssertEqual(try sha256Hex(of: srcMP4), srcHash)

        await coordinator.undo(in: .convert)
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcMP4.path))
        XCTAssertEqual(try sha256Hex(of: srcMP4), srcHash)

        // Redo restores out1 identically
        await coordinator.redo(in: .convert)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertEqual(try sha256Hex(of: out1), out1Hash)
    }

    // MARK: - 16. VideoPreviewService Filmstrip Extraction (Native & FFmpeg Fallback)

    func testVideoPreviewServiceFilmstripNativeAndFFmpegFallback() async throws {
        let sandbox = try makeSandbox(name: "preview")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let mp4 = try await makeSyntheticMP4(in: sandbox.workDir, durationSeconds: 4.0)
        let webm = try await makeSyntheticWebM(in: sandbox.workDir, durationSeconds: 4.0)

        XCTAssertTrue(VideoPreviewService.supportsNativeAVPlayer(url: mp4))
        XCTAssertFalse(VideoPreviewService.supportsNativeAVPlayer(url: webm))

        let nativeThumbs = try await VideoPreviewService.extractFilmstrip(url: mp4, duration: 4.0, count: 5, maxWidth: 160)
        XCTAssertEqual(nativeThumbs.count, 5)
        XCTAssertGreaterThan(nativeThumbs[0].cgImage.width, 0)

        let fallbackThumbs = try await VideoPreviewService.extractFilmstrip(url: webm, duration: 4.0, count: 4, maxWidth: 160)
        XCTAssertEqual(fallbackThumbs.count, 4)
        XCTAssertGreaterThan(fallbackThumbs[0].cgImage.width, 0)

        let scrubFrame = try await VideoPreviewService.extractFrame(url: webm, atSeconds: 1.5, maxWidth: 320)
        XCTAssertNotNil(scrubFrame)
    }
}

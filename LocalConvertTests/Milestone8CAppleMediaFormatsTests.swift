import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

final class Milestone8CAppleMediaFormatsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConversionManager.clearReservedOutputURLs()
    }

    override func tearDown() {
        ConversionManager.clearReservedOutputURLs()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String = "M8CMedia") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bundledPaths() async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: false)
        guard let ffmpeg = await provider.findFFmpegPath(),
              let ffprobe = await provider.findFFprobePath() else {
            throw XCTSkip("Bundled FFmpeg/FFprobe binaries unavailable in test environment.")
        }
        return (ffmpeg, ffprobe)
    }

    private func runFFmpeg(_ ffmpeg: String, args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 60.0)
        guard output.terminationStatus == 0 else {
            let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed(
                "FFmpeg fixture generation failed with status \(output.terminationStatus).",
                underlyingError: stderr
            )
        }
    }

    private func makeSyntheticWAV(in dir: URL, name: String, durationSeconds: Double) async throws -> URL {
        let (ffmpeg, _) = try await bundledPaths()
        let outURL = dir.appendingPathComponent(name)
        let durStr = String(format: "%.2f", durationSeconds)
        try await runFFmpeg(ffmpeg, args: [
            "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:sample_rate=44100:duration=\(durStr)",
            "-ac", "2",
            "-c:a", "pcm_s16le",
            outURL.path
        ])
        return outURL
    }

    private func makeSyntheticMP4WithAudio(in dir: URL, name: String, durationSeconds: Double) async throws -> URL {
        let (ffmpeg, _) = try await bundledPaths()
        let outURL = dir.appendingPathComponent(name)
        let durStr = String(format: "%.2f", durationSeconds)
        try await runFFmpeg(ffmpeg, args: [
            "-y",
            "-f", "lavfi", "-i", "color=c=blue:s=160x120:r=15:d=\(durStr)",
            "-f", "lavfi", "-i", "sine=frequency=523.25:sample_rate=44100:duration=\(durStr)",
            "-c:v", "h264_videotoolbox",
            "-pix_fmt", "yuv420p",
            "-b:v", "250k",
            "-c:a", "aac",
            "-b:a", "128k",
            outURL.path
        ])
        return outURL
    }

    private func makeSolidImage(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Milestone8CAppleMediaFormatsTests", code: 1)
        }
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "Milestone8CAppleMediaFormatsTests", code: 2)
        }
        return image
    }

    private func writeHEICSSequence(
        to url: URL,
        width: Int = 32,
        height: Int = 32,
        frameCount: Int = 3,
        delaySeconds: Double = 0.14
    ) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.heics" as CFString,
            frameCount,
            nil
        ) else {
            throw NSError(domain: "Milestone8CAppleMediaFormatsTests", code: 3)
        }
        let palette: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        for i in 0..<frameCount {
            let c = palette[i % palette.count]
            let img = try makeSolidImage(width: width, height: height, r: c.0, g: c.1, b: c.2)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyHEICSDictionary: [
                    kCGImagePropertyHEICSDelayTime: delaySeconds,
                    kCGImagePropertyHEICSUnclampedDelayTime: delaySeconds
                ]
            ]
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest), "Failed to finalize HEICS sequence at \(url.lastPathComponent)")
    }

    private func extractArgValue(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    // MARK: - 1. M4R Capabilities & Option Descriptors

    func testMediaConversionEngineRegistersM4RInputOutputAndOptionDescriptors() {
        let engine = MediaConversionEngine()

        XCTAssertTrue(engine.supportedInputFormats.contains(.m4r))
        XCTAssertTrue(engine.supportedOutputFormats.contains(.m4r))

        XCTAssertTrue(engine.canConvert(from: .wav, to: .m4r))
        XCTAssertTrue(engine.canConvert(from: .mp3, to: .m4r))
        XCTAssertTrue(engine.canConvert(from: .mp4, to: .m4r))
        XCTAssertFalse(engine.canConvert(from: .m4r, to: .m4r))

        for target in [FileFormat.mp3, .m4a, .wav, .flac, .aac, .ogg, .opus] {
            XCTAssertTrue(engine.canConvert(from: .m4r, to: target), "Expected .m4r -> .\(target.fileExtension) to be supported")
        }

        let descriptors = engine.optionDescriptors(from: .wav, to: .m4r)
        XCTAssertTrue(descriptors.contains(where: { $0.id == "ringtone_duration" }))
        XCTAssertTrue(descriptors.contains(where: { $0.id == "audio_codec" }))
        XCTAssertFalse(descriptors.contains(where: { $0.id == "m4a_lossless" }))
    }

    // MARK: - 2. M4R FFmpeg Argument Construction & Duration Capping

    func testBaseFFmpegProviderBuildsM4RArgumentsWithIpodMuxerAnd30SecondCap() {
        let provider = BaseFFmpegProvider()
        let audioInfo = MediaInfo(
            url: URL(fileURLWithPath: "/tmp/long_track.wav"),
            formatName: "wav",
            duration: 90.0,
            fileSize: 1_000_000,
            bitRate: 1_411_200,
            streams: [
                MediaStreamInfo(
                    index: 0,
                    streamType: .audio,
                    codecName: "pcm_s16le",
                    codecLongName: nil,
                    bitRate: 1_411_200,
                    width: nil,
                    height: nil,
                    frameRate: nil,
                    sampleRate: 44100,
                    channels: 2,
                    duration: 90.0
                )
            ]
        )

        // Default conversion caps ringtone to 30 seconds with -f ipod and AAC
        let defaultArgs = provider.buildFFmpegArguments(
            inputURL: audioInfo.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.m4r"),
            inputInfo: audioInfo,
            outputFormat: .m4r,
            options: .default
        )
        XCTAssertEqual(extractArgValue("-f", from: defaultArgs), "ipod")
        XCTAssertEqual(extractArgValue("-c:a", from: defaultArgs), "aac")
        XCTAssertEqual(extractArgValue("-t", from: defaultArgs), "00:00:30.000")
        XCTAssertNil(extractArgValue("-ss", from: defaultArgs))

        // Shorter user-specified ringtone_duration (12s) is honored
        var shortCustom = ConversionOptions.default
        shortCustom.customOptions["ringtone_duration"] = "12"
        let shortArgs = provider.buildFFmpegArguments(
            inputURL: audioInfo.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.m4r"),
            inputInfo: audioInfo,
            outputFormat: .m4r,
            options: shortCustom
        )
        XCTAssertEqual(extractArgValue("-t", from: shortArgs), "00:00:12.000")

        // Oversized user ringtone_duration (60s) is clamped to 30s max
        var overCustom = ConversionOptions.default
        overCustom.customOptions["ringtone_duration"] = "60"
        let clampedCustomArgs = provider.buildFFmpegArguments(
            inputURL: audioInfo.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.m4r"),
            inputInfo: audioInfo,
            outputFormat: .m4r,
            options: overCustom
        )
        XCTAssertEqual(extractArgValue("-t", from: clampedCustomArgs), "00:00:30.000")

        // Shorter videoTrim (10s window starting at 5s) is honored
        var shortTrimOpts = ConversionOptions.default
        shortTrimOpts.videoTrim = VideoTrimRange(startSeconds: 5.0, endSeconds: 15.0)
        let shortTrimArgs = provider.buildFFmpegArguments(
            inputURL: audioInfo.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.m4r"),
            inputInfo: audioInfo,
            outputFormat: .m4r,
            options: shortTrimOpts
        )
        XCTAssertEqual(extractArgValue("-ss", from: shortTrimArgs), "00:00:05.000")
        XCTAssertEqual(extractArgValue("-t", from: shortTrimArgs), "00:00:10.000")

        // Longer videoTrim (45s window starting at 5s) is capped at 30s max
        var longTrimOpts = ConversionOptions.default
        longTrimOpts.videoTrim = VideoTrimRange(startSeconds: 5.0, endSeconds: 50.0)
        let longTrimArgs = provider.buildFFmpegArguments(
            inputURL: audioInfo.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.m4r"),
            inputInfo: audioInfo,
            outputFormat: .m4r,
            options: longTrimOpts
        )
        XCTAssertEqual(extractArgValue("-ss", from: longTrimArgs), "00:00:05.000")
        XCTAssertEqual(extractArgValue("-t", from: longTrimArgs), "00:00:30.000")

        // Hardening checks preserved
        XCTAssertEqual(BaseFFmpegProvider.defaultConversionTimeoutSeconds, 1800.0)
        XCTAssertFalse(BaseFFmpegProvider.canStreamCopyContainerAndCodecs(inputInfo: audioInfo, targetFormat: .m4r))
        XCTAssertEqual(
            BaseFFmpegProvider.effectiveAudioBitrateBps(for: .m4r, options: .default, audioArgs: defaultArgs),
            256_000.0
        )
    }

    // MARK: - 3. End-to-End M4R Conversion (Audio/Video -> M4R, M4R -> Audio)

    func testAudioToM4RTrimsLongAudioTo30SecondsAndRespectsShorterDuration() async throws {
        let (_, ffprobePath) = try await bundledPaths()
        let dir = try makeTempDir(prefix: "M8C-M4R-Audio")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let longWAV = try await makeSyntheticWAV(in: dir, name: "melody_34s.wav", durationSeconds: 34.0)
        let engine = MediaConversionEngine(provider: BundledFFmpegProvider(fallbackToSystem: false))

        // 1. Default conversion automatically trims 34s audio to <= 30s .m4r
        let defaultResult = try await engine.convert(
            inputs: [longWAV],
            to: .m4r,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        XCTAssertEqual(defaultResult.outputFormat, .m4r)
        XCTAssertEqual(defaultResult.outputURL.pathExtension.lowercased(), "m4r")
        XCTAssertEqual(FileDetector.detectFormat(url: defaultResult.outputURL), .m4r)

        let probedDefault = try await MediaProbe.probe(url: defaultResult.outputURL, ffprobePath: ffprobePath)
        XCTAssertTrue(probedDefault.hasAudio)
        XCTAssertFalse(probedDefault.hasRealVideo)
        XCTAssertEqual(probedDefault.primaryAudioStream?.codecName.lowercased(), "aac")
        XCTAssertLessThanOrEqual(probedDefault.duration, 30.2)
        XCTAssertGreaterThan(probedDefault.duration, 29.5)

        // 2. Shorter user-specified duration via videoTrim (6.0s)
        var trimOpts = ConversionOptions.default
        trimOpts.videoTrim = VideoTrimRange(startSeconds: 2.0, endSeconds: 8.0)
        let trimmedResult = try await engine.convert(
            inputs: [longWAV],
            to: .m4r,
            outputDirectory: outDir,
            options: trimOpts,
            progress: { _ in }
        )
        XCTAssertNotEqual(trimmedResult.outputURL, defaultResult.outputURL, "Unique collision policy must preserve prior output")
        let probedTrimmed = try await MediaProbe.probe(url: trimmedResult.outputURL, ffprobePath: ffprobePath)
        XCTAssertLessThanOrEqual(probedTrimmed.duration, 6.2)
        XCTAssertGreaterThan(probedTrimmed.duration, 5.5)

        // 3. Shorter user-specified duration via ringtone_duration custom option (4.0s)
        var customDurOpts = ConversionOptions.default
        customDurOpts.customOptions["ringtone_duration"] = "4"
        let customDurResult = try await engine.convert(
            inputs: [longWAV],
            to: .m4r,
            outputDirectory: outDir,
            options: customDurOpts,
            progress: { _ in }
        )
        let probedCustomDur = try await MediaProbe.probe(url: customDurResult.outputURL, ffprobePath: ffprobePath)
        XCTAssertLessThanOrEqual(probedCustomDur.duration, 4.2)
        XCTAssertGreaterThan(probedCustomDur.duration, 3.5)

        // 4. Invalid ringtone_duration rejects cleanly before FFmpeg execution
        var badDurOpts = ConversionOptions.default
        badDurOpts.customOptions["ringtone_duration"] = "-2"
        do {
            _ = try await engine.convert(
                inputs: [longWAV],
                to: .m4r,
                outputDirectory: outDir,
                options: badDurOpts,
                progress: { _ in }
            )
            XCTFail("Expected invalid negative ringtone_duration to fail")
        } catch let err as ConversionError {
            guard case .invalidInput = err else {
                return XCTFail("Expected ConversionError.invalidInput, got \(err)")
            }
        }
    }

    func testVideoToM4RAndM4RToStandardAudioFormats() async throws {
        let (_, ffprobePath) = try await bundledPaths()
        let dir = try makeTempDir(prefix: "M8C-M4R-Roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let mp4URL = try await makeSyntheticMP4WithAudio(in: dir, name: "clip_4s.mp4", durationSeconds: 4.0)
        let engine = MediaConversionEngine(provider: BundledFFmpegProvider(fallbackToSystem: false))

        // Video -> .m4r extracts audio-only AAC ringtone preserving short duration
        let ringtoneResult = try await engine.convert(
            inputs: [mp4URL],
            to: .m4r,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        XCTAssertEqual(FileDetector.detectFormat(url: ringtoneResult.outputURL), .m4r)
        let ringtoneInfo = try await MediaProbe.probe(url: ringtoneResult.outputURL, ffprobePath: ffprobePath)
        XCTAssertTrue(ringtoneInfo.hasAudio)
        XCTAssertFalse(ringtoneInfo.hasVideo)
        XCTAssertLessThanOrEqual(ringtoneInfo.duration, 4.3)
        XCTAssertGreaterThan(ringtoneInfo.duration, 3.5)

        // .m4r -> standard audio formats (.mp3, .m4a, .wav, .flac, .opus)
        for targetFormat in [FileFormat.mp3, .m4a, .wav, .flac, .opus] {
            let audioResult = try await engine.convert(
                inputs: [ringtoneResult.outputURL],
                to: targetFormat,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
            XCTAssertEqual(audioResult.outputFormat, targetFormat)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioResult.outputURL.path))
            let info = try await MediaProbe.probe(url: audioResult.outputURL, ffprobePath: ffprobePath)
            XCTAssertTrue(info.hasAudio, "Expected audio stream in .\(targetFormat.fileExtension) output")
            XCTAssertGreaterThan(info.duration, 3.0)
        }
    }

    // MARK: - 4. HEICS / HEIFS Detection, Still Decoding, Animated GIF & LC-015 Safety

    func testImageEngineSupportsHEICSAndHEIFSAsReadOnlyInputsAndDetectsFormats() throws {
        let engine = ImageConversionEngine()
        XCTAssertTrue(engine.supportedInputFormats.contains(.heics))
        XCTAssertTrue(engine.supportedInputFormats.contains(.heifs))
        XCTAssertFalse(engine.supportedOutputFormats.contains(.heics))
        XCTAssertFalse(engine.supportedOutputFormats.contains(.heifs))

        for input in [FileFormat.heics, .heifs] {
            let outputs = engine.availableOutputFormats(for: input)
            XCTAssertTrue(outputs.contains(.png))
            XCTAssertTrue(outputs.contains(.jpg))
            XCTAssertTrue(outputs.contains(.webp))
            XCTAssertTrue(outputs.contains(.gif))
            XCTAssertFalse(outputs.contains(.heics))
            XCTAssertFalse(outputs.contains(.heifs))
        }

        let dir = try makeTempDir(prefix: "M8C-HEICS-Detect")
        defer { try? FileManager.default.removeItem(at: dir) }

        let heicsURL = dir.appendingPathComponent("burst.heics")
        try writeHEICSSequence(to: heicsURL, width: 16, height: 16, frameCount: 2)
        XCTAssertEqual(FileDetector.detectFormat(url: heicsURL), .heics)

        let heifsURL = dir.appendingPathComponent("burst.heifs")
        try Data(contentsOf: heicsURL).write(to: heifsURL)
        XCTAssertEqual(FileDetector.detectFormat(url: heifsURL), .heifs)
    }

    func testHEICSAndHEIFSDecodeToStillImagesAndAnimatedGIFWithTimingMetadata() async throws {
        let dir = try makeTempDir(prefix: "M8C-HEICS-Convert")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let heicsURL = dir.appendingPathComponent("sequence.heics")
        try writeHEICSSequence(to: heicsURL, width: 32, height: 24, frameCount: 3, delaySeconds: 0.14)

        let heifsURL = dir.appendingPathComponent("sequence_copy.heifs")
        try Data(contentsOf: heicsURL).write(to: heifsURL)

        let engine = ImageConversionEngine()

        // 1. Multi-frame HEICS -> Animated GIF preserves all 3 frames & HEICS delay timing
        let gifResult = try await engine.convert(
            inputs: [heicsURL],
            to: .gif,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        XCTAssertEqual(gifResult.outputFormat, .gif)
        let gifSource = try XCTUnwrap(CGImageSourceCreateWithURL(gifResult.outputURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gifSource), 3)
        let frame0Props = CGImageSourceCopyPropertiesAtIndex(gifSource, 0, nil) as? [CFString: Any]
        let gifFrame0Dict = frame0Props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gifFrame0Dict?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
        XCTAssertEqual(delay, 0.14, accuracy: 0.03)

        // 2. Multi-frame HEIFS -> Animated GIF preserves all 3 frames
        let heifsGifResult = try await engine.convert(
            inputs: [heifsURL],
            to: .gif,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        let heifsGifSource = try XCTUnwrap(CGImageSourceCreateWithURL(heifsGifResult.outputURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(heifsGifSource), 3)

        // 3. HEICS -> Still PNG / JPEG / WebP decodes cleanly
        for stillTarget in [FileFormat.png, .jpg, .webp] {
            let stillResult = try await engine.convert(
                inputs: [heicsURL],
                to: stillTarget,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
            XCTAssertEqual(stillResult.outputFormat, stillTarget)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stillResult.outputURL.path))
            XCTAssertGreaterThan(stillResult.fileSize, 0)
            if stillTarget != .webp {
                let src = try XCTUnwrap(CGImageSourceCreateWithURL(stillResult.outputURL as CFURL, nil))
                let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
                XCTAssertEqual(img.width, 32)
                XCTAssertEqual(img.height, 24)
            } else {
                let webpData = try Data(contentsOf: stillResult.outputURL)
                XCTAssertTrue(WebPEncoder.validate(webpData))
            }
        }

        // 4. HEIFS -> Still PNG
        let heifsPngResult = try await engine.convert(
            inputs: [heifsURL],
            to: .png,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        let heifsPngSrc = try XCTUnwrap(CGImageSourceCreateWithURL(heifsPngResult.outputURL as CFURL, nil))
        let heifsPngImg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(heifsPngSrc, 0, nil))
        XCTAssertEqual(heifsPngImg.width, 32)
        XCTAssertEqual(heifsPngImg.height, 24)

        // 5. Single-frame HEICS -> GIF falls back cleanly to 1-frame GIF
        let singleHEICS = dir.appendingPathComponent("single_frame.heics")
        try writeHEICSSequence(to: singleHEICS, width: 20, height: 20, frameCount: 1, delaySeconds: 0.1)
        let singleGifResult = try await engine.convert(
            inputs: [singleHEICS],
            to: .gif,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        let singleGifSrc = try XCTUnwrap(CGImageSourceCreateWithURL(singleGifResult.outputURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(singleGifSrc), 1)
    }

    func testHEICSAndHEIFSEnforceLC015MemoryCapsDeduplicatedFrame0AndAtomicCommit() async throws {
        final class DecodedFrameTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var indices: [Int] = []

            func record(_ index: Int) {
                lock.lock()
                indices.append(index)
                lock.unlock()
            }

            func snapshot() -> [Int] {
                lock.lock()
                defer { lock.unlock() }
                return indices
            }
        }

        let dir = try makeTempDir(prefix: "M8C-HEICS-LC015")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let heicsURL = dir.appendingPathComponent("burst.heics")
        try writeHEICSSequence(to: heicsURL, width: 32, height: 32, frameCount: 3, delaySeconds: 0.1)

        let heifsURL = dir.appendingPathComponent("burst.heifs")
        try Data(contentsOf: heicsURL).write(to: heifsURL)

        // 1. Frame 0 is decoded at most once under normal budget
        let gifOut = dir.appendingPathComponent("out.gif")
        let tracker = DecodedFrameTracker()
        let converted = try await ImageConversionEngine.convertAnimatedIfApplicable(
            input: heicsURL,
            inputFormat: .heics,
            outputFormat: .gif,
            outputURL: gifOut,
            options: .default,
            onFrameDecoded: { index in tracker.record(index) },
            progress: { _ in }
        )
        XCTAssertTrue(converted)
        XCTAssertEqual(tracker.snapshot(), [0, 1, 2], "Each HEICS frame including frame 0 must be decoded once")

        // 2. Tight LC-015 budget rejects 32x32x4x3 = 12,288 bytes BEFORE decoding any frames
        for (inputURL, format) in [(heicsURL, FileFormat.heics), (heifsURL, FileFormat.heifs)] {
            let cappedOut = dir.appendingPathComponent("capped_\(format.rawValue).gif")
            let cappedTracker = DecodedFrameTracker()
            do {
                _ = try await ImageConversionEngine.convertAnimatedIfApplicable(
                    input: inputURL,
                    inputFormat: format,
                    outputFormat: .gif,
                    outputURL: cappedOut,
                    options: .default,
                    maxUncompressedMemoryBytes: 1024,
                    onFrameDecoded: { index in cappedTracker.record(index) },
                    progress: { _ in }
                )
                XCTFail("Expected LC-015 budget check to reject \(format.rawValue)")
            } catch let error as ConversionError {
                guard case .invalidInput = error else {
                    return XCTFail("Expected ConversionError.invalidInput, got \(error)")
                }
            }
            XCTAssertTrue(cappedTracker.snapshot().isEmpty, "Oversized \(format.rawValue) must fail before decoding frames")
            XCTAssertFalse(FileManager.default.fileExists(atPath: cappedOut.path))
        }

        // 3. Atomic OutputReservationCoordinator commit preserves existing destination unless overwriteExisting = true
        let engine = ImageConversionEngine()
        let firstOut = try await engine.convert(
            inputs: [heicsURL],
            to: .gif,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        let secondUniqueOut = try await engine.convert(
            inputs: [heicsURL],
            to: .gif,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )
        XCTAssertNotEqual(firstOut.outputURL, secondUniqueOut.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstOut.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondUniqueOut.outputURL.path))

        var overwriteOpts = ConversionOptions.default
        overwriteOpts.overwriteExisting = true
        let overwrittenOut = try await engine.convert(
            inputs: [heicsURL],
            to: .gif,
            outputDirectory: outDir,
            options: overwriteOpts,
            progress: { _ in }
        )
        XCTAssertEqual(overwrittenOut.outputURL, firstOut.outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overwrittenOut.outputURL.path))
    }
}

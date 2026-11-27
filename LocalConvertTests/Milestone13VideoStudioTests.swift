import XCTest
import Foundation
import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone13VideoStudioTests: XCTestCase {

    // MARK: - Helpers

    private func makeSandbox(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M13VideoStudio-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func createSyntheticMP4(
        at outputURL: URL,
        width: Int = 160,
        height: Int = 120,
        frameCount: Int = 20,
        fps: Int32 = 10,
        includeAudio: Bool = false
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttrs
        )

        XCTAssertTrue(writer.canAdd(videoInput))
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = false
            XCTAssertTrue(writer.canAdd(aInput))
            writer.add(aInput)
            audioInput = aInput
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            var maybeBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                pixelAttrs as CFDictionary,
                &maybeBuffer
            )
            XCTAssertEqual(status, kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(maybeBuffer)

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
                let blue = UInt8((index * 12) % 255)
                let green: UInt8 = 110
                let red: UInt8 = 210
                for y in 0..<height {
                    let row = ptr.advanced(by: y * bytesPerRow)
                    for x in 0..<width {
                        let offset = x * 4
                        row[offset] = blue
                        row[offset + 1] = green
                        row[offset + 2] = red
                        row[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let pts = CMTime(value: Int64(index), timescale: fps)
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: pts))
        }
        videoInput.markAsFinished()

        if let audioInput {
            let durationSeconds = Double(frameCount) / Double(fps)
            let totalSamples = max(4410, Int((durationSeconds * 44100.0).rounded()))
            var pcmSamples = [Int16](repeating: 0, count: totalSamples)
            // Keep initial 0.2s silent, middle 440Hz tone, trailing 0.2s silent
            let silenceSamples = min(totalSamples / 5, 8820)
            for i in silenceSamples..<(totalSamples - silenceSamples) {
                let phase = 2.0 * Double.pi * 440.0 * (Double(i) / 44100.0)
                pcmSamples[i] = Int16(sin(phase) * 12000.0)
            }

            let pcmData = pcmSamples.withUnsafeBytes { Data($0) }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 44100.0,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            var formatDesc: CMAudioFormatDescription?
            let fmtStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
            XCTAssertEqual(fmtStatus, noErr)
            let unwrappedDesc = try XCTUnwrap(formatDesc)

            var blockBuffer: CMBlockBuffer?
            let bbStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: pcmData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: pcmData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            XCTAssertEqual(bbStatus, kCMBlockBufferNoErr)
            let unwrappedBlock = try XCTUnwrap(blockBuffer)
            XCTAssertEqual(CMBlockBufferAssureBlockMemory(unwrappedBlock), kCMBlockBufferNoErr)
            let replaceStatus = pcmData.withUnsafeBytes { rawBuf in
                CMBlockBufferReplaceDataBytes(
                    with: rawBuf.baseAddress!,
                    blockBuffer: unwrappedBlock,
                    offsetIntoDestination: 0,
                    dataLength: pcmData.count
                )
            }
            XCTAssertEqual(replaceStatus, kCMBlockBufferNoErr)

            var sampleBuffer: CMSampleBuffer?
            let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: unwrappedBlock,
                formatDescription: unwrappedDesc,
                sampleCount: totalSamples,
                presentationTimeStamp: .zero,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )
            XCTAssertEqual(sbStatus, noErr)
            let unwrappedSample = try XCTUnwrap(sampleBuffer)

            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertTrue(audioInput.append(unwrappedSample))
            audioInput.markAsFinished()
        }

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "AVAssetWriter failed: \(writer.error?.localizedDescription ?? "unknown")")
    }

    // MARK: - 1. Aspect-Ratio Crop Filter Builders

    func testCropFilterBuildersForFree16x99x16And1x1() throws {
        // Inactive configurations produce nil
        XCTAssertNil(QuickVideoCutterEngine.buildCropFilter(configuration: VideoCropConfiguration(aspectRatio: .none)))
        XCTAssertNil(
            QuickVideoCutterEngine.buildCropFilter(
                configuration: VideoCropConfiguration(
                    aspectRatio: .free,
                    normalizedRect: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                )
            )
        )

        // Free custom normalized rect on 1920x1080
        let freeConfig = VideoCropConfiguration(
            aspectRatio: .free,
            normalizedRect: NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
        XCTAssertEqual(
            QuickVideoCutterEngine.buildCropFilter(configuration: freeConfig, sourceWidth: 1920, sourceHeight: 1080),
            "crop=1536:864:192:108"
        )
        let freeExpr = try XCTUnwrap(QuickVideoCutterEngine.buildCropFilter(configuration: freeConfig))
        XCTAssertTrue(freeExpr.hasPrefix("crop=trunc(iw*0.8000/2)*2:trunc(ih*0.8000/2)*2:"))

        // 16:9 centered on portrait 1080x1920
        let centered16x9 = VideoCropConfiguration.centeredNormalizedRect(for: .widescreen16x9, sourceWidth: 1080, sourceHeight: 1920)
        let config16x9 = VideoCropConfiguration(aspectRatio: .widescreen16x9, normalizedRect: centered16x9)
        let px16x9 = try XCTUnwrap(QuickVideoCutterEngine.pixelCropRect(from: config16x9, sourceWidth: 1080, sourceHeight: 1920))
        XCTAssertEqual(px16x9.width, 1080)
        XCTAssertEqual(px16x9.height, 608)
        XCTAssertEqual(px16x9.width % 2, 0)
        XCTAssertEqual(px16x9.height % 2, 0)
        XCTAssertEqual(
            QuickVideoCutterEngine.buildCropFilter(configuration: config16x9, sourceWidth: 1080, sourceHeight: 1920),
            "crop=1080:608:0:\(px16x9.y)"
        )
        let expr16x9 = try XCTUnwrap(QuickVideoCutterEngine.buildCropFilter(configuration: VideoCropConfiguration(aspectRatio: .widescreen16x9)))
        XCTAssertTrue(expr16x9.contains("16/9"))

        // 9:16 centered on landscape 1920x1080
        let centered9x16 = VideoCropConfiguration.centeredNormalizedRect(for: .vertical9x16, sourceWidth: 1920, sourceHeight: 1080)
        let config9x16 = VideoCropConfiguration(aspectRatio: .vertical9x16, normalizedRect: centered9x16)
        let px9x16 = try XCTUnwrap(QuickVideoCutterEngine.pixelCropRect(from: config9x16, sourceWidth: 1920, sourceHeight: 1080))
        XCTAssertEqual(px9x16.width, 608)
        XCTAssertEqual(px9x16.height, 1080)
        let expr9x16 = try XCTUnwrap(QuickVideoCutterEngine.buildCropFilter(configuration: VideoCropConfiguration(aspectRatio: .vertical9x16)))
        XCTAssertTrue(expr9x16.contains("9/16"))

        // 1:1 centered on landscape 1920x1080
        let centered1x1 = VideoCropConfiguration.centeredNormalizedRect(for: .square1x1, sourceWidth: 1920, sourceHeight: 1080)
        let config1x1 = VideoCropConfiguration(aspectRatio: .square1x1, normalizedRect: centered1x1)
        let px1x1 = try XCTUnwrap(QuickVideoCutterEngine.pixelCropRect(from: config1x1, sourceWidth: 1920, sourceHeight: 1080))
        XCTAssertEqual(px1x1.width, 1080)
        XCTAssertEqual(px1x1.height, 1080)
        XCTAssertEqual(px1x1.x, 420)
        XCTAssertEqual(px1x1.y, 0)
        let expr1x1 = try XCTUnwrap(QuickVideoCutterEngine.buildCropFilter(configuration: VideoCropConfiguration(aspectRatio: .square1x1)))
        XCTAssertTrue(expr1x1.hasPrefix("crop=trunc(min(iw\\,ih)/2)*2"))

        // Compressed MP4 argument builder with rotation + crop swaps dimensions before cropping
        let rotatedArgs = try QuickVideoCutterEngine.buildCompressedMP4Arguments(
            inputURL: URL(fileURLWithPath: "/tmp/in.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            segments: [VideoSegment(startSeconds: 0, endSeconds: 2, isKept: true)],
            rotation: .deg90,
            cropConfiguration: VideoCropConfiguration(
                aspectRatio: .square1x1,
                normalizedRect: VideoCropConfiguration.centeredNormalizedRect(for: .square1x1, sourceWidth: 1080, sourceHeight: 1920)
            ),
            sourceWidth: 1920,
            sourceHeight: 1080
        )
        let fcIdx = try XCTUnwrap(rotatedArgs.firstIndex(of: "-filter_complex"))
        let fc = rotatedArgs[fcIdx + 1]
        XCTAssertTrue(fc.contains("transpose=1,crop=1080:1080:0:420"))
    }

    // MARK: - 2. Multi-Clip Join (Concat) Builders

    func testMultiClipConcatDemuxerAndFilterBuilders() throws {
        let clipA = URL(fileURLWithPath: "/tmp/clip'1 [hd].mp4")
        let clipB = URL(fileURLWithPath: "/tmp/clip 2.mov")
        let listURL = URL(fileURLWithPath: "/tmp/join_list.txt")
        let outURL = URL(fileURLWithPath: "/tmp/joined.mp4")

        let listText = QuickVideoCutterEngine.formatConcatListFile(segmentURLs: [clipA, clipB])
        XCTAssertTrue(listText.contains("file '/tmp/clip'\\''1 [hd].mp4'"))
        XCTAssertTrue(listText.contains("file '/tmp/clip 2.mov'"))

        let demuxerArgs = QuickVideoCutterEngine.buildMultiClipConcatDemuxerArguments(
            concatListURL: listURL,
            outputURL: outURL,
            includeAudio: true,
            includeProgressPipe: true
        )
        XCTAssertTrue(demuxerArgs.contains("-f"))
        XCTAssertTrue(demuxerArgs.contains("concat"))
        XCTAssertTrue(demuxerArgs.contains("-safe"))
        XCTAssertTrue(demuxerArgs.contains("0"))
        XCTAssertTrue(demuxerArgs.contains("copy"))
        XCTAssertTrue(demuxerArgs.contains("+faststart"))
        XCTAssertEqual(demuxerArgs.last, outURL.path)

        // Reject < 2 clips
        XCTAssertThrowsError(
            try QuickVideoCutterEngine.buildMultiClipConcatFilterArguments(
                inputURLs: [clipA],
                outputURL: outURL,
                targetWidth: 1280,
                targetHeight: 720,
                hasAudioPerClip: [true]
            )
        )

        // Mixed audio + loudnorm + silenceremove + subtitle burn-in
        let srtURL = URL(fileURLWithPath: "/tmp/sub:title's.srt")
        let filterArgs = try QuickVideoCutterEngine.buildMultiClipConcatFilterArguments(
            inputURLs: [clipA, clipB],
            outputURL: outURL,
            targetWidth: 1281,
            targetHeight: 721,
            hasAudioPerClip: [true, false],
            clipDurations: [2.0, 3.5],
            audioProcessing: VideoAudioProcessingOptions(loudnessNormalize: true, trimSilence: true),
            subtitleURL: srtURL
        )
        let fcIdx = try XCTUnwrap(filterArgs.firstIndex(of: "-filter_complex"))
        let fc = filterArgs[fcIdx + 1]
        XCTAssertTrue(fc.contains("scale=1280:720"))
        XCTAssertTrue(fc.contains("anullsrc=channel_layout=stereo:sample_rate=48000:d=3.500"))
        XCTAssertTrue(fc.contains("concat=n=2:v=1:a=1"))
        XCTAssertTrue(fc.contains("silenceremove="))
        XCTAssertTrue(fc.contains("loudnorm=I=-16:TP=-1.5:LRA=11"))
        XCTAssertTrue(fc.contains("subtitles='"))
        XCTAssertTrue(filterArgs.contains("h264_videotoolbox"))
        XCTAssertEqual(filterArgs.last, outURL.path)

        // Stream copy eligibility check
        let uniform1 = MediaInfo(
            url: clipA,
            formatName: "mp4",
            duration: 2,
            fileSize: 1000,
            bitRate: 1000,
            streams: [
                MediaStreamInfo(index: 0, streamType: .video, codecName: "h264", codecLongName: nil, bitRate: nil, width: 1280, height: 720, frameRate: 30, sampleRate: nil, channels: nil, duration: 2),
                MediaStreamInfo(index: 1, streamType: .audio, codecName: "aac", codecLongName: nil, bitRate: nil, width: nil, height: nil, frameRate: nil, sampleRate: 48000, channels: 2, duration: 2)
            ]
        )
        let uniform2 = MediaInfo(
            url: clipB,
            formatName: "mp4",
            duration: 3,
            fileSize: 1500,
            bitRate: 1000,
            streams: uniform1.streams
        )
        let mismatch = MediaInfo(
            url: clipB,
            formatName: "mov",
            duration: 3,
            fileSize: 1500,
            bitRate: 1000,
            streams: [
                MediaStreamInfo(index: 0, streamType: .video, codecName: "hevc", codecLongName: nil, bitRate: nil, width: 1920, height: 1080, frameRate: 30, sampleRate: nil, channels: nil, duration: 3)
            ]
        )
        XCTAssertTrue(QuickVideoCutterEngine.canStreamCopyConcat(infos: [uniform1, uniform2]))
        XCTAssertFalse(QuickVideoCutterEngine.canStreamCopyConcat(infos: [uniform1, mismatch]))
    }

    // MARK: - 3. SRT Subtitle Parsing, Remapping & FFmpeg Filter Escaping

    func testSRTSubtitleEscapingParsingAndSegmentRemapping() throws {
        let srtURL = URL(fileURLWithPath: "/tmp/My Video's [Cut]: Part\\1.srt")
        let escaped = QuickVideoCutterEngine.escapeFFmpegFilterPath(srtURL.path)
        XCTAssertTrue(escaped.contains("\\\\"))
        XCTAssertTrue(escaped.contains("\\:"))
        XCTAssertTrue(escaped.contains("'\\\\\\''"))

        let filter = QuickVideoCutterEngine.buildSubtitleBurnInFilter(srtURL: srtURL)
        XCTAssertTrue(filter.hasPrefix("subtitles='"))
        XCTAssertTrue(filter.hasSuffix("'"))

        let mp4Args = try QuickVideoCutterEngine.buildCompressedMP4Arguments(
            inputURL: URL(fileURLWithPath: "/tmp/in.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            segments: [VideoSegment(startSeconds: 0, endSeconds: 5, isKept: true)],
            subtitleURL: srtURL
        )
        let fcIdx = try XCTUnwrap(mp4Args.firstIndex(of: "-filter_complex"))
        XCTAssertTrue(mp4Args[fcIdx + 1].contains(filter))

        let rawSRT = "\u{FEFF}1\r\n00:00:00,500 --> 00:00:02,000\r\n<i>First</i> line\r\n\r\n2\r\n00:00:03.000 --> 00:00:05.500\r\nSecond line\r\n"
        let cues = QuickVideoCutterEngine.parseSRTCues(from: rawSRT)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "First line")
        XCTAssertEqual(cues[0].startSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].endSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(cues[1].startSeconds, 3.0, accuracy: 0.001)

        // Remap across cut segments: keep [0, 1.5] and [4.0, 5.5] at 1x
        let remapped = QuickVideoCutterEngine.remapSRTCues(
            cues,
            keptSegments: [
                VideoSegment(startSeconds: 0.0, endSeconds: 1.5, isKept: true),
                VideoSegment(startSeconds: 4.0, endSeconds: 5.5, isKept: true)
            ],
            speedMultiplier: 1.0
        )
        XCTAssertEqual(remapped.count, 2)
        XCTAssertEqual(remapped[0].startSeconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(remapped[0].endSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(remapped[1].startSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(remapped[1].endSeconds, 3.0, accuracy: 0.001)
    }

    // MARK: - 4. Audio Processing (loudnorm & silenceremove) + Extract Audio

    func testAudioProcessingFiltersAndExtractAudioArguments() throws {
        let none = QuickVideoCutterEngine.buildAudioProcessingFilters(options: VideoAudioProcessingOptions())
        XCTAssertTrue(none.isEmpty)

        let loudOnly = QuickVideoCutterEngine.buildAudioProcessingFilters(
            options: VideoAudioProcessingOptions(loudnessNormalize: true, trimSilence: false)
        )
        XCTAssertEqual(loudOnly, ["loudnorm=I=-16:TP=-1.5:LRA=11"])

        let silenceOnly = QuickVideoCutterEngine.buildAudioProcessingFilters(
            options: VideoAudioProcessingOptions(loudnessNormalize: false, trimSilence: true)
        )
        XCTAssertEqual(
            silenceOnly,
            ["silenceremove=start_periods=1:start_threshold=-50dB:stop_periods=-1:stop_duration=0.5:stop_threshold=-50dB"]
        )

        let both = QuickVideoCutterEngine.buildAudioProcessingFilters(
            options: VideoAudioProcessingOptions(loudnessNormalize: true, trimSilence: true)
        )
        XCTAssertEqual(both.count, 2)

        let inputURL = URL(fileURLWithPath: "/tmp/video.mp4")

        // .m4a with loudnorm
        let m4aArgs = try QuickVideoCutterEngine.buildExtractAudioArguments(
            inputURL: inputURL,
            outputURL: URL(fileURLWithPath: "/tmp/out.m4a"),
            format: .m4a,
            audioProcessing: VideoAudioProcessingOptions(loudnessNormalize: true)
        )
        XCTAssertTrue(m4aArgs.contains("-vn"))
        XCTAssertTrue(m4aArgs.contains("-sn"))
        XCTAssertTrue(m4aArgs.contains("aac"))
        XCTAssertTrue(m4aArgs.contains("256k"))
        let afIdx = try XCTUnwrap(m4aArgs.firstIndex(of: "-af"))
        XCTAssertEqual(m4aArgs[afIdx + 1], "loudnorm=I=-16:TP=-1.5:LRA=11")

        // .mp3 with multi-segment trim + silenceremove
        let mp3Args = try QuickVideoCutterEngine.buildExtractAudioArguments(
            inputURL: inputURL,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp3"),
            format: .mp3,
            segments: [
                VideoSegment(startSeconds: 0.0, endSeconds: 1.5, isKept: true),
                VideoSegment(startSeconds: 2.5, endSeconds: 4.0, isKept: true)
            ],
            audioProcessing: VideoAudioProcessingOptions(trimSilence: true)
        )
        XCTAssertTrue(mp3Args.contains("libmp3lame"))
        XCTAssertTrue(mp3Args.contains("-q:a"))
        XCTAssertTrue(mp3Args.contains("2"))
        let audioFcIdx = try XCTUnwrap(mp3Args.firstIndex(of: "-filter_complex"))
        XCTAssertTrue(mp3Args[audioFcIdx + 1].contains("concat=n=2:v=0:a=1"))
        XCTAssertTrue(mp3Args[audioFcIdx + 1].contains("silenceremove="))

        // .wav direct
        let wavArgs = try QuickVideoCutterEngine.buildExtractAudioArguments(
            inputURL: inputURL,
            outputURL: URL(fileURLWithPath: "/tmp/out.wav"),
            format: .wav
        )
        XCTAssertTrue(wavArgs.contains("pcm_s16le"))
        XCTAssertFalse(wavArgs.contains("-af"))

        // Compressed MP4 includes loudnorm/silenceremove when unmuted, excludes when muted
        let mp4WithAudioFX = try QuickVideoCutterEngine.buildCompressedMP4Arguments(
            inputURL: inputURL,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            segments: [VideoSegment(startSeconds: 0, endSeconds: 2, isKept: true)],
            hasAudio: true,
            isMuted: false,
            audioProcessing: VideoAudioProcessingOptions(loudnessNormalize: true, trimSilence: true)
        )
        let mp4FcIdx = try XCTUnwrap(mp4WithAudioFX.firstIndex(of: "-filter_complex"))
        XCTAssertTrue(mp4WithAudioFX[mp4FcIdx + 1].contains("loudnorm=I=-16:TP=-1.5:LRA=11"))
        XCTAssertTrue(mp4WithAudioFX[mp4FcIdx + 1].contains("silenceremove="))

        let mp4MutedFX = try QuickVideoCutterEngine.buildCompressedMP4Arguments(
            inputURL: inputURL,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            segments: [VideoSegment(startSeconds: 0, endSeconds: 2, isKept: true)],
            hasAudio: true,
            isMuted: true,
            audioProcessing: VideoAudioProcessingOptions(loudnessNormalize: true, trimSilence: true)
        )
        let mp4MutedFcIdx = try XCTUnwrap(mp4MutedFX.firstIndex(of: "-filter_complex"))
        XCTAssertFalse(mp4MutedFX[mp4MutedFcIdx + 1].contains("loudnorm"))
        XCTAssertTrue(mp4MutedFX.contains("-an"))
    }

    // MARK: - 5. 3x3 Contact Sheet PNG Arguments

    func testContactSheet3x3ArgumentsAndDefaultNaming() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/demo_clip.mp4")
        let outURL = URL(fileURLWithPath: "/tmp/demo_clip_contact_sheet.png")
        let args = QuickVideoCutterEngine.buildContactSheetArguments(
            inputURL: inputURL,
            outputURL: outURL,
            durationSeconds: 18.0,
            rotation: .deg90,
            cropConfiguration: VideoCropConfiguration(aspectRatio: .square1x1),
            sourceWidth: 1920,
            sourceHeight: 1080,
            tileWidth: 320,
            padding: 6,
            margin: 10
        )

        let vfIdx = try XCTUnwrap(args.firstIndex(of: "-vf"))
        let vf = args[vfIdx + 1]
        XCTAssertTrue(vf.contains("fps=0.500000"))
        XCTAssertTrue(vf.contains("transpose=1"))
        XCTAssertTrue(vf.contains("crop=1080:1080:"))
        XCTAssertTrue(vf.contains("scale=320:-1:flags=lanczos"))
        XCTAssertTrue(vf.contains("tile=3x3:padding=6:margin=10:color=black"))
        XCTAssertTrue(args.contains("-frames:v"))
        XCTAssertTrue(args.contains("1"))
        XCTAssertTrue(args.contains("png"))
        XCTAssertEqual(args.last, outURL.path)

        let defaultSheet = QuickVideoCutterEngine.defaultContactSheetURL(for: inputURL, in: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(defaultSheet.lastPathComponent.hasSuffix("_contact_sheet.png"))

        let defaultAudio = QuickVideoCutterEngine.defaultExtractAudioURL(for: inputURL, format: .mp3, in: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(defaultAudio.lastPathComponent.hasSuffix("_audio.mp3"))
    }

    // MARK: - 6. Atomic Output Commit & Failure Cleanup (LC-001)

    func testAtomicCommitAndTempCleanupOnFailure() throws {
        let sandbox = try makeSandbox(name: "atomic")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let destURL = sandbox.appendingPathComponent("output.mp4")
        let originalBytes = Data("EXISTING_OUTPUT".utf8)
        try originalBytes.write(to: destURL)

        let stagedURL = sandbox.appendingPathComponent("staged.mp4")
        let newBytes = Data("NEW_VIDEO_STUDIO_OUTPUT".utf8)
        try newBytes.write(to: stagedURL)

        // Faulty move must restore backup and leave original untouched
        let failingOps = OutputReservationCoordinator.AtomicPublishFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            isSameVolume: { _, _ in false },
            copyItem: { src, dst in try FileManager.default.copyItem(at: src, to: dst) },
            moveItem: { src, dst in
                if src.lastPathComponent.contains(".stage-") && dst == destURL {
                    throw NSError(domain: "M13Fault", code: 99)
                }
                try FileManager.default.moveItem(at: src, to: dst)
            },
            replaceItemAt: { _, _ in throw NSError(domain: "M13Fault", code: 100) },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )

        XCTAssertThrowsError(
            try OutputReservationCoordinator.moveOrReplaceTempFile(
                stagedURL,
                to: destURL,
                policy: .overwrite,
                operations: failingOps
            )
        )
        XCTAssertEqual(try Data(contentsOf: destURL), originalBytes)

        let committed = try OutputReservationCoordinator.moveOrReplaceTempFile(
            stagedURL,
            to: destURL,
            policy: .overwrite
        )
        XCTAssertEqual(committed, destURL)
        XCTAssertEqual(try Data(contentsOf: destURL), newBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    // MARK: - 7. End-to-End Bundled FFmpeg Verification (Crop, Subtitle, Contact Sheet, Join, Extract Audio)

    func testEndToEndVideoStudioPipelinesWithBundledFFmpeg() async throws {
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpegPath = await provider.findFFmpegPath(),
              let ffprobePath = await provider.findFFprobePath() else {
            throw XCTSkip("Bundled FFmpeg/FFprobe unavailable in test environment.")
        }

        let sandbox = try makeSandbox(name: "e2e")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let clip1URL = sandbox.appendingPathComponent("clip1.mp4")
        let clip2URL = sandbox.appendingPathComponent("clip2.mp4")
        try await createSyntheticMP4(at: clip1URL, width: 192, height: 108, frameCount: 18, fps: 10, includeAudio: true)
        try await createSyntheticMP4(at: clip2URL, width: 128, height: 96, frameCount: 12, fps: 10, includeAudio: false)

        let srcHash1 = try sha256Hex(of: clip1URL)
        let srcHash2 = try sha256Hex(of: clip2URL)

        let srtURL = sandbox.appendingPathComponent("captions.srt")
        try """
        1
        00:00:00,100 --> 00:00:01,500
        LocalConvert Studio Test
        """.write(to: srtURL, atomically: true, encoding: .utf8)

        // A. Crop 1:1 + SRT subtitle burn-in + loudnorm
        let cropCentered = VideoCropConfiguration.centeredNormalizedRect(for: .square1x1, sourceWidth: 192, sourceHeight: 108)
        let croppedOut = try await QuickVideoCutterEngine.export(
            QuickVideoExportRequest(
                inputURL: clip1URL,
                destinationURL: sandbox.appendingPathComponent("cropped_subbed.mp4"),
                segments: [VideoSegment(startSeconds: 0.0, endSeconds: 1.6, isKept: true)],
                mode: .compressedMP4,
                cropConfiguration: VideoCropConfiguration(aspectRatio: .square1x1, normalizedRect: cropCentered),
                subtitleURL: srtURL,
                audioProcessing: VideoAudioProcessingOptions(loudnessNormalize: true)
            ),
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath
        )
        let croppedInfo = try await MediaProbe.probe(url: croppedOut, ffprobePath: ffprobePath)
        XCTAssertTrue(croppedInfo.hasRealVideo)
        XCTAssertTrue(croppedInfo.hasAudio)
        XCTAssertEqual(croppedInfo.primaryVideoStream?.width, 108)
        XCTAssertEqual(croppedInfo.primaryVideoStream?.height, 108)

        // B. 3x3 Contact Sheet PNG
        let sheetOut = try await QuickVideoCutterEngine.generateContactSheet(
            from: clip1URL,
            to: sandbox.appendingPathComponent("sheet.png"),
            tileWidth: 160,
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath
        )
        let sheetSource = try XCTUnwrap(CGImageSourceCreateWithURL(sheetOut as CFURL, nil))
        let sheetImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sheetSource, 0, nil))
        XCTAssertGreaterThanOrEqual(sheetImage.width, 480)
        XCTAssertGreaterThanOrEqual(sheetImage.height, 270)

        // C. Multi-Clip Join (heterogeneous resolutions & audio presence)
        let joinedOut = try await QuickVideoCutterEngine.joinClips(
            MultiClipJoinRequest(
                clipURLs: [clip1URL, clip2URL],
                destinationURL: sandbox.appendingPathComponent("joined.mp4")
            ),
            ffmpegPath: ffmpegPath,
            ffprobePath: ffprobePath
        )
        let joinedInfo = try await MediaProbe.probe(url: joinedOut, ffprobePath: ffprobePath)
        XCTAssertTrue(joinedInfo.hasRealVideo)
        XCTAssertTrue(joinedInfo.hasAudio)
        XCTAssertGreaterThan(joinedInfo.duration, 2.5)

        // D. 1-Click Extract Audio (.m4a, .mp3, .wav)
        for fmt in VideoExtractAudioFormat.allCases {
            let audioOut = try await QuickVideoCutterEngine.extractAudio(
                from: clip1URL,
                to: sandbox.appendingPathComponent("extracted.\(fmt.fileExtension)"),
                format: fmt,
                audioProcessing: VideoAudioProcessingOptions(loudnessNormalize: true, trimSilence: false),
                ffmpegPath: ffmpegPath,
                ffprobePath: ffprobePath
            )
            let audioInfo = try await MediaProbe.probe(url: audioOut, ffprobePath: ffprobePath)
            XCTAssertTrue(audioInfo.hasAudio)
            XCTAssertFalse(audioInfo.hasRealVideo)
        }

        // Source clips remain untouched and no staging dirs leaked
        XCTAssertEqual(try sha256Hex(of: clip1URL), srcHash1)
        XCTAssertEqual(try sha256Hex(of: clip2URL), srcHash2)
        let tmpItems = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        let leaked = tmpItems.filter { $0.hasPrefix("LocalConvert-VideoCutter-") }
        XCTAssertTrue(leaked.isEmpty, "Temporary staging directories leaked: \(leaked)")
    }

    // MARK: - 8. LC-019 820x580 Layout Check

    func testVideoViewerEditorViewLayoutsWithin820x580Bounds() {
        let sampleURL = URL(fileURLWithPath: "/tmp/nonexistent_m13_video.mp4")
        let view = VideoViewerEditorView(url: sampleURL)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: AppTheme.Layout.minWindowWidth, height: AppTheme.Layout.minWindowHeight)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(hosting.fittingSize.width.isNaN || hosting.fittingSize.height.isNaN)
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, AppTheme.Layout.minWindowWidth)
        XCTAssertLessThanOrEqual(hosting.fittingSize.height, AppTheme.Layout.minWindowHeight)
    }
}

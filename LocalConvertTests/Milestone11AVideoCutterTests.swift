import XCTest
import Foundation
import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone11AVideoCutterTests: XCTestCase {

    // MARK: - Helpers

    private func makeSandbox(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("M11AVideoCutter-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func createSyntheticMP4WithAVAssetWriter(
        at outputURL: URL,
        width: Int = 96,
        height: Int = 64,
        frameCount: Int = 20,
        fps: Int32 = 10
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
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelAttrs
        )

        XCTAssertTrue(writer.canAdd(writerInput))
        writer.add(writerInput)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !writerInput.isReadyForMoreMediaData {
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
                let green = UInt8(120)
                let red = UInt8(220)
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

        writerInput.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "AVAssetWriter failed: \(writer.error?.localizedDescription ?? "unknown")")
    }

    // MARK: - 1. Multi-Segment Splitting, In/Out Clamping & Middle Segment Removal

    func testSegmentSplittingInOutClampingAndMiddleRemovalMath() throws {
        let totalDuration = 10.0
        var segments = QuickVideoCutterEngine.initialSegments(durationSeconds: totalDuration)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endSeconds, 10.0, accuracy: 0.001)
        XCTAssertTrue(segments[0].isKept)

        // Split near boundary (< 0.10s) must be rejected without mutating segments
        let nearStart = QuickVideoCutterEngine.splitSegment(at: 0.04, in: segments)
        XCTAssertEqual(nearStart.count, 1)
        let nearEnd = QuickVideoCutterEngine.splitSegment(at: 9.96, in: segments)
        XCTAssertEqual(nearEnd.count, 1)

        // Split at 3.0s and 7.0s -> 3 segments: [0,3], [3,7], [7,10]
        segments = QuickVideoCutterEngine.splitSegment(at: 3.0, in: segments)
        XCTAssertEqual(segments.count, 2)
        segments = QuickVideoCutterEngine.splitSegment(at: 7.0, in: segments)
        XCTAssertEqual(segments.count, 3)

        XCTAssertEqual(segments[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].startSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].endSeconds, 7.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].startSeconds, 7.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].endSeconds, 10.0, accuracy: 0.001)

        // Delete middle segment [3,7] -> kept segments are sorted, non-overlapping [0,3] and [7,10]
        let middleID = segments[1].id
        segments = QuickVideoCutterEngine.deleteSegment(id: middleID, in: segments)
        let keptAfterDelete = try QuickVideoCutterEngine.normalizedKeptSegments(from: segments, totalDuration: totalDuration)
        XCTAssertEqual(keptAfterDelete.count, 2)
        XCTAssertEqual(keptAfterDelete[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(keptAfterDelete[0].endSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(keptAfterDelete[1].startSeconds, 7.0, accuracy: 0.001)
        XCTAssertEqual(keptAfterDelete[1].endSeconds, 10.0, accuracy: 0.001)
        XCTAssertEqual(QuickVideoCutterEngine.totalKeptDurationSeconds(in: segments), 6.0, accuracy: 0.001)

        // Set In on segment 0 to -2.0 -> clamped to 0.0; then to 1.25 -> 1.25
        segments = QuickVideoCutterEngine.setInPoint(at: -2.0, selectedSegmentID: segments[0].id, in: segments, totalDuration: totalDuration)
        XCTAssertEqual(segments[0].startSeconds, 0.0, accuracy: 0.001)
        segments = QuickVideoCutterEngine.setInPoint(at: 1.25, selectedSegmentID: segments[0].id, in: segments, totalDuration: totalDuration)
        XCTAssertEqual(segments[0].startSeconds, 1.25, accuracy: 0.001)

        // Set In past segment 0 end - minDuration (e.g. 2.98) -> clamped to 2.90
        segments = QuickVideoCutterEngine.setInPoint(at: 2.98, selectedSegmentID: segments[0].id, in: segments, totalDuration: totalDuration)
        XCTAssertEqual(segments[0].startSeconds, 2.90, accuracy: 0.001)

        // Set Out on segment 2 past totalDuration (15.0) -> clamped to 10.0; then 8.5 -> 8.5
        segments = QuickVideoCutterEngine.setOutPoint(at: 15.0, selectedSegmentID: segments[2].id, in: segments, totalDuration: totalDuration)
        XCTAssertEqual(segments[2].endSeconds, 10.0, accuracy: 0.001)
        segments = QuickVideoCutterEngine.setOutPoint(at: 8.5, selectedSegmentID: segments[2].id, in: segments, totalDuration: totalDuration)
        XCTAssertEqual(segments[2].endSeconds, 8.5, accuracy: 0.001)

        // Set Out on segment 2 before segment 1 end (5.0) -> clamped to next/prev boundary >= 7.10
        segments = QuickVideoCutterEngine.setOutPoint(at: 5.0, selectedSegmentID: segments[2].id, in: segments, totalDuration: totalDuration)
        XCTAssertEqual(segments[2].endSeconds, 7.10, accuracy: 0.001)

        // Prevent emptying kept set when only 1 kept segment remains
        segments = QuickVideoCutterEngine.deleteSegment(id: segments[0].id, in: segments)
        XCTAssertEqual(segments.filter(\.isKept).count, 1)
        let lastKeptID = try XCTUnwrap(segments.first(where: \.isKept)?.id)
        segments = QuickVideoCutterEngine.toggleSegmentKept(id: lastKeptID, in: segments)
        XCTAssertEqual(segments.filter(\.isKept).count, 1, "Must never allow empty kept segment set")

        // Verify CMTimeRange conversion
        let lastKept = try XCTUnwrap(segments.first(where: \.isKept))
        XCTAssertEqual(CMTimeGetSeconds(lastKept.cmTimeRange.start), lastKept.startSeconds, accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(lastKept.cmTimeRange.duration), lastKept.durationSeconds, accuracy: 0.01)
    }

    func testNormalizedKeptSegmentsRejectsEmptyOrOverlappingRanges() {
        let empty: [VideoSegment] = [
            VideoSegment(startSeconds: 0, endSeconds: 2, isKept: false)
        ]
        XCTAssertThrowsError(try QuickVideoCutterEngine.normalizedKeptSegments(from: empty))

        let overlapping: [VideoSegment] = [
            VideoSegment(startSeconds: 0, endSeconds: 3, isKept: true),
            VideoSegment(startSeconds: 2.5, endSeconds: 5, isKept: true)
        ]
        XCTAssertThrowsError(try QuickVideoCutterEngine.normalizedKeptSegments(from: overlapping))
    }

    // MARK: - 2. Pure FFmpeg Command Construction

    func testFFmpegArgumentBuildersForCutConcatCompressedMP4AndGIF() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/input clip.mp4")
        let outputMP4 = URL(fileURLWithPath: "/tmp/output clip.mp4")
        let outputGIF = URL(fileURLWithPath: "/tmp/output clip.gif")
        let concatListURL = URL(fileURLWithPath: "/tmp/concat.txt")

        let seg1 = VideoSegment(startSeconds: 1.0, endSeconds: 3.5, isKept: true)
        let deleted = VideoSegment(startSeconds: 3.5, endSeconds: 5.0, isKept: false)
        let seg2 = VideoSegment(startSeconds: 5.0, endSeconds: 8.0, isKept: true)

        // Single-segment lossless cut (muted)
        let singleCutArgs = try QuickVideoCutterEngine.buildCutArguments(
            inputURL: inputURL,
            outputURL: outputMP4,
            segments: [seg1, deleted],
            isMuted: true
        )
        XCTAssertTrue(singleCutArgs.contains("-ss"))
        XCTAssertTrue(singleCutArgs.contains("00:00:01.000"))
        XCTAssertTrue(singleCutArgs.contains("-t"))
        XCTAssertTrue(singleCutArgs.contains("00:00:02.500"))
        XCTAssertTrue(singleCutArgs.contains("-c"))
        XCTAssertTrue(singleCutArgs.contains("copy"))
        XCTAssertTrue(singleCutArgs.contains("-an"))
        XCTAssertTrue(singleCutArgs.contains("-avoid_negative_ts"))
        XCTAssertTrue(singleCutArgs.contains("make_zero"))
        XCTAssertTrue(singleCutArgs.contains("+faststart"))
        XCTAssertEqual(singleCutArgs.last, outputMP4.path)

        // Multi-segment lossless concat
        let concatFileText = QuickVideoCutterEngine.formatConcatListFile(segmentURLs: [
            URL(fileURLWithPath: "/tmp/part'0.mp4"),
            URL(fileURLWithPath: "/tmp/part 1.mp4")
        ])
        XCTAssertTrue(concatFileText.contains("file '/tmp/part'\\''0.mp4'"))
        XCTAssertTrue(concatFileText.contains("file '/tmp/part 1.mp4'"))

        let multiConcatArgs = try QuickVideoCutterEngine.buildCutArguments(
            inputURL: inputURL,
            outputURL: outputMP4,
            segments: [seg1, deleted, seg2],
            concatListURL: concatListURL,
            isMuted: false
        )
        XCTAssertTrue(multiConcatArgs.contains("-f"))
        XCTAssertTrue(multiConcatArgs.contains("concat"))
        XCTAssertTrue(multiConcatArgs.contains("-safe"))
        XCTAssertTrue(multiConcatArgs.contains("0"))
        XCTAssertTrue(multiConcatArgs.contains(concatListURL.path))
        XCTAssertTrue(multiConcatArgs.contains("copy"))
        XCTAssertFalse(multiConcatArgs.contains("-an"))

        // Compressed MP4 with 2 kept segments, 90° rotation, 1.5x speed, audio included
        let mp4Args = try QuickVideoCutterEngine.buildCompressedMP4Arguments(
            inputURL: inputURL,
            outputURL: outputMP4,
            segments: [seg1, deleted, seg2],
            hasAudio: true,
            isMuted: false,
            rotation: .deg90,
            speedMultiplier: 1.5
        )
        let fcIdx = try XCTUnwrap(mp4Args.firstIndex(of: "-filter_complex"))
        let fcGraph = mp4Args[fcIdx + 1]
        XCTAssertTrue(fcGraph.contains("trim=start=1.000:end=3.500"))
        XCTAssertTrue(fcGraph.contains("trim=start=5.000:end=8.000"))
        XCTAssertTrue(fcGraph.contains("concat=n=2:v=1:a=1"))
        XCTAssertTrue(fcGraph.contains("transpose=1"))
        XCTAssertTrue(fcGraph.contains("setpts="))
        XCTAssertTrue(fcGraph.contains("atempo=1.5000"))
        XCTAssertTrue(mp4Args.contains("h264_videotoolbox"))
        XCTAssertTrue(mp4Args.contains("aac"))

        // Compressed MP4 muted with 270° rotation
        let mutedMP4Args = try QuickVideoCutterEngine.buildCompressedMP4Arguments(
            inputURL: inputURL,
            outputURL: outputMP4,
            segments: [seg1],
            hasAudio: true,
            isMuted: true,
            rotation: .deg270,
            speedMultiplier: 0.5
        )
        let mutedFcIdx = try XCTUnwrap(mutedMP4Args.firstIndex(of: "-filter_complex"))
        let mutedFc = mutedMP4Args[mutedFcIdx + 1]
        XCTAssertTrue(mutedFc.contains("transpose=2"))
        XCTAssertTrue(mutedFc.contains("setpts=2.000000*PTS"))
        XCTAssertFalse(mutedFc.contains("atempo"))
        XCTAssertTrue(mutedMP4Args.contains("-an"))

        // Animated GIF with palettegen/paletteuse, 180° rotation, 2.0x speed
        let gifArgs = try QuickVideoCutterEngine.buildGIFArguments(
            inputURL: inputURL,
            outputURL: outputGIF,
            segments: [seg1, deleted, seg2],
            rotation: .deg180,
            speedMultiplier: 2.0,
            fps: 12,
            maxWidth: 480
        )
        let gifFcIdx = try XCTUnwrap(gifArgs.firstIndex(of: "-filter_complex"))
        let gifFc = gifArgs[gifFcIdx + 1]
        XCTAssertTrue(gifFc.contains("concat=n=2:v=1:a=0"))
        XCTAssertTrue(gifFc.contains("transpose=1,transpose=1"))
        XCTAssertTrue(gifFc.contains("setpts=0.500000*PTS"))
        XCTAssertTrue(gifFc.contains("fps=12"))
        XCTAssertTrue(gifFc.contains("scale=min(480\\,iw):-1:flags=lanczos"))
        XCTAssertTrue(gifFc.contains("palettegen"))
        XCTAssertTrue(gifFc.contains("paletteuse"))
        XCTAssertTrue(gifArgs.contains("-an"))
        XCTAssertEqual(gifArgs.last, outputGIF.path)
    }

    // MARK: - 3. Frame Snapshot Export (PNG & JPEG) from Programmatic AVAsset

    func testFrameSnapshotExportPNGAndJPEGWithRotation() async throws {
        let sandbox = try makeSandbox(name: "snapshot")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let videoURL = sandbox.appendingPathComponent("synthetic.mp4")
        try await createSyntheticMP4WithAVAssetWriter(at: videoURL, width: 96, height: 64, frameCount: 15, fps: 10)
        let srcHash = try sha256Hex(of: videoURL)

        let pngDest = sandbox.appendingPathComponent("frame.png")
        let exportedPNG = try await QuickVideoCutterEngine.exportFrameSnapshot(
            from: videoURL,
            atSeconds: 0.5,
            to: pngDest,
            format: .png,
            rotation: .deg0,
            existingFileHandling: .createUnique
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedPNG.path))
        let pngSource = try XCTUnwrap(CGImageSourceCreateWithURL(exportedPNG as CFURL, nil))
        let pngImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
        XCTAssertEqual(pngImage.width, 96)
        XCTAssertEqual(pngImage.height, 64)

        let jpegDest = sandbox.appendingPathComponent("frame_rotated.jpg")
        let exportedJPEG = try await QuickVideoCutterEngine.exportFrameSnapshot(
            from: videoURL,
            atSeconds: 0.5,
            to: jpegDest,
            format: .jpeg,
            rotation: .deg90,
            existingFileHandling: .createUnique
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedJPEG.path))
        let jpegSource = try XCTUnwrap(CGImageSourceCreateWithURL(exportedJPEG as CFURL, nil))
        let jpegImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil))
        XCTAssertEqual(jpegImage.width, 64)
        XCTAssertEqual(jpegImage.height, 96)

        // Source video must remain untouched
        XCTAssertEqual(try sha256Hex(of: videoURL), srcHash)
    }

    // MARK: - 4. Atomic Output Commit & Failure Preservation (LC-001)

    func testAtomicPublishPreservesOriginalOnFailureAndReplacesAtomicallyOnSuccess() throws {
        let sandbox = try makeSandbox(name: "atomic")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let destURL = sandbox.appendingPathComponent("existing.mp4")
        let originalBytes = Data("ORIGINAL_VIDEO_BYTES".utf8)
        try originalBytes.write(to: destURL)

        let tempURL = sandbox.appendingPathComponent("staged_new.mp4")
        let replacementBytes = Data("NEW_EDITED_BYTES".utf8)
        try replacementBytes.write(to: tempURL)

        // 1. Non-overwrite policy must reject overwriting existing destination and preserve original
        XCTAssertThrowsError(
            try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempURL,
                to: destURL,
                policy: .createUnique
            )
        ) { error in
            guard case ConversionError.outputFileAlreadyExists(let errURL) = error else {
                XCTFail("Expected outputFileAlreadyExists, got \(error)")
                return
            }
            XCTAssertEqual(errURL, destURL)
        }
        XCTAssertEqual(try Data(contentsOf: destURL), originalBytes)

        // 2. Simulated failure during .overwrite fallback must restore backup and preserve original bytes
        let failingOps = OutputReservationCoordinator.AtomicPublishFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            isSameVolume: { _, _ in false },
            copyItem: { src, dst in try FileManager.default.copyItem(at: src, to: dst) },
            moveItem: { src, dst in
                if src.lastPathComponent.contains(".stage-") && dst == destURL {
                    throw NSError(domain: "TestFault", code: 42)
                }
                try FileManager.default.moveItem(at: src, to: dst)
            },
            replaceItemAt: { _, _ in throw NSError(domain: "TestFault", code: 43) },
            removeItem: { url in try FileManager.default.removeItem(at: url) }
        )

        XCTAssertThrowsError(
            try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempURL,
                to: destURL,
                policy: .overwrite,
                operations: failingOps
            )
        )
        XCTAssertEqual(try Data(contentsOf: destURL), originalBytes)

        // 3. Live .overwrite succeeds atomically
        let committed = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempURL,
            to: destURL,
            policy: .overwrite
        )
        XCTAssertEqual(committed, destURL)
        XCTAssertEqual(try Data(contentsOf: destURL), replacementBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    // MARK: - 5. End-to-End Video Export & Interface Contract Verification

    func testVideoViewerEditorViewInitializerSignature() {
        let sampleURL = URL(fileURLWithPath: "/tmp/nonexistent_sample.mp4")
        let defaultView = VideoViewerEditorView(url: sampleURL)
        let fullView = VideoViewerEditorView(
            url: sampleURL,
            onSendToConvertQueue: { _ in },
            onDismiss: {}
        )
        XCTAssertNotNil(defaultView)
        XCTAssertNotNil(fullView)
    }

    func testEndToEndMultiSegmentCutAndGIFExportWithBundledFFmpeg() async throws {
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpegPath = await provider.findFFmpegPath(),
              let ffprobePath = await provider.findFFprobePath() else {
            throw XCTSkip("Bundled FFmpeg/FFprobe unavailable in test environment.")
        }

        let sandbox = try makeSandbox(name: "e2e")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let videoURL = sandbox.appendingPathComponent("clip.mp4")
        try await createSyntheticMP4WithAVAssetWriter(at: videoURL, width: 128, height: 96, frameCount: 30, fps: 10)
        let srcHash = try sha256Hex(of: videoURL)

        let segments = [
            VideoSegment(startSeconds: 0.0, endSeconds: 0.9, isKept: true),
            VideoSegment(startSeconds: 0.9, endSeconds: 1.8, isKept: false),
            VideoSegment(startSeconds: 1.8, endSeconds: 2.8, isKept: true)
        ]

        // Compressed MP4 multi-segment export with rotation & speed
        let mp4Dest = sandbox.appendingPathComponent("clip_edited.mp4")
        let mp4Req = QuickVideoExportRequest(
            inputURL: videoURL,
            destinationURL: mp4Dest,
            segments: segments,
            mode: .compressedMP4,
            isMuted: true,
            rotation: .deg90,
            speedMultiplier: 1.0,
            existingFileHandling: .createUnique
        )
        let mp4Out = try await QuickVideoCutterEngine.export(mp4Req, ffmpegPath: ffmpegPath, ffprobePath: ffprobePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4Out.path))
        let mp4Info = try await MediaProbe.probe(url: mp4Out, ffprobePath: ffprobePath)
        XCTAssertTrue(mp4Info.hasRealVideo)
        XCTAssertFalse(mp4Info.hasAudio)
        XCTAssertEqual(mp4Info.primaryVideoStream?.width, 96)
        XCTAssertEqual(mp4Info.primaryVideoStream?.height, 128)

        // Quick GIF export
        let gifDest = sandbox.appendingPathComponent("clip_export.gif")
        let gifReq = QuickVideoExportRequest(
            inputURL: videoURL,
            destinationURL: gifDest,
            segments: segments,
            mode: .quickGIF,
            isMuted: true,
            rotation: .deg0,
            speedMultiplier: 1.5,
            existingFileHandling: .createUnique,
            gifFPS: 10,
            gifMaxWidth: 160
        )
        let gifOut = try await QuickVideoCutterEngine.export(gifReq, ffmpegPath: ffmpegPath, ffprobePath: ffprobePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gifOut.path))
        let gifInfo = try await MediaProbe.probe(url: gifOut, ffprobePath: ffprobePath)
        XCTAssertTrue(gifInfo.hasVideo)

        // Source untouched & no leaked VideoCutter temp dirs
        XCTAssertEqual(try sha256Hex(of: videoURL), srcHash)
        let tmpItems = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        let leaked = tmpItems.filter { $0.hasPrefix("LocalConvert-VideoCutter-") }
        XCTAssertTrue(leaked.isEmpty, "Temporary staging directories leaked: \(leaked)")
    }
}

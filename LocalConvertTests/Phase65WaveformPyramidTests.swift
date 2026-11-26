import XCTest
import AVFoundation
import os
@testable import LocalConvert

final class Phase65WaveformPyramidTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase65-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDownWithError() throws {
        OutputReservationCoordinator.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        StructuredDiagnostics.clearRecentEvents()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Helpers

    /// Writes a canonical RIFF/WAVE IEEE Float32 (`formatTag = 3`) file supporting arbitrary channel counts (`1...8`)
    /// and exact per-sample values (including impulses and `>= 1.0` clipping peaks).
    private func writeFloatWAV(
        to url: URL,
        sampleRate: Int32 = 48_000,
        channels: Int,
        frameCount: Int,
        generator: (_ frame: Int, _ channel: Int) -> Float
    ) throws {
        var pcm = Data()
        let dataByteCount = frameCount * channels * 4
        pcm.reserveCapacity(44 + dataByteCount)

        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }

        let blockAlign = UInt16(channels * 4)
        let byteRate = UInt32(Int(sampleRate) * Int(blockAlign))

        pcm.append(contentsOf: "RIFF".utf8)
        appendU32(UInt32(36 + dataByteCount))
        pcm.append(contentsOf: "WAVE".utf8)
        pcm.append(contentsOf: "fmt ".utf8)
        appendU32(16)
        appendU16(3) // IEEE Float
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(32)
        pcm.append(contentsOf: "data".utf8)
        appendU32(UInt32(dataByteCount))

        for f in 0..<frameCount {
            for ch in 0..<channels {
                var le = generator(f, ch).bitPattern.littleEndian
                withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
            }
        }
        try pcm.write(to: url, options: .atomic)
    }

    // MARK: - 1. Mip Levels Accuracy (64 / 256 / 1024 / 4096 / 16384), Clipping & Empty Safety

    func testAllFiveMipLevelsAccuracySineImpulseClippedAndEmpty() async throws {
        let diskCache = LCWaveDiskCache(directory: AppStoragePaths.audioWaveformCacheDirectory)
        let service = WaveformPyramidService(diskCache: diskCache)

        // 32,768 stereo frames: distinct per-channel signal, impulse + clipped spike in ch0 bucket 200
        let totalFrames = 32_768
        let url = sandbox.temporaryURL.appendingPathComponent("mip_accuracy.wav")
        try writeFloatWAV(to: url, sampleRate: 48_000, channels: 2, frameCount: totalFrames) { frame, ch in
            if ch == 0 && frame == 12_805 { // belongs to L0 bucket 12805/64 == 200
                return 1.05
            }
            if ch == 1 {
                return -0.25
            }
            let phase = 2.0 * Double.pi * 440.0 * Double(frame) / 48_000.0
            return Float(0.5 * sin(phase))
        }

        let pyramid = try await service.pyramid(for: url)
        XCTAssertEqual(pyramid.sampleRate, 48_000)
        XCTAssertEqual(pyramid.channelCount, 2)
        XCTAssertEqual(pyramid.totalFrames, Int64(totalFrames))
        XCTAssertEqual(pyramid.levels.map(\.framesPerBucket), [64, 256, 1024, 4096, 16_384])

        XCTAssertEqual(pyramid.levels[0].bucketCount, 512)
        XCTAssertEqual(pyramid.levels[1].bucketCount, 128)
        XCTAssertEqual(pyramid.levels[2].bucketCount, 32)
        XCTAssertEqual(pyramid.levels[3].bucketCount, 8)
        XCTAssertEqual(pyramid.levels[4].bucketCount, 2)

        // Check clipped spike bucket propagates across all 5 mip levels only on channel 0
        XCTAssertTrue(pyramid.levels[0].channels[0].buckets[200].clipped)
        XCTAssertFalse(pyramid.levels[0].channels[1].buckets[200].clipped)
        XCTAssertTrue(pyramid.levels[1].channels[0].buckets[200 / 4].clipped)
        XCTAssertTrue(pyramid.levels[2].channels[0].buckets[200 / 16].clipped)
        XCTAssertTrue(pyramid.levels[3].channels[0].buckets[200 / 64].clipped)
        XCTAssertTrue(pyramid.levels[4].channels[0].buckets[200 / 256].clipped)

        // Constant -0.25 channel 1 should have exact min = max = -0.25, rms = 0.25 across every mip level
        for level in pyramid.levels {
            let bucket = level.channels[1].buckets[0]
            XCTAssertEqual(bucket.minSample, -0.25, accuracy: 1e-5)
            XCTAssertEqual(bucket.maxSample, -0.25, accuracy: 1e-5)
            XCTAssertEqual(bucket.rms, 0.25, accuracy: 1e-5)
            XCTAssertFalse(bucket.clipped)
        }

        // Empty (0-frame) WAV returns valid 5-level empty pyramid cleanly
        let emptyURL = sandbox.temporaryURL.appendingPathComponent("empty.wav")
        try writeFloatWAV(to: emptyURL, sampleRate: 48_000, channels: 2, frameCount: 0) { _, _ in 0 }
        let emptyPyramid = try await service.pyramid(for: emptyURL)
        XCTAssertEqual(emptyPyramid.totalFrames, 0)
        XCTAssertEqual(emptyPyramid.levels.map(\.framesPerBucket), [64, 256, 1024, 4096, 16_384])
        for level in emptyPyramid.levels {
            XCTAssertEqual(level.bucketCount, 0)
        }
    }

    func testBestLevelSelectionAndInvalidThresholds() {
        let pyramid = WaveformPyramid.empty(cacheKey: "k", sampleRate: 48_000, channelCount: 2)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 10)?.framesPerBucket, 64)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 64)?.framesPerBucket, 64)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 255)?.framesPerBucket, 64)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 256)?.framesPerBucket, 256)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 1_500)?.framesPerBucket, 1_024)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 8_000)?.framesPerBucket, 4_096)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 25_000)?.framesPerBucket, 16_384)

        // Edge safety
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: 0)?.framesPerBucket, 64)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: -50)?.framesPerBucket, 64)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: .nan)?.framesPerBucket, 64)
        XCTAssertEqual(pyramid.bestLevel(forSamplesPerPixel: .infinity)?.framesPerBucket, 16_384)

        let zeroLevels = WaveformPyramid(
            cacheKey: "empty",
            sampleRate: 48_000,
            channelCount: 2,
            totalFrames: 0,
            duration: 0,
            levels: [],
            isPartial: false,
            completedFrames: 0
        )
        XCTAssertNil(zeroLevels.bestLevel(forSamplesPerPixel: 256))
    }

    // MARK: - 2. Mandatory Dual PCM Chunk-Limit Boundaries (Float32 / Int16 / Float64, Interleaved & Planar)

    func testDualPCMChunkLimitExactBoundariesAndRejections() throws {
        struct BoundaryCase {
            let label: String
            let channels: Int
            let bytesPerSample: Int
            let expectedMaxFrames: Int
            let expectedBoundaryBytes: Int
        }

        let cases: [BoundaryCase] = [
            // Float32 (4 bytes/sample)
            BoundaryCase(label: "Mono Float32", channels: 1, bytesPerSample: 4, expectedMaxFrames: 65_536, expectedBoundaryBytes: 262_144),
            BoundaryCase(label: "Stereo Float32", channels: 2, bytesPerSample: 4, expectedMaxFrames: 32_768, expectedBoundaryBytes: 262_144),
            BoundaryCase(label: "5.1 6ch Float32", channels: 6, bytesPerSample: 4, expectedMaxFrames: 10_922, expectedBoundaryBytes: 262_128),
            BoundaryCase(label: "8ch Float32", channels: 8, bytesPerSample: 4, expectedMaxFrames: 8_192, expectedBoundaryBytes: 262_144),
            // Non-Float32: Int16 (2 bytes/sample) & Float64 (8 bytes/sample)
            BoundaryCase(label: "Mono Int16", channels: 1, bytesPerSample: 2, expectedMaxFrames: 65_536, expectedBoundaryBytes: 131_072),
            BoundaryCase(label: "Stereo Int16", channels: 2, bytesPerSample: 2, expectedMaxFrames: 65_536, expectedBoundaryBytes: 262_144),
            BoundaryCase(label: "6ch Int16", channels: 6, bytesPerSample: 2, expectedMaxFrames: 21_845, expectedBoundaryBytes: 262_140),
            BoundaryCase(label: "8ch Int16", channels: 8, bytesPerSample: 2, expectedMaxFrames: 16_384, expectedBoundaryBytes: 262_144),
            BoundaryCase(label: "Mono Float64", channels: 1, bytesPerSample: 8, expectedMaxFrames: 32_768, expectedBoundaryBytes: 262_144),
            BoundaryCase(label: "Stereo Float64", channels: 2, bytesPerSample: 8, expectedMaxFrames: 16_384, expectedBoundaryBytes: 262_144)
        ]

        for c in cases {
            let computed = PCMChunkLimitPolicy.maxFrames(channelCount: c.channels, bytesPerSample: c.bytesPerSample)
            XCTAssertEqual(computed, c.expectedMaxFrames, "\(c.label) maxFrames mismatch")

            for isPlanar in [false, true] {
                let bytesAtBoundary = PCMChunkLimitPolicy.inputPayloadBytes(
                    frameCount: c.expectedMaxFrames,
                    channelCount: c.channels,
                    bytesPerSample: c.bytesPerSample,
                    isPlanar: isPlanar
                )
                XCTAssertEqual(bytesAtBoundary, c.expectedBoundaryBytes, "\(c.label) boundary byte calculation")
                XCTAssertLessThanOrEqual(c.expectedMaxFrames, PCMChunkLimitPolicy.maxFramesPerChunk)
                XCTAssertLessThanOrEqual(bytesAtBoundary ?? Int.max, PCMChunkLimitPolicy.maxInputPayloadBytes)

                // Exact boundary MUST be accepted
                XCTAssertNoThrow(
                    try PCMChunkLimitPolicy.validateChunk(
                        frameCount: c.expectedMaxFrames,
                        channelCount: c.channels,
                        bytesPerSample: c.bytesPerSample,
                        isPlanar: isPlanar
                    ),
                    "\(c.label) (planar=\(isPlanar)) failed at valid boundary \(c.expectedMaxFrames)"
                )

                // Exact boundary + 1 frame MUST be rejected
                XCTAssertThrowsError(
                    try PCMChunkLimitPolicy.validateChunk(
                        frameCount: c.expectedMaxFrames + 1,
                        channelCount: c.channels,
                        bytesPerSample: c.bytesPerSample,
                        isPlanar: isPlanar
                    ),
                    "\(c.label) (planar=\(isPlanar)) accepted oversized frame count \(c.expectedMaxFrames + 1)"
                )
            }
        }
    }

    // MARK: - 3. Multichannel Runtime Streaming & Chunk Bound Metrics

    func testMultichannelWAVStreamingRespectsRuntimeChunkLimits() async throws {
        let diskCache = LCWaveDiskCache(directory: AppStoragePaths.audioWaveformCacheDirectory)

        for channels in [1, 2, 6, 8] {
            let service = WaveformPyramidService(diskCache: diskCache)
            let frames = 90_000 // forces multiple chunks for 2ch/6ch/8ch and 2 chunks for 1ch
            let url = sandbox.temporaryURL.appendingPathComponent("multi_\(channels)ch.wav")
            try writeFloatWAV(to: url, sampleRate: 48_000, channels: channels, frameCount: frames) { frame, ch in
                let sign: Float = (ch % 2 == 0) ? 1.0 : -1.0
                return sign * Float(0.1 + 0.05 * Double(ch)) * sin(Float(frame) * 0.02)
            }

            let pyramid = try await service.pyramid(for: url)
            XCTAssertEqual(pyramid.channelCount, channels)
            XCTAssertEqual(pyramid.totalFrames, Int64(frames))

            let metrics = await service.metricsForTesting()
            let allowedMax = PCMChunkLimitPolicy.maxFrames(channelCount: channels, bytesPerSample: 4)
            XCTAssertLessThanOrEqual(metrics.lastMaxChunkFrames, allowedMax)
            XCTAssertLessThanOrEqual(metrics.lastMaxChunkFrames, PCMChunkLimitPolicy.maxFramesPerChunk)
            XCTAssertLessThanOrEqual(metrics.lastMaxChunkPayloadBytes, PCMChunkLimitPolicy.maxInputPayloadBytes)
        }
    }

    // MARK: - 4. Bundled FFmpeg Streaming Pipe Fallback & Progressive Callbacks

    func testFFmpegStreamingFallbackMatchesNativeAndEmitsProgressiveUpdates() async throws {
        let diskCacheNative = LCWaveDiskCache(directory: sandbox.cachesURL.appendingPathComponent("nativeCache", isDirectory: true))
        let diskCacheFFmpeg = LCWaveDiskCache(directory: sandbox.cachesURL.appendingPathComponent("ffmpegCache", isDirectory: true))

        // 200,000 stereo frames (~4.16s @ 48kHz) -> multiple chunks and partial progress notifications
        let frames = 200_000
        let wavURL = sandbox.temporaryURL.appendingPathComponent("parity.wav")
        try writeFloatWAV(to: wavURL, sampleRate: 48_000, channels: 2, frameCount: frames) { frame, ch in
            let freq = ch == 0 ? 220.0 : 440.0
            return Float(0.4 * sin(2.0 * Double.pi * freq * Double(frame) / 48_000.0))
        }

        let nativeService = WaveformPyramidService(diskCache: diskCacheNative, forceFFmpegForTesting: false)
        let ffmpegService = WaveformPyramidService(diskCache: diskCacheFFmpeg, forceFFmpegForTesting: true)

        let nativePyramid = try await nativeService.pyramid(for: wavURL)

        let progressEvents = OSAllocatedUnfairLock(initialState: [WaveformBuildProgress]())
        let ffmpegPyramid = try await ffmpegService.pyramid(for: wavURL) { progress in
            progressEvents.withLock { $0.append(progress) }
        }

        let metricsFFmpeg = await ffmpegService.metricsForTesting()
        XCTAssertEqual(metricsFFmpeg.lastBackendUsed, "BundledFFmpeg")
        XCTAssertLessThanOrEqual(metricsFFmpeg.lastMaxChunkFrames, 32_768)
        XCTAssertLessThanOrEqual(metricsFFmpeg.lastMaxChunkPayloadBytes, PCMChunkLimitPolicy.maxInputPayloadBytes)

        XCTAssertEqual(ffmpegPyramid.totalFrames, nativePyramid.totalFrames)
        XCTAssertEqual(ffmpegPyramid.channelCount, nativePyramid.channelCount)
        XCTAssertEqual(ffmpegPyramid.levels.count, nativePyramid.levels.count)

        for levelIdx in 0..<nativePyramid.levels.count {
            let natLevel = nativePyramid.levels[levelIdx]
            let ffLevel = ffmpegPyramid.levels[levelIdx]
            XCTAssertEqual(ffLevel.bucketCount, natLevel.bucketCount)
            for ch in 0..<2 {
                for bIdx in 0..<natLevel.bucketCount {
                    XCTAssertEqual(ffLevel.channels[ch].buckets[bIdx].minSample, natLevel.channels[ch].buckets[bIdx].minSample, accuracy: 1e-4)
                    XCTAssertEqual(ffLevel.channels[ch].buckets[bIdx].maxSample, natLevel.channels[ch].buckets[bIdx].maxSample, accuracy: 1e-4)
                    XCTAssertEqual(ffLevel.channels[ch].buckets[bIdx].rms, natLevel.channels[ch].buckets[bIdx].rms, accuracy: 1e-4)
                }
            }
        }

        let captured = progressEvents.withLock { $0 }
        XCTAssertTrue(captured.contains(where: { !$0.isComplete }), "Expected progressive partial callbacks")
        XCTAssertEqual(captured.last?.isComplete, true)
    }

    // MARK: - 5. .lcwave Disk Cache Round-Trip, Key Invalidation, Corruption Recovery & LRU Eviction

    func testLCWaveDiskCacheRoundTripInvalidationCorruptionRecoveryAndEviction() async throws {
        let cacheDir = sandbox.cachesURL.appendingPathComponent("WaveLRU", isDirectory: true)
        // Each 40,000-frame stereo .lcwave file is ~26.8 KB, so a 60 KB cap retains at most 2 entries and evicts older ones.
        let smallCap: Int64 = 60_000
        let diskCache = LCWaveDiskCache(directory: cacheDir, maxBytes: smallCap)
        let service = WaveformPyramidService(diskCache: diskCache)

        let url1 = sandbox.temporaryURL.appendingPathComponent("cache_one.wav")
        try writeFloatWAV(to: url1, sampleRate: 48_000, channels: 2, frameCount: 48_000) { f, _ in Float(0.3 * sin(Double(f) * 0.05)) }

        let p1 = try await service.pyramid(for: url1)
        let cacheFileURL = await diskCache.fileURL(forKey: p1.cacheKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFileURL.path))

        // Corrupt the binary payload and verify load deletes corrupt file and service rebuilds transparently.
        await service.clearMemoryCache()
        var corruptData = try Data(contentsOf: cacheFileURL)
        corruptData[corruptData.count - 1] ^= 0xFF
        try corruptData.write(to: cacheFileURL)

        let diskLoadCorrupt = await diskCache.load(cacheKey: p1.cacheKey)
        XCTAssertNil(diskLoadCorrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFileURL.path))

        // Bad magic/version header also recovers cleanly
        try Data("NOTWAVE!".utf8).write(to: cacheFileURL)
        let badHeaderLoad = await diskCache.load(cacheKey: p1.cacheKey)
        XCTAssertNil(badHeaderLoad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFileURL.path))

        // Service rebuilds after corruption
        let rebuilt = try await service.pyramid(for: url1)
        XCTAssertEqual(rebuilt.levels, p1.levels)

        // Modifying source file invalidates cache key cleanly
        try writeFloatWAV(to: url1, sampleRate: 48_000, channels: 2, frameCount: 49_000) { f, _ in Float(0.2 * cos(Double(f) * 0.05)) }
        let updated = try await service.pyramid(for: url1)
        XCTAssertNotEqual(updated.cacheKey, p1.cacheKey)
        XCTAssertEqual(updated.totalFrames, 49_000)

        // Store extra entries to trigger LRU eviction under smallCap (12 KB)
        for i in 0..<5 {
            let extraURL = sandbox.temporaryURL.appendingPathComponent("evict_\(i).wav")
            try writeFloatWAV(to: extraURL, sampleRate: 48_000, channels: 2, frameCount: 40_000) { _, _ in 0.1 }
            _ = try await service.pyramid(for: extraURL)
        }
        let diskBytesAfter = await diskCache.currentDiskBytes()
        XCTAssertLessThanOrEqual(diskBytesAfter, smallCap)
    }

    // MARK: - 6. RAM LRU Eviction, In-Flight Deduplication & Cooperative Cancellation

    func testRAMLRUEvictionDeduplicationAndCancellation() async throws {
        let diskCache = LCWaveDiskCache(directory: AppStoragePaths.audioWaveformCacheDirectory)
        // Each 64k stereo pyramid is ~45 KB; cap RAM at 50 KB so storing 2 evicts the first.
        let smallMemCap = 50_000
        let service = WaveformPyramidService(diskCache: diskCache, maxMemoryBytes: smallMemCap)

        var urls: [URL] = []
        for idx in 0..<3 {
            let u = sandbox.temporaryURL.appendingPathComponent("ram_\(idx).wav")
            try writeFloatWAV(to: u, sampleRate: 48_000, channels: 2, frameCount: 64_000) { f, _ in
                Float(0.2 * sin(Double(f + idx * 10) * 0.01))
            }
            urls.append(u)
        }

        // Concurrent deduplication on urls[0]: 4 concurrent tasks coalesce to 1 build.
        let dedupURL = urls[0]
        let dedupResults = try await withThrowingTaskGroup(of: WaveformPyramid.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await service.pyramid(for: dedupURL)
                }
            }
            var items: [WaveformPyramid] = []
            for try await item in group { items.append(item) }
            return items
        }
        XCTAssertEqual(dedupResults.count, 4)
        let metricsAfterDedup = await service.metricsForTesting()
        XCTAssertEqual(metricsAfterDedup.buildCount, 1)

        _ = try await service.pyramid(for: urls[1])
        _ = try await service.pyramid(for: urls[2])
        let memBytes = await service.cachedMemoryBytes()
        XCTAssertLessThanOrEqual(memBytes, smallMemCap)

        // Cooperative cancellation cleanly unwinds without hanging or leaking in-flight entries.
        // Verify partial cancellation: cancelling waiter A while waiter B remains active still completes waiter B!
        let largeURL = sandbox.temporaryURL.appendingPathComponent("cancel_me.wav")
        try writeFloatWAV(to: largeURL, sampleRate: 48_000, channels: 2, frameCount: 480_000) { f, _ in Float(sin(Double(f) * 0.01)) }

        let waiterA = Task {
            try await service.pyramid(for: largeURL)
        }
        let waiterB = Task {
            try await service.pyramid(for: largeURL)
        }
        waiterA.cancel()
        do {
            _ = try await waiterA.value
        } catch is CancellationError {
            // Expected cancellation path
        }
        let bResult = try await waiterB.value
        XCTAssertEqual(bResult.totalFrames, 480_000)
        await Task.yield()
        let inFlightAfter = await service.inFlightCount()
        XCTAssertEqual(inFlightAfter, 0)

        // Full cancellation on fresh un-cached file also leaves zero leaked in-flight entries
        let allCancelURL = sandbox.temporaryURL.appendingPathComponent("cancel_all.wav")
        try writeFloatWAV(to: allCancelURL, sampleRate: 48_000, channels: 2, frameCount: 480_000) { f, _ in Float(cos(Double(f) * 0.01)) }
        let soloCancel = Task {
            try await service.pyramid(for: allCancelURL)
        }
        soloCancel.cancel()
        _ = try? await soloCancel.value
        await Task.yield()
        let finalInFlight = await service.inFlightCount()
        XCTAssertEqual(finalInFlight, 0)
    }

    // MARK: - 7. Bounded-Memory Long File Stress Benchmark

    func testBoundedMemoryLongAudioStressPerformance() async throws {
        // 5 minutes @ 48 kHz stereo = 14,400,000 frames (~115 MB raw float PCM if buffered whole, <256 KiB streamed/chunk)
        let totalFrames = 14_400_000
        let url = sandbox.temporaryURL.appendingPathComponent("five_minute_stress.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let writeChunk: AVAudioFrameCount = 32_768
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: writeChunk) else {
                XCTFail("Unable to allocate write buffer")
                return
            }
            buf.frameLength = writeChunk
            if let chData = buf.floatChannelData {
                for i in 0..<Int(writeChunk) {
                    let v = Float(0.3 * sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0))
                    chData[0][i] = v
                    chData[1][i] = -v
                }
            }
            var remaining = totalFrames
            while remaining > 0 {
                let n = min(remaining, Int(writeChunk))
                buf.frameLength = AVAudioFrameCount(n)
                try file.write(from: buf)
                remaining -= n
            }
        }

        let diskCache = LCWaveDiskCache(directory: AppStoragePaths.audioWaveformCacheDirectory)
        let service = WaveformPyramidService(diskCache: diskCache)

        let start = CFAbsoluteTimeGetCurrent()
        let pyramid = try await service.pyramid(for: url)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print(String(format: "[StageA-Benchmark] 5m stereo pyramid (14,400,000 frames) built in %.4fs", elapsed))

        let metrics = await service.metricsForTesting()
        XCTAssertEqual(pyramid.totalFrames, Int64(totalFrames))
        XCTAssertEqual(pyramid.channelCount, 2)
        XCTAssertLessThanOrEqual(metrics.lastMaxChunkFrames, 32_768)
        XCTAssertLessThanOrEqual(metrics.lastMaxChunkPayloadBytes, PCMChunkLimitPolicy.maxInputPayloadBytes)
        XCTAssertLessThan(elapsed, 15.0)
    }
}

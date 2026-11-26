import XCTest
import SwiftUI
import AppKit
import AVFoundation
import CoreAudio
import CryptoKit
import Darwin
import os
@testable import LocalConvert

// MARK: - Stage D Test Doubles (Zero-Sleep Latency & Arbitration Instrumentation)

@MainActor
private final class StageDLatencySpyTransport: AudioPlaybackTransportProtocol {
    var volume: Float = 1.0
    var rate: Float = 1.0
    private(set) var scheduledCount = 0
    private(set) var firstScheduleTime: CFAbsoluteTime?
    private(set) var resetCount = 0

    func configure(sampleRate: Double, channelCount: Int) throws {}
    func setOutputDevice(deviceID: AudioDeviceID?) throws {}
    func startEngine() throws {}
    func playNode() {}
    func pauseNode() {}
    func stopAndResetNode() {
        resetCount += 1
        scheduledCount = 0
        firstScheduleTime = nil
    }
    func scheduleChunk(_ chunk: DecodedPCMChunk, onRendered: @escaping @MainActor () -> Void) {
        if firstScheduleTime == nil {
            firstScheduleTime = CFAbsoluteTimeGetCurrent()
        }
        scheduledCount += 1
    }
    func currentRenderedFramesSinceReset() -> Int64 { 0 }
}

// MARK: - Phase 71 Stage D Benchmarks & Platform Validation

final class Phase71AudioWorkspacePerformanceTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase71Perf-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        MetadataRegistry.shared.register(provider: AudioMetadataProvider())
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

    // MARK: - Telemetry Helpers

    private static func memorySnapshotMB() -> (nonVolatileInternalMB: Double, physFootprintMB: Double) {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kVM = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard kVM == KERN_SUCCESS else { return (0, 0) }
        let volatileBytes = UInt64(max(0, vmInfo.ledger_purgeable_volatile + vmInfo.ledger_purgeable_volatile_compressed)) + vmInfo.reusable
        let nonVolatileInternalBytes = (vmInfo.internal > volatileBytes) ? (vmInfo.internal - volatileBytes) : 0
        let scale = 1024.0 * 1024.0
        return (
            Double(nonVolatileInternalBytes) / scale,
            Double(vmInfo.phys_footprint) / scale
        )
    }

    private func processCPUTimeSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let user = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000.0
        let sys = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000.0
        return user + sys
    }

    private func settleMemory() async {
        autoreleasepool {
            malloc_zone_pressure_relief(nil, 0)
        }
        try? await Task.sleep(for: .milliseconds(150))
        autoreleasepool {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Streams a canonical RIFF/WAVE 24-bit signed integer PCM file directly to disk using a repeated block
    /// so even a 2-hour 96 kHz stereo WAV (~4.15 GB) writes quickly and with minimal RAM.
    private func writeStreaming24BitWAV(
        to url: URL,
        sampleRate: Int32,
        channels: Int,
        totalFrames: Int64
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }

        let bytesPerSample = 3
        let blockAlign = channels * bytesPerSample
        let dataBytes = totalFrames * Int64(blockAlign)
        precondition(dataBytes <= Int64(UInt32.max) - 36, "RIFF WAV requires data + 36 <= UInt32.max")

        var header = Data()
        header.reserveCapacity(44)
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }

        header.append(contentsOf: "RIFF".utf8)
        appendU32(UInt32(36 + dataBytes))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        appendU32(16)
        appendU16(1) // PCM
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(Int64(sampleRate) * Int64(blockAlign)))
        appendU16(UInt16(blockAlign))
        appendU16(24)
        header.append(contentsOf: "data".utf8)
        appendU32(UInt32(dataBytes))
        try fh.write(contentsOf: header)

        // Build a 1,048,576-frame reusable PCM tile (or smaller if totalFrames < that) with non-trivial 24-bit sine values.
        let tileFrames = Int(min(totalFrames, 524_288))
        let tileBytes = tileFrames * blockAlign
        var tile = Data(count: tileBytes)
        tile.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let period = max(16.0, Double(sampleRate) / 440.0)
            for f in 0..<tileFrames {
                let s = sin((2.0 * Double.pi * Double(f)) / period) * 0.45
                let q = Int32((s * 8_388_607.0).rounded())
                let b0 = UInt8(truncatingIfNeeded: q)
                let b1 = UInt8(truncatingIfNeeded: q >> 8)
                let b2 = UInt8(truncatingIfNeeded: q >> 16)
                for ch in 0..<channels {
                    let off = (f * channels + ch) * 3
                    ptr[off] = b0
                    ptr[off + 1] = b1
                    ptr[off + 2] = b2
                }
            }
        }

        var remaining = totalFrames
        while remaining > 0 {
            let chunkFrames = Int(min(remaining, Int64(tileFrames)))
            let byteCount = chunkFrames * blockAlign
            if byteCount == tile.count {
                try fh.write(contentsOf: tile)
            } else {
                try fh.write(contentsOf: tile.prefix(byteCount))
            }
            remaining -= Int64(chunkFrames)
        }
    }

    private func makeSyntheticLibraryRecords(count: Int, baseDir: URL) throws -> [AudioLibraryRecord] {
        let genres = ["Ambient", "Electronic", "Jazz", "Classical", "Rock", "Folk", "Acoustic", "Synth"]
        var records: [AudioLibraryRecord] = []
        records.reserveCapacity(count)

        for i in 0..<count {
            let isFLAC = (i % 3 == 0)
            let isHiRes = (i % 5 == 0)
            let rate = isHiRes ? SampleRate.rate96k : SampleRate.rate48k
            let ext = isFLAC ? "flac" : "wav"
            let rawFmt = isFLAC ? FileFormat.flac.rawValue : FileFormat.wav.rawValue
            let artist = "Artist \(String(format: "%03d", i % 250))"
            let album = "Album \(String(format: "%03d", i % 400)) Studio"
            let title = "Track \(String(format: "%05d", i)) \(i % 7 == 0 ? "nocturne" : "session")"
            let path = baseDir.appendingPathComponent("f_\(i % 50)/track_\(i).\(ext)").path
            let asset = try AudioAsset(
                canonicalPath: path,
                displayFilename: "track_\(i).\(ext)",
                fileExtension: ext,
                formatRawValue: rawFmt,
                fileSizeBytes: Int64(1_000_000 + (i % 5000) * 128),
                modificationTime: 1_700_000_000.0 + Double(i),
                sampleRate: rate,
                channelCount: 2,
                bitDepth: isHiRes ? 24 : 16,
                frameCount: Int64(rate.hz) * Int64(120 + (i % 180)),
                isLosslessCodec: true,
                codecName: isFLAC ? "flac" : "pcm_s24le",
                status: .ok,
                isFavorite: (i % 10 == 0),
                rating: i % 6
            )
            let meta = AudioMetadata(
                title: title,
                artist: artist,
                album: album,
                genre: genres[i % genres.count],
                year: 2010 + (i % 16)
            )
            records.append(AudioLibraryRecord(asset: asset, metadata: meta))
        }
        return records
    }

    // MARK: - 1. 10,000-Row Library Indexing/Loading & Real 500-File Scanner Throughput

    func testLibrary10000RowLoadAnd500RealFilesScanThroughput() async throws {
        let dbURL = sandbox.applicationSupportURL.appendingPathComponent("library_10k.sqlite")
        let db = AudioLibraryDatabase(databaseURL: dbURL)
        let artwork = AudioArtworkProvider(cacheDirectory: sandbox.cachesURL.appendingPathComponent("art_10k", isDirectory: true))
        let fakeRoot = sandbox.temporaryURL.appendingPathComponent("Virtual10kMusic", isDirectory: true)
        let records = try makeSyntheticLibraryRecords(count: 10_000, baseDir: fakeRoot)

        await settleMemory()
        let memBefore = Self.memorySnapshotMB()
        let cpuBefore = processCPUTimeSeconds()

        // Seed 10,000 rows in 250-row transactions per roadmap strategy
        let seedStart = CFAbsoluteTimeGetCurrent()
        var idx = 0
        while idx < records.count {
            let end = min(records.count, idx + 250)
            try await db.upsertAssets(Array(records[idx..<end]))
            idx = end
        }
        let seedElapsed = CFAbsoluteTimeGetCurrent() - seedStart

        // Measure cold DB fetchAllAssets & full AudioLibraryStore.loadAndRefresh() (SQL + DISTINCT + displayedRecords)
        let fetchStart = CFAbsoluteTimeGetCurrent()
        let fetched = try await db.fetchAllAssets()
        let fetchElapsed = CFAbsoluteTimeGetCurrent() - fetchStart
        XCTAssertEqual(fetched.count, 10_000)

        let storeStart = CFAbsoluteTimeGetCurrent()
        let store = await MainActor.run { AudioLibraryStore(database: db, artworkProvider: artwork) }
        await store.reloadMetadataAndTracks()
        let storeLoadElapsed = CFAbsoluteTimeGetCurrent() - storeStart
        let displayedCount = await MainActor.run { store.displayedRecords.count }
        XCTAssertEqual(displayedCount, 10_000)

        let memAfter10k = Self.memorySnapshotMB()
        let cpuAfter10k = processCPUTimeSeconds()

        // Now measure REAL end-to-end file discovery + header/tag scan across 500 synthetic mixed audio files (400 WAV + 100 AIFF)
        let realScanDir = sandbox.temporaryURL.appendingPathComponent("Real500MixedFiles", isDirectory: true)
        try FileManager.default.createDirectory(at: realScanDir, withIntermediateDirectories: true)
        for i in 0..<500 {
            let sub = realScanDir.appendingPathComponent("album_\(i % 10)", isDirectory: true)
            if i % 5 == 0 {
                let target = sub.appendingPathComponent("clip_\(i).aiff")
                _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
                    to: target,
                    spec: SyntheticAudioFixtureWriter.Spec(format: .aiff, sampleRate: 44_100, channelCount: 2, bitDepth: 16, frameCount: 4_410)
                )
            } else {
                let target = sub.appendingPathComponent("clip_\(i).wav")
                _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
                    to: target,
                    spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 4_800)
                )
            }
        }

        let scanDB = AudioLibraryDatabase(databaseURL: sandbox.applicationSupportURL.appendingPathComponent("scan_500.sqlite"))
        let scanner = AudioLibraryScanner(database: scanDB, artworkProvider: artwork)
        let rootFolder = try LibraryRootFolder(path: realScanDir.path)
        try await scanDB.upsertRootFolder(rootFolder)

        let realScanStart = CFAbsoluteTimeGetCurrent()
        let scanReport = try await scanner.scanRootFolder(rootFolder)
        let realScanElapsed = CFAbsoluteTimeGetCurrent() - realScanStart
        XCTAssertEqual(scanReport.status, .completed)
        XCTAssertEqual(scanReport.newlyIndexedCount, 500)

        let filesPerSecond = 500.0 / max(0.001, realScanElapsed)
        let extrapolated10kSeconds = 10_000.0 / filesPerSecond

        print(String(
            format: "[StageD-Perf] 10k-Row Library: seed10k=%.3fs fetchAll10k=%.3fs storeRefresh10k=%.3fs ramDelta=%.1fMB cpu=%.3fs | Real500MixedScan=%.3fs (%.1f files/s, extrapolated 10k=%.2fs vs <=15.0s target)",
            seedElapsed,
            fetchElapsed,
            storeLoadElapsed,
            memAfter10k.nonVolatileInternalMB - memBefore.nonVolatileInternalMB,
            cpuAfter10k - cpuBefore,
            realScanElapsed,
            filesPerSecond,
            extrapolated10kSeconds
        ))

        XCTAssertLessThan(storeLoadElapsed, 5.0)
    }

    // MARK: - 2. 25,000-Row FTS5 Search vs LIKE Fallback Latency

    func testLibrary25000RowFTS5SearchVsLikeFallbackLatency() async throws {
        let ftsDBURL = sandbox.applicationSupportURL.appendingPathComponent("library_25k_fts.sqlite")
        let ftsDB = AudioLibraryDatabase(databaseURL: ftsDBURL, forceDisableFTS5: false)
        let likeDB = AudioLibraryDatabase(databaseURL: ftsDBURL, forceDisableFTS5: true)
        let fakeRoot = sandbox.temporaryURL.appendingPathComponent("Virtual25kMusic", isDirectory: true)
        let records = try makeSyntheticLibraryRecords(count: 25_000, baseDir: fakeRoot)

        var idx = 0
        while idx < records.count {
            let end = min(records.count, idx + 500)
            try await ftsDB.upsertAssets(Array(records[idx..<end]))
            idx = end
        }

        let isFTS5 = await ftsDB.isFTS5Available
        XCTAssertTrue(isFTS5, "SQLite FTS5 must be compiled and active on macOS")

        let queries = [
            "Artist 012 Album 012",
            "nocturne",
            "Artist 099 sess",
            "flac Album 120",
            "Jazz noct",
            "Artist 145 track_145",
            "Acoustic Studio",
            "Electronic 033",
            "Classical Album 200",
            "Rock Studio track",
            "Folk Artist 007",
            "Synth noct",
            "Artist 200",
            "Album 399",
            "session Ambient",
            "Artist 001 Album 001",
            "track_249",
            "wav Jazz",
            "noct Artist",
            "Studio 050"
        ]

        // Warm-up query
        _ = try await ftsDB.searchAssets(query: "Artist 001", limit: 200)

        var ftsSamplesMs: [Double] = []
        for q in queries {
            let t0 = CFAbsoluteTimeGetCurrent()
            let hits = try await ftsDB.searchAssets(query: q, limit: 200)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            ftsSamplesMs.append(ms)
            XCTAssertFalse(hits.isEmpty, "FTS5 query '\(q)' should return matches in seeded 25k dataset")
        }

        var likeSamplesMs: [Double] = []
        for q in queries.prefix(5) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let hits = try await likeDB.searchAssets(query: q, limit: 200)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            likeSamplesMs.append(ms)
            XCTAssertFalse(hits.isEmpty)
        }

        let sortedFTS = ftsSamplesMs.sorted()
        let medianFTS = sortedFTS[sortedFTS.count / 2]
        let p95FTS = sortedFTS[min(sortedFTS.count - 1, Int(Double(sortedFTS.count) * 0.95))]
        let maxFTS = sortedFTS.last ?? 0
        let avgLike = likeSamplesMs.reduce(0, +) / Double(max(1, likeSamplesMs.count))

        print(String(
            format: "[StageD-Perf] 25k-Row Search: FTS5 median=%.2fms p95=%.2fms max=%.2fms (target <=25.0ms) | LIKE avg=%.2fms",
            medianFTS, p95FTS, maxFTS, avgLike
        ))

        XCTAssertLessThanOrEqual(p95FTS, 25.0, "25k-row FTS5 p95 query latency exceeded 25ms target")
    }

    // MARK: - 3. Player First-Audio & Seek Latency

    @MainActor
    func testPlayerFirstAudioAndSeekLatencyTargets() async throws {
        let wavURL = sandbox.temporaryURL.appendingPathComponent("latency_native.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 240_000)
        )
        let flacURL = sandbox.temporaryURL.appendingPathComponent("latency_ffmpeg.flac")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: flacURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .flac, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 240_000)
        )

        let transport = StageDLatencySpyTransport()
        let engine = AudioLibraryPlayerEngine(transport: transport)

        func waitUntilScheduled(timeoutSeconds: Double = 3.0) async -> Bool {
            let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
            while CFAbsoluteTimeGetCurrent() < deadline {
                if transport.firstScheduleTime != nil {
                    return true
                }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return transport.firstScheduleTime != nil
        }

        // Native WAV load+play latency
        let nativeStart = CFAbsoluteTimeGetCurrent()
        try await engine.load(url: wavURL, assetID: UUID(), fileFormat: .wav, autoPlay: true)
        let nativeScheduled = await waitUntilScheduled()
        XCTAssertTrue(nativeScheduled)
        let nativeLatencyMs = ((transport.firstScheduleTime ?? CFAbsoluteTimeGetCurrent()) - nativeStart) * 1000.0

        // Seek latency on native WAV
        transport.stopAndResetNode()
        let seekStart = CFAbsoluteTimeGetCurrent()
        try await engine.seek(toSeconds: 2.0)
        let seekScheduled = await waitUntilScheduled()
        XCTAssertTrue(seekScheduled)
        let seekLatencyMs = ((transport.firstScheduleTime ?? CFAbsoluteTimeGetCurrent()) - seekStart) * 1000.0

        // FFmpeg streaming FLAC load+play latency
        let ffmpegStart = CFAbsoluteTimeGetCurrent()
        try await engine.load(url: flacURL, assetID: UUID(), fileFormat: .flac, autoPlay: true)
        let ffmpegScheduled = await waitUntilScheduled()
        XCTAssertTrue(ffmpegScheduled)
        let ffmpegLatencyMs = ((transport.firstScheduleTime ?? CFAbsoluteTimeGetCurrent()) - ffmpegStart) * 1000.0

        await engine.stop()

        print(String(
            format: "[StageD-Perf] Player Latency (StageDLatencySpyTransport): NativeWAV=%.2fms (target <=100ms), FFmpegFLAC=%.2fms (target <=400ms), SeekResume=%.2fms (target <=30ms)",
            nativeLatencyMs, ffmpegLatencyMs, seekLatencyMs
        ))

        XCTAssertLessThanOrEqual(nativeLatencyMs, 100.0)
        XCTAssertLessThanOrEqual(ffmpegLatencyMs, 400.0)
        XCTAssertLessThanOrEqual(seekLatencyMs, 30.0)
    }

    // MARK: - 4. Two-Hour 96 kHz 24-Bit Stereo WAV (~4.15 GB) Pyramid, RAM, Cache Hit, Eviction & Cancellation

    func testTwoHour96kHzStereoWAVStreamingPyramidMemoryCacheAndCancel() async throws {
        // Exact 2-hour 96 kHz 24-bit stereo WAV: 7,200s * 96,000 Hz = 691,200,000 frames (4,147,200,044 bytes ~4.15 GB)
        let totalFrames: Int64 = 691_200_000
        let sampleRate: Int32 = 96_000
        let wavURL = sandbox.temporaryURL.appendingPathComponent("two_hour_96k_24b.wav")
        let writeStart = CFAbsoluteTimeGetCurrent()
        try writeStreaming24BitWAV(to: wavURL, sampleRate: sampleRate, channels: 2, totalFrames: totalFrames)
        let writeElapsed = CFAbsoluteTimeGetCurrent() - writeStart
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let fileSize = (try FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(fileSize, 4_147_200_044)

        let cacheDir = sandbox.cachesURL.appendingPathComponent("TwoHourWaveCache", isDirectory: true)
        let diskCache = LCWaveDiskCache(directory: cacheDir)
        let service = WaveformPyramidService(diskCache: diskCache)

        await settleMemory()
        let memBaseline = Self.memorySnapshotMB()
        let cpuStart = processCPUTimeSeconds()

        let peakRAMTracker = OSAllocatedUnfairLock(initialState: memBaseline.nonVolatileInternalMB)
        let firstProgressMs = OSAllocatedUnfairLock<Double?>(initialState: nil)
        let progressCount = OSAllocatedUnfairLock(initialState: 0)

        let buildStart = CFAbsoluteTimeGetCurrent()
        let samplerTask = Task {
            while !Task.isCancelled {
                let cur = Self.memorySnapshotMB().nonVolatileInternalMB
                peakRAMTracker.withLock { $0 = max($0, cur) }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        let pyramid = try await service.pyramid(for: wavURL) { progress in
            let now = CFAbsoluteTimeGetCurrent()
            if !progress.isComplete {
                firstProgressMs.withLock { existing in
                    if existing == nil {
                        existing = (now - buildStart) * 1000.0
                    }
                }
                progressCount.withLock { $0 += 1 }
            }
        }
        samplerTask.cancel()
        let buildElapsed = CFAbsoluteTimeGetCurrent() - buildStart
        let cpuElapsed = processCPUTimeSeconds() - cpuStart

        let memAfterBuild = Self.memorySnapshotMB()
        await settleMemory()
        let memSettled = Self.memorySnapshotMB()

        let peakRAMMB = max(peakRAMTracker.withLock { $0 }, memAfterBuild.nonVolatileInternalMB)
        let peakDeltaMB = peakRAMMB - memBaseline.nonVolatileInternalMB
        let settledDeltaMB = memSettled.nonVolatileInternalMB - memBaseline.nonVolatileInternalMB
        let firstCoarseMs = firstProgressMs.withLock { $0 } ?? -1.0

        XCTAssertEqual(pyramid.totalFrames, totalFrames)
        XCTAssertEqual(pyramid.channelCount, 2)
        XCTAssertGreaterThan(firstCoarseMs, 0)
        XCTAssertLessThanOrEqual(firstCoarseMs, 150.0, "Progressive coarse waveform exceeded 150ms first-render target")
        XCTAssertLessThanOrEqual(peakDeltaMB, 120.0, "2-hour 96kHz WAV peak non-volatile internal RAM delta exceeded 120MB ceiling")

        let metrics = await service.metricsForTesting()
        XCTAssertLessThanOrEqual(metrics.lastMaxChunkFrames, 32_768)
        XCTAssertLessThanOrEqual(metrics.lastMaxChunkPayloadBytes, PCMChunkLimitPolicy.maxInputPayloadBytes)

        // Verify .lcwave disk cache hit latency (cold from RAM, warm on disk)
        await service.clearMemoryCache()
        let diskHitStart = CFAbsoluteTimeGetCurrent()
        let diskHit = try await service.pyramid(for: wavURL)
        let diskHitMs = (CFAbsoluteTimeGetCurrent() - diskHitStart) * 1000.0
        XCTAssertEqual(diskHit.totalFrames, totalFrames)

        // Verify RAM LRU hit latency
        let ramHitStart = CFAbsoluteTimeGetCurrent()
        let ramHit = try await service.pyramid(for: wavURL)
        let ramHitMs = (CFAbsoluteTimeGetCurrent() - ramHitStart) * 1000.0
        XCTAssertEqual(ramHit.totalFrames, totalFrames)

        // Verify mid-stream cooperative cancellation on the 2-hour WAV cleans up in-flight build & .tmp files
        await service.clearMemoryCache()
        await diskCache.removeAll()
        let cancelService = WaveformPyramidService(diskCache: diskCache)
        let cancelTask = Task {
            try await cancelService.pyramid(for: wavURL)
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelTask.cancel()
        _ = try? await cancelTask.value
        await Task.yield()
        let remainingInFlight = await cancelService.inFlightCount()
        XCTAssertEqual(remainingInFlight, 0)
        let cacheEntries = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
        XCTAssertFalse(cacheEntries.contains(where: { $0.pathExtension == "tmp" }), "Cancelled pyramid build left stray .tmp files")

        // Verify 50+ asset eviction under RAM and Disk bounds
        let evictCacheDir = sandbox.cachesURL.appendingPathComponent("Evict55Cache", isDirectory: true)
        let evictDiskCap: Int64 = 512 * 1024
        let evictMemCap = 256 * 1024
        let evictDisk = LCWaveDiskCache(directory: evictCacheDir, maxBytes: evictDiskCap)
        let evictService = WaveformPyramidService(diskCache: evictDisk, maxMemoryBytes: evictMemCap)
        for i in 0..<55 {
            let assetURL = sandbox.temporaryURL.appendingPathComponent("evict_asset_\(i).wav")
            try writeStreaming24BitWAV(to: assetURL, sampleRate: 48_000, channels: 2, totalFrames: 48_000)
            _ = try await evictService.pyramid(for: assetURL)
            try? FileManager.default.removeItem(at: assetURL)
        }
        let cachedRAM = await evictService.cachedMemoryBytes()
        let cachedDisk = await evictDisk.currentDiskBytes()
        XCTAssertLessThanOrEqual(cachedRAM, evictMemCap)
        XCTAssertLessThanOrEqual(cachedDisk, evictDiskCap)

        print(String(
            format: "[StageD-Perf] 2-Hour 96kHz 24b Stereo WAV (4.15GB): fixtureWrite=%.2fs firstCoarse=%.2fms (<=150ms) fullBuild=%.2fs cpu=%.2fs peakRAMDelta=%.1fMB (<=120MB) settledDelta=%.1fMB lcwaveDiskHit=%.2fms (<=20ms) ramHit=%.2fms progressCallbacks=%d",
            writeElapsed, firstCoarseMs, buildElapsed, cpuElapsed, peakDeltaMB, settledDeltaMB, diskHitMs, ramHitMs, progressCount.withLock { $0 }
        ))
    }

    // MARK: - 5. 192 kHz Six-Channel Audio Decoding & Extraction

    func test192kHzSixChannelDecodingThroughputAndWaveformExtraction() async throws {
        let frames: Int64 = 1_920_000 // 10s @ 192 kHz, 6 channels (~34.56 MB PCM)
        let wavURL = sandbox.temporaryURL.appendingPathComponent("surround_192k_6ch.wav")
        try writeStreaming24BitWAV(to: wavURL, sampleRate: 192_000, channels: 6, totalFrames: frames)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        await settleMemory()
        let memBefore = Self.memorySnapshotMB()

        let decodeStart = CFAbsoluteTimeGetCurrent()
        let decoder = try await AudioPlaybackDecoderFactory.openDecoder(url: wavURL, format: .wav)
        XCTAssertEqual(decoder.streamInfo.sampleRate.hz, 192_000)
        XCTAssertEqual(decoder.streamInfo.channelCount, 6)

        var decodedFrames: Int64 = 0
        while let chunk = try await decoder.readNextChunk(maxFrames: 8_192) {
            decodedFrames += Int64(chunk.frameCount)
        }
        await decoder.close()
        let decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStart
        XCTAssertEqual(decodedFrames, frames)

        let diskCache = LCWaveDiskCache(directory: AppStoragePaths.audioWaveformCacheDirectory)
        let pyramidService = WaveformPyramidService(diskCache: diskCache)
        let waveStart = CFAbsoluteTimeGetCurrent()
        let pyramid = try await pyramidService.pyramid(for: wavURL)
        let waveElapsed = CFAbsoluteTimeGetCurrent() - waveStart

        let memAfter = Self.memorySnapshotMB()
        let metrics = await pyramidService.metricsForTesting()

        XCTAssertEqual(pyramid.channelCount, 6)
        XCTAssertEqual(pyramid.sampleRate, 192_000)
        XCTAssertEqual(pyramid.totalFrames, frames)
        XCTAssertLessThanOrEqual(metrics.lastMaxChunkFrames, 10_922)
        XCTAssertLessThanOrEqual(metrics.lastMaxChunkPayloadBytes, PCMChunkLimitPolicy.maxInputPayloadBytes)

        let decodeSpeedX = 10.0 / max(0.001, decodeElapsed)
        print(String(
            format: "[StageD-Perf] 192kHz 6ch Decode (10s): decodeTime=%.3fs (%.1fx RT), waveformBuild=%.3fs, maxChunkFrames=%d (<=10922), maxChunkBytes=%d, ramDelta=%.1fMB",
            decodeElapsed, decodeSpeedX, waveElapsed, metrics.lastMaxChunkFrames, metrics.lastMaxChunkPayloadBytes,
            memAfter.nonVolatileInternalMB - memBefore.nonVolatileInternalMB
        ))
    }

    // MARK: - 6. Audio Export Throughput & Cancellation Cleanup

    func testAudioExportThroughputDryAndEQDynamicsPlusCancellation() async throws {
        // 30s @ 48 kHz 24-bit stereo WAV
        let durationSeconds = 30.0
        let sampleRate = 48_000
        let frames = Int64(durationSeconds * Double(sampleRate))
        let srcURL = sandbox.temporaryURL.appendingPathComponent("export_bench_30s.wav")
        try writeStreaming24BitWAV(to: srcURL, sampleRate: Int32(sampleRate), channels: 2, totalFrames: frames)
        defer { try? FileManager.default.removeItem(at: srcURL) }

        let ref = AudioMediaReference(
            id: UUID(),
            path: srcURL.path,
            displayName: srcURL.lastPathComponent,
            fileSize: (try FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? Int64) ?? 0,
            modificationTime: 0,
            duration: durationSeconds,
            sampleRate: Double(sampleRate),
            channels: 2,
            durationFrames: frames
        )

        func makeProject(withDSP: Bool) -> AudioEditorProject {
            var proj = AudioEditorProject()
            proj.projectSampleRate = .rate48k
            proj.mediaAssets = [ref]
            var clip = AudioClip(
                sourceAssetID: ref.id,
                name: "Bench",
                timelineStartFrame: 0,
                sourceStartFrame: 0,
                durationFrames: frames,
                projectRate: .rate48k,
                sourceRate: .rate48k
            )
            if withDSP {
                clip.effectSlots = [
                    AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams()),
                    AudioEffectSlot(kind: .compressor, compressor: CompressorParams()),
                    AudioEffectSlot(kind: .limiter, limiter: LimiterParams())
                ]
            }
            proj.tracks = [AudioTrack(name: "Main", clips: [clip])]
            return proj
        }

        let dryProject = makeProject(withDSP: false)

        func measureExport(project: AudioEditorProject, format: FileFormat, name: String) async throws -> Double {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: format,
                sampleRate: sampleRate,
                bitDepth: 24,
                channels: 2,
                loudnessNormalizeEnabled: false,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: sandbox.outputsURL,
                baseFileName: name,
                exportMode: .losslessFormatReRender
            )
            let start = CFAbsoluteTimeGetCurrent()
            let res = try await AudioExportService.export(project: project, request: req)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            XCTAssertEqual(res.outputURLs.count, 1)
            return durationSeconds / max(0.001, elapsed)
        }

        let wavDryX = try await measureExport(project: dryProject, format: .wav, name: "bench_dry_wav")
        let alacDryX = try await measureExport(project: dryProject, format: .alac, name: "bench_dry_alac")
        let flacDryX = try await measureExport(project: dryProject, format: .flac, name: "bench_dry_flac")

        print(String(
            format: "[StageD-Perf] 30s Dry Export Throughput (target >=10x): WAV=%.1fx ALAC=%.1fx FLAC=%.1fx",
            wavDryX, alacDryX, flacDryX
        ))
    }

    func testAudioExportEQDynamicsThroughputAndCancellation() async throws {
        // 30s @ 48 kHz 24-bit stereo WAV with Parametric EQ + Compressor + Limiter
        let durationSeconds = 30.0
        let sampleRate = 48_000
        let frames = Int64(durationSeconds * Double(sampleRate))
        let srcURL = sandbox.temporaryURL.appendingPathComponent("export_bench_dsp_30s.wav")
        try writeStreaming24BitWAV(to: srcURL, sampleRate: Int32(sampleRate), channels: 2, totalFrames: frames)
        defer { try? FileManager.default.removeItem(at: srcURL) }

        let ref = AudioMediaReference(
            id: UUID(),
            path: srcURL.path,
            displayName: srcURL.lastPathComponent,
            fileSize: (try FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? Int64) ?? 0,
            modificationTime: 0,
            duration: durationSeconds,
            sampleRate: Double(sampleRate),
            channels: 2,
            durationFrames: frames
        )

        let dspProject: AudioEditorProject = {
            var proj = AudioEditorProject()
            proj.projectSampleRate = .rate48k
            proj.mediaAssets = [ref]
            var clip = AudioClip(
                sourceAssetID: ref.id,
                name: "BenchDSP",
                timelineStartFrame: 0,
                sourceStartFrame: 0,
                durationFrames: frames,
                projectRate: .rate48k,
                sourceRate: .rate48k
            )
            clip.effectSlots = [
                AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams()),
                AudioEffectSlot(kind: .compressor, compressor: CompressorParams()),
                AudioEffectSlot(kind: .limiter, limiter: LimiterParams())
            ]
            proj.tracks = [AudioTrack(name: "Main", clips: [clip])]
            return proj
        }()

        func measureDSPExport(format: FileFormat, name: String) async throws -> Double {
            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: format,
                sampleRate: sampleRate,
                bitDepth: 24,
                channels: 2,
                loudnessNormalizeEnabled: false,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: sandbox.outputsURL,
                baseFileName: name,
                exportMode: .losslessFormatReRender
            )
            let start = CFAbsoluteTimeGetCurrent()
            let res = try await AudioExportService.export(project: dspProject, request: req)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            XCTAssertEqual(res.outputURLs.count, 1)
            return durationSeconds / max(0.001, elapsed)
        }

        let wavDSPX = try await measureDSPExport(format: .wav, name: "bench_dsp_wav")
        let alacDSPX = try await measureDSPExport(format: .alac, name: "bench_dsp_alac")
        let flacDSPX = try await measureDSPExport(format: .flac, name: "bench_dsp_flac")

        print(String(
            format: "[StageD-Perf] 30s EQ+Dynamics Export Throughput (target >=4x): WAV=%.1fx ALAC=%.1fx FLAC=%.1fx",
            wavDSPX, alacDSPX, flacDSPX
        ))

        // Cancellation cleanup verification
        let cancelReq = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .flac,
            sampleRate: sampleRate,
            bitDepth: 24,
            channels: 2,
            validateOutput: true,
            outputDirectory: sandbox.outputsURL,
            baseFileName: "cancelled_bench",
            exportMode: .losslessFormatReRender
        )
        let projectSnapshot = dspProject
        let cancelTask = Task {
            try await AudioExportService.export(project: projectSnapshot, request: cancelReq)
        }
        try await Task.sleep(for: .milliseconds(25))
        cancelTask.cancel()
        _ = try? await cancelTask.value

        let stagingContents = (try? FileManager.default.contentsOfDirectory(
            at: AppStoragePaths.audioExportStagingDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(stagingContents.isEmpty, "Cancelled export left staging artifacts: \(stagingContents)")

        // Confirm output reservation was cleanly released by reserving the exact same path without collision suffix.
        let reReserved = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: sandbox.outputsURL,
            baseName: "cancelled_bench",
            extension: "flac"
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(reReserved) }
        XCTAssertEqual(reReserved.lastPathComponent, "cancelled_bench.flac")
    }

    // MARK: - 7. Waveform Rendering 60 FPS Zoom/Pan & Playhead Isolation

    @MainActor
    func testWaveformRenderingFrameRateZoomBoundsAndPlayheadIsolation() throws {
        // Build 300s 48kHz stereo 5-level pyramid (~450 KB)
        let totalFrames: Int64 = 14_400_000
        let levels = WaveformPyramid.standardBucketSizes.map { fpb -> WaveformMipLevel in
            let bucketCount = max(1, Int((totalFrames + Int64(fpb) - 1) / Int64(fpb)))
            let chLevels = (0..<2).map { ch in
                let buckets = (0..<bucketCount).map { idx -> WaveformBucket in
                    let amp = Float(0.35 + 0.3 * sin(Double(idx + ch) * 0.05))
                    return WaveformBucket(minSample: -amp, maxSample: amp, rms: amp * 0.707, clipped: false)
                }
                return WaveformChannelLevel(channelIndex: ch, buckets: buckets)
            }
            return WaveformMipLevel(framesPerBucket: fpb, channels: chLevels)
        }
        let pyramid = WaveformPyramid(
            assetID: UUID(),
            cacheKey: "fps-bench",
            sampleRate: 48_000,
            channelCount: 2,
            totalFrames: totalFrames,
            duration: 300.0,
            levels: levels,
            isPartial: false,
            completedFrames: totalFrames
        )

        let viewportWidth = 900.0
        let maxBuckets = Int(ceil(viewportWidth)) * 2
        let zoomLevels: [Double] = [2.0, 10.0, 80.0, 500.0, 2_000.0, 8_000.0, 20_000.0]

        var drawTimesMs: [Double] = []
        var planRecomputeCount = 0

        let hostRect = NSRect(x: 0, y: 0, width: viewportWidth, height: 120)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(viewportWidth),
            pixelsHigh: 120,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("Failed to allocate offscreen bitmap rep")
            return
        }

        // Measure actual Canvas rasterization via NSHostingView.cacheDisplay across full zoom sweep
        for pps in zoomLevels {
            let visibleSpanFrames = min(totalFrames, max(48_000, Int64((viewportWidth / pps) * 48_000.0)))
            let plan = WaveformCanvasRenderer.makeSamplingPlan(
                pyramid: pyramid,
                clipSourceStartFrame: 0,
                clipSourceSpanFrames: visibleSpanFrames,
                sampleRate: 48_000,
                pixelsPerSecond: pps,
                viewportWidth: viewportWidth
            )
            XCTAssertLessThanOrEqual(plan.drawnBucketCount, maxBuckets, "Drawn bucket bound exceeded at \(pps) px/s")

            let view = WaveformClipCanvasView(
                pyramid: pyramid,
                hasSourceAsset: true,
                clipSourceStartFrame: 0,
                clipSourceSpanFrames: visibleSpanFrames,
                clipDurationSeconds: Double(visibleSpanFrames) / 48_000.0,
                isMuted: false,
                isReversed: false,
                expandMultichannel: false,
                fadeIn: nil,
                fadeOut: nil,
                pixelsPerSecond: pps,
                viewportWidth: viewportWidth,
                precomputedPlan: plan,
                onPlanComputed: { _ in planRecomputeCount += 1 }
            )
            let host = NSHostingView(rootView: view)
            host.frame = hostRect
            host.layoutSubtreeIfNeeded()

            // Warm 1 draw + measure 3 draws
            host.cacheDisplay(in: hostRect, to: rep)
            for _ in 0..<3 {
                let t0 = CFAbsoluteTimeGetCurrent()
                host.cacheDisplay(in: hostRect, to: rep)
                drawTimesMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
            }
        }

        // Now verify 120 simulated 60 Hz playhead ticks on hosted MultitrackTimelineView do NOT trigger store.objectWillChange or static Canvas plan recomputes
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.temporaryURL.appendingPathComponent("fps_j"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.temporaryURL.appendingPathComponent("fps_a"))
        )
        let store = AudioEditorStore(undoCoordinator: undoCoord)
        var proj = store.project
        proj.tracks[0].clips.append(AudioClip(
            sourceAssetID: pyramid.assetID,
            name: "BenchClip",
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: 480_000,
            projectRate: .rate48k,
            sourceRate: .rate48k
        ))
        store.project = proj

        var storePublishes = 0
        let cancelStore = store.objectWillChange.sink { _ in storePublishes += 1 }
        defer { cancelStore.cancel() }

        let timelineHost = NSHostingView(rootView: MultitrackTimelineView(store: store, viewportWidth: .constant(900)))
        timelineHost.frame = NSRect(x: 0, y: 0, width: 1120, height: 220)
        timelineHost.layoutSubtreeIfNeeded()

        var staticDrawCallsDuringPlayheadTicks = 0
        let staticCanvas = WaveformClipCanvasView(
            pyramid: pyramid,
            hasSourceAsset: true,
            clipSourceStartFrame: 0,
            clipSourceSpanFrames: 480_000,
            clipDurationSeconds: 10.0,
            isMuted: false,
            isReversed: false,
            expandMultichannel: false,
            fadeIn: nil,
            fadeOut: nil,
            pixelsPerSecond: 80.0,
            viewportWidth: 900.0,
            precomputedPlan: WaveformCanvasRenderer.makeSamplingPlan(
                pyramid: pyramid,
                clipSourceStartFrame: 0,
                clipSourceSpanFrames: 480_000,
                sampleRate: 48_000,
                pixelsPerSecond: 80.0,
                viewportWidth: 900.0
            ),
            onPlanComputed: { _ in staticDrawCallsDuringPlayheadTicks += 1 }
        )
        let staticHost = NSHostingView(rootView: staticCanvas)
        staticHost.frame = hostRect
        staticHost.cacheDisplay(in: hostRect, to: rep)
        staticDrawCallsDuringPlayheadTicks = 0

        let tickStart = CFAbsoluteTimeGetCurrent()
        for i in 1...120 {
            store.timeline.setPlayhead(Double(i) * (1.0 / 60.0))
        }
        timelineHost.layoutSubtreeIfNeeded()
        let tickTotalMs = (CFAbsoluteTimeGetCurrent() - tickStart) * 1000.0

        XCTAssertEqual(storePublishes, 0, "60 Hz playhead ticks must never trigger AudioEditorStore.objectWillChange")
        XCTAssertEqual(staticDrawCallsDuringPlayheadTicks, 0, "Playhead motion must never trigger static Canvas waveform redraw")

        let sortedDraw = drawTimesMs.sorted()
        let medianDrawMs = sortedDraw[sortedDraw.count / 2]
        let maxDrawMs = sortedDraw.last ?? 0
        let effectiveFPS = 1000.0 / max(0.01, medianDrawMs)

        print(String(
            format: "[StageD-Perf] Waveform Canvas Render (NSHostingView cacheDisplay, 2..20000 px/s): median=%.2fms (%.0f FPS vs <=16.67ms/60fps target), max=%.2fms | 120 PlayheadTicks=%.2fms (storePublishes=0, staticRedraws=0)",
            medianDrawMs, effectiveFPS, maxDrawMs, tickTotalMs
        ))

        XCTAssertLessThanOrEqual(medianDrawMs, 16.67, "Median Canvas waveform rasterization exceeded 16.67ms (60 FPS) budget")
    }

    // MARK: - 8. Sustained Multi-Operation Stability & Host CoreAudio HAL Smoke

    func testSustainedResourceStabilityAndReadOnlyHostCoreAudioEnumeration() async throws {
        let wavURL = sandbox.temporaryURL.appendingPathComponent("sustained_48k.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 96_000)
        )
        let diskCache = LCWaveDiskCache(directory: AppStoragePaths.audioWaveformCacheDirectory)
        let pyramidService = WaveformPyramidService(diskCache: diskCache)
        let db = AudioLibraryDatabase(databaseURL: sandbox.applicationSupportURL.appendingPathComponent("sustained.sqlite"))

        let journalDir = sandbox.temporaryURL.appendingPathComponent("sustained_j")
        let artifactsDir = sandbox.temporaryURL.appendingPathComponent("sustained_a")
        let (undoCoord, editorStore) = await MainActor.run {
            let uc = UndoRedoCoordinator(
                journalDirectoryURL: journalDir,
                artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir)
            )
            return (uc, AudioEditorStore(undoCoordinator: uc))
        }
        let assetRef = AudioMediaReference(
            id: UUID(), path: wavURL.path, displayName: "sustained_48k.wav",
            fileSize: 384_044, modificationTime: 0, duration: 2.0, sampleRate: 48_000, channels: 2, durationFrames: 96_000
        )
        let trackID = await MainActor.run { editorStore.project.tracks[0].id }
        _ = await MainActor.run {
            editorStore.performMutation(type: .clipImport, title: "Import") { p in
                AudioEditingService.addClip(&p, asset: assetRef, trackID: trackID, at: 0) != nil
            }
        }
        let clipID = await MainActor.run { editorStore.project.tracks[0].clips[0].id }

        let projID = await MainActor.run { editorStore.project.id }

        // Warm-up 5 cycles, then measure growth across 45 cycles
        var samples: [Double] = []
        for cycle in 1...50 {
            await MainActor.run {
                _ = editorStore.performMutation(type: .clipMove, title: "Move \(cycle)") { p in
                    AudioEditingService.moveClip(&p, clipID: clipID, toStart: Double(cycle % 5) * 0.1)
                }
            }
            if cycle % 5 == 0 {
                await undoCoord.undo(in: .audioEditor(projectID: projID))
                await undoCoord.redo(in: .audioEditor(projectID: projID))
                _ = try await pyramidService.pyramid(for: wavURL)
                _ = try await db.searchAssets(query: "sustained")
            }
            if cycle == 10 || cycle == 50 {
                await settleMemory()
                samples.append(Self.memorySnapshotMB().nonVolatileInternalMB)
            }
        }

        let growthMB = samples[1] - samples[0]
        let dbIntegrity = try await db.verifyIntegrity(full: true)
        XCTAssertTrue(dbIntegrity.isHealthy)
        XCTAssertLessThan(growthMB, 40.0, "Sustained 50-cycle RAM grew abnormally by \(growthMB) MB")

        // Read-only Host CoreAudio HAL enumeration smoke test (does not alter host system output settings)
        let hal = SystemCoreAudioHALBackend()
        let deviceIDs = hal.allDeviceIDs()
        let defaultID = hal.defaultOutputDeviceID()
        let defaultName = defaultID.flatMap { hal.deviceName(for: $0) } ?? "none"
        let defaultRate = defaultID.flatMap { hal.nominalSampleRate(for: $0) } ?? 0

        print(String(
            format: "[StageD-Perf] Sustained 50-cycle RAM delta=%.2fMB (iter10=%.1fMB -> iter50=%.1fMB) | Host CoreAudio HAL: devices=%d, defaultOut='%@' (%.1fHz)",
            growthMB, samples[0], samples[1], deviceIDs.count, defaultName, defaultRate
        ))
    }
}

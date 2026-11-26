import Foundation
import AVFoundation
import Accelerate
import os

// MARK: - Errors & Policy

enum WaveformPyramidError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case invalidFormat(String)
    case chunkLimitExceeded(frames: Int, payloadBytes: Int, maxFrames: Int, maxPayloadBytes: Int)
    case ffmpegUnavailable
    case ffmpegFailed(Int32, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Audio file not found: \(path)"
        case .invalidFormat(let detail):
            return "Unable to inspect audio format: \(detail)"
        case .chunkLimitExceeded(let frames, let bytes, let maxFrames, let maxBytes):
            return "PCM chunk (\(frames) frames, \(bytes) bytes) exceeds dual limit (max \(maxFrames) frames, max \(maxBytes) bytes)."
        case .ffmpegUnavailable:
            return "Bundled FFmpeg/FFprobe binaries are unavailable for streaming waveform decode."
        case .ffmpegFailed(let status, let detail):
            return "Bundled FFmpeg waveform decode failed (exit \(status)): \(detail)"
        case .cancelled:
            return "Waveform pyramid generation was cancelled."
        }
    }
}

/// Enforces Stage A dual PCM input chunk limits:
/// - Maximum frames per PCM processing chunk: `65,536` frames
/// - Maximum aggregate decoded PCM input payload per chunk across all channels/planes: `262,144` bytes (256 KiB)
enum PCMChunkLimitPolicy {
    static let maxFramesPerChunk: Int = 65_536
    static let maxInputPayloadBytes: Int = 262_144

    /// Computes `min(65_536, floor(262_144 / (channelCount * bytesPerSample)))`.
    static func maxFrames(channelCount: Int, bytesPerSample: Int) -> Int {
        guard channelCount >= 1, bytesPerSample >= 1 else { return 0 }
        let (bytesPerFrame, overflow) = channelCount.multipliedReportingOverflow(by: bytesPerSample)
        guard !overflow, bytesPerFrame > 0, bytesPerFrame <= maxInputPayloadBytes else { return 0 }
        return min(maxFramesPerChunk, maxInputPayloadBytes / bytesPerFrame)
    }

    /// Computes aggregate decoded PCM input payload bytes across all channels (interleaved or planar).
    static func inputPayloadBytes(
        frameCount: Int,
        channelCount: Int,
        bytesPerSample: Int,
        isPlanar: Bool
    ) -> Int? {
        _ = isPlanar // Aggregate payload sums all planes/channels equally for both layouts.
        guard frameCount >= 0, channelCount >= 1, bytesPerSample >= 1 else { return nil }
        let (bytesPerFrame, ov1) = channelCount.multipliedReportingOverflow(by: bytesPerSample)
        guard !ov1 else { return nil }
        let (totalBytes, ov2) = frameCount.multipliedReportingOverflow(by: bytesPerFrame)
        guard !ov2 else { return nil }
        return totalBytes
    }

    /// Validates a single PCM chunk against both the frame cap and the 256 KiB aggregate byte cap.
    static func validateChunk(
        frameCount: Int,
        channelCount: Int,
        bytesPerSample: Int,
        isPlanar: Bool
    ) throws {
        let allowedFrames = maxFrames(channelCount: channelCount, bytesPerSample: bytesPerSample)
        guard frameCount > 0,
              allowedFrames > 0,
              let payloadBytes = inputPayloadBytes(
                frameCount: frameCount,
                channelCount: channelCount,
                bytesPerSample: bytesPerSample,
                isPlanar: isPlanar
              ) else {
            throw WaveformPyramidError.chunkLimitExceeded(
                frames: frameCount,
                payloadBytes: Int.max,
                maxFrames: allowedFrames,
                maxPayloadBytes: maxInputPayloadBytes
            )
        }
        guard frameCount <= maxFramesPerChunk,
              frameCount <= allowedFrames,
              payloadBytes <= maxInputPayloadBytes else {
            throw WaveformPyramidError.chunkLimitExceeded(
                frames: frameCount,
                payloadBytes: payloadBytes,
                maxFrames: allowedFrames,
                maxPayloadBytes: maxInputPayloadBytes
            )
        }
    }
}

// MARK: - vDSP Multi-Resolution Incremental Accumulator

private struct PyramidAccumulator {
    private struct RunningBucket {
        var minVal: Float = .greatestFiniteMagnitude
        var maxVal: Float = -.greatestFiniteMagnitude
        var sumSquares: Double = 0
        var sampleCount: Int = 0
        var clipped: Bool = false
        var childCount: Int = 0

        mutating func appendSamples(pointer: UnsafePointer<Float>, count n: Int) {
            guard n > 0 else { return }
            var segMin: Float = 0
            var segMax: Float = 0
            var segSumSq: Float = 0
            vDSP_minv(pointer, 1, &segMin, vDSP_Length(n))
            vDSP_maxv(pointer, 1, &segMax, vDSP_Length(n))
            vDSP_svesq(pointer, 1, &segSumSq, vDSP_Length(n))

            let safeMin = segMin.isFinite ? segMin : 0
            let safeMax = segMax.isFinite ? segMax : 0
            let safeSumSq = segSumSq.isFinite ? Double(segSumSq) : 0

            if sampleCount == 0 {
                minVal = safeMin
                maxVal = safeMax
            } else {
                minVal = min(minVal, safeMin)
                maxVal = max(maxVal, safeMax)
            }
            if abs(safeMin) >= 1.0 || abs(safeMax) >= 1.0 || !segMin.isFinite || !segMax.isFinite {
                clipped = true
            }
            sumSquares += safeSumSq
            sampleCount += n
        }

        mutating func appendChild(minSample: Float, maxSample: Float, sumSquares childSumSq: Double, sampleCount childSamples: Int, clipped childClipped: Bool) {
            if childCount == 0 {
                minVal = minSample
                maxVal = maxSample
            } else {
                minVal = min(minVal, minSample)
                maxVal = max(maxVal, maxSample)
            }
            clipped = clipped || childClipped
            sumSquares += childSumSq
            sampleCount += childSamples
            childCount += 1
        }

        func makeBucket() -> WaveformBucket {
            let denom = max(1, sampleCount)
            let rms = Float(sqrt(max(0.0, sumSquares / Double(denom))))
            return WaveformBucket(
                minSample: sampleCount > 0 ? minVal : 0,
                maxSample: sampleCount > 0 ? maxVal : 0,
                rms: rms.isFinite ? rms : 0,
                clipped: clipped
            )
        }
    }

    let sampleRate: Int32
    let channelCount: Int
    let assetID: UUID?
    let cacheKey: String
    let tierBucketSizes: [Int]
    let baseBucketSize: Int
    private(set) var completedFrames: Int64 = 0

    // finalized[tier][channel] stores completed buckets directly without intermediate wrappers.
    private var finalized: [[[WaveformBucket]]]
    private var partials: [[RunningBucket]]

    static func adaptiveStartLevelIndex(
        estimatedTotalFrames: Int64,
        channelCount: Int,
        memoryBudgetBytes: Int = WaveformPyramidService.defaultMaxMemoryBytes / 2
    ) -> Int {
        let sizes = WaveformPyramid.standardBucketSizes
        guard estimatedTotalFrames > 0, channelCount > 0, memoryBudgetBytes > 0 else { return 0 }
        let safeCh = Int64(max(1, channelCount))
        for idx in 0..<sizes.count {
            var estimatedBytes: Int64 = 128
            for tier in idx..<sizes.count {
                let fpb = Int64(sizes[tier])
                let buckets = (estimatedTotalFrames + fpb - 1) / fpb
                let (tierBuckets, ov1) = buckets.multipliedReportingOverflow(by: safeCh)
                let (tierBytes, ov2) = tierBuckets.multipliedReportingOverflow(by: 16)
                if ov1 || ov2 {
                    estimatedBytes = Int64.max
                    break
                }
                estimatedBytes = estimatedBytes &+ tierBytes
            }
            if estimatedBytes <= Int64(memoryBudgetBytes) {
                return idx
            }
        }
        return sizes.count - 1
    }

    init(
        assetID: UUID?,
        cacheKey: String,
        sampleRate: Int32,
        channelCount: Int,
        estimatedTotalFrames: Int64 = 0
    ) {
        self.assetID = assetID
        self.cacheKey = cacheKey
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        let startIdx = Self.adaptiveStartLevelIndex(
            estimatedTotalFrames: estimatedTotalFrames,
            channelCount: self.channelCount
        )
        let sizes = Array(WaveformPyramid.standardBucketSizes[startIdx...])
        self.tierBucketSizes = sizes
        self.baseBucketSize = sizes[0]
        self.finalized = Array(
            repeating: Array(repeating: [], count: self.channelCount),
            count: sizes.count
        )
        self.partials = Array(
            repeating: Array(repeating: RunningBucket(), count: self.channelCount),
            count: sizes.count
        )

        if estimatedTotalFrames > 0 {
            for tierIdx in 0..<sizes.count {
                let fpb = Int64(sizes[tierIdx])
                let expectedBuckets = Int(min(Int64(2_000_000), (estimatedTotalFrames + fpb - 1) / fpb))
                if expectedBuckets > 0 {
                    for ch in 0..<self.channelCount {
                        self.finalized[tierIdx][ch].reserveCapacity(expectedBuckets)
                    }
                }
            }
        }
    }

    mutating func appendPlanarChunk(channels: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        guard frameCount > 0 else { return }
        for ch in 0..<channelCount {
            let chPtr = channels[ch]
            var offset = 0
            while offset < frameCount {
                let remainingInBucket = baseBucketSize - partials[0][ch].sampleCount
                let sliceCount = min(remainingInBucket, frameCount - offset)
                partials[0][ch].appendSamples(pointer: chPtr.advanced(by: offset), count: sliceCount)
                if partials[0][ch].sampleCount == baseBucketSize {
                    emitBaseBucket(channel: ch)
                }
                offset += sliceCount
            }
        }
        completedFrames += Int64(frameCount)
    }

    mutating func appendDeinterleavedBuffers(_ planes: [[Float]], frameCount: Int) {
        guard frameCount > 0 else { return }
        for ch in 0..<min(channelCount, planes.count) {
            planes[ch].withUnsafeBufferPointer { buf in
                guard let ptr = buf.baseAddress else { return }
                var offset = 0
                while offset < frameCount {
                    let remainingInBucket = baseBucketSize - partials[0][ch].sampleCount
                    let sliceCount = min(remainingInBucket, frameCount - offset)
                    partials[0][ch].appendSamples(pointer: ptr.advanced(by: offset), count: sliceCount)
                    if partials[0][ch].sampleCount == baseBucketSize {
                        emitBaseBucket(channel: ch)
                    }
                    offset += sliceCount
                }
            }
        }
        completedFrames += Int64(frameCount)
    }

    private mutating func emitBaseBucket(channel ch: Int) {
        let running = partials[0][ch]
        let bucket = running.makeBucket()
        finalized[0][ch].append(bucket)
        partials[0][ch] = RunningBucket()

        var carryMin = bucket.minSample
        var carryMax = bucket.maxSample
        var carrySumSq = running.sumSquares
        var carrySamples = running.sampleCount
        var carryClipped = bucket.clipped

        for tier in 1..<tierBucketSizes.count {
            partials[tier][ch].appendChild(
                minSample: carryMin,
                maxSample: carryMax,
                sumSquares: carrySumSq,
                sampleCount: carrySamples,
                clipped: carryClipped
            )
            if partials[tier][ch].childCount == 4 {
                let parentRunning = partials[tier][ch]
                let parentBucket = parentRunning.makeBucket()
                finalized[tier][ch].append(parentBucket)
                partials[tier][ch] = RunningBucket()
                carryMin = parentBucket.minSample
                carryMax = parentBucket.maxSample
                carrySumSq = parentRunning.sumSquares
                carrySamples = parentRunning.sampleCount
                carryClipped = parentBucket.clipped
            } else {
                break
            }
        }
    }

    func snapshot(expectedTotalFrames: Int64, isPartial: Bool, coarseOnly: Bool = false) -> WaveformPyramid {
        // Compute trailing folded partials cleanly without mutating finalized arrays.
        var trailingPerTier: [[WaveformBucket?]] = Array(
            repeating: Array(repeating: nil, count: channelCount),
            count: tierBucketSizes.count
        )

        for ch in 0..<channelCount {
            var carry: RunningBucket? = partials[0][ch].sampleCount > 0 ? partials[0][ch] : nil
            if let c = carry {
                trailingPerTier[0][ch] = c.makeBucket()
            }
            for tier in 1..<tierBucketSizes.count {
                var combined = partials[tier][ch]
                if let c = carry {
                    combined.appendChild(
                        minSample: c.minVal,
                        maxSample: c.maxVal,
                        sumSquares: c.sumSquares,
                        sampleCount: c.sampleCount,
                        clipped: c.clipped
                    )
                }
                if combined.sampleCount > 0 {
                    trailingPerTier[tier][ch] = combined.makeBucket()
                    carry = combined
                } else {
                    carry = nil
                }
            }
        }

        let startTier = coarseOnly ? max(0, tierBucketSizes.count - 2) : 0
        var builtLevels: [WaveformMipLevel] = []
        builtLevels.reserveCapacity(tierBucketSizes.count - startTier)

        for tier in startTier..<tierBucketSizes.count {
            let chLevels = (0..<channelCount).map { ch in
                var buckets = finalized[tier][ch]
                if let tail = trailingPerTier[tier][ch] {
                    buckets.append(tail)
                }
                return WaveformChannelLevel(channelIndex: ch, buckets: buckets)
            }
            builtLevels.append(WaveformMipLevel(framesPerBucket: tierBucketSizes[tier], channels: chLevels))
        }

        let finalTotalFrames = isPartial ? max(expectedTotalFrames, completedFrames) : completedFrames
        let duration = sampleRate > 0 ? Double(finalTotalFrames) / Double(sampleRate) : 0
        return WaveformPyramid(
            assetID: assetID,
            cacheKey: cacheKey,
            sampleRate: sampleRate,
            channelCount: channelCount,
            totalFrames: finalTotalFrames,
            duration: duration,
            levels: builtLevels,
            isPartial: isPartial,
            completedFrames: completedFrames
        )
    }
}

// MARK: - Streaming FFmpeg Process Helper

private final class WaveformFFmpegProcessBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ProcessState())

    private struct ProcessState {
        var process: Process?
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?
        var stderrData = Data()
        var exited = false
        var exitStatus: Int32 = 0
        var cancelled = false
        var exitWaiters: [@Sendable (Int32) -> Void] = []
    }

    func attach(process: Process, stdout: FileHandle, stderr: FileHandle) {
        lock.withLock { state in
            state.process = process
            state.stdoutHandle = stdout
            state.stderrHandle = stderr
        }
    }

    func appendStderr(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { state in
            if state.stderrData.count < 16_384 {
                state.stderrData.append(chunk.prefix(16_384 - state.stderrData.count))
            }
        }
    }

    func stderrText() -> String {
        lock.withLock { state in
            String(data: state.stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    func markExited(status: Int32) {
        let waiters: [@Sendable (Int32) -> Void] = lock.withLock { state in
            state.exited = true
            state.exitStatus = status
            let list = state.exitWaiters
            state.exitWaiters.removeAll()
            return list
        }
        for waiter in waiters {
            waiter(status)
        }
    }

    func terminateAndClosePipes() {
        let (proc, outH, errH, exited, waiters) = lock.withLock { state -> (Process?, FileHandle?, FileHandle?, Bool, [@Sendable (Int32) -> Void]) in
            state.cancelled = true
            let p = state.process
            let o = state.stdoutHandle
            let e = state.stderrHandle
            let x = state.exited
            let list = state.exitWaiters
            state.exitWaiters.removeAll()
            state.process = nil
            state.stdoutHandle = nil
            state.stderrHandle = nil
            return (p, o, e, x, list)
        }

        for waiter in waiters {
            waiter(-1)
        }

        // Close read-side pipes before terminating so any blocked pipe write unblocks immediately.
        try? outH?.close()
        try? errH?.close()

        if let proc, !exited, proc.isRunning {
            let pid = proc.processIdentifier
            proc.terminate()
            if pid > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(200)) {
                    if proc.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }

    var wasCancelled: Bool {
        lock.withLock { $0.cancelled }
    }

    func awaitExit(timeoutMilliseconds: Int = 2_000) async -> Int32 {
        let immediate: Int32? = lock.withLock { state in
            if state.exited { return state.exitStatus }
            if let proc = state.process, !proc.isRunning {
                state.exited = true
                state.exitStatus = proc.terminationStatus
                return state.exitStatus
            }
            if state.process == nil { return 0 }
            return nil
        }
        if let immediate { return immediate }

        return await withCheckedContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) { [weak self] in
                guard resumed.withLock({ r in let first = !r; r = true; return first }) else { return }
                self?.terminateAndClosePipes()
                cont.resume(returning: -1)
            }

            let immediateNow: Int32? = lock.withLock { state in
                if state.exited { return state.exitStatus }
                if let proc = state.process, !proc.isRunning {
                    state.exited = true
                    state.exitStatus = proc.terminationStatus
                    return state.exitStatus
                }
                state.exitWaiters.append { status in
                    guard resumed.withLock({ r in let first = !r; r = true; return first }) else { return }
                    cont.resume(returning: status)
                }
                return nil
            }
            if let immediateNow {
                guard resumed.withLock({ r in let first = !r; r = true; return first }) else { return }
                cont.resume(returning: immediateNow)
            }
        }
    }
}

// MARK: - WaveformPyramidService

/// Multi-resolution waveform pyramid generator combining:
/// - `64 MB` in-memory LRU cache
/// - `.lcwave` persistent disk cache via `LCWaveDiskCache`
/// - Dual-bounded streaming PCM decode (`<= 65,536` frames AND `<= 256 KiB` aggregate payload/chunk)
/// - Native `AVAudioFile` + bundled FFmpeg streaming pipes + `Accelerate`/`vDSP`
/// - Cooperative cancellation and ref-counted in-flight deduplication
actor WaveformPyramidService {
    static let shared = WaveformPyramidService()
    static let defaultMaxMemoryBytes: Int = 64 * 1024 * 1024

    private struct MemoryEntry {
        let pyramid: WaveformPyramid
        let bytes: Int
        var lastAccessTick: UInt64
    }

    private struct StreamProbeMetadata: Sendable {
        let sampleRate: Int32
        let channelCount: Int
        let estimatedTotalFrames: Int64
        let isNativeReadable: Bool
    }

    private struct InFlightBuild {
        let task: Task<WaveformPyramid, Error>
        var waiterContinuations: [UUID: CheckedContinuation<WaveformPyramid, Error>] = [:]
        var activeWaiterIDs: Set<UUID> = []
        var earlyResults: [UUID: Result<WaveformPyramid, Error>] = [:]
        var progressHandlers: [UUID: @Sendable (WaveformBuildProgress) -> Void] = [:]
    }

    struct TestingMetrics: Sendable, Equatable {
        var lastMaxChunkFrames: Int = 0
        var lastMaxChunkPayloadBytes: Int = 0
        var lastBackendUsed: String = ""
        var buildCount: Int = 0
    }

    private let diskCache: LCWaveDiskCache
    private let maxMemoryBytes: Int
    private let customFFmpegPathProvider: (@Sendable () async -> String?)?
    private let customFFprobePathProvider: (@Sendable () async -> String?)?
    private let forceFFmpegForTesting: Bool

    private var memoryCache: [String: MemoryEntry] = [:]
    private var memoryBytes: Int = 0
    private var accessTick: UInt64 = 0

    private var inFlightBuilds: [String: InFlightBuild] = [:]
    private var cancelledWaiterIDs: Set<UUID> = []
    private var testingMetrics = TestingMetrics()

    init(
        diskCache: LCWaveDiskCache = LCWaveDiskCache(),
        maxMemoryBytes: Int = WaveformPyramidService.defaultMaxMemoryBytes,
        ffmpegPathProvider: (@Sendable () async -> String?)? = nil,
        ffprobePathProvider: (@Sendable () async -> String?)? = nil,
        forceFFmpegForTesting: Bool = false
    ) {
        self.diskCache = diskCache
        self.maxMemoryBytes = max(0, maxMemoryBytes)
        self.customFFmpegPathProvider = ffmpegPathProvider
        self.customFFprobePathProvider = ffprobePathProvider
        self.forceFFmpegForTesting = forceFFmpegForTesting
    }

    // MARK: - Public API

    func pyramid(
        for url: URL,
        assetID: UUID? = nil,
        onProgress: (@Sendable (WaveformBuildProgress) -> Void)? = nil
    ) async throws -> WaveformPyramid {
        try Task.checkCancellation()

        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPath = canonicalURL.path
        guard FileManager.default.fileExists(atPath: canonicalPath) else {
            throw WaveformPyramidError.fileNotFound(canonicalPath)
        }

        let fp = AudioMediaReference.fingerprint(of: canonicalURL)
        let probe = try await probeMetadata(for: canonicalURL)
        let cacheKey = LCWaveDiskCache.cacheKey(
            canonicalPath: canonicalPath,
            fileSize: fp.size,
            modificationTime: fp.mtime,
            channelCount: probe.channelCount
        )

        // 1. RAM LRU hit
        if let hit = touchMemoryCache(forKey: cacheKey) {
            onProgress?(WaveformBuildProgress(
                completedFrames: hit.totalFrames,
                totalFrames: hit.totalFrames,
                isComplete: true,
                pyramid: hit
            ))
            return hit
        }

        // 2. .lcwave Disk Cache hit
        if let diskHit = await diskCache.load(cacheKey: cacheKey, assetID: assetID) {
            insertMemoryCache(diskHit, forKey: cacheKey)
            onProgress?(WaveformBuildProgress(
                completedFrames: diskHit.totalFrames,
                totalFrames: diskHit.totalFrames,
                isComplete: true,
                pyramid: diskHit
            ))
            return diskHit
        }

        // 3. In-flight deduplication + cooperative ref-counted cancellation
        let waiterID = UUID()
        registerWaiter(
            waiterID,
            forKey: cacheKey,
            onProgress: onProgress,
            canonicalURL: canonicalURL,
            assetID: assetID,
            probe: probe
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    self.bindWaiterContinuation(continuation, waiterID: waiterID, forKey: cacheKey)
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, forKey: cacheKey)
            }
        }
    }

    func cachedMemoryBytes() -> Int {
        memoryBytes
    }

    func cachedKeyCount() -> Int {
        memoryCache.count
    }

    func clearMemoryCache() {
        memoryCache.removeAll()
        memoryBytes = 0
    }

    func inFlightCount() -> Int {
        inFlightBuilds.count
    }

    func metricsForTesting() -> TestingMetrics {
        testingMetrics
    }

    // MARK: - In-Flight Waiter Management

    private func registerWaiter(
        _ waiterID: UUID,
        forKey cacheKey: String,
        onProgress: (@Sendable (WaveformBuildProgress) -> Void)?,
        canonicalURL: URL,
        assetID: UUID?,
        probe: StreamProbeMetadata
    ) {
        if var existing = inFlightBuilds[cacheKey] {
            existing.activeWaiterIDs.insert(waiterID)
            if let onProgress {
                existing.progressHandlers[waiterID] = onProgress
            }
            inFlightBuilds[cacheKey] = existing
            return
        }

        let useNative = probe.isNativeReadable && !forceFFmpegForTesting
        let hasProgressHandlers = (onProgress != nil)
        let diskCache = self.diskCache
        let ffmpegProvider = self.customFFmpegPathProvider
        let progressSink: (@Sendable (WaveformBuildProgress) async -> Void)?
        if hasProgressHandlers {
            progressSink = { [weak self] progress in
                await self?.dispatchProgress(progress, forKey: cacheKey)
            }
        } else {
            progressSink = nil
        }

        var build = InFlightBuild(
            task: Task.detached(priority: .utility) { [weak service = self] in
                do {
                    let result: WaveformPyramid
                    let metrics: TestingMetrics
                    if useNative {
                        (result, metrics) = try await Self.buildNativeAVAudioFile(
                            url: canonicalURL,
                            assetID: assetID,
                            cacheKey: cacheKey,
                            probe: probe,
                            progressCallback: progressSink
                        )
                    } else {
                        let resolvedFFmpeg: String?
                        if let ffmpegProvider {
                            resolvedFFmpeg = await ffmpegProvider()
                        } else {
                            resolvedFFmpeg = await BundledFFmpegProvider(fallbackToSystem: false).findFFmpegPath()
                        }
                        guard let ffmpegPath = resolvedFFmpeg else {
                            throw WaveformPyramidError.ffmpegUnavailable
                        }
                        (result, metrics) = try await Self.buildFFmpegStreaming(
                            url: canonicalURL,
                            assetID: assetID,
                            cacheKey: cacheKey,
                            probe: probe,
                            ffmpegPath: ffmpegPath,
                            progressCallback: progressSink
                        )
                    }

                    try? await diskCache.store(result, forKey: cacheKey)
                    await service?.completeBuild(forKey: cacheKey, result: .success(result), metrics: metrics)
                    return result
                } catch {
                    let mappedError: Error = (error is CancellationError) ? error : error
                    await service?.completeBuild(forKey: cacheKey, result: .failure(mappedError), metrics: nil)
                    throw mappedError
                }
            }
        )
        build.activeWaiterIDs.insert(waiterID)
        if let onProgress {
            build.progressHandlers[waiterID] = onProgress
        }
        inFlightBuilds[cacheKey] = build
    }

    private func bindWaiterContinuation(
        _ continuation: CheckedContinuation<WaveformPyramid, Error>,
        waiterID: UUID,
        forKey cacheKey: String
    ) {
        if cancelledWaiterIDs.remove(waiterID) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        if var build = inFlightBuilds[cacheKey] {
            if let early = build.earlyResults.removeValue(forKey: waiterID) {
                build.activeWaiterIDs.remove(waiterID)
                if build.activeWaiterIDs.isEmpty && build.earlyResults.isEmpty && build.waiterContinuations.isEmpty {
                    inFlightBuilds.removeValue(forKey: cacheKey)
                } else {
                    inFlightBuilds[cacheKey] = build
                }
                continuation.resume(with: early)
                return
            }
            if !build.activeWaiterIDs.contains(waiterID), let cached = touchMemoryCache(forKey: cacheKey) {
                continuation.resume(returning: cached)
                return
            }
            build.waiterContinuations[waiterID] = continuation
            inFlightBuilds[cacheKey] = build
            return
        }

        if let cached = touchMemoryCache(forKey: cacheKey) {
            continuation.resume(returning: cached)
            return
        }

        continuation.resume(throwing: CancellationError())
    }

    private func cancelWaiter(_ waiterID: UUID, forKey cacheKey: String) {
        guard var build = inFlightBuilds[cacheKey] else {
            cancelledWaiterIDs.insert(waiterID)
            return
        }

        build.activeWaiterIDs.remove(waiterID)
        build.progressHandlers.removeValue(forKey: waiterID)
        build.earlyResults.removeValue(forKey: waiterID)

        if let cont = build.waiterContinuations.removeValue(forKey: waiterID) {
            cont.resume(throwing: CancellationError())
        } else {
            cancelledWaiterIDs.insert(waiterID)
        }

        if build.activeWaiterIDs.isEmpty {
            let taskToCancel = build.task
            inFlightBuilds.removeValue(forKey: cacheKey)
            taskToCancel.cancel()
        } else {
            inFlightBuilds[cacheKey] = build
        }
    }

    private func dispatchProgress(_ progress: WaveformBuildProgress, forKey cacheKey: String) {
        guard let build = inFlightBuilds[cacheKey] else { return }
        for handler in build.progressHandlers.values {
            handler(progress)
        }
    }

    private func completeBuild(
        forKey cacheKey: String,
        result: Result<WaveformPyramid, Error>,
        metrics: TestingMetrics?
    ) {
        if case .success(let pyramid) = result {
            insertMemoryCache(pyramid, forKey: cacheKey)
        }
        if let metrics {
            testingMetrics.lastMaxChunkFrames = metrics.lastMaxChunkFrames
            testingMetrics.lastMaxChunkPayloadBytes = metrics.lastMaxChunkPayloadBytes
            testingMetrics.lastBackendUsed = metrics.lastBackendUsed
            testingMetrics.buildCount += 1
        }

        guard let build = inFlightBuilds.removeValue(forKey: cacheKey) else {
            return
        }

        if case .success(let pyramid) = result {
            let finalProgress = WaveformBuildProgress(
                completedFrames: pyramid.totalFrames,
                totalFrames: pyramid.totalFrames,
                isComplete: true,
                pyramid: pyramid
            )
            for handler in build.progressHandlers.values {
                handler(finalProgress)
            }
        }

        for (_, cont) in build.waiterContinuations {
            cont.resume(with: result)
        }
        // Keep early results until `bindWaiterContinuation` (which always executes once per waiter) consumes them.
        let unattached = build.activeWaiterIDs.subtracting(build.waiterContinuations.keys)
        if !unattached.isEmpty {
            var placeholder = build
            placeholder.waiterContinuations.removeAll()
            for waiterID in unattached {
                placeholder.earlyResults[waiterID] = result
            }
            inFlightBuilds[cacheKey] = placeholder
        }
    }

    // MARK: - RAM LRU Cache

    private func touchMemoryCache(forKey key: String) -> WaveformPyramid? {
        guard var entry = memoryCache[key] else { return nil }
        accessTick &+= 1
        entry.lastAccessTick = accessTick
        memoryCache[key] = entry
        return entry.pyramid
    }

    private func insertMemoryCache(_ pyramid: WaveformPyramid, forKey key: String) {
        let entryBytes = pyramid.estimatedMemoryBytes
        guard entryBytes <= maxMemoryBytes || maxMemoryBytes == 0 else {
            return
        }
        if let existing = memoryCache.removeValue(forKey: key) {
            memoryBytes -= existing.bytes
        }
        accessTick &+= 1
        memoryCache[key] = MemoryEntry(pyramid: pyramid, bytes: entryBytes, lastAccessTick: accessTick)
        memoryBytes += entryBytes

        while memoryBytes > maxMemoryBytes {
            let evictCandidate = memoryCache
                .filter { $0.key != key }
                .min { $0.value.lastAccessTick < $1.value.lastAccessTick }
            guard let victim = evictCandidate else { break }
            memoryBytes -= victim.value.bytes
            memoryCache.removeValue(forKey: victim.key)
        }
    }

    // MARK: - Format Probing

    private func probeMetadata(for url: URL) async throws -> StreamProbeMetadata {
        if let file = try? AVAudioFile(forReading: url) {
            let fmt = file.processingFormat
            let sr = Int32(fmt.sampleRate.rounded())
            let ch = max(1, Int(fmt.channelCount))
            if sr > 0 && SampleRate.validRange.contains(sr) {
                return StreamProbeMetadata(
                    sampleRate: sr,
                    channelCount: ch,
                    estimatedTotalFrames: max(0, file.length),
                    isNativeReadable: true
                )
            }
        }

        let resolvedFFprobe: String?
        if let customFFprobePathProvider {
            resolvedFFprobe = await customFFprobePathProvider()
        } else {
            resolvedFFprobe = await BundledFFmpegProvider(fallbackToSystem: false).findFFprobePath()
        }

        if let ffprobePath = resolvedFFprobe {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffprobePath)
            proc.arguments = [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "format=duration:stream=sample_rate,channels,duration",
                "-of", "json",
                url.path
            ]
            let out = try await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: 15)
            if out.terminationStatus == 0,
               let json = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any],
               let streams = json["streams"] as? [[String: Any]],
               let stream = streams.first {
                let rawSR = (stream["sample_rate"] as? String).flatMap { Int32($0) } ?? (stream["sample_rate"] as? Int).map { Int32($0) }
                let ch = max(1, (stream["channels"] as? Int) ?? 2)
                if let sr = rawSR, SampleRate.validRange.contains(sr) {
                    let formatDict = json["format"] as? [String: Any]
                    let sDur = (stream["duration"] as? String).flatMap { Double($0) } ?? (stream["duration"] as? Double)
                    let fDur = (formatDict?["duration"] as? String).flatMap { Double($0) } ?? (formatDict?["duration"] as? Double)
                    let dur = max(0, sDur ?? fDur ?? 0)
                    let frames = dur.isFinite ? Int64((dur * Double(sr)).rounded()) : 0
                    return StreamProbeMetadata(
                        sampleRate: sr,
                        channelCount: ch,
                        estimatedTotalFrames: frames,
                        isNativeReadable: false
                    )
                }
            }
        }

        throw WaveformPyramidError.invalidFormat(url.lastPathComponent)
    }

    // MARK: - Native AVAudioFile Streaming Builder

    private static func buildNativeAVAudioFile(
        url: URL,
        assetID: UUID?,
        cacheKey: String,
        probe: StreamProbeMetadata,
        progressCallback: (@Sendable (WaveformBuildProgress) async -> Void)?
    ) async throws -> (WaveformPyramid, TestingMetrics) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = Int32(format.sampleRate.rounded())
        let channelCount = max(1, Int(format.channelCount))
        let fileLength = max(0, file.length)

        guard sampleRate > 0, SampleRate.validRange.contains(sampleRate) else {
            throw WaveformPyramidError.invalidFormat("Unsupported sample rate \(sampleRate)")
        }

        if fileLength == 0 {
            let empty = WaveformPyramid.empty(
                assetID: assetID,
                cacheKey: cacheKey,
                sampleRate: sampleRate,
                channelCount: channelCount
            )
            return (empty, TestingMetrics(lastMaxChunkFrames: 0, lastMaxChunkPayloadBytes: 0, lastBackendUsed: "AVAudioFile", buildCount: 1))
        }

        let chunkFrames = PCMChunkLimitPolicy.maxFrames(channelCount: channelCount, bytesPerSample: MemoryLayout<Float>.size)
        guard chunkFrames > 0 else {
            throw WaveformPyramidError.invalidFormat("Channel count \(channelCount) exceeds PCM chunk payload limit")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw WaveformPyramidError.invalidFormat("Unable to allocate reusable AVAudioPCMBuffer")
        }

        var accumulator = PyramidAccumulator(
            assetID: assetID,
            cacheKey: cacheKey,
            sampleRate: sampleRate,
            channelCount: channelCount,
            estimatedTotalFrames: fileLength
        )

        var maxObservedFrames = 0
        var maxObservedPayloadBytes = 0
        let isLargeStream = fileLength > 10_000_000
        let progressIntervalFrames: Int64 = isLargeStream ? max(131_072, fileLength / 16) : 131_072
        var nextProgressFrame: Int64 = min(fileLength, Int64(chunkFrames))

        while file.framePosition < fileLength {
            try Task.checkCancellation()
            let remaining = fileLength - file.framePosition
            let toRead = Int(min(Int64(chunkFrames), remaining))
            guard toRead > 0 else { break }

            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(toRead))
            } catch let nsError as NSError {
                // CoreAudio eofErr (-39) at EOF terminates cleanly if nothing more was readable.
                if nsError.code == -39 {
                    break
                }
                throw nsError
            }

            let readCount = Int(buffer.frameLength)
            if readCount == 0 {
                break
            }

            try PCMChunkLimitPolicy.validateChunk(
                frameCount: readCount,
                channelCount: channelCount,
                bytesPerSample: MemoryLayout<Float>.size,
                isPlanar: format.isInterleaved == false
            )
            let payloadBytes = PCMChunkLimitPolicy.inputPayloadBytes(
                frameCount: readCount,
                channelCount: channelCount,
                bytesPerSample: MemoryLayout<Float>.size,
                isPlanar: format.isInterleaved == false
            ) ?? 0
            maxObservedFrames = max(maxObservedFrames, readCount)
            maxObservedPayloadBytes = max(maxObservedPayloadBytes, payloadBytes)

            guard let channelData = buffer.floatChannelData else {
                throw WaveformPyramidError.invalidFormat("Missing Float32 channel data")
            }
            accumulator.appendPlanarChunk(channels: channelData, frameCount: readCount)

            if let progressCallback,
               accumulator.completedFrames >= nextProgressFrame,
               accumulator.completedFrames < fileLength {
                let partial = accumulator.snapshot(
                    expectedTotalFrames: fileLength,
                    isPartial: true,
                    coarseOnly: isLargeStream
                )
                await progressCallback(WaveformBuildProgress(
                    completedFrames: accumulator.completedFrames,
                    totalFrames: fileLength,
                    isComplete: false,
                    pyramid: partial
                ))
                nextProgressFrame = accumulator.completedFrames + progressIntervalFrames
            }
        }

        try Task.checkCancellation()
        let finalPyramid = accumulator.snapshot(expectedTotalFrames: fileLength, isPartial: false)

        let metrics = TestingMetrics(
            lastMaxChunkFrames: maxObservedFrames,
            lastMaxChunkPayloadBytes: maxObservedPayloadBytes,
            lastBackendUsed: "AVAudioFile",
            buildCount: 1
        )
        return (finalPyramid, metrics)
    }

    // MARK: - Bundled FFmpeg Streaming Pipe Builder

    private static func buildFFmpegStreaming(
        url: URL,
        assetID: UUID?,
        cacheKey: String,
        probe: StreamProbeMetadata,
        ffmpegPath: String,
        progressCallback: (@Sendable (WaveformBuildProgress) async -> Void)?
    ) async throws -> (WaveformPyramid, TestingMetrics) {
        let channelCount = max(1, probe.channelCount)
        let sampleRate = probe.sampleRate
        let bytesPerSample = MemoryLayout<Float>.size
        let bytesPerFrame = channelCount * bytesPerSample
        let chunkFrames = PCMChunkLimitPolicy.maxFrames(channelCount: channelCount, bytesPerSample: bytesPerSample)
        guard chunkFrames > 0 else {
            throw WaveformPyramidError.invalidFormat("Channel count \(channelCount) exceeds PCM chunk payload limit")
        }
        let targetByteCount = chunkFrames * bytesPerFrame

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-i", url.path,
            "-vn", "-sn", "-dn",
            "-f", "f32le",
            "-acodec", "pcm_f32le",
            "-ac", "\(channelCount)",
            "-ar", "\(sampleRate)",
            "pipe:1"
        ]

        let box = WaveformFFmpegProcessBox()
        proc.terminationHandler = { finished in
            box.markExited(status: finished.terminationStatus)
        }

        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            throw WaveformPyramidError.ffmpegFailed(-1, error.localizedDescription)
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        box.attach(process: proc, stdout: outHandle, stderr: errHandle)

        DispatchQueue.global(qos: .utility).async {
            while let part = try? errHandle.read(upToCount: 4_096), !part.isEmpty {
                box.appendStderr(part)
            }
        }

        defer {
            box.terminateAndClosePipes()
        }

        let ioQueue = DispatchQueue(label: "com.localconvert.waveform.ffmpeg.io", qos: .utility)
        var accumulator = PyramidAccumulator(
            assetID: assetID,
            cacheKey: cacheKey,
            sampleRate: sampleRate,
            channelCount: channelCount,
            estimatedTotalFrames: probe.estimatedTotalFrames
        )
        var deinterleavedPlanes = (0..<channelCount).map { _ in [Float](repeating: 0, count: chunkFrames) }
        var carryOver = Data()
        carryOver.reserveCapacity(bytesPerFrame)

        var maxObservedFrames = 0
        var maxObservedPayloadBytes = 0
        let isLargeStream = probe.estimatedTotalFrames > 10_000_000
        let progressIntervalFrames: Int64 = isLargeStream ? max(131_072, probe.estimatedTotalFrames / 16) : 131_072
        var nextProgressFrame: Int64 = Int64(chunkFrames)

        while true {
            try Task.checkCancellation()

            let readTarget = targetByteCount - carryOver.count
            let rawChunk: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    ioQueue.async {
                        do {
                            var data = Data()
                            data.reserveCapacity(max(0, readTarget))
                            while data.count < readTarget {
                                let remaining = readTarget - data.count
                                guard let part = try outHandle.read(upToCount: remaining), !part.isEmpty else {
                                    break
                                }
                                data.append(part)
                            }
                            continuation.resume(returning: data)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                box.terminateAndClosePipes()
            }

            try Task.checkCancellation()

            if carryOver.isEmpty && rawChunk.isEmpty {
                break
            }

            var combined: Data
            if carryOver.isEmpty {
                combined = rawChunk
            } else {
                combined = carryOver
                combined.append(rawChunk)
                carryOver.removeAll(keepingCapacity: true)
            }

            let usableFrames = min(chunkFrames, combined.count / bytesPerFrame)
            let usableBytes = usableFrames * bytesPerFrame
            let trailingBytes = combined.count - usableBytes
            if trailingBytes > 0 && rawChunk.isEmpty == false {
                carryOver = Data(combined.suffix(trailingBytes))
            }

            if usableFrames > 0 {
                try PCMChunkLimitPolicy.validateChunk(
                    frameCount: usableFrames,
                    channelCount: channelCount,
                    bytesPerSample: bytesPerSample,
                    isPlanar: false
                )
                let payloadBytes = PCMChunkLimitPolicy.inputPayloadBytes(
                    frameCount: usableFrames,
                    channelCount: channelCount,
                    bytesPerSample: bytesPerSample,
                    isPlanar: false
                ) ?? 0
                maxObservedFrames = max(maxObservedFrames, usableFrames)
                maxObservedPayloadBytes = max(maxObservedPayloadBytes, payloadBytes)

                // Deinterleave in-place into preallocated channel scratch arrays (alignment- and endian-safe).
                combined.prefix(usableBytes).withUnsafeBytes { raw in
                    for ch in 0..<channelCount {
                        for frameIdx in 0..<usableFrames {
                            let byteOffset = ((frameIdx * channelCount) + ch) * 4
                            let bits = raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self)
                            deinterleavedPlanes[ch][frameIdx] = Float(bitPattern: UInt32(littleEndian: bits))
                        }
                    }
                }
                accumulator.appendDeinterleavedBuffers(deinterleavedPlanes, frameCount: usableFrames)

                if let progressCallback, accumulator.completedFrames >= nextProgressFrame {
                    let expected = max(probe.estimatedTotalFrames, accumulator.completedFrames)
                    let partial = accumulator.snapshot(
                        expectedTotalFrames: expected,
                        isPartial: true,
                        coarseOnly: isLargeStream
                    )
                    await progressCallback(WaveformBuildProgress(
                        completedFrames: accumulator.completedFrames,
                        totalFrames: expected,
                        isComplete: false,
                        pyramid: partial
                    ))
                    nextProgressFrame = accumulator.completedFrames + progressIntervalFrames
                }
            }

            if rawChunk.isEmpty {
                break
            }
        }

        let exitStatus = await box.awaitExit(timeoutMilliseconds: 2_000)
        try Task.checkCancellation()

        if exitStatus != 0 && !box.wasCancelled {
            throw WaveformPyramidError.ffmpegFailed(exitStatus, box.stderrText())
        }

        let finalPyramid: WaveformPyramid
        if accumulator.completedFrames == 0 {
            finalPyramid = WaveformPyramid.empty(
                assetID: assetID,
                cacheKey: cacheKey,
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        } else {
            finalPyramid = accumulator.snapshot(expectedTotalFrames: accumulator.completedFrames, isPartial: false)
        }

        let metrics = TestingMetrics(
            lastMaxChunkFrames: maxObservedFrames,
            lastMaxChunkPayloadBytes: maxObservedPayloadBytes,
            lastBackendUsed: "BundledFFmpeg",
            buildCount: 1
        )
        return (finalPyramid, metrics)
    }
}

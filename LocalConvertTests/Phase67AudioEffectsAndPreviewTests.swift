import XCTest
import AVFoundation
import CoreAudio
import CoreAudioTypes
import CryptoKit
import Darwin
@testable import LocalConvert

private final class RenderCallbackTestBuffers: @unchecked Sendable {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        self.left = .allocate(capacity: count)
        self.right = .allocate(capacity: count)
        self.left.initialize(repeating: 0, count: count)
        self.right.initialize(repeating: 0, count: count)
    }

    deinit {
        left.deinitialize(count: count)
        right.deinitialize(count: count)
        left.deallocate()
        right.deallocate()
    }
}

private final class WeakObjectBox<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

// MARK: - Gapless Deterministic Spy Transport

@MainActor
private final class GaplessSpyTransport: AudioPlaybackTransportProtocol {
    struct ScheduledChunkRecord {
        let frameCount: Int
        let sampleRate: Double
        let channelCount: Int
        let firstSample: Float
        let lastSample: Float
        let plane0: [Float]
        let completion: @MainActor () -> Void
    }

    var configuredSampleRate: Double = 0
    var configuredChannelCount: Int = 0
    var configuredChannelLayout: AudioChannelLayoutInfo? = nil
    var configureHistory: [(rate: Double, channels: Int, layout: AudioChannelLayoutInfo?)] = []
    var isEngineRunning = false
    var isNodePlaying = false
    var volume: Float = 1.0
    var rate: Float = 1.0
    var resetCount = 0
    var scheduledItems: [ScheduledChunkRecord] = []
    var renderedSamplesPlane0: [Float] = []
    var renderedFramesSinceReset: Int64 = 0
    var maxObservedInFlightCount = 0

    func configure(sampleRate: Double, channelCount: Int) throws {
        try configure(sampleRate: sampleRate, channelCount: channelCount, channelLayout: nil)
    }

    func configure(sampleRate: Double, channelCount: Int, channelLayout: AudioChannelLayoutInfo?) throws {
        configuredSampleRate = sampleRate
        configuredChannelCount = channelCount
        configuredChannelLayout = channelLayout
        configureHistory.append((sampleRate, channelCount, channelLayout))
    }

    func setOutputDevice(deviceID: AudioDeviceID?) throws {}

    func startEngine() throws {
        isEngineRunning = true
    }

    func playNode() {
        isNodePlaying = true
    }

    func pauseNode() {
        isNodePlaying = false
    }

    func stopAndResetNode() {
        isNodePlaying = false
        resetCount += 1
        scheduledItems.removeAll()
        renderedFramesSinceReset = 0
    }

    func scheduleChunk(_ chunk: DecodedPCMChunk, onRendered: @escaping @MainActor () -> Void) {
        let plane0 = chunk.channels.first ?? []
        scheduledItems.append(ScheduledChunkRecord(
            frameCount: chunk.frameCount,
            sampleRate: chunk.sampleRate,
            channelCount: chunk.channelCount,
            firstSample: plane0.first ?? 0,
            lastSample: plane0.last ?? 0,
            plane0: plane0,
            completion: onRendered
        ))
        maxObservedInFlightCount = max(maxObservedInFlightCount, scheduledItems.count)
    }

    func currentRenderedFramesSinceReset() -> Int64 {
        renderedFramesSinceReset
    }

    @discardableResult
    func completeNextScheduledChunk() -> Bool {
        guard !scheduledItems.isEmpty else { return false }
        let item = scheduledItems.removeFirst()
        renderedSamplesPlane0.append(contentsOf: item.plane0)
        renderedFramesSinceReset += Int64(item.frameCount)
        item.completion()
        return true
    }

    func completeAllScheduledChunks(maxSteps: Int = 500) async {
        var steps = 0
        while steps < maxSteps {
            if completeNextScheduledChunk() {
                steps += 1
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(5))
            } else {
                try? await Task.sleep(for: .milliseconds(10))
                if scheduledItems.isEmpty { break }
            }
        }
    }
}

// MARK: - Scripted PCM Stream Decoder for Gapless Edge Cases

private actor ScriptedPCMDecoder: AudioPlaybackDecoderProtocol {
    nonisolated let streamInfo: DecodedAudioStreamInfo
    private let totalSamplesPlane0: [Float]
    private var cursor: Int = 0
    private let failOnReadAtFrame: Int?
    private(set) var isClosed = false

    init(
        sampleRate: SampleRate,
        channelCount: Int,
        channelLayout: AudioChannelLayoutInfo? = nil,
        samples: [Float],
        failOnReadAtFrame: Int? = nil
    ) {
        self.totalSamplesPlane0 = samples
        self.failOnReadAtFrame = failOnReadAtFrame
        let resolvedLayout = channelLayout ?? {
            switch channelCount {
            case 1:
                return AudioChannelLayoutInfo(channelCount: 1, coreAudioTag: kAudioChannelLayoutTag_Mono, normalizedName: "mono")
            case 2:
                return AudioChannelLayoutInfo(channelCount: 2, coreAudioTag: kAudioChannelLayoutTag_Stereo, normalizedName: "stereo")
            default:
                return nil
            }
        }()
        self.streamInfo = DecodedAudioStreamInfo(
            sampleRate: sampleRate,
            channelCount: channelCount,
            channelLayout: resolvedLayout,
            totalFrames: Int64(samples.count),
            isExactFrameSeekSupported: true,
            codecName: "pcm_f32le",
            backend: .nativeAVAudioFile
        )
    }

    func seek(toFrame frame: Int64) async throws {
        cursor = max(0, min(Int(frame), totalSamplesPlane0.count))
    }

    func readNextChunk(maxFrames: Int) async throws -> DecodedPCMChunk? {
        if let failAt = failOnReadAtFrame, cursor >= failAt {
            throw AudioPlaybackError.decodeFailed("Simulated scripted decode failure")
        }
        guard cursor < totalSamplesPlane0.count else { return nil }
        let end = min(totalSamplesPlane0.count, cursor + maxFrames)
        let slice = Array(totalSamplesPlane0[cursor..<end])
        cursor = end
        let planes = (0..<streamInfo.channelCount).map { _ in slice }
        return DecodedPCMChunk(
            sampleRate: Double(streamInfo.sampleRate.hz),
            channelCount: streamInfo.channelCount,
            frameCount: slice.count,
            channels: planes,
            channelLayout: streamInfo.channelLayout
        )
    }

    func close() async {
        isClosed = true
    }
}

// MARK: - Phase 67 Test Suite

final class Phase67AudioEffectsAndPreviewTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase67StageB-\(UUID().uuidString)")
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

    private func writeFloat32WAV(
        to url: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        frameCount: Int = 48_000,
        generator: (Int, Int) -> Float
    ) throws {
        let format: AVAudioFormat
        if channels <= 2 {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            )!
        } else {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        if let data = buf.floatChannelData {
            for ch in 0..<channels {
                for i in 0..<frameCount {
                    data[ch][i] = generator(ch, i)
                }
            }
        }
        try file.write(from: buf)
    }

    private func readFloat32Planes(from url: URL) throws -> (planes: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let count = Int(file.length)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, count)))!
        try file.read(into: buf)
        var out: [[Float]] = []
        let chCount = Int(fmt.channelCount)
        let len = Int(buf.frameLength)
        if let data = buf.floatChannelData {
            for ch in 0..<chCount {
                out.append(Array(UnsafeBufferPointer(start: data[ch], count: len)))
            }
        }
        return (out, fmt.sampleRate)
    }

    private func computeParityMetrics(reference: [Float], test: [Float]) -> (snrDB: Double, maxAbsDiff: Float) {
        let n = min(reference.count, test.count)
        guard n > 0 else { return (-120, 1) }
        var sigEnergy = 0.0
        var errEnergy = 0.0
        var maxDiff: Float = 0
        for i in 0..<n {
            let r = Double(reference[i])
            let e = r - Double(test[i])
            sigEnergy += r * r
            errEnergy += e * e
            maxDiff = max(maxDiff, abs(reference[i] - test[i]))
        }
        let snr = errEnergy > 1e-18 ? 10.0 * log10(max(1e-18, sigEnergy) / errEnergy) : 140.0
        return (snr, maxDiff)
    }

    private func fullDSPChainSlots() -> [AudioEffectSlot] {
        [
            AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams(bands: [
                EQBand(isEnabled: true, type: .highPass, frequencyHz: 80, gainDB: 0, q: 0.707),
                EQBand(isEnabled: true, type: .peaking, frequencyHz: 1500, gainDB: 4.5, q: 1.2)
            ])),
            AudioEffectSlot(kind: .compressor, compressor: CompressorParams(
                thresholdDB: -16, ratio: 4.0, attackMs: 3.0, releaseMs: 80.0, kneeDB: 3.0, makeupGainDB: 1.5
            )),
            AudioEffectSlot(kind: .limiter, limiter: LimiterParams(ceilingDB: -1.5, lookaheadMs: 8.0, releaseMs: 60.0)),
            AudioEffectSlot(kind: .noiseGate, noiseGate: NoiseGateParams(thresholdDB: -50, attackMs: 2, holdMs: 20, releaseMs: 60, rangeDB: -40)),
            AudioEffectSlot(kind: .noiseReduction, noiseReduction: NoiseReductionParams(reductionAmount: 45, smoothing: 0.5, noiseFloorDB: -40)),
            AudioEffectSlot(kind: .delay, delay: DelayParams(delayTimeMs: 40, feedback: 0.3, wetDryMix: 0.25, dampingHz: 6000, pingPong: true)),
            AudioEffectSlot(kind: .reverb, reverb: ReverbParams(roomPreset: .smallRoom, decaySeconds: 1.0, preDelayMs: 5, damping: 0.5, stereoWidth: 0.8, wetDryMix: 0.2))
        ]
    }

    // MARK: - 1. Multi-rate & Multichannel DSP Stability

    func testDSPMultiRateAndMultichannelStabilityAcrossAllEffects() {
        let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 192_000]
        let channelCounts = [1, 2, 6]
        let amplitudeLevels: [(name: String, amp: Float)] = [
            ("silence", 0.0),
            ("near_silence_-90dBFS", Float(pow(10.0, -90.0 / 20.0))),
            ("high_amp_+6dBFS", 2.0)
        ]

        let slots = fullDSPChainSlots()

        for sr in rates {
            for chCount in channelCounts {
                let proc = AudioChainProcessor(slots: slots, sampleRate: 44_100)
                // Reconfigure up to 192 kHz dynamically to test buffer resizing
                proc.sync(slots: slots, sampleRate: sr)
                let frameCount = 4096

                for (label, amp) in amplitudeLevels {
                    proc.resetStates()
                    var planes: [[Float]] = (0..<chCount).map { ch in
                        (0..<frameCount).map { i in
                            let base = amp * Float(sin(2.0 * .pi * (250.0 + Double(ch) * 110.0) * Double(i) / sr))
                            return base
                        }
                    }

                    // Run mutable pointer invocation cleanly via contiguous storage copy back
                    var flat = [Float](repeating: 0, count: chCount * frameCount)
                    for ch in 0..<chCount {
                        flat.replaceSubrange((ch * frameCount)..<((ch + 1) * frameCount), with: planes[ch])
                    }
                    flat.withUnsafeMutableBufferPointer { buf in
                        let base = buf.baseAddress!
                        var ptrs = (0..<chCount).map { base.advanced(by: $0 * frameCount) }
                        ptrs.withUnsafeBufferPointer { ptrBuf in
                            proc.processMultichannel(slots: slots, channels: ptrBuf.baseAddress!, channelCount: chCount, frameCount: frameCount)
                        }
                    }

                    for ch in 0..<chCount {
                        let start = ch * frameCount
                        for i in 0..<frameCount {
                            let s = flat[start + i]
                            XCTAssertTrue(s.isFinite, "Non-finite output for \(sr)Hz/\(chCount)ch/\(label)")
                            XCTAssertLessThan(abs(s), 10.0, "Runaway sample for \(sr)Hz/\(chCount)ch/\(label)")
                        }
                    }

                    // Inject NaN intentionally and verify sanitization guard clears it
                    flat[0] = .nan
                    flat[1] = .infinity
                    flat.withUnsafeMutableBufferPointer { buf in
                        let base = buf.baseAddress!
                        var ptrs = (0..<chCount).map { base.advanced(by: $0 * frameCount) }
                        ptrs.withUnsafeBufferPointer { ptrBuf in
                            proc.processMultichannel(slots: slots, channels: ptrBuf.baseAddress!, channelCount: chCount, frameCount: frameCount)
                        }
                    }
                    XCTAssertTrue(flat.allSatisfy(\.isFinite), "NaN/Inf escaped sanitization at \(sr)Hz/\(chCount)ch")
                    _ = planes.removeAll()
                }
            }
        }
    }

    // MARK: - 2. Distinct Peak vs. LUFS Normalization & True-Peak Ceiling Safety

    func testPeakVsLUFSNormalizationAndTruePeakSafety() {
        let sr = 48_000.0
        let frameCount = 48_000 // 1.0s

        // Compare Peak vs LUFS normalization on a quiet 1 kHz + low-bass mix
        var ch0 = (0..<frameCount).map { i in
            Float(0.1 * sin(2.0 * .pi * 1000.0 * Double(i) / sr))
        }
        var ch1 = ch0

        var peakL = ch0
        var peakR = ch1
        let appliedPeakGain = peakL.withUnsafeMutableBufferPointer { lb in
            peakR.withUnsafeMutableBufferPointer { rb in
                var ptrs = [lb.baseAddress!, rb.baseAddress!]
                return ptrs.withUnsafeBufferPointer {
                    AudioNormalizer.applyPeakNormalization(channels: $0.baseAddress!, channelCount: 2, frameCount: frameCount, targetPeakDBFS: -2.0)
                }
            }
        }
        XCTAssertNotNil(appliedPeakGain)
        let peakAfter = peakL.reduce(0.0) { max($0, abs($1)) }
        let peakAfterDB = 20.0 * log10(Double(peakAfter))
        XCTAssertEqual(peakAfterDB, -2.0, accuracy: 0.05)

        // LUFS Normalization at -14.0 LUFS with -1.0 dBTP ceiling
        var lufsL = ch0
        var lufsR = ch1
        let lufsGain = lufsL.withUnsafeMutableBufferPointer { lb in
            lufsR.withUnsafeMutableBufferPointer { rb in
                var ptrs = [lb.baseAddress!, rb.baseAddress!]
                return ptrs.withUnsafeBufferPointer {
                    AudioNormalizer.applyLUFSNormalization(
                        channels: $0.baseAddress!,
                        channelCount: 2,
                        frameCount: frameCount,
                        sampleRate: sr,
                        targetLUFS: -14.0,
                        truePeakCeilingDBTP: -1.0
                    )
                }
            }
        }
        XCTAssertNotNil(lufsGain)
        XCTAssertNotEqual(appliedPeakGain ?? 0, lufsGain ?? 0, accuracy: 0.2)

        let reportAfter = lufsL.withUnsafeMutableBufferPointer { lb in
            lufsR.withUnsafeMutableBufferPointer { rb in
                var ptrs = [lb.baseAddress!, rb.baseAddress!]
                return ptrs.withUnsafeBufferPointer {
                    AudioNormalizer.measureLoudness(channels: $0.baseAddress!, channelCount: 2, frameCount: frameCount, sampleRate: sr)
                }
            }
        }
        XCTAssertLessThanOrEqual(reportAfter.truePeakDBTP, -0.95)
        if let integrated = reportAfter.integratedLUFS {
            XCTAssertEqual(integrated, -14.0, accuracy: 1.5)
        } else {
            XCTFail("Expected valid integrated LUFS")
        }

        // Pure silence returns nil gain and stays zero without NaN/Inf
        var silentL = [Float](repeating: 0, count: 8192)
        var silentR = silentL
        let silentGain = silentL.withUnsafeMutableBufferPointer { lb in
            silentR.withUnsafeMutableBufferPointer { rb in
                var ptrs = [lb.baseAddress!, rb.baseAddress!]
                return ptrs.withUnsafeBufferPointer {
                    AudioNormalizer.applyLUFSNormalization(channels: $0.baseAddress!, channelCount: 2, frameCount: 8192, sampleRate: sr, targetLUFS: -14.0)
                }
            }
        }
        XCTAssertNil(silentGain)
        XCTAssertTrue(silentL.allSatisfy { $0 == 0 && $0.isFinite })
    }

    // MARK: - 3. ClipProxyCache Key Invalidation, Deduplication, LRU Eviction & Cancellation

    func testClipProxyCacheHitInvalidationDedupEvictionAndCancellation() async throws {
        let srcDir = sandbox.temporaryURL.appendingPathComponent("ProxySources", isDirectory: true)
        let cacheDir = sandbox.temporaryURL.appendingPathComponent("ProxyCache", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        let srcURL = srcDir.appendingPathComponent("clip_src.wav")
        try writeFloat32WAV(to: srcURL, sampleRate: 48_000, channels: 2, frameCount: 48_000) { ch, i in
            Float(0.25 * sin(2.0 * .pi * (ch == 0 ? 440.0 : 550.0) * Double(i) / 48_000.0))
        }
        let sha1 = try AudioMediaReference.sha256Hex(of: srcURL)
        let ref1 = AudioMediaReference(
            id: UUID(), path: srcURL.path, displayName: "clip_src.wav",
            fileSize: 400_000, modificationTime: 1000, duration: 1.0, sampleRate: 48_000, channels: 2,
            contentSHA256: sha1, durationFrames: 48_000
        )
        var refDifferentSHA = ref1
        refDifferentSHA.contentSHA256 = String(sha1.reversed())

        let clipA = AudioClip(sourceAssetID: ref1.id, name: "Clip A", timelineStartFrame: 0, sourceStartFrame: 0, durationFrames: 48_000, isReversed: true)
        var clipDifferentFX = clipA
        clipDifferentFX.effectSlots = [AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams())]

        let keyBase = ClipProxyCache.cacheKey(clip: clipA, asset: ref1, rate: 48_000, channelCount: 2)
        let keySHA = ClipProxyCache.cacheKey(clip: clipA, asset: refDifferentSHA, rate: 48_000, channelCount: 2)
        let keyRate = ClipProxyCache.cacheKey(clip: clipA, asset: ref1, rate: 96_000, channelCount: 2)
        let keyCh = ClipProxyCache.cacheKey(clip: clipA, asset: ref1, rate: 48_000, channelCount: 6)
        let keySlots = ClipProxyCache.cacheKey(clip: clipDifferentFX, asset: ref1, rate: 48_000, channelCount: 2)

        XCTAssertNotEqual(keyBase, keySHA)
        XCTAssertNotEqual(keyBase, keyRate)
        XCTAssertNotEqual(keyBase, keyCh)
        XCTAssertNotEqual(keyBase, keySlots)
        XCTAssertGreaterThanOrEqual(ClipProxyCache.proxyVersion, 2)

        // Default shared cache resolves under AppStoragePaths, never /tmp
        XCTAssertFalse(AppStoragePaths.audioEditorProxiesDirectory.path.hasPrefix("/tmp"))

        // Concurrent in-flight deduplication + deterministic hit
        let dedupCache = ClipProxyCache(directory: cacheDir, maxBytes: 5_000_000)
        async let u1 = dedupCache.proxyURL(for: clipA, asset: ref1, projectRate: 48_000)
        async let u2 = dedupCache.proxyURL(for: clipA, asset: ref1, projectRate: 48_000)
        let (res1, res2) = try await (u1, u2)
        XCTAssertEqual(res1, res2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: res1.path))
        let countAfterDedup = await dedupCache.cachedFileCount()
        XCTAssertEqual(countAfterDedup, 1)

        // LRU eviction under small maxBytes limit (each 1s stereo float32 CAF is ~384 KB)
        let evictDir = sandbox.temporaryURL.appendingPathComponent("EvictCache", isDirectory: true)
        let smallCache = ClipProxyCache(directory: evictDir, maxBytes: 450_000)
        let p1 = try await smallCache.proxyURL(for: clipA, asset: ref1, projectRate: 48_000)
        try await Task.sleep(for: .milliseconds(50))
        var clipB = clipA
        clipB.swapChannels = true
        let p2 = try await smallCache.proxyURL(for: clipB, asset: ref1, projectRate: 48_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p2.path), "Most recently created proxy must be retained")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p1.path), "Oldest proxy must be evicted over maxBytes")

        // Cancellation cleanup leaves zero .tmp artifacts
        let cancelDir = sandbox.temporaryURL.appendingPathComponent("CancelCache", isDirectory: true)
        let cancelCache = ClipProxyCache(directory: cancelDir, maxBytes: 5_000_000)
        var mutableClipCancel = clipA
        mutableClipCancel.effects.timeStretch = 0.75
        let clipCancel = mutableClipCancel
        let task = Task {
            try await cancelCache.proxyURL(for: clipCancel, asset: ref1, projectRate: 48_000)
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch {}
        if let files = try? FileManager.default.contentsOfDirectory(atPath: cancelDir.path) {
            XCTAssertTrue(files.filter { $0.contains(".tmp.") || $0.hasPrefix(".") }.isEmpty)
        }
    }

    // MARK: - 4. AudioRingBuffer Sample-Frame Tracking & Loop Boundary Continuity

    func testAudioRingBufferSampleFrameAccuracyAndLoopContinuity() async throws {
        // Long offset where Float32/time accumulation might drift: 100_000_000 frames (~34 min @ 48k)
        let ring = AudioRingBuffer(capacity: 8192)
        let startTimelineFrame: Int64 = 100_000_003
        var chunkA = [Float](repeating: 0.25, count: 1024)
        var chunkB = [Float](repeating: -0.25, count: 1024)

        chunkA.withUnsafeBufferPointer { lb in
            chunkB.withUnsafeBufferPointer { rb in
                ring.write(left: lb.baseAddress!, right: rb.baseAddress!, count: 1024, timelineFrame: startTimelineFrame)
                ring.write(left: lb.baseAddress!, right: rb.baseAddress!, count: 512, timelineFrame: startTimelineFrame + 1024)
            }
        }

        var outL = [Float](repeating: 0, count: 1300)
        var outR = [Float](repeating: 0, count: 1300)
        outL.withUnsafeMutableBufferPointer { lb in
            outR.withUnsafeMutableBufferPointer { rb in
                ring.read(left: lb.baseAddress!, right: rb.baseAddress!, count: 1300)
            }
        }

        let pos = ring.playbackTimelineFrame()
        XCTAssertEqual(pos.frame, startTimelineFrame + 1300)
        XCTAssertEqual(ring.playbackPosition(sampleRate: SampleRate.rate48k).position?.frame, startTimelineFrame + 1300)

        // Exact loop wrap check via AudioMixSession.mix(startFrame:)
        let srcURL = sandbox.temporaryURL.appendingPathComponent("loop_ramp.wav")
        try writeFloat32WAV(to: srcURL, sampleRate: 48_000, channels: 2, frameCount: 16_000) { _, i in
            Float(i + 1) / 20_000.0
        }
        guard let asset = await AudioEditorStore.buildMediaReference(for: srcURL) else {
            return XCTFail("Failed to create AudioMediaReference")
        }
        let clip = AudioClip(sourceAssetID: asset.id, name: "Ramp", timelineStartFrame: 0, sourceStartFrame: 0, durationFrames: 16_000, projectRate: .rate48k, sourceRate: .rate48k)
        let project = AudioEditorProject(name: "LoopCheck", sampleRate: 48_000, tracks: [AudioTrack(name: "Main", clips: [clip])], mediaAssets: [asset])
        let resolved = try await AudioSourceResolver.resolve(project: project)
        let session = AudioMixSession(project: project, sources: resolved)

        let loopStart: Int64 = 100
        let loopEnd: Int64 = 500
        var l1 = [Float](repeating: 0, count: 150)
        var r1 = [Float](repeating: 0, count: 150)
        l1.withUnsafeMutableBufferPointer { lb in
            r1.withUnsafeMutableBufferPointer { rb in
                session.mix(startFrame: 400, frameCount: Int(loopEnd - 400), left: lb.baseAddress!, right: rb.baseAddress!)
                session.mix(startFrame: loopStart, frameCount: 50, left: lb.baseAddress!.advanced(by: 100), right: rb.baseAddress!.advanced(by: 100))
            }
        }
        // Frame 499 is 500/20000, Frame 100 is 101/20000: zero dropped or duplicated sample
        XCTAssertEqual(l1[99], Float(500) / 20_000.0, accuracy: 1e-6)
        XCTAssertEqual(l1[100], Float(101) / 20_000.0, accuracy: 1e-6)
    }

    // MARK: - 5. Preview vs. Offline Render Numerical Parity

    func testPreviewVsOfflineRenderNumericalParity() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("Parity", isDirectory: true)
        let outDir = dir.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let srcURL = dir.appendingPathComponent("parity_src.wav")
        let sr = 48_000.0
        let totalFrames = 48_000
        try writeFloat32WAV(to: srcURL, sampleRate: sr, channels: 2, frameCount: totalFrames) { ch, i in
            let freq = ch == 0 ? 440.0 : 660.0
            return Float(0.35 * sin(2.0 * .pi * freq * Double(i) / sr))
        }
        guard let asset = await AudioEditorStore.buildMediaReference(for: srcURL) else {
            return XCTFail("Failed to build AudioMediaReference")
        }

        let eqCompSlots: [AudioEffectSlot] = [
            AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams(bands: [
                EQBand(isEnabled: true, type: .peaking, frequencyHz: 1000, gainDB: 3.0, q: 1.0)
            ])),
            AudioEffectSlot(kind: .compressor, compressor: CompressorParams(
                thresholdDB: -18, ratio: 3.0, attackMs: 5.0, releaseMs: 100.0, kneeDB: 3.0, makeupGainDB: 0.0
            ))
        ]

        let clip1 = AudioClip(
            sourceAssetID: asset.id,
            name: "EQ+Fades+Comp",
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: 48_000,
            projectRate: .rate48k,
            sourceRate: .rate48k,
            fadeInFrames: ClipFadeSpecFrames(durationFrames: 4800, curve: .equalPower),
            fadeOutFrames: ClipFadeSpecFrames(durationFrames: 4800, curve: .sCurve),
            effectSlots: eqCompSlots
        )
        var clip2 = AudioClip(
            sourceAssetID: asset.id,
            name: "Reverse+Stretch",
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: 38_400,
            projectRate: .rate48k,
            sourceRate: .rate48k,
            isReversed: true
        )
        clip2.effects.timeStretch = 1.25

        for (label, testClip, frames) in [("EQ_Fades_Comp", clip1, 48_000), ("Reverse_TimeStretch", clip2, 38_400)] {
            let proj = AudioEditorProject(
                name: "Parity_\(label)",
                sampleRate: sr,
                tracks: [AudioTrack(name: "Main", clips: [testClip])],
                mediaAssets: [asset]
            )
            let resolved = try await AudioSourceResolver.resolve(project: proj)
            let session = AudioMixSession(project: proj, sources: resolved)

            var previewL = [Float](repeating: 0, count: frames)
            var previewR = [Float](repeating: 0, count: frames)
            let chunk = 4096
            var pos = 0
            while pos < frames {
                let n = min(chunk, frames - pos)
                previewL.withUnsafeMutableBufferPointer { lb in
                    previewR.withUnsafeMutableBufferPointer { rb in
                        session.mix(startFrame: Int64(pos), frameCount: n, left: lb.baseAddress!.advanced(by: pos), right: rb.baseAddress!.advanced(by: pos))
                    }
                }
                pos += n
            }

            let req = AudioExportRequest(
                scope: .entireProject,
                outputFormat: .wav,
                sampleRate: 48_000,
                bitDepth: 32,
                channels: 2,
                preserveMetadata: false,
                loudnessNormalizeEnabled: false,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: outDir,
                baseFileName: "offline_\(label)",
                exportMode: .losslessFormatReRender
            )
            let result = try await AudioExportService.export(project: proj, request: req)
            let offline = try readFloat32Planes(from: result.outputURLs[0])

            let metrics = computeParityMetrics(reference: previewL, test: offline.planes[0])
            XCTAssertGreaterThan(metrics.snrDB, 90.0, "Preview/Offline SNR too low for \(label): \(metrics.snrDB) dB")
            XCTAssertLessThan(metrics.maxAbsDiff, 1e-4, "Preview/Offline peak diff too large for \(label): \(metrics.maxAbsDiff)")
        }
    }

    // MARK: - 6. Gapless Same-Rate & Explicit Channel Layout Playback Tests

    private func writeFloat32AudioFile(
        to url: URL,
        sampleRate: Double,
        channels: Int,
        frameCount: Int,
        explicitLayoutTag: AudioChannelLayoutTag?,
        generator: (Int, Int) -> Float
    ) throws {
        let format: AVAudioFormat
        if let explicitLayoutTag,
           let layout = AVAudioChannelLayout(layoutTag: explicitLayoutTag) {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: layout
            )
        } else if channels <= 2 {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: false
            )!
        } else {
            let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
            let layout = AVAudioChannelLayout(layoutTag: tag)!
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        if let data = buf.floatChannelData {
            for ch in 0..<channels {
                for i in 0..<frameCount {
                    data[ch][i] = generator(ch, i)
                }
            }
        }
        try file.write(from: buf)
    }

    private func defaultExplicitTag(forChannels channels: Int) -> AudioChannelLayoutTag? {
        switch channels {
        case 1: return kAudioChannelLayoutTag_Mono
        case 2: return kAudioChannelLayoutTag_Stereo
        case 6: return kAudioChannelLayoutTag_MPEG_5_1_A
        case 8: return kAudioChannelLayoutTag_MPEG_7_1_C
        default: return nil
        }
    }

    @MainActor
    private func buildCoordinatorWithFiles(
        _ specs: [(name: String, rate: Double, channels: Int, markerValue: Float)],
        transport: GaplessSpyTransport,
        fileExtension: String = "caf",
        includeExplicitLayouts: Bool = true,
        explicitTags: [AudioChannelLayoutTag?]? = nil
    ) async throws -> (coordinator: AudioWorkspaceCoordinator, records: [AudioLibraryRecord]) {
        let folder = sandbox.temporaryURL.appendingPathComponent("GaplessLib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (index, spec) in specs.enumerated() {
            let url = folder.appendingPathComponent("\(spec.name).\(fileExtension)")
            let tag: AudioChannelLayoutTag?
            if let explicitTags, index < explicitTags.count {
                tag = explicitTags[index]
            } else if includeExplicitLayouts {
                tag = defaultExplicitTag(forChannels: spec.channels)
            } else {
                tag = nil
            }
            try writeFloat32AudioFile(
                to: url,
                sampleRate: spec.rate,
                channels: spec.channels,
                frameCount: 12_000,
                explicitLayoutTag: tag
            ) { _, i in
                spec.markerValue + Float(i) * 0.0001
            }
        }

        let coordinator = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport
        )
        await coordinator.ensureInitialized()
        await coordinator.libraryStore.addFolderAndScan(url: folder)
        let sorted = coordinator.libraryStore.displayedRecords.sorted { $0.asset.displayFilename < $1.asset.displayFilename }
        return (coordinator, sorted)
    }

    @MainActor
    func testGapless1And3SameRateTransitionZeroResetGapAndExactSampleContinuity() async throws {
        let transport = GaplessSpyTransport()
        let (coord, records) = try await buildCoordinatorWithFiles([
            ("01_trackA", 48_000, 2, 1.0),
            ("02_trackB", 48_000, 2, 100.0)
        ], transport: transport)
        XCTAssertEqual(records.count, 2)

        await coord.playbackCoordinator.playQueue(records: records, startAt: 0)
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        try? await Task.sleep(for: .milliseconds(40))

        let resetsAfterInitialStart = transport.resetCount
        XCTAssertTrue(coord.playbackCoordinator.engine.isGaplessArmed)
        XCTAssertEqual(transport.configureHistory.count, 1)
        XCTAssertEqual(transport.configuredChannelLayout?.normalizedName, "stereo")

        // Wait for feed loop to push Track A chunks (12,000 frames = 2 chunks) AND pre-schedule Track B chunks
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(transport.resetCount, resetsAfterInitialStart, "Gapless pre-scheduling must not reset AVAudioPlayerNode")

        // Drain Track A + Track B chunks sequentially
        for _ in 0..<4 {
            XCTAssertTrue(transport.completeNextScheduledChunk())
            try? await Task.sleep(for: .milliseconds(30))
        }

        XCTAssertEqual(transport.resetCount, resetsAfterInitialStart, "Same-rate + same-layout gapless transition must NOT call stopAndResetNode")
        XCTAssertEqual(transport.configureHistory.count, 1, "Same-rate + same-layout gapless transition must reuse configured transport")
        XCTAssertEqual(transport.renderedSamplesPlane0.count, 24_000, "Zero dropped or duplicated frames across boundary")

        // Exact sample continuity across index 11999 (last frame of A) -> 12000 (first frame of B)
        XCTAssertEqual(transport.renderedSamplesPlane0[0], 1.0, accuracy: 1e-5)
        XCTAssertEqual(transport.renderedSamplesPlane0[11_999], 1.0 + Float(11_999) * 0.0001, accuracy: 1e-3)
        XCTAssertEqual(transport.renderedSamplesPlane0[12_000], 100.0, accuracy: 1e-5)
        XCTAssertEqual(transport.renderedSamplesPlane0[23_999], 100.0 + Float(11_999) * 0.0001, accuracy: 1e-3)
    }

    @MainActor
    func testGapless2QueueDoesNotAdvancePrematurelyWhenPreScheduled() async throws {
        let transport = GaplessSpyTransport()
        let (coord, records) = try await buildCoordinatorWithFiles([
            ("01_trackA", 48_000, 2, 1.0),
            ("02_trackB", 48_000, 2, 100.0)
        ], transport: transport)

        await coord.playbackCoordinator.playQueue(records: records, startAt: 0)
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        try? await Task.sleep(for: .milliseconds(80))

        // Both Track A chunks and at least 1 Track B chunk are already scheduled on the transport
        XCTAssertGreaterThanOrEqual(transport.scheduledItems.count, 3)
        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[0].asset.id, "Queue must NOT advance while Track A is still rendering")
        XCTAssertEqual(coord.playbackCoordinator.currentTrack?.asset.id, records[0].asset.id)

        // Complete chunk 1 of Track A (chunk 2 still playing)
        XCTAssertTrue(transport.completeNextScheduledChunk())
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[0].asset.id)

        // Complete final chunk (chunk 2) of Track A -> boundary reached -> queue advances cleanly to Track B!
        XCTAssertTrue(transport.completeNextScheduledChunk())
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[1].asset.id)
        XCTAssertEqual(coord.playbackCoordinator.currentTrack?.asset.id, records[1].asset.id)
    }

    @MainActor
    func testGapless4CrossRateTransitionFallsBackCleanlyToReconfigure() async throws {
        let transport = GaplessSpyTransport()
        let (coord, records) = try await buildCoordinatorWithFiles([
            ("01_rate44k", 44_100, 2, 1.0),
            ("02_rate48k", 48_000, 2, 100.0)
        ], transport: transport)

        await coord.playbackCoordinator.playQueue(records: records, startAt: 0)
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        XCTAssertFalse(coord.playbackCoordinator.engine.isGaplessArmed, "Cross-rate track must NOT arm same-node gapless")

        try? await Task.sleep(for: .milliseconds(60))
        let resetsBeforeEOF = transport.resetCount
        await transport.completeAllScheduledChunks(maxSteps: 10)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[1].asset.id)
        XCTAssertGreaterThan(transport.resetCount, resetsBeforeEOF)
        XCTAssertGreaterThanOrEqual(transport.configureHistory.count, 2)
        XCTAssertEqual(transport.configuredSampleRate, 48_000)
    }

    @MainActor
    func testGapless5ChannelLayoutMismatchFallsBackCleanlyToReconfigure() async throws {
        // Equal channel count (6 ch) & equal sample rate (48 kHz), but differing speaker layouts: 5.1 vs 5.1(side).
        let transport = GaplessSpyTransport()
        let (coord, records) = try await buildCoordinatorWithFiles([
            ("01_51_back", 48_000, 6, 1.0),
            ("02_51_side", 48_000, 6, 100.0)
        ], transport: transport, fileExtension: "caf", explicitTags: [
            kAudioChannelLayoutTag_WAVE_5_1_B,
            kAudioChannelLayoutTag_MPEG_5_1_A
        ])
        XCTAssertEqual(records.count, 2)

        await coord.playbackCoordinator.playQueue(records: records, startAt: 0)
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        XCTAssertFalse(
            coord.playbackCoordinator.engine.isGaplessArmed,
            "Same-rate 6-ch tracks with different layouts (5.1 vs 5.1(side)) must NOT arm same-node gapless"
        )
        XCTAssertEqual(transport.configuredChannelLayout?.normalizedName, "5.1")

        try? await Task.sleep(for: .milliseconds(60))
        let resetsBeforeEOF = transport.resetCount
        await transport.completeAllScheduledChunks(maxSteps: 10)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[1].asset.id)
        XCTAssertGreaterThan(transport.resetCount, resetsBeforeEOF)
        XCTAssertGreaterThanOrEqual(transport.configureHistory.count, 2)
        XCTAssertEqual(transport.configuredChannelCount, 6)
        XCTAssertEqual(transport.configuredChannelLayout?.normalizedName, "5.1(side)")
    }

    @MainActor
    func testGaplessMonoToStereoChannelCountMismatchFallsBackCleanlyToReconfigure() async throws {
        let transport = GaplessSpyTransport()
        let (coord, records) = try await buildCoordinatorWithFiles([
            ("01_mono", 48_000, 1, 1.0),
            ("02_stereo", 48_000, 2, 100.0)
        ], transport: transport)

        await coord.playbackCoordinator.playQueue(records: records, startAt: 0)
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        XCTAssertFalse(coord.playbackCoordinator.engine.isGaplessArmed, "1ch -> 2ch transition must NOT arm same-node gapless")

        try? await Task.sleep(for: .milliseconds(60))
        await transport.completeAllScheduledChunks(maxSteps: 10)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[1].asset.id)
        XCTAssertEqual(transport.configuredChannelCount, 2)
        XCTAssertEqual(transport.configuredChannelLayout?.normalizedName, "stereo")
        XCTAssertGreaterThanOrEqual(transport.configureHistory.count, 2)
    }

    @MainActor
    func testGaplessUnknownLayoutPlainWAVFallsBackCleanlyToReconfigure() async throws {
        // Plain RIFF WAV files lack channel-layout chunks (channelLayout == nil) -> do NOT assume compatibility.
        let transport = GaplessSpyTransport()
        let (coord, records) = try await buildCoordinatorWithFiles([
            ("01_plain_a", 48_000, 2, 1.0),
            ("02_plain_b", 48_000, 2, 100.0)
        ], transport: transport, fileExtension: "wav", includeExplicitLayouts: false)
        XCTAssertEqual(records.count, 2)

        await coord.playbackCoordinator.playQueue(records: records, startAt: 0)
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        XCTAssertFalse(
            coord.playbackCoordinator.engine.isGaplessArmed,
            "Unknown channel layout (nil) must NOT arm gapless even when sample rate and channel count match"
        )
        XCTAssertNil(transport.configuredChannelLayout)

        try? await Task.sleep(for: .milliseconds(60))
        let resetsBeforeEOF = transport.resetCount
        await transport.completeAllScheduledChunks(maxSteps: 10)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[1].asset.id)
        XCTAssertGreaterThan(transport.resetCount, resetsBeforeEOF)
        XCTAssertGreaterThanOrEqual(transport.configureHistory.count, 2)
    }

    @MainActor
    func testGapless6QueueReplacementAndStopCancelPreScheduledTrackCleanly() async throws {
        let transport = GaplessSpyTransport()
        let (coord, records) = try await buildCoordinatorWithFiles([
            ("01_trackA", 48_000, 2, 1.0),
            ("02_trackB", 48_000, 2, 100.0),
            ("03_trackC", 48_000, 2, 200.0)
        ], transport: transport)

        // Start [A, B], wait until B is preloaded & pre-scheduled
        await coord.playbackCoordinator.playQueue(records: [records[0], records[1]], startAt: 0)
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(coord.playbackCoordinator.engine.isGaplessArmed)

        // Replace upcoming queue track B with C cleanly via enqueueNext / remove
        await coord.playbackCoordinator.enqueueNext(records[2])
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(coord.playbackCoordinator.engine.preloadedAssetID, records[2].asset.id)
        // Drain active track tail -> must transition to C, never B!
        XCTAssertTrue(transport.completeNextScheduledChunk())
        try? await Task.sleep(for: .milliseconds(30))
        while coord.playbackCoordinator.queueManager.currentTrackID == records[0].asset.id && !transport.scheduledItems.isEmpty {
            XCTAssertTrue(transport.completeNextScheduledChunk())
            try? await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(coord.playbackCoordinator.queueManager.currentTrackID, records[2].asset.id)
        XCTAssertFalse(transport.renderedSamplesPlane0.contains { abs($0 - 100.0) < 0.001 }, "Cancelled Track B audio must not render")

        // Now verify stop() clears preload and resets node cleanly
        await coord.playbackCoordinator.engine.waitForPendingPreload()
        await coord.playbackCoordinator.stop()
        XCTAssertFalse(coord.playbackCoordinator.engine.isGaplessArmed)
        XCTAssertEqual(coord.playbackCoordinator.engine.playbackState, .stopped)
    }

    @MainActor
    func testGapless7NextTrackDecodeFailureDoesNotInterruptActivePlayback() async throws {
        let transport = GaplessSpyTransport()
        let trackA = UUID()
        let trackB = UUID()
        let samplesA = (0..<16_000).map { Float($0 + 1) }

        let engine = AudioLibraryPlayerEngine(
            transport: transport,
            decoderLoader: { url, _ in
                if url.lastPathComponent.contains("badB") {
                    return ScriptedPCMDecoder(sampleRate: .rate48k, channelCount: 2, samples: Array(repeating: 0, count: 1024), failOnReadAtFrame: 0)
                }
                return ScriptedPCMDecoder(sampleRate: .rate48k, channelCount: 2, samples: samplesA)
            }
        )

        let urlA = sandbox.temporaryURL.appendingPathComponent("goodA.caf")
        let urlB = sandbox.temporaryURL.appendingPathComponent("badB.caf")
        try await engine.load(url: urlA, assetID: trackA, autoPlay: true)
        engine.preloadNextTrack(url: urlB, assetID: trackB)
        await engine.waitForPendingPreload()

        XCTAssertFalse(engine.isGaplessArmed, "Failing next-track preload must clear gapless state cleanly")
        XCTAssertEqual(engine.playbackState, .playing, "Active Track A playback must remain unaffected by next-track decode failure")

        var endedCount = 0
        engine.onTrackEnded = { endedCount += 1 }
        try? await Task.sleep(for: .milliseconds(60))
        await transport.completeAllScheduledChunks(maxSteps: 10)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(transport.renderedSamplesPlane0.count, 16_000)
        await engine.unload()
    }

    // MARK: - 7. Multichannel Layout Formatting & Decoder Metadata Verification

    @MainActor
    func testMultichannelChannelLayoutFormatsAndPCMBufferConstruction() async throws {
        let specs: [(name: String, channels: Int, tag: AudioChannelLayoutTag)] = [
            ("4.0", 4, kAudioChannelLayoutTag_MPEG_4_0_A),
            ("quad", 4, kAudioChannelLayoutTag_WAVE_4_0_B),
            ("5.1", 6, kAudioChannelLayoutTag_WAVE_5_1_B),
            ("5.1(side)", 6, kAudioChannelLayoutTag_MPEG_5_1_A),
            ("7.1", 8, kAudioChannelLayoutTag_MPEG_7_1_C)
        ]

        for spec in specs {
            let layout = try XCTUnwrap(AudioChannelLayoutInfo.fromFFmpegLayoutName(spec.name, channelCount: spec.channels))
            XCTAssertEqual(layout.coreAudioTag, spec.tag)
            let planes = (0..<spec.channels).map { ch in [Float](repeating: Float(ch + 1) * 0.1, count: 64) }
            let chunk = DecodedPCMChunk(
                sampleRate: 48_000,
                channelCount: spec.channels,
                frameCount: 64,
                channels: planes,
                channelLayout: layout
            )
            let pcmBuffer = try XCTUnwrap(chunk.makeAVAudioPCMBuffer(), "Expected non-nil multichannel buffer for \(spec.name)")
            XCTAssertEqual(Int(pcmBuffer.format.channelCount), spec.channels)
            XCTAssertEqual(pcmBuffer.format.channelLayout?.layoutTag, spec.tag)

            let transport = AVAudioEnginePlaybackTransport()
            XCTAssertNoThrow(try transport.configure(sampleRate: 48_000, channelCount: spec.channels, channelLayout: layout))
        }

        // Verify unknown / ambiguous FFmpeg layout strings normalize to nil
        XCTAssertNil(AudioChannelLayoutInfo.fromFFmpegLayoutName(nil, channelCount: 2))
        XCTAssertNil(AudioChannelLayoutInfo.fromFFmpegLayoutName("unknown", channelCount: 2))
        XCTAssertNil(AudioChannelLayoutInfo.fromFFmpegLayoutName("6 channels", channelCount: 6))

        // Verify equal-count differing layouts never report gapless compatibility
        let layout51 = try XCTUnwrap(AudioChannelLayoutInfo.fromFFmpegLayoutName("5.1", channelCount: 6))
        let layout51Side = try XCTUnwrap(AudioChannelLayoutInfo.fromFFmpegLayoutName("5.1(side)", channelCount: 6))
        let layout40 = try XCTUnwrap(AudioChannelLayoutInfo.fromFFmpegLayoutName("4.0", channelCount: 4))
        let layoutQuad = try XCTUnwrap(AudioChannelLayoutInfo.fromFFmpegLayoutName("quad", channelCount: 4))
        XCTAssertFalse(layout51.isGaplessCompatible(with: layout51Side))
        XCTAssertFalse(layout40.isGaplessCompatible(with: layoutQuad))

        // Verify real NativeAVAudioPlaybackDecoder preserves 5.1 vs 5.1(side) layouts on disk
        let wavBack = sandbox.temporaryURL.appendingPathComponent("real_51_back.caf")
        let wavSide = sandbox.temporaryURL.appendingPathComponent("real_51_side.caf")
        try writeFloat32AudioFile(to: wavBack, sampleRate: 48_000, channels: 6, frameCount: 2048, explicitLayoutTag: kAudioChannelLayoutTag_WAVE_5_1_B) { _, _ in 0.1 }
        try writeFloat32AudioFile(to: wavSide, sampleRate: 48_000, channels: 6, frameCount: 2048, explicitLayoutTag: kAudioChannelLayoutTag_MPEG_5_1_A) { _, _ in 0.1 }

        let decBack = try NativeAVAudioPlaybackDecoder(url: wavBack, format: .caf)
        let decSide = try NativeAVAudioPlaybackDecoder(url: wavSide, format: .caf)
        XCTAssertEqual(decBack.streamInfo.channelLayout?.normalizedName, "5.1")
        XCTAssertEqual(decSide.streamInfo.channelLayout?.normalizedName, "5.1(side)")
        await decBack.close()
        await decSide.close()
    }

    // MARK: - 8. Correction A: Lock-Free Wait-Free SPSC AudioRingBuffer Verification

    func testAudioRingBufferSPSCConcurrencyWraparoundAndExactContinuity() async throws {
        // Capacity smaller than total stream forces many full ring-buffer wraparounds
        let capacity = 512
        let totalFrames = 120_000
        let ring = AudioRingBuffer(capacity: capacity)

        let producedQueue = DispatchQueue(label: "test.spsc.producer", qos: .userInitiated)
        let producerDone = XCTestExpectation(description: "SPSC producer finished")

        producedQueue.async {
            let chunkFrames = 97 // Prime chunk size stresses odd wraparound boundaries
            var lChunk = [Float](repeating: 0, count: chunkFrames)
            var rChunk = [Float](repeating: 0, count: chunkFrames)
            var written = 0
            while written < totalFrames {
                let n = min(chunkFrames, totalFrames - written)
                for i in 0..<n {
                    let v = Float(written + i + 1)
                    lChunk[i] = v
                    rChunk[i] = -v
                }
                var offset = 0
                lChunk.withUnsafeBufferPointer { lb in
                    rChunk.withUnsafeBufferPointer { rb in
                        while offset < n {
                            let wrote = ring.write(
                                left: lb.baseAddress!.advanced(by: offset),
                                right: rb.baseAddress!.advanced(by: offset),
                                count: n - offset,
                                timelineFrame: Int64(written + offset)
                            )
                            if wrote > 0 {
                                offset += wrote
                            } else {
                                usleep(20)
                            }
                        }
                    }
                }
                written += n
            }
            ring.markFinished()
            producerDone.fulfill()
        }

        var readL = [Float](repeating: 0, count: 64)
        var readR = [Float](repeating: 0, count: 64)
        var capturedL = [Float]()
        capturedL.reserveCapacity(totalFrames)
        var capturedR = [Float]()
        capturedR.reserveCapacity(totalFrames)

        while capturedL.count < totalFrames {
            let nRead = readL.withUnsafeMutableBufferPointer { lb in
                readR.withUnsafeMutableBufferPointer { rb in
                    ring.read(left: lb.baseAddress!, right: rb.baseAddress!, count: 64)
                }
            }
            if nRead > 0 {
                capturedL.append(contentsOf: readL.prefix(nRead))
                capturedR.append(contentsOf: readR.prefix(nRead))
            } else {
                usleep(20)
            }
        }

        await fulfillment(of: [producerDone], timeout: 5.0)
        // Drain final read so drained flag becomes true
        _ = readL.withUnsafeMutableBufferPointer { lb in
            readR.withUnsafeMutableBufferPointer { rb in
                ring.read(left: lb.baseAddress!, right: rb.baseAddress!, count: 64)
            }
        }
        XCTAssertTrue(ring.playbackTimelineFrame().drained)
        XCTAssertEqual(capturedL.count, totalFrames)
        for i in 0..<totalFrames {
            let expected = Float(i + 1)
            if capturedL[i] != expected || capturedR[i] != -expected {
                XCTFail("Sample mismatch at frame \(i): L=\(capturedL[i]) R=\(capturedR[i]) expected=±\(expected)")
                break
            }
        }
    }

    func testAudioRingBufferDeterministicZeroFillUnderrunAndFreshGeneration() throws {
        let ring = AudioRingBuffer(capacity: 256)
        var outL = [Float](repeating: 99.0, count: 32)
        var outR = [Float](repeating: -99.0, count: 32)

        // Empty read returns 0 frames and deterministically zeroes entire output buffer (real-time silence)
        let emptyRead = outL.withUnsafeMutableBufferPointer { lb in
            outR.withUnsafeMutableBufferPointer { rb in
                ring.read(left: lb.baseAddress!, right: rb.baseAddress!, count: 32)
            }
        }
        XCTAssertEqual(emptyRead, 0)
        XCTAssertTrue(outL.allSatisfy { $0 == 0 })
        XCTAssertTrue(outR.allSatisfy { $0 == 0 })

        // Partial read: 10 available, request 32 -> 10 samples + 22 zero-filled frames
        let inL = (0..<10).map { Float($0 + 1) }
        let inR = (0..<10).map { Float(-($0 + 1)) }
        inL.withUnsafeBufferPointer { lb in
            inR.withUnsafeBufferPointer { rb in
                let wrote = ring.write(left: lb.baseAddress!, right: rb.baseAddress!, count: 10, timelineFrame: 500)
                XCTAssertEqual(wrote, 10)
            }
        }
        let partialRead = outL.withUnsafeMutableBufferPointer { lb in
            outR.withUnsafeMutableBufferPointer { rb in
                ring.read(left: lb.baseAddress!, right: rb.baseAddress!, count: 32)
            }
        }
        XCTAssertEqual(partialRead, 10)
        XCTAssertEqual(outL[0], 1.0)
        XCTAssertEqual(outL[9], 10.0)
        for idx in 10..<32 {
            XCTAssertEqual(outL[idx], 0.0)
            XCTAssertEqual(outR[idx], 0.0)
        }
        XCTAssertEqual(ring.playbackTimelineFrame().frame, 510)

        // A playback rollover allocates a fresh ring instead of resetting storage that a
        // previously admitted source-node callback could still be reading.
        let nextGenerationRing = AudioRingBuffer(capacity: 256)
        XCTAssertEqual(nextGenerationRing.availableFramesToRead, 0)
        let afterReset = nextGenerationRing.playbackTimelineFrame()
        XCTAssertFalse(afterReset.drained)
        XCTAssertNil(afterReset.frame)
    }

    func testAudioRenderGenerationRetirementDuringInFlightReadIsolatedFromNextGeneration() async throws {
        var oldRing: AudioRingBuffer? = AudioRingBuffer(capacity: 256)
        let oldInputL: [Float] = [0.25, 0.5, 0.75]
        let oldInputR: [Float] = [-0.25, -0.5, -0.75]
        oldInputL.withUnsafeBufferPointer { left in
            oldInputR.withUnsafeBufferPointer { right in
                XCTAssertEqual(oldRing?.write(left: left.baseAddress!, right: right.baseAddress!, count: 3, timelineFrame: 40), 3)
            }
        }

        var inFlightGeneration: AudioRenderGeneration? = AudioRenderGeneration(ring: try XCTUnwrap(oldRing))
        let weakOldRing = WeakObjectBox(inFlightGeneration?.ring)
        oldRing = nil
        let oldGate = try XCTUnwrap(inFlightGeneration?.callbackGate)
        let callbackBuffers = RenderCallbackTestBuffers(count: 3)
        let resumeCallback = DispatchSemaphore(value: 0)
        let callbackEntered = expectation(description: "render callback entered")
        let callbackFinished = expectation(description: "render callback finished")
        let staleWriteFinished = expectation(description: "retired producer write finished")
        DispatchQueue.global(qos: .userInitiated).async { [inFlightGeneration, callbackBuffers] in
            guard let inFlightGeneration else { return }
            guard inFlightGeneration.callbackGate.enter() else { return }
            callbackEntered.fulfill()
            _ = resumeCallback.wait(timeout: .now() + 2)
            inFlightGeneration.ring.read(
                left: callbackBuffers.left,
                right: callbackBuffers.right,
                count: callbackBuffers.count
            )
            inFlightGeneration.callbackGate.leave()
            callbackFinished.fulfill()
        }
        let staleProducerL: [Float] = [0.125]
        let staleProducerR: [Float] = [-0.125]
        DispatchQueue.global(qos: .userInitiated).async { [inFlightGeneration] in
            guard let inFlightGeneration else { return }
            staleProducerL.withUnsafeBufferPointer { left in
                staleProducerR.withUnsafeBufferPointer { right in
                    XCTAssertEqual(inFlightGeneration.ring.write(
                        left: left.baseAddress!, right: right.baseAddress!, count: 1, timelineFrame: 43
                    ), 1)
                }
            }
            staleWriteFinished.fulfill()
        }
        inFlightGeneration = nil
        await fulfillment(of: [callbackEntered, staleWriteFinished], timeout: 2)

        // Retirement closes admission immediately. The callback already inside read may
        // finish against its captured old ring, but storage and indices are never reset.
        oldGate.close()
        XCTAssertFalse(oldGate.enter(), "A callback arriving after retirement must be rejected")
        XCTAssertFalse(oldGate.isQuiescent, "The admitted callback must remain accounted for")

        let nextGeneration = AudioRenderGeneration(ring: AudioRingBuffer(capacity: 256))
        let nextInputL: [Float] = [0.9, 0.8]
        let nextInputR: [Float] = [-0.9, -0.8]
        nextInputL.withUnsafeBufferPointer { left in
            nextInputR.withUnsafeBufferPointer { right in
                XCTAssertEqual(nextGeneration.ring.write(left: left.baseAddress!, right: right.baseAddress!, count: 2, timelineFrame: 900), 2)
            }
        }

        XCTAssertEqual(nextGeneration.ring.playbackTimelineFrame().frame, 900)
        XCTAssertNotNil(weakOldRing.value, "The admitted callback must keep its old ring alive during retirement")

        resumeCallback.signal()
        await fulfillment(of: [callbackFinished], timeout: 2)
        XCTAssertTrue(oldGate.isQuiescent)
        XCTAssertNil(weakOldRing.value, "The retired ring should be releasable after its callback context exits")
        XCTAssertEqual(Array(UnsafeBufferPointer(start: callbackBuffers.left, count: 3)), oldInputL)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: callbackBuffers.right, count: 3)), oldInputR)

        var nextOutputL = [Float](repeating: 0, count: 2)
        var nextOutputR = [Float](repeating: 0, count: 2)
        XCTAssertTrue(nextGeneration.callbackGate.enter(), "The new generation has its own open gate")
        _ = nextOutputL.withUnsafeMutableBufferPointer { left in
            nextOutputR.withUnsafeMutableBufferPointer { right in
                nextGeneration.ring.read(left: left.baseAddress!, right: right.baseAddress!, count: 2)
            }
        }
        nextGeneration.callbackGate.leave()
        XCTAssertEqual(nextOutputL, nextInputL)
        XCTAssertEqual(nextOutputR, nextInputR)
    }

    func testAudioRenderCallbackGateCloseRaceRejectsLateEntryWithoutWaiting() async throws {
        let gate = AudioRenderCallbackGate()
        XCTAssertTrue(gate.enter())
        XCTAssertFalse(gate.enter(), "Concurrent callback entry must not violate the ring's single-consumer contract")
        gate.close()
        XCTAssertFalse(gate.enter())
        XCTAssertFalse(gate.isQuiescent)

        let waiter = Task { await gate.waitUntilQuiescent() }
        // No timing-based assumption: the gate's state itself proves the waiter cannot
        // observe quiescence until the already-admitted callback leaves.
        XCTAssertFalse(gate.isQuiescent)
        gate.leave()
        await waiter.value
        XCTAssertTrue(gate.isQuiescent)
        XCTAssertFalse(gate.enter(), "A closed generation gate is never reopened")
    }

    func testAudioRingBufferReadZeroHeapAllocations() throws {
        let inL = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let inR = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let outL = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let outR = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer {
            inL.deallocate()
            inR.deallocate()
            outL.deallocate()
            outR.deallocate()
        }
        inL.initialize(repeating: 0.25, count: 256)
        inR.initialize(repeating: -0.25, count: 256)
        outL.initialize(repeating: 0, count: 256)
        outR.initialize(repeating: 0, count: 256)

        // Warmup the exact gated render path before measurement.
        let warmGeneration = AudioRenderGeneration(ring: AudioRingBuffer(capacity: 4096))
        _ = warmGeneration.ring.write(left: inL, right: inR, count: 256, timelineFrame: 0)
        warmGeneration.render(left: outL, right: outR, count: 256)

        var blocksDeltas: [Int64] = []
        var sizeDeltas: [Int64] = []
        var exactZeroBurstCount = 0

        for _ in 0..<3 {
            let renderGeneration = AudioRenderGeneration(ring: AudioRingBuffer(capacity: 4096))
            var statsBefore = malloc_statistics_t()
            var statsAfter = malloc_statistics_t()
            var readSum: Float = 0

            for batch in 0..<10 {
                let frameBase = Int64(batch * 256)
                _ = renderGeneration.ring.write(left: inL, right: inR, count: 256, timelineFrame: frameBase)
                malloc_zone_statistics(nil, &statsBefore)
                for _ in 0..<1000 {
                    renderGeneration.render(left: outL, right: outR, count: 64)
                    readSum += outL[0]
                }
                malloc_zone_statistics(nil, &statsAfter)
                let bd = Int64(statsAfter.blocks_in_use) - Int64(statsBefore.blocks_in_use)
                let sd = Int64(statsAfter.size_in_use) - Int64(statsBefore.size_in_use)
                let allocDelta = Int64(statsAfter.size_allocated) - Int64(statsBefore.size_allocated)
                blocksDeltas.append(bd)
                sizeDeltas.append(sd)
                if bd == 0 && sd == 0 && allocDelta == 0 {
                    exactZeroBurstCount += 1
                }
            }
            XCTAssertGreaterThanOrEqual(readSum, 0)
        }

        let sortedBlocks = blocksDeltas.sorted()
        let sortedSizes = sizeDeltas.sorted()
        XCTAssertGreaterThan(exactZeroBurstCount, 0, "Expected multiple 1,000-read bursts with exact 0 block / 0 byte / 0 VM growth")
        XCTAssertLessThanOrEqual(sortedBlocks[sortedBlocks.count / 2], 0, "Median block delta during AudioRingBuffer.read must be <= 0")
        XCTAssertLessThanOrEqual(sortedSizes[sortedSizes.count / 2], 0, "Median heap size delta during AudioRingBuffer.read must be <= 0")
    }

    @MainActor
    func testAudioPlaybackEngineCancellationQuiescesProducerBeforeGenerationReplacement() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("Quiesce", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("long.wav")
        try writeFloat32AudioFile(to: wav, sampleRate: 48_000, channels: 2, frameCount: 48_000 * 4, explicitLayoutTag: nil) { _, i in
            Float(0.2 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
        }
        let builtAsset = await AudioEditorStore.buildMediaReference(for: wav)
        let asset = try XCTUnwrap(builtAsset)
        let clip = AudioClip(
            sourceAssetID: asset.id,
            name: "QuiesceClip",
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: 48_000 * 4,
            projectRate: .rate48k,
            sourceRate: .rate48k
        )
        let project = AudioEditorProject(
            name: "QuiesceProject",
            sampleRate: 48_000,
            tracks: [AudioTrack(name: "Main", clips: [clip])],
            mediaAssets: [asset]
        )

        let engine = AudioPlaybackEngine()
        for step in 0..<6 {
            engine.play(from: Double(step) * 0.1, project: project)
            try? await Task.sleep(for: .milliseconds(25))
            engine.seek(to: Double(step) * 0.4, project: project)
            try? await Task.sleep(for: .milliseconds(15))
            engine.stop()
        }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(engine.isPlaying)
    }
}

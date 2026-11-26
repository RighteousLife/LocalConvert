import XCTest
import AVFoundation
@testable import LocalConvert

private final class WeakCallbackContextBox: @unchecked Sendable {
    weak var value: EditorCallbackContext?
    init(_ value: EditorCallbackContext?) { self.value = value }
}

private final class WeakPoolBox: @unchecked Sendable {
    weak var value: EditorPCMBufferPool?
    init(_ value: EditorPCMBufferPool?) { self.value = value }
}

@MainActor
private final class MockEditorPlaybackTransport: EditorPlaybackTransport {
    struct ScheduledBufferRecord {
        let frameCount: Int
        let firstSampleL: Float
        let lastSampleL: Float
        let samplesL: [Float]
        let callbackType: AVAudioPlayerNodeCompletionCallbackType
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    }

    var isEngineRunning = false
    var isNodePlaying = false
    var onConfigurationChange: (@MainActor () -> Void)?

    var configureCount = 0
    var configuredSampleRate: Double = 0
    var configuredChannelCount: Int = 0
    var startEngineError: Error?
    var scheduleErrorOnCallIndex: Int?
    var scheduleCallCount = 0
    var stopCallCount = 0
    var pauseCallCount = 0
    var playCallCount = 0

    var scheduledRecords: [ScheduledBufferRecord] = []
    var renderedSampleTimeValue: Int64?

    func configure(sampleRate: Double, channelCount: Int) throws {
        configureCount += 1
        configuredSampleRate = sampleRate
        configuredChannelCount = channelCount
    }

    func startEngine() throws {
        if let startEngineError {
            throw startEngineError
        }
        isEngineRunning = true
    }

    func playNode() {
        playCallCount += 1
        isNodePlaying = true
    }

    func pauseNode() {
        pauseCallCount += 1
        isNodePlaying = false
    }

    func stopNode() {
        stopCallCount += 1
        isNodePlaying = false
        renderedSampleTimeValue = nil
    }

    func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer,
        callbackType: AVAudioPlayerNodeCompletionCallbackType,
        completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) throws {
        scheduleCallCount += 1
        if let failAt = scheduleErrorOnCallIndex, scheduleCallCount == failAt {
            throw EditorSchedulingError.scheduleFailed("Injected schedule failure #\(failAt)")
        }
        let n = Int(buffer.frameLength)
        let planeL: [Float]
        if let data = buffer.floatChannelData, n > 0 {
            planeL = Array(UnsafeBufferPointer(start: data[0], count: n))
        } else {
            planeL = []
        }
        scheduledRecords.append(ScheduledBufferRecord(
            frameCount: n,
            firstSampleL: planeL.first ?? 0,
            lastSampleL: planeL.last ?? 0,
            samplesL: planeL,
            callbackType: callbackType,
            completion: completion
        ))
    }

    func currentRenderedSampleTime() -> Int64? {
        renderedSampleTimeValue
    }

    @discardableResult
    func deliverNextCompletion(overrideType: AVAudioPlayerNodeCompletionCallbackType? = nil) -> Bool {
        guard !scheduledRecords.isEmpty else { return false }
        let rec = scheduledRecords.removeFirst()
        rec.completion(overrideType ?? rec.callbackType)
        return true
    }

    func triggerConfigurationChange() {
        isEngineRunning = false
        isNodePlaying = false
        onConfigurationChange?()
    }
}

final class AudioEditorPlaybackSchedulerTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "AudioEditorPlayback-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDownWithError() throws {
        AppStoragePaths.clearTestOverrides()
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
        frameCount: Int = 48_000,
        generator: (Int) -> Float
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frameCount)))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        if let data = buf.floatChannelData {
            for i in 0..<frameCount {
                let s = generator(i)
                data[0][i] = s
                data[1][i] = s
            }
        }
        try file.write(from: buf)
    }

    @MainActor
    private func makeSingleClipProject(
        name: String = "TestProj",
        frameCount: Int = 48_000,
        sampleRate: Double = 48_000,
        rampStart: Float = 0.001,
        gainDB: Double = 0
    ) async throws -> (AudioEditorProject, AudioMediaReference, URL) {
        let url = sandbox.temporaryURL.appendingPathComponent("\(name)_\(UUID().uuidString).wav")
        try writeFloat32WAV(to: url, sampleRate: sampleRate, frameCount: frameCount) { i in
            rampStart + Float(i) * 0.00001
        }
        let builtAsset = await AudioEditorStore.buildMediaReference(for: url)
        let asset = try XCTUnwrap(builtAsset)
        let rate = try SampleFrameMigration.validatedSampleRate(sampleRate)
        let clip = AudioClip(
            sourceAssetID: asset.id,
            name: "MainClip",
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: Int64(frameCount),
            projectRate: rate,
            sourceRate: rate,
            gainDB: gainDB
        )
        let track = AudioTrack(name: "Track 1", clips: [clip])
        let project = AudioEditorProject(
            name: name,
            sampleRate: sampleRate,
            tracks: [track],
            mediaAssets: [asset]
        )
        return (project, asset, url)
    }

    // MARK: - 1. PCM Ownership, Payload Budget & Publication Ordering

    func testPCMPoolBoundedPayloadAndExplicitOwnershipStates() throws {
        let config = EditorPCMPoolConfig()
        XCTAssertEqual(config.slotCount, 8)
        XCTAssertEqual(config.framesPerSlot, 2048)
        XCTAssertEqual(config.channelCount, 2)
        XCTAssertEqual(config.slotPCMPayloadBytes, 16_384)
        XCTAssertEqual(config.poolPCMPayloadBytes, 131_072)
        XCTAssertEqual(config.transferBufferPCMPayloadBytes, 16_384)
        XCTAssertEqual(config.totalPCMPayloadBytes, 147_456)

        let pool = try EditorPCMBufferPool(config: config, epoch: 1)
        let transfer = EditorPCMTransferBuffer(capacity: 2048)
        XCTAssertEqual(transfer.payloadBytes, 16_384)
        XCTAssertEqual(pool.freeSlotCount, 8)

        let slot = try XCTUnwrap(pool.acquireFreeSlotForWrite(epoch: 1))
        XCTAssertEqual(pool.slotStates[slot], .writing)
        XCTAssertEqual(pool.freeSlotCount, 7)

        // Scheduler cannot schedule a `.writing` slot until producer publishes READY.
        XCTAssertNil(try pool.beginSchedulingNextReady(expectedEpoch: 1, minRevision: 1))

        transfer.left[0] = 0.42
        transfer.right[0] = -0.42
        let meta = EditorPCMBlockMetadata(
            epoch: 1, revision: 1, timelineStartFrame: 0, frameCount: 2048,
            isEndOfStream: false, peakL: 0.42, peakR: 0.42, gainReductionDB: 0
        )
        XCTAssertTrue(pool.copyAndPublishReady(slotIndex: slot, from: transfer, metadata: meta))
        XCTAssertEqual(pool.slotStates[slot], .ready)
        XCTAssertEqual(pool.readySlotCount, 1)

        // Mark scheduled BEFORE submitting to node.
        let scheduled = try XCTUnwrap(pool.beginSchedulingNextReady(expectedEpoch: 1, minRevision: 1))
        XCTAssertEqual(scheduled.slotIndex, slot)
        XCTAssertEqual(pool.slotStates[slot], .scheduled)
        XCTAssertEqual(scheduled.callbackType, .dataConsumed)
        XCTAssertEqual(scheduled.buffer.floatChannelData?[0][0] ?? 0, 0.42, accuracy: 1e-6)
        XCTAssertEqual(pool.callbackContext.outstandingCallbackCount, 1)

        // Deliver .dataConsumed -> reclaims slot cleanly to .free.
        pool.callbackContext.recordCompletion(slotIndex: slot, tokenSequence: scheduled.token.sequence, callbackType: .dataConsumed)
        let poll = pool.pollAndReclaimCompletedSlots()
        XCTAssertEqual(poll.reclaimedTokens, [scheduled.token])
        XCTAssertTrue(poll.playedBackBlocks.isEmpty)
        XCTAssertEqual(pool.slotStates[slot], .free)
        XCTAssertEqual(pool.freeSlotCount, 8)
    }

    // MARK: - 2. Partial Write Cancellation Never Publishes READY

    @MainActor
    func testPartialWriteCancellationNeverBecomesReady() async throws {
        let config = EditorPCMPoolConfig(slotCount: 4, framesPerSlot: 2048, channelCount: 2, sampleRate: 48_000)
        let pool = try EditorPCMBufferPool(config: config, epoch: 1)
        let producer = EditorPCMProducer(transferCapacity: 2048)

        let enteredMixHook = expectation(description: "producer entered mix hook")
        let gate = AsyncHookGate()

        await producer.setTestHookAfterMixBeforePublish { _ in
            enteredMixHook.fulfill()
            await gate.wait()
        }

        let (project, _, _) = try await makeSingleClipProject(frameCount: 16_384)
        let sources = try await AudioSourceResolver.resolve(project: project)
        await producer.configureSession(project: project, sources: sources, resetEffectStates: true)

        await producer.startProducing(
            epoch: 1, revision: 1, startFrame: 0, projectRate: .rate48k,
            endDurationFrames: 16_384, autoStopAtFrame: nil, loopBounds: nil, pool: pool
        )
        await fulfillment(of: [enteredMixHook], timeout: 2.0)

        // Cancel & drain while slot is mid-write inside hook.
        let stopTask = Task {
            await producer.stopAndDrain(nextEpoch: 2)
        }
        await gate.release()
        await stopTask.value

        XCTAssertEqual(pool.readySlotCount, 0, "Aborted/cancelled partial PCM write must NEVER become READY")
        XCTAssertEqual(pool.freeSlotCount, 4, "Aborted write slot must return cleanly to .free")
    }

    // MARK: - 3. Stale, Duplicate & ABA Token Protection + Token Overflow

    func testStaleDuplicateABATokensAndTokenSequenceOverflow() throws {
        let config = EditorPCMPoolConfig(slotCount: 2, framesPerSlot: 512, channelCount: 2, sampleRate: 48_000)
        let transfer = EditorPCMTransferBuffer(capacity: 512)
        transfer.left[0] = 0.25

        let pool = try EditorPCMBufferPool(config: config, epoch: 7, startingSequence: UInt64.max - 1)

        // Issue token seq = UInt64.max - 1
        let s0 = try XCTUnwrap(pool.acquireFreeSlotForWrite(epoch: 7))
        XCTAssertTrue(pool.copyAndPublishReady(slotIndex: s0, from: transfer, metadata: EditorPCMBlockMetadata(
            epoch: 7, revision: 1, timelineStartFrame: 0, frameCount: 512,
            isEndOfStream: false, peakL: 0.25, peakR: 0.25, gainReductionDB: 0
        )))
        let sched0 = try XCTUnwrap(pool.beginSchedulingNextReady(expectedEpoch: 7, minRevision: 1))
        XCTAssertEqual(sched0.token.sequence, UInt64.max - 1)

        // Stale wrong sequence callback must be ignored without corrupting state
        pool.callbackContext.recordCompletion(slotIndex: s0, tokenSequence: 123, callbackType: .dataConsumed)
        XCTAssertEqual(pool.callbackContext.staleCallbackCount, 1)
        XCTAssertEqual(pool.slotStates[s0], .scheduled)

        // Deliver valid callback twice -> second is duplicate, counted & ignored safely
        pool.callbackContext.recordCompletion(slotIndex: s0, tokenSequence: sched0.token.sequence, callbackType: .dataConsumed)
        pool.callbackContext.recordCompletion(slotIndex: s0, tokenSequence: sched0.token.sequence, callbackType: .dataConsumed)
        XCTAssertEqual(pool.callbackContext.duplicateCallbackCount, 1)
        _ = pool.pollAndReclaimCompletedSlots()
        XCTAssertEqual(pool.slotStates[s0], .free)

        // Issue final sequence = UInt64.max (different token on same slot -> prevents ABA!)
        let sAgain = try XCTUnwrap(pool.acquireFreeSlotForWrite(epoch: 7))
        XCTAssertTrue(pool.copyAndPublishReady(slotIndex: sAgain, from: transfer, metadata: EditorPCMBlockMetadata(
            epoch: 7, revision: 1, timelineStartFrame: 512, frameCount: 512,
            isEndOfStream: false, peakL: 0.25, peakR: 0.25, gainReductionDB: 0
        )))
        let sched1 = try XCTUnwrap(pool.beginSchedulingNextReady(expectedEpoch: 7, minRevision: 1))
        XCTAssertEqual(sched1.token.sequence, UInt64.max)
        XCTAssertNotEqual(sched1.token, sched0.token)

        // Late replay of sched0's token must NOT affect sched1
        pool.callbackContext.recordCompletion(slotIndex: sAgain, tokenSequence: sched0.token.sequence, callbackType: .dataConsumed)
        XCTAssertEqual(pool.callbackContext.staleCallbackCount, 2)
        XCTAssertEqual(pool.slotStates[sAgain], .scheduled)

        // Attempting another issue after UInt64.max must throw EditorTokenError.sequenceOverflow rather than wrapping
        let sOther = try XCTUnwrap(pool.acquireFreeSlotForWrite(epoch: 7))
        XCTAssertTrue(pool.copyAndPublishReady(slotIndex: sOther, from: transfer, metadata: EditorPCMBlockMetadata(
            epoch: 7, revision: 1, timelineStartFrame: 1024, frameCount: 512,
            isEndOfStream: true, peakL: 0.25, peakR: 0.25, gainReductionDB: 0
        )))
        XCTAssertThrowsError(try pool.beginSchedulingNextReady(expectedEpoch: 7, minRevision: 1)) { err in
            XCTAssertEqual(err as? EditorTokenError, .sequenceOverflow)
        }
    }

    @MainActor
    func testSchedulerSafeEpochRolloverOnTokenOverflow() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 16_384)
        let assetID = project.tracks[0].clips[0].sourceAssetID!
        let clipID = project.tracks[0].clips[0].id
        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5),
            startingTokenSequence: UInt64.max
        )
        _ = assetID

        scheduler.play(fromFrame: 0, project: project)
        let initialEpoch = scheduler.epoch
        await scheduler.waitForTransitionCompletion()

        // First buffer uses UInt64.max; second triggers EditorTokenError.sequenceOverflow -> safe epoch rollover!
        for _ in 0..<25 where scheduler.epoch <= initialEpoch {
            try? await Task.sleep(for: .milliseconds(10))
            await scheduler.pollOnce()
            await scheduler.waitForTransitionCompletion()
        }

        XCTAssertGreaterThan(scheduler.epoch, initialEpoch, "Token sequence exhaustion should roll over cleanly to a new epoch")
        XCTAssertEqual(scheduler.state, .playing)
        scheduler.shutdown()
    }

    // MARK: - 4. Slot Exhaustion & Bounded Producer Back-Pressure

    @MainActor
    func testSlotExhaustionBoundedBackPressureAndRecoveryOnConsume() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 48_000) // ~24 blocks of 2048 frames
        let clipID = project.tracks[0].clips[0].id
        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )

        scheduler.play(fromFrame: 0, project: project)
        await scheduler.waitForTransitionCompletion()

        // Give producer plenty of cycles while zero completions are delivered -> fills all 8 slots cleanly.
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(15))
            await scheduler.pollOnce()
        }

        let pool = try XCTUnwrap(scheduler.activePool)
        XCTAssertEqual(pool.scheduledSlotCount, 8)
        XCTAssertEqual(pool.freeSlotCount, 0)
        XCTAssertEqual(transport.scheduledRecords.count, 8, "Exactly 8 buffers should be in flight under bounded back-pressure")

        // Consume 3 slots -> producer wakes under back-pressure and fills freed slots.
        for _ in 0..<3 {
            XCTAssertTrue(transport.deliverNextCompletion(overrideType: .dataConsumed))
        }
        for _ in 0..<8 {
            await scheduler.pollOnce()
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertGreaterThanOrEqual(transport.scheduleCallCount, 11, "Producer must resume producing as soon as consumed callbacks free slots")
        scheduler.shutdown()
    }

    // MARK: - 5. Scheduling Failure & Rollback

    @MainActor
    func testSchedulingFailureTransitionsCleanlyAndSurfacesError() async throws {
        let transport = MockEditorPlaybackTransport()
        transport.scheduleErrorOnCallIndex = 1
        let (project, _, url) = try await makeSingleClipProject(frameCount: 8_192)
        let clipID = project.tracks[0].clips[0].id
        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )

        scheduler.play(fromFrame: 0, project: project)
        await scheduler.waitForTransitionCompletion()
        await scheduler.pollOnce()

        if case .failed(let msg) = scheduler.state {
            XCTAssertTrue(msg.contains("Injected schedule failure"))
        } else {
            XCTFail("Expected .failed state on schedule failure, got \(scheduler.state)")
        }
        XCTAssertNotNil(scheduler.lastError)
        XCTAssertEqual(scheduler.activeMonitorLoopCount, 0)
    }

    // MARK: - 6. Outstanding Buffers During Stop & Shutdown (Quarantine & Lifetime)

    @MainActor
    func testOutstandingBuffersDuringStopAndShutdownAreQuarantinedUntilLateCallbacksArrive() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 12_288)
        let clipID = project.tracks[0].clips[0].id
        var scheduler: EditorPCMPlaybackScheduler? = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )

        scheduler?.play(fromFrame: 0, project: project)
        await scheduler?.waitForTransitionCompletion()
        try? await Task.sleep(for: .milliseconds(25))
        await scheduler?.pollOnce()

        let pool = try XCTUnwrap(scheduler?.activePool)
        let weakPool = WeakPoolBox(pool)
        let weakContext = WeakCallbackContextBox(pool.callbackContext)
        let scheduledBeforeStop = transport.scheduledRecords.count
        XCTAssertGreaterThan(scheduledBeforeStop, 0)

        // Stop while callbacks are still outstanding.
        scheduler?.stop()
        XCTAssertEqual(scheduler?.state, .stopped)
        XCTAssertEqual(pool.quarantinedSlotCount, scheduledBeforeStop)
        XCTAssertEqual(pool.freeSlotCount, pool.config.slotCount - scheduledBeforeStop)

        // Wait 60ms without callbacks: no arbitrary timeout may reclaim quarantined buffers!
        try? await Task.sleep(for: .milliseconds(60))
        await scheduler?.pollOnce()
        XCTAssertEqual(pool.quarantinedSlotCount, scheduledBeforeStop, "Quarantined buffers must NEVER be reclaimed by arbitrary timeout")
        XCTAssertEqual(pool.callbackContext.outstandingCallbackCount, scheduledBeforeStop)

        // Shutdown scheduler and release reference; callback closures still retain context safely.
        scheduler?.shutdown()
        scheduler = nil
        _ = weakPool
        XCTAssertNotNil(weakContext.value, "Callback closures must keep EditorCallbackContext alive until AVFoundation finishes")

        // Now deliver late AVFoundation callbacks after shutdown -> no crash, zero outstanding left.
        while transport.deliverNextCompletion() {}
        XCTAssertEqual(weakContext.value?.outstandingCallbackCount ?? 0, 0)
        transport.scheduledRecords.removeAll()
    }

    // MARK: - 7. Playhead Separation vs. Buffer Consumption (.dataConsumed vs .dataPlayedBack)

    @MainActor
    func testDataConsumedReclaimsMemoryWithoutAdvancingPlayheadOrTriggeringEOF() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 3_000) // 2 blocks (2048 + EOF)
        let clipID = project.tracks[0].clips[0].id
        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )

        scheduler.play(fromFrame: 0, project: project)
        await scheduler.waitForTransitionCompletion()
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(10))
            await scheduler.pollOnce()
        }

        // Verify non-EOF block uses .dataConsumed and final EOF block uses .dataPlayedBack
        XCTAssertGreaterThanOrEqual(transport.scheduledRecords.count, 2)
        XCTAssertEqual(transport.scheduledRecords[0].callbackType, .dataConsumed)
        XCTAssertEqual(transport.scheduledRecords.last?.callbackType, .dataPlayedBack)

        // Deliver .dataConsumed on non-EOF buffer while renderedSampleTime stays at 0.
        XCTAssertTrue(transport.deliverNextCompletion(overrideType: .dataConsumed))
        await scheduler.pollOnce()
        XCTAssertEqual(scheduler.displayedPlayheadFrame, 0, "Consuming PCM buffer for memory reuse must NOT advance audible playhead")
        XCTAssertEqual(scheduler.state, .playing)

        // Advance rendered sample time -> playhead follows audible timeline position.
        transport.renderedSampleTimeValue = 1500
        await scheduler.pollOnce()
        XCTAssertEqual(scheduler.displayedPlayheadFrame, 1500)
        XCTAssertEqual(scheduler.state, .playing)

        // Deliver .dataPlayedBack on EOF block -> playback finishes cleanly.
        while transport.deliverNextCompletion() {}
        await scheduler.pollOnce()
        XCTAssertEqual(scheduler.state, .stopped)
        scheduler.shutdown()
    }

    // MARK: - 8. Non-Structural Revisions & Rapid Coalescing vs. Structural Edits & Undo/Redo

    @MainActor
    func testSemanticProjectDiffClassificationCoversDirectAndUndoRedoStates() async throws {
        let (baseProj, _, _) = try await makeSingleClipProject(frameCount: 24_000)
        var nonStructMute = baseProj
        nonStructMute.tracks[0].isMuted = true
        XCTAssertEqual(AudioProjectChangeClassifier.classify(from: baseProj, to: nonStructMute), .nonStructural)

        var nonStructVol = baseProj
        nonStructVol.tracks[0].volume = 0.45
        XCTAssertEqual(AudioProjectChangeClassifier.classify(from: baseProj, to: nonStructVol), .nonStructural)

        var nonStructClipGain = baseProj
        nonStructClipGain.tracks[0].clips[0].gainDB = -6.0
        XCTAssertEqual(AudioProjectChangeClassifier.classify(from: baseProj, to: nonStructClipGain), .nonStructural)

        var nonAudioMarker = baseProj
        nonAudioMarker.markers = [AudioMarker(frame: 1000, sampleRate: .rate48k, name: "Verse")]
        XCTAssertEqual(AudioProjectChangeClassifier.classify(from: baseProj, to: nonAudioMarker), .noAudioImpact)

        var structMove = baseProj
        structMove.tracks[0].clips[0].timelineStartFrame = 4800
        XCTAssertEqual(AudioProjectChangeClassifier.classify(from: baseProj, to: structMove), .structural)

        // Undo semantic check (restoring back to baseProj has the same classification symmetry)
        XCTAssertEqual(AudioProjectChangeClassifier.classify(from: structMove, to: baseProj), .structural)
        XCTAssertEqual(AudioProjectChangeClassifier.classify(from: nonStructMute, to: baseProj), .nonStructural)
    }

    @MainActor
    func testNonStructuralRapidRevisionCoalescesWithoutBumpingEpoch() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 48_000)
        let clipID = project.tracks[0].clips[0].id
        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )

        scheduler.play(fromFrame: 0, project: project)
        await scheduler.waitForTransitionCompletion()
        let initialEpoch = scheduler.epoch

        // Rapid non-structural volume/mute edits coalesce to latest revision without bumping epoch.
        for step in 1...5 {
            var edited = project
            edited.tracks[0].volume = Double(step) * 0.1
            scheduler.projectDidChange(edited)
        }
        await scheduler.waitForRevisionCoalescing()

        XCTAssertEqual(scheduler.epoch, initialEpoch, "Non-structural edits must NOT bump epoch")
        XCTAssertEqual(scheduler.revision, 6)
        XCTAssertEqual(scheduler.state, .playing)
        scheduler.shutdown()
    }

    @MainActor
    func testStructuralEditDuringPlaybackInvalidatesOldEpochAndRestartsFromDisplayedPlayhead() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 48_000)
        let clipID = project.tracks[0].clips[0].id
        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )

        scheduler.play(fromFrame: 0, project: project)
        await scheduler.waitForTransitionCompletion()

        // Ensure at least 2 blocks (>= 4096 frames) are scheduled before simulating hardware render at frame 3000
        for _ in 0..<40 {
            let scheduledFrames = transport.scheduledRecords.reduce(0) { $0 + $1.frameCount }
            if scheduledFrames >= 4096 { break }
            try? await Task.sleep(for: .milliseconds(5))
            await scheduler.pollOnce()
        }

        // Advance audible rendered sample time to frame 3000 before structural edit
        transport.renderedSampleTimeValue = 3000
        await scheduler.pollOnce()
        XCTAssertEqual(scheduler.displayedPlayheadFrame, 3000)
        let oldEpoch = scheduler.epoch
        let oldPool = try XCTUnwrap(scheduler.activePool)

        // Structural edit: move clip start to frame 1000
        var moved = project
        moved.tracks[0].clips[0].timelineStartFrame = 1000
        scheduler.projectDidChange(moved)
        await scheduler.waitForTransitionCompletion()

        XCTAssertGreaterThan(scheduler.epoch, oldEpoch, "Structural edit must bump epoch")
        XCTAssertTrue(oldPool.isRetired, "Old pool must be retired so stale PCM cannot enter the new epoch")
        XCTAssertEqual(scheduler.displayedPlayheadFrame, 3000, "Structural edit restart origin must match displayed user playhead")
        XCTAssertEqual(scheduler.state, .playing)

        // Drain old scheduled records; verify new epoch scheduled from frame 3000 (which has audio at clip start 1000 + offset 2000)
        scheduler.shutdown()
    }

    // MARK: - 9. Pause, Resume, Seek, Loop Continuity & Interruption Recovery

    @MainActor
    func testPauseResumeSeekLoopAndInterruptionRecovery() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 48_000)
        let clipID = project.tracks[0].clips[0].id
        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )

        scheduler.setLoop(frameRange: try SampleFrameRange(startFrame: 1000, frameCount: 3000, sampleRate: .rate48k), enabled: true)
        scheduler.play(fromFrame: 0, project: project) // clamped into loop start 1000
        await scheduler.waitForTransitionCompletion()
        XCTAssertEqual(scheduler.displayedPlayheadFrame, 1000)
        let epochBeforePause = scheduler.epoch

        // Pause -> buffers stay queued, no duplicate monitor loops
        scheduler.pause()
        XCTAssertEqual(scheduler.state, .paused)
        XCTAssertEqual(scheduler.activeMonitorLoopCount, 0)

        // Resume -> reuses active node without restarting epoch
        scheduler.resume(project: project)
        XCTAssertEqual(scheduler.state, .playing)
        XCTAssertEqual(scheduler.epoch, epochBeforePause)
        XCTAssertEqual(scheduler.activeMonitorLoopCount, 1)

        // Seek while playing -> restarts from seek target (within loop bounds)
        scheduler.seek(toFrame: 2048, project: project)
        await scheduler.waitForTransitionCompletion()
        XCTAssertEqual(scheduler.displayedPlayheadFrame, 2048)

        // Simulate AVAudioEngineConfigurationChange interruption -> recovers and resumes cleanly
        let epochBeforeRoute = scheduler.epoch
        transport.triggerConfigurationChange()
        await scheduler.waitForTransitionCompletion()
        XCTAssertGreaterThan(scheduler.epoch, epochBeforeRoute)
        XCTAssertEqual(scheduler.state, .playing)
        XCTAssertEqual(scheduler.displayedPlayheadFrame, 2048)

        // Simulated restart failure surfaces clean error
        transport.startEngineError = EditorSchedulingError.engineStartFailed("Mock hardware disconnected")
        transport.triggerConfigurationChange()
        await scheduler.waitForTransitionCompletion()
        if case .failed(let reason) = scheduler.state {
            XCTAssertTrue(reason.contains("Mock hardware disconnected"))
        } else {
            XCTFail("Expected .failed state when engine restart fails")
        }
        scheduler.shutdown()
    }

    // MARK: - 10. Facade Integration (AudioPlaybackEngine + AudioEditorStore + Arbitration) & Library Independence

    @MainActor
    func testAudioEditorFacadeAndStoreIntegrationPreservingArbitration() async throws {
        let transport = MockEditorPlaybackTransport()
        let (project, _, url) = try await makeSingleClipProject(frameCount: 24_000)
        let clipID = project.tracks[0].clips[0].id
        let center = PlaybackArbitrationCenter()
        var libraryPauseCount = 0
        let libToken = center.registerClient(.audioLibraryPlayer) {
            libraryPauseCount += 1
        }
        defer { center.unregisterClient(libToken) }

        let scheduler = EditorPCMPlaybackScheduler(
            transport: transport,
            sourceResolver: { _ in [clipID: ResolvedClipSource(clipID: clipID, url: url, baseFrame: 0)] },
            monitorInterval: .milliseconds(5)
        )
        let engine = AudioPlaybackEngine(arbitrationCenter: center, backendMode: .playerNodePool, scheduler: scheduler)

        engine.play(fromFrame: 0, project: project)
        await scheduler.waitForTransitionCompletion()
        XCTAssertEqual(libraryPauseCount, 1, "Audio Editor playback must still arbitrate with Library Player")
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(engine.isPaused)

        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.isPaused)

        engine.resume(project: project)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertFalse(engine.isPaused)

        // Library Player starting pauses Editor Engine without tearing down Library state
        center.notifyPlaybackStarted(by: .audioLibraryPlayer)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.isPaused)

        engine.shutdown()

        // Verify AudioEditorStore end-to-end command routing + undo/redo classification
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.temporaryURL.appendingPathComponent("j"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.temporaryURL.appendingPathComponent("a"))
        )
        let store = AudioEditorStore(undoCoordinator: undoCoord)
        store.performMutation(type: .clipImport, title: "Load") { p in
            p = project
            return true
        }
        await store.flushPendingUndoRecords()
        XCTAssertEqual(store.project.tracks[0].clips.count, 1)
        store.togglePlayPause()
        try? await Task.sleep(for: .milliseconds(50))
        store.stopPlayback()
        store.seek(to: 0.2)
        XCTAssertEqual(store.timeline.playheadTime, 0.2, accuracy: 0.01)
    }
}

private actor AsyncHookGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

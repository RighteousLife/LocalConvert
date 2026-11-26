import Foundation
import AVFoundation

actor EditorPCMProducer {
    private let transferBuffer: EditorPCMTransferBuffer
    private var mixSession: AudioMixSession?
    private var activeEpoch: UInt64 = 0
    private var activeRevision: UInt64 = 1
    private var activeLoopTask: Task<Void, Never>?
    private var pendingRevision: (revision: UInt64, project: AudioEditorProject, sources: [UUID: ResolvedClipSource], resumeFrame: Int64)?
    private var testHookAfterMixBeforePublish: (@Sendable (Int64) async -> Void)?

    init(transferCapacity: Int = EditorPCMPoolConfig.defaultFramesPerSlot) {
        self.transferBuffer = EditorPCMTransferBuffer(capacity: transferCapacity)
    }

    func setTestHookAfterMixBeforePublish(_ hook: (@Sendable (Int64) async -> Void)?) {
        self.testHookAfterMixBeforePublish = hook
    }

    func configureSession(
        project: AudioEditorProject,
        sources: [UUID: ResolvedClipSource],
        resetEffectStates: Bool
    ) {
        if let existing = mixSession, abs(existing.sampleRate - project.sampleRate) < 0.5 {
            existing.update(project: project, sources: sources)
            if resetEffectStates {
                existing.resetEffectStates()
            }
        } else {
            let session = AudioMixSession(project: project, sources: sources)
            if resetEffectStates {
                session.resetEffectStates()
            }
            mixSession = session
        }
    }

    func applyNonStructuralRevision(
        epoch: UInt64,
        revision: UInt64,
        project: AudioEditorProject,
        sources: [UUID: ResolvedClipSource],
        pool: EditorPCMBufferPool,
        resumeFromFrame: Int64
    ) {
        guard epoch == activeEpoch, !pool.isRetired else { return }
        if let existing = pendingRevision, existing.revision >= revision {
            return
        }
        pendingRevision = (revision, project, sources, max(0, resumeFromFrame))
        _ = pool.discardUnscheduledReadySlots(olderThanRevision: revision)
    }

    func stopAndDrain(nextEpoch: UInt64) async {
        activeEpoch = nextEpoch
        pendingRevision = nil
        if let task = activeLoopTask {
            task.cancel()
            await task.value
            activeLoopTask = nil
        }
    }

    func startProducing(
        epoch: UInt64,
        revision: UInt64,
        startFrame: Int64,
        projectRate: SampleRate,
        endDurationFrames: Int64,
        autoStopAtFrame: Int64?,
        loopBounds: (startFrame: Int64, endFrame: Int64)?,
        pool: EditorPCMBufferPool
    ) async {
        // Enforce single serial producer: stop and drain any prior loop before launching a new one.
        await stopAndDrain(nextEpoch: epoch)
        guard !Task.isCancelled, !pool.isRetired else { return }

        activeEpoch = epoch
        activeRevision = revision
        pendingRevision = nil

        let task = Task {
            await self.runProductionLoop(
                epoch: epoch,
                initialRevision: revision,
                startFrame: max(0, startFrame),
                projectRate: projectRate,
                endDurationFrames: endDurationFrames,
                autoStopAtFrame: autoStopAtFrame,
                loopBounds: loopBounds,
                pool: pool
            )
        }
        activeLoopTask = task
    }

    var transferBufferPayloadBytes: Int {
        transferBuffer.payloadBytes
    }

    // MARK: - Serial Actor Production Loop

    private func runProductionLoop(
        epoch: UInt64,
        initialRevision: UInt64,
        startFrame: Int64,
        projectRate: SampleRate,
        endDurationFrames: Int64,
        autoStopAtFrame: Int64?,
        loopBounds: (startFrame: Int64, endFrame: Int64)?,
        pool: EditorPCMBufferPool
    ) async {
        var posFrame = startFrame
        var currentRevision = initialRevision
        let blockCapacity = min(pool.config.framesPerSlot, transferBuffer.capacity)

        while !Task.isCancelled, activeEpoch == epoch, !pool.isRetired {
            // Apply any coalesced non-structural revision before mixing the next block.
            if let update = consumePendingRevisionIfNewer(than: currentRevision) {
                mixSession?.update(project: update.project, sources: update.sources)
                currentRevision = update.revision
                _ = pool.discardUnscheduledReadySlots(olderThanRevision: currentRevision)
                posFrame = update.resumeFrame
            }

            // Compute exact block length and EOF/loop boundaries before acquiring a slot.
            var frameCount = blockCapacity
            var isEndOfStream = false
            var wrappedLoop = false

            if let loop = loopBounds, loop.endFrame > loop.startFrame {
                if posFrame >= loop.endFrame || posFrame < loop.startFrame {
                    posFrame = loop.startFrame
                }
                let remaining = loop.endFrame - posFrame
                if remaining <= Int64(blockCapacity) {
                    frameCount = Int(max(1, remaining))
                    wrappedLoop = true
                }
            } else {
                let effectiveEnd: Int64
                if let stopAt = autoStopAtFrame {
                    effectiveEnd = min(endDurationFrames, stopAt)
                } else {
                    effectiveEnd = endDurationFrames
                }
                if posFrame >= effectiveEnd {
                    return
                }
                let remaining = effectiveEnd - posFrame
                if remaining <= Int64(blockCapacity) {
                    frameCount = Int(max(1, remaining))
                    isEndOfStream = true
                }
            }

            // Acquire free slot with bounded back-pressure.
            guard let slotIndex = pool.acquireFreeSlotForWrite(epoch: epoch) else {
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }

            // Mix strictly into the producer-owned transfer buffer while slot is in `.writing`.
            transferBuffer.zero(count: frameCount)
            var peakL: Float = 0
            var peakR: Float = 0
            var gainReductionDB: Float = 0

            if let session = mixSession {
                session.mix(startFrame: posFrame, frameCount: frameCount, left: transferBuffer.left, right: transferBuffer.right)
                peakL = session.peakL
                peakR = session.peakR
                gainReductionDB = session.gainReductionDB
                session.resetPeaks()
            }

            if let hook = testHookAfterMixBeforePublish {
                await hook(posFrame)
            }

            // Validate cancellation, epoch, and pool state BEFORE publishing READY.
            if Task.isCancelled || activeEpoch != epoch || pool.isRetired {
                pool.abortWrite(slotIndex: slotIndex)
                return
            }

            // If a newer non-structural revision arrived during mixing, abort partial stale render cleanly
            // and re-render from the updated revision rather than publishing stale audio.
            if let newer = pendingRevision, newer.revision > currentRevision {
                pool.abortWrite(slotIndex: slotIndex)
                continue
            }

            let metadata = EditorPCMBlockMetadata(
                epoch: epoch,
                revision: currentRevision,
                timelineStartFrame: posFrame,
                frameCount: frameCount,
                isEndOfStream: isEndOfStream,
                peakL: peakL,
                peakR: peakR,
                gainReductionDB: gainReductionDB
            )

            let published = pool.copyAndPublishReady(slotIndex: slotIndex, from: transferBuffer, metadata: metadata)
            guard published else {
                pool.abortWrite(slotIndex: slotIndex)
                return
            }

            if isEndOfStream {
                return
            }

            if wrappedLoop, let loop = loopBounds {
                posFrame = loop.startFrame
            } else {
                posFrame += Int64(frameCount)
            }

            await Task.yield()
        }
    }

    private func consumePendingRevisionIfNewer(
        than currentRevision: UInt64
    ) -> (revision: UInt64, project: AudioEditorProject, sources: [UUID: ResolvedClipSource], resumeFrame: Int64)? {
        guard let update = pendingRevision, update.revision > currentRevision else {
            return nil
        }
        pendingRevision = nil
        return update
    }
}

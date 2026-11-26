import Foundation
import AVFoundation
import os
import Synchronization

// MARK: - Pool Configuration & Memory Accounting

struct EditorPCMPoolConfig: Sendable, Equatable {
    static let defaultSlotCount = 8
    static let defaultFramesPerSlot = 2048
    static let defaultChannelCount = 2

    let slotCount: Int
    let framesPerSlot: Int
    let channelCount: Int
    let sampleRate: Double

    init(
        slotCount: Int = EditorPCMPoolConfig.defaultSlotCount,
        framesPerSlot: Int = EditorPCMPoolConfig.defaultFramesPerSlot,
        channelCount: Int = EditorPCMPoolConfig.defaultChannelCount,
        sampleRate: Double = 48_000
    ) {
        self.slotCount = max(2, slotCount)
        self.framesPerSlot = max(256, framesPerSlot)
        self.channelCount = max(1, min(2, channelCount))
        self.sampleRate = max(8_000, sampleRate)
    }

    var slotPCMPayloadBytes: Int {
        framesPerSlot * channelCount * MemoryLayout<Float>.stride
    }

    var poolPCMPayloadBytes: Int {
        slotCount * slotPCMPayloadBytes
    }

    var transferBufferPCMPayloadBytes: Int {
        slotPCMPayloadBytes
    }

    var totalPCMPayloadBytes: Int {
        (slotCount + 1) * slotPCMPayloadBytes
    }
}

// MARK: - ABA-Proof Buffer Tokens & Overflow Protection

struct EditorBufferToken: Equatable, Hashable, Sendable {
    let epoch: UInt64
    let slotIndex: Int
    let sequence: UInt64
}

enum EditorTokenError: Error, Equatable, Sendable {
    case sequenceOverflow
    case epochOverflow
}

struct EditorTokenGenerator: Sendable {
    private(set) var nextSequence: UInt64

    init(startingSequence: UInt64 = 1) {
        self.nextSequence = max(1, startingSequence)
    }

    mutating func issue(epoch: UInt64, slotIndex: Int) throws -> EditorBufferToken {
        guard nextSequence != 0 else {
            throw EditorTokenError.sequenceOverflow
        }
        let issued = nextSequence
        if nextSequence == UInt64.max {
            nextSequence = 0
        } else {
            nextSequence += 1
        }
        return EditorBufferToken(epoch: epoch, slotIndex: slotIndex, sequence: issued)
    }
}

// MARK: - Dedicated Producer Transfer Buffer

final class EditorPCMTransferBuffer: @unchecked Sendable {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let capacity: Int

    init(capacity: Int = EditorPCMPoolConfig.defaultFramesPerSlot) {
        let cap = max(256, capacity)
        self.capacity = cap
        self.left = .allocate(capacity: cap)
        self.right = .allocate(capacity: cap)
        self.left.initialize(repeating: 0, count: cap)
        self.right.initialize(repeating: 0, count: cap)
    }

    deinit {
        left.deinitialize(count: capacity)
        right.deinitialize(count: capacity)
        left.deallocate()
        right.deallocate()
    }

    var payloadBytes: Int {
        capacity * 2 * MemoryLayout<Float>.stride
    }

    func zero(count: Int) {
        let clamped = min(max(0, count), capacity)
        guard clamped > 0 else { return }
        left.update(repeating: 0, count: clamped)
        right.update(repeating: 0, count: clamped)
    }
}

// MARK: - Lock-Free Per-Slot Callback Mailbox & Lifetime Context

private final class AtomicSlotMailbox: @unchecked Sendable {
    let expectedSeq = Atomic<UInt64>(0)
    let consumedSeq = Atomic<UInt64>(0)
    let playedBackSeq = Atomic<UInt64>(0)
    let outstanding = Atomic<Bool>(false)
}

final class EditorCallbackContext: @unchecked Sendable {
    let epoch: UInt64
    let slotCount: Int
    private let mailboxes: [AtomicSlotMailbox]
    // Strong retention of every preallocated AVAudioPCMBuffer ensures zero use-after-free
    // as long as any AVAudioPlayerNode completion closure holds this context.
    private let retainedBuffers: [AVAudioPCMBuffer]
    private let retired = Atomic<Bool>(false)
    private let activeOutstandingCount = Atomic<Int>(0)
    private let staleCount = Atomic<Int>(0)
    private let duplicateCount = Atomic<Int>(0)

    init(epoch: UInt64, buffers: [AVAudioPCMBuffer]) {
        self.epoch = epoch
        self.slotCount = buffers.count
        self.retainedBuffers = buffers
        self.mailboxes = (0..<buffers.count).map { _ in AtomicSlotMailbox() }
    }

    func armSlot(_ slotIndex: Int, tokenSequence: UInt64) {
        guard slotIndex >= 0, slotIndex < slotCount, tokenSequence != 0 else { return }
        let m = mailboxes[slotIndex]
        m.consumedSeq.store(0, ordering: .relaxed)
        m.playedBackSeq.store(0, ordering: .relaxed)
        m.expectedSeq.store(tokenSequence, ordering: .releasing)
        let wasOutstanding = m.outstanding.exchange(true, ordering: .acquiringAndReleasing)
        if !wasOutstanding {
            activeOutstandingCount.wrappingAdd(1, ordering: .acquiringAndReleasing)
        }
    }

    func disarmSlotOnPreSubmitFailure(_ slotIndex: Int, tokenSequence: UInt64) {
        guard slotIndex >= 0, slotIndex < slotCount else { return }
        let m = mailboxes[slotIndex]
        if m.expectedSeq.load(ordering: .acquiring) == tokenSequence {
            m.expectedSeq.store(0, ordering: .releasing)
            m.consumedSeq.store(0, ordering: .relaxed)
            m.playedBackSeq.store(0, ordering: .relaxed)
        }
        if m.outstanding.exchange(false, ordering: .acquiringAndReleasing) {
            activeOutstandingCount.wrappingSubtract(1, ordering: .acquiringAndReleasing)
        }
    }

    /// Minimal AVFoundation callback sink: strictly wait-free atomics only.
    /// Zero allocations, zero locks, zero Tasks, zero actor hops, zero logging, zero blocking.
    @inline(__always)
    func recordCompletion(
        slotIndex: Int,
        tokenSequence: UInt64,
        callbackType: AVAudioPlayerNodeCompletionCallbackType
    ) {
        guard slotIndex >= 0, slotIndex < slotCount, tokenSequence != 0 else {
            staleCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let m = mailboxes[slotIndex]
        let expected = m.expectedSeq.load(ordering: .acquiring)
        guard expected == tokenSequence else {
            staleCount.wrappingAdd(1, ordering: .relaxed)
            return
        }

        switch callbackType {
        case .dataConsumed:
            let (exchanged, _) = m.consumedSeq.compareExchange(
                expected: 0,
                desired: tokenSequence,
                ordering: .acquiringAndReleasing
            )
            if !exchanged {
                duplicateCount.wrappingAdd(1, ordering: .relaxed)
                return
            }
        case .dataPlayedBack, .dataRendered:
            let (exchanged, _) = m.playedBackSeq.compareExchange(
                expected: 0,
                desired: tokenSequence,
                ordering: .acquiringAndReleasing
            )
            if !exchanged {
                duplicateCount.wrappingAdd(1, ordering: .relaxed)
                return
            }
            if callbackType == .dataPlayedBack {
                _ = m.consumedSeq.compareExchange(
                    expected: 0,
                    desired: tokenSequence,
                    ordering: .acquiringAndReleasing
                )
            }
        @unknown default:
            let (exchanged, _) = m.consumedSeq.compareExchange(
                expected: 0,
                desired: tokenSequence,
                ordering: .acquiringAndReleasing
            )
            if !exchanged {
                duplicateCount.wrappingAdd(1, ordering: .relaxed)
                return
            }
        }

        if m.outstanding.exchange(false, ordering: .acquiringAndReleasing) {
            activeOutstandingCount.wrappingSubtract(1, ordering: .acquiringAndReleasing)
        }
    }

    func pollSlot(_ slotIndex: Int, expectedSequence: UInt64) -> (consumed: Bool, playedBack: Bool) {
        guard slotIndex >= 0, slotIndex < slotCount, expectedSequence != 0 else {
            return (false, false)
        }
        let m = mailboxes[slotIndex]
        let consumed = m.consumedSeq.load(ordering: .acquiring) == expectedSequence
        let playedBack = m.playedBackSeq.load(ordering: .acquiring) == expectedSequence
        return (consumed, playedBack)
    }

    func markRetired() {
        retired.store(true, ordering: .releasing)
    }

    var isRetired: Bool {
        retired.load(ordering: .acquiring)
    }

    var outstandingCallbackCount: Int {
        max(0, activeOutstandingCount.load(ordering: .acquiring))
    }

    var staleCallbackCount: Int {
        staleCount.load(ordering: .relaxed)
    }

    var duplicateCallbackCount: Int {
        duplicateCount.load(ordering: .relaxed)
    }
}

// MARK: - Bounded Slot State Machine & Pool

enum EditorPCMSlotState: Equatable, Sendable {
    case free
    case writing
    case ready
    case scheduled
    case consumed
    case playedBack
    case quarantined
}

struct EditorPCMBlockMetadata: Equatable, Sendable {
    let epoch: UInt64
    let revision: UInt64
    let timelineStartFrame: Int64
    let frameCount: Int
    let isEndOfStream: Bool
    let peakL: Float
    let peakR: Float
    let gainReductionDB: Float
}

struct EditorScheduledSlotInfo: @unchecked Sendable {
    let slotIndex: Int
    let token: EditorBufferToken
    let metadata: EditorPCMBlockMetadata
    let callbackType: AVAudioPlayerNodeCompletionCallbackType
    let buffer: AVAudioPCMBuffer
}

enum EditorBufferPoolError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedAudioFormat(Double, Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioFormat(let rate, let channels):
            return "Unable to allocate AVAudioPCMBuffer pool for \(rate) Hz / \(channels) ch."
        }
    }
}

final class EditorPCMBufferPool: @unchecked Sendable {
    private struct SlotRecord: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var state: EditorPCMSlotState = .free
        var metadata: EditorPCMBlockMetadata?
        var token: EditorBufferToken?
    }

    private struct PoolState: @unchecked Sendable {
        var slots: [SlotRecord]
        var readyQueue: [Int] = []
        var tokenGenerator: EditorTokenGenerator
        var isRetired: Bool = false
    }

    let config: EditorPCMPoolConfig
    let epoch: UInt64
    let format: AVAudioFormat
    let callbackContext: EditorCallbackContext
    private let stateLock: OSAllocatedUnfairLock<PoolState>

    init(
        config: EditorPCMPoolConfig = EditorPCMPoolConfig(),
        epoch: UInt64,
        startingSequence: UInt64 = 1
    ) throws {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: AVAudioChannelCount(config.channelCount),
            interleaved: false
        ) else {
            throw EditorBufferPoolError.unsupportedAudioFormat(config.sampleRate, config.channelCount)
        }

        var buffers: [AVAudioPCMBuffer] = []
        buffers.reserveCapacity(config.slotCount)
        var slots: [SlotRecord] = []
        slots.reserveCapacity(config.slotCount)

        for _ in 0..<config.slotCount {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(config.framesPerSlot)) else {
                throw EditorBufferPoolError.unsupportedAudioFormat(config.sampleRate, config.channelCount)
            }
            buf.frameLength = 0
            buffers.append(buf)
            slots.append(SlotRecord(buffer: buf))
        }

        self.config = config
        self.epoch = epoch
        self.format = fmt
        self.callbackContext = EditorCallbackContext(epoch: epoch, buffers: buffers)
        self.stateLock = OSAllocatedUnfairLock(initialState: PoolState(
            slots: slots,
            readyQueue: [],
            tokenGenerator: EditorTokenGenerator(startingSequence: startingSequence),
            isRetired: false
        ))
    }

    var isRetired: Bool {
        callbackContext.isRetired
    }

    var outstandingCallbackCount: Int {
        callbackContext.outstandingCallbackCount
    }

    var pcmPayloadBytes: Int {
        config.poolPCMPayloadBytes
    }

    var slotStates: [EditorPCMSlotState] {
        stateLock.withLock { $0.slots.map(\.state) }
    }

    var freeSlotCount: Int {
        stateLock.withLock { $0.slots.filter { $0.state == .free }.count }
    }

    var readySlotCount: Int {
        stateLock.withLock { $0.slots.filter { $0.state == .ready }.count }
    }

    var scheduledSlotCount: Int {
        stateLock.withLock { $0.slots.filter { $0.state == .scheduled }.count }
    }

    var quarantinedSlotCount: Int {
        stateLock.withLock { $0.slots.filter { $0.state == .quarantined }.count }
    }

    func acquireFreeSlotForWrite(epoch: UInt64) -> Int? {
        guard epoch == self.epoch else { return nil }
        return stateLock.withLock { state in
            guard !state.isRetired else { return nil }
            guard let idx = state.slots.firstIndex(where: { $0.state == .free }) else {
                return nil
            }
            state.slots[idx].state = .writing
            state.slots[idx].metadata = nil
            state.slots[idx].token = nil
            state.slots[idx].buffer.frameLength = 0
            return idx
        }
    }

    /// Atomically copies PCM from the producer's transfer buffer and transitions `.writing -> .ready`.
    /// Partial or stale-epoch writes are rejected and never become `.ready`.
    @discardableResult
    func copyAndPublishReady(
        slotIndex: Int,
        from transfer: EditorPCMTransferBuffer,
        metadata: EditorPCMBlockMetadata
    ) -> Bool {
        stateLock.withLock { state in
            guard slotIndex >= 0, slotIndex < state.slots.count else { return false }
            guard !state.isRetired,
                  metadata.epoch == self.epoch,
                  state.slots[slotIndex].state == .writing,
                  metadata.frameCount > 0,
                  metadata.frameCount <= config.framesPerSlot,
                  metadata.frameCount <= transfer.capacity else {
                return false
            }

            let buf = state.slots[slotIndex].buffer
            guard let chData = buf.floatChannelData else { return false }
            let n = metadata.frameCount
            chData[0].update(from: transfer.left, count: n)
            if config.channelCount > 1 {
                chData[1].update(from: transfer.right, count: n)
            }
            buf.frameLength = AVAudioFrameCount(n)
            state.slots[slotIndex].metadata = metadata
            state.slots[slotIndex].state = .ready
            state.readyQueue.append(slotIndex)
            return true
        }
    }

    func abortWrite(slotIndex: Int) {
        stateLock.withLock { state in
            guard slotIndex >= 0, slotIndex < state.slots.count else { return }
            guard state.slots[slotIndex].state == .writing else { return }
            state.slots[slotIndex].metadata = nil
            state.slots[slotIndex].token = nil
            state.slots[slotIndex].buffer.frameLength = 0
            state.slots[slotIndex].state = .free
        }
    }

    @discardableResult
    func discardUnscheduledReadySlots(olderThanRevision minRevision: UInt64) -> Int {
        stateLock.withLock { state in
            var discarded = 0
            var keptQueue: [Int] = []
            keptQueue.reserveCapacity(state.readyQueue.count)

            for idx in state.readyQueue {
                guard state.slots[idx].state == .ready else { continue }
                if let meta = state.slots[idx].metadata,
                   meta.epoch == self.epoch,
                   meta.revision >= minRevision {
                    keptQueue.append(idx)
                } else {
                    state.slots[idx].metadata = nil
                    state.slots[idx].token = nil
                    state.slots[idx].buffer.frameLength = 0
                    state.slots[idx].state = .free
                    discarded += 1
                }
            }

            state.readyQueue = keptQueue
            return discarded
        }
    }

    /// Marks the next valid `.ready` slot as `.scheduled` and arms its lock-free callback mailbox
    /// BEFORE submitting the buffer to `AVAudioPlayerNode`.
    func beginSchedulingNextReady(expectedEpoch: UInt64, minRevision: UInt64) throws -> EditorScheduledSlotInfo? {
        guard expectedEpoch == self.epoch else { return nil }
        return try stateLock.withLock { state in
            guard !state.isRetired else { return nil }
            while !state.readyQueue.isEmpty {
                let idx = state.readyQueue.removeFirst()
                guard state.slots[idx].state == .ready,
                      let meta = state.slots[idx].metadata else {
                    continue
                }
                guard meta.epoch == expectedEpoch, meta.revision >= minRevision else {
                    state.slots[idx].metadata = nil
                    state.slots[idx].token = nil
                    state.slots[idx].buffer.frameLength = 0
                    state.slots[idx].state = .free
                    continue
                }

                let token = try state.tokenGenerator.issue(epoch: expectedEpoch, slotIndex: idx)
                let cbType: AVAudioPlayerNodeCompletionCallbackType = meta.isEndOfStream ? .dataPlayedBack : .dataConsumed
                state.slots[idx].token = token
                state.slots[idx].state = .scheduled
                callbackContext.armSlot(idx, tokenSequence: token.sequence)

                return EditorScheduledSlotInfo(
                    slotIndex: idx,
                    token: token,
                    metadata: meta,
                    callbackType: cbType,
                    buffer: state.slots[idx].buffer
                )
            }
            return nil
        }
    }

    func rollbackScheduledSlotOnFailure(slotIndex: Int, token: EditorBufferToken, wasSubmittedToAudioNode: Bool) {
        stateLock.withLock { state in
            guard slotIndex >= 0, slotIndex < state.slots.count else { return }
            guard state.slots[slotIndex].token == token else { return }
            if wasSubmittedToAudioNode || state.isRetired {
                state.slots[slotIndex].state = .quarantined
            } else {
                callbackContext.disarmSlotOnPreSubmitFailure(slotIndex, tokenSequence: token.sequence)
                state.slots[slotIndex].metadata = nil
                state.slots[slotIndex].token = nil
                state.slots[slotIndex].buffer.frameLength = 0
                state.slots[slotIndex].state = .free
            }
        }
    }

    func pollAndReclaimCompletedSlots() -> (
        reclaimedTokens: [EditorBufferToken],
        playedBackBlocks: [(token: EditorBufferToken, metadata: EditorPCMBlockMetadata)]
    ) {
        stateLock.withLock { state in
            var reclaimed: [EditorBufferToken] = []
            var playedBack: [(token: EditorBufferToken, metadata: EditorPCMBlockMetadata)] = []

            for idx in state.slots.indices {
                let slotState = state.slots[idx].state
                guard slotState == .scheduled || slotState == .quarantined,
                      let token = state.slots[idx].token else {
                    continue
                }
                let meta = state.slots[idx].metadata
                let polled = callbackContext.pollSlot(idx, expectedSequence: token.sequence)

                if polled.playedBack, let meta {
                    playedBack.append((token, meta))
                }

                if polled.consumed || polled.playedBack {
                    state.slots[idx].metadata = nil
                    state.slots[idx].token = nil
                    state.slots[idx].buffer.frameLength = 0
                    if !state.isRetired && slotState == .scheduled {
                        // Record intermediate transition semantics before freeing for next producer write.
                        state.slots[idx].state = polled.playedBack ? .playedBack : .consumed
                        state.slots[idx].state = .free
                    } else {
                        // Quarantined or retired slots never re-enter active production.
                        state.slots[idx].state = polled.playedBack ? .playedBack : .consumed
                    }
                    reclaimed.append(token)
                }
            }
            return (reclaimed, playedBack)
        }
    }

    func retireAndQuarantineOutstanding() {
        callbackContext.markRetired()
        stateLock.withLock { state in
            state.isRetired = true
            state.readyQueue.removeAll()
            for idx in state.slots.indices {
                switch state.slots[idx].state {
                case .free, .consumed, .playedBack:
                    break
                case .writing, .ready:
                    state.slots[idx].metadata = nil
                    state.slots[idx].token = nil
                    state.slots[idx].buffer.frameLength = 0
                    state.slots[idx].state = .free
                case .scheduled, .quarantined:
                    state.slots[idx].state = .quarantined
                }
            }
        }
    }
}

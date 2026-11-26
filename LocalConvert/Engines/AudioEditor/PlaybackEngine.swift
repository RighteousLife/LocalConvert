import Foundation
import AVFoundation
import os
import Synchronization

/// A per-render-generation admission gate. Closing the gate is permanent; a new playback
/// generation gets a new gate and ring buffer. The callback only performs bounded atomic
/// operations and never waits for control code.
final class AudioRenderCallbackGate: @unchecked Sendable {
    private let closed: Atomic<Bool>
    private let activeCallback = Atomic<Bool>(false)

    init(closed: Bool = false) {
        self.closed = Atomic<Bool>(closed)
    }

    /// A callback that races with close either registers before close and is counted, or
    /// observes close on the second check and is rejected before touching ring storage.
    @inline(__always)
    func enter() -> Bool {
        guard !closed.load(ordering: .sequentiallyConsistent) else { return false }
        guard !activeCallback.exchange(true, ordering: .sequentiallyConsistent) else { return false }
        guard !closed.load(ordering: .sequentiallyConsistent) else {
            activeCallback.store(false, ordering: .sequentiallyConsistent)
            return false
        }
        return true
    }

    @inline(__always)
    func leave() {
        activeCallback.store(false, ordering: .sequentiallyConsistent)
    }

    func close() {
        closed.store(true, ordering: .sequentiallyConsistent)
    }

    var isQuiescent: Bool {
        !activeCallback.load(ordering: .sequentiallyConsistent)
    }

    /// Control-side asynchronous retirement; no callback or thread is blocked while the
    /// last admitted render callback finishes its bounded buffer copy.
    func waitUntilQuiescent() async {
        while !isQuiescent {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

// MARK: - Wait-free single-producer / single-consumer PCM ring buffer with decoupled frame markers

final class AudioRingBuffer: @unchecked Sendable {
    private struct FrameMarker {
        var writtenFrame: Int64 = 0
        var timelineFrame: Int64 = 0
    }

    private struct MarkerState {
        var slots: [FrameMarker]
        var start: Int = 0
        var count: Int = 0
        var lastPassed: FrameMarker? = nil
    }

    private static let markerCapacity = 128

    let capacity: Int
    private let lStorage: UnsafeMutablePointer<Float>
    private let rStorage: UnsafeMutablePointer<Float>
    private let readIndex = Atomic<Int64>(0)
    private let writeIndex = Atomic<Int64>(0)
    private let finishedAtFrame = Atomic<Int64>(-1)
    private let markerLock: OSAllocatedUnfairLock<MarkerState>

    init(capacity: Int = 48_000) {
        let cap = max(256, capacity)
        self.capacity = cap
        self.lStorage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.rStorage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.lStorage.initialize(repeating: 0, count: cap)
        self.rStorage.initialize(repeating: 0, count: cap)
        self.markerLock = OSAllocatedUnfairLock(initialState: MarkerState(
            slots: [FrameMarker](repeating: FrameMarker(), count: Self.markerCapacity)
        ))
    }

    deinit {
        lStorage.deinitialize(count: capacity)
        rStorage.deinitialize(count: capacity)
        lStorage.deallocate()
        rStorage.deallocate()
    }

    var freeFrames: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        return max(0, capacity - Int(w &- r))
    }

    var availableFramesToRead: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        return max(0, Int(w &- r))
    }

    func markFinished() {
        let w = writeIndex.load(ordering: .acquiring)
        finishedAtFrame.store(w, ordering: .releasing)
    }

    /// Producer-only write path. Never blocks on the render thread and never overwrites unread frames.
    @discardableResult
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, timelineFrame: Int64) -> Int {
        guard count > 0 else { return 0 }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let avail = max(0, capacity - Int(w &- r))
        let toWrite = min(count, avail)
        guard toWrite > 0 else { return 0 }

        let writeOffset = Int(w % Int64(capacity))
        let firstPart = min(toWrite, capacity - writeOffset)
        let secondPart = toWrite - firstPart

        lStorage.advanced(by: writeOffset).update(from: left, count: firstPart)
        rStorage.advanced(by: writeOffset).update(from: right, count: firstPart)
        if secondPart > 0 {
            lStorage.update(from: left.advanced(by: firstPart), count: secondPart)
            rStorage.update(from: right.advanced(by: firstPart), count: secondPart)
        }

        let newMarker = FrameMarker(writtenFrame: w, timelineFrame: timelineFrame)
        markerLock.withLock { m in
            if m.count < Self.markerCapacity {
                let slot = (m.start + m.count) % Self.markerCapacity
                m.slots[slot] = newMarker
                m.count += 1
            } else {
                let evicted = m.slots[m.start]
                if evicted.writtenFrame <= r {
                    m.lastPassed = evicted
                }
                m.slots[m.start] = newMarker
                m.start = (m.start + 1) % Self.markerCapacity
            }
        }

        writeIndex.store(w &+ Int64(toWrite), ordering: .releasing)
        return toWrite
    }

    /// Convenience overload bridging time-based writes to integer timeline frames.
    @discardableResult
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, startTime: Double, sampleRate: Double = 48_000) -> Int {
        let frame = Int64((startTime * max(8_000.0, sampleRate)).rounded())
        return write(left: left, right: right, count: count, timelineFrame: frame)
    }

    /// Real-time consumer read path (`AVAudioSourceNode`). Wait-free: zero locks, zero heap allocations, deterministic underrun zero-fill.
    @discardableResult
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let avail = max(0, Int(w &- r))
        let n = min(avail, count)
        if n > 0 {
            let readOffset = Int(r % Int64(capacity))
            let firstPart = min(n, capacity - readOffset)
            let secondPart = n - firstPart
            left.update(from: lStorage.advanced(by: readOffset), count: firstPart)
            right.update(from: rStorage.advanced(by: readOffset), count: firstPart)
            if secondPart > 0 {
                left.advanced(by: firstPart).update(from: lStorage, count: secondPart)
                right.advanced(by: firstPart).update(from: rStorage, count: secondPart)
            }
            readIndex.store(r &+ Int64(n), ordering: .releasing)
        }
        if n < count {
            left.advanced(by: n).update(repeating: 0, count: count - n)
            right.advanced(by: n).update(repeating: 0, count: count - n)
        }
        return n
    }

    /// Exact integer timeline sample frame corresponding to the sample currently at the output.
    /// Contends only with producer marker writes via `markerLock`; never blocks the render thread.
    func playbackTimelineFrame() -> (frame: Int64?, drained: Bool) {
        let r = readIndex.load(ordering: .acquiring)
        let finishTarget = finishedAtFrame.load(ordering: .acquiring)
        let drained = finishTarget >= 0 && r >= finishTarget

        return markerLock.withLock { m in
            var matched: FrameMarker? = nil
            if m.count > 0 {
                for offset in stride(from: m.count - 1, through: 0, by: -1) {
                    let idx = (m.start + offset) % Self.markerCapacity
                    let candidate = m.slots[idx]
                    if candidate.writtenFrame <= r {
                        matched = candidate
                        break
                    }
                }
            }
            if matched == nil {
                matched = m.lastPassed
            }
            guard let marker = matched else {
                return (nil, drained)
            }
            let timelineFrame = marker.timelineFrame + (r - marker.writtenFrame)
            return (timelineFrame, drained)
        }
    }

    func playbackPosition(sampleRate: SampleRate) -> (position: SampleFrameTime?, drained: Bool) {
        let (frame, drained) = playbackTimelineFrame()
        return (frame.map { SampleFrameTime(frame: $0, sampleRate: sampleRate) }, drained)
    }

    /// Derived timeline seconds corresponding to the sample currently at the output, plus drained state.
    func playbackPosition(sampleRate: Double) -> (time: Double?, drained: Bool) {
        let (frame, drained) = playbackTimelineFrame()
        let time = frame.map { Double($0) / max(1.0, sampleRate) }
        return (time, drained)
    }
}

/// Immutable ownership unit for one playback run. Its ring indices and storage are never
/// reset or reused. Old source-node callbacks and producers retain this context until they
/// finish, while its closed gate rejects every callback that arrives after retirement.
final class AudioRenderGeneration: @unchecked Sendable {
    let ring: AudioRingBuffer
    let callbackGate: AudioRenderCallbackGate

    init(ring: AudioRingBuffer = AudioRingBuffer(capacity: 48_000), callbackGate: AudioRenderCallbackGate = AudioRenderCallbackGate()) {
        self.ring = ring
        self.callbackGate = callbackGate
    }

    @inline(__always)
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        guard callbackGate.enter() else {
            left.update(repeating: 0, count: count)
            right.update(repeating: 0, count: count)
            return
        }
        defer { callbackGate.leave() }
        ring.read(left: left, right: right, count: count)
    }
}

private final class MixSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: AudioMixSession?
    func set(_ s: AudioMixSession?) { lock.lock(); session = s; lock.unlock() }
    func with<T>(_ body: (AudioMixSession) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let s = session else { return nil }
        return body(s)
    }
}

private final class GenerationCounter: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func bump() -> Int { value.withLock { $0 += 1; return $0 } }
    var current: Int { value.withLock { $0 } }
}

private final class LoopConfigBox: @unchecked Sendable {
    struct Config: Sendable {
        var frameRange: SampleFrameRange?
        var timeRange: ClosedRange<TimeInterval>?
        var enabled: Bool
    }

    private let state = OSAllocatedUnfairLock<Config>(initialState: Config(frameRange: nil, timeRange: nil, enabled: false))

    func set(range: ClosedRange<TimeInterval>?, enabled: Bool) {
        state.withLock { $0 = Config(frameRange: nil, timeRange: range, enabled: enabled && range != nil) }
    }

    func set(frameRange: SampleFrameRange?, enabled: Bool) {
        let tRange = frameRange.map {
            SampleFrameMigration.framesToSeconds($0.startFrame, sampleRate: $0.sampleRate)...SampleFrameMigration.framesToSeconds($0.endFrame, sampleRate: $0.sampleRate)
        }
        state.withLock { $0 = Config(frameRange: frameRange, timeRange: tRange, enabled: enabled && frameRange != nil) }
    }

    func resolvedFrameBounds(for rate: SampleRate) -> (startFrame: Int64, endFrame: Int64)? {
        let cfg = state.withLock { $0 }
        guard cfg.enabled else { return nil }
        if let fr = cfg.frameRange {
            let aligned = (try? fr.converted(to: rate)) ?? fr
            guard aligned.frameCount > 0 else { return nil }
            return (aligned.startFrame, aligned.endFrame)
        }
        if let tr = cfg.timeRange {
            let start = (try? SampleFrameMigration.secondsToFrames(tr.lowerBound, sampleRate: rate, field: "loop.start")) ?? 0
            let end = (try? SampleFrameMigration.secondsToFrames(tr.upperBound, sampleRate: rate, field: "loop.end")) ?? 0
            guard end > start else { return nil }
            return (start, end)
        }
        return nil
    }
}

enum EditorPlaybackBackendMode: String, Sendable {
    case playerNodePool
    case sourceNodeFallback
}

// MARK: - Playback engine

@MainActor
final class AudioPlaybackEngine: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isPreparing = false
    @Published private(set) var playheadTime: TimeInterval = 0
    @Published private(set) var playheadFrame: Int64 = 0
    @Published private(set) var meterL: Float = 0
    @Published private(set) var meterR: Float = 0
    @Published private(set) var gainReductionDB: Float = 0
    @Published var lastError: String?

    /// Called (main actor) when playhead advances due to playback.
    var onPlayheadChanged: ((TimeInterval) -> Void)?
    var onPlayheadFrameChanged: ((SampleFrameTime) -> Void)?

    let backendMode: EditorPlaybackBackendMode
    let scheduler: EditorPCMPlaybackScheduler?

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var renderGeneration: AudioRenderGeneration?
    private var retiredRenderGenerations: [AudioRenderGeneration] = []
    private let box = MixSessionBox()
    private let generation = GenerationCounter()
    private let loopBox = LoopConfigBox()
    private var producer: Task<Void, Never>?
    private var drainingProducers: [Task<Void, Never>] = []
    private var producerDrainTask: Task<Void, Never>?
    nonisolated(unsafe) private var displayTimer: Timer?
    private var preparedProject: AudioEditorProject?
    private var autoStopAtFrame: Int64?
    private var currentProjectDurationFrames: Int64 = 0
    private var sessionSampleRate: SampleRate = .rate48k
    private var sessionRate: Double { Double(sessionSampleRate.hz) }
    private var refreshTask: Task<Void, Never>?
    private var prepareTask: Task<Bool, Never>?
    private var lastScrubTimestamp: CFAbsoluteTime = 0
    private var pendingScrubTask: Task<Void, Never>?
    private let scrubThrottleSeconds: TimeInterval = 0.05
    private let arbitrationCenter: PlaybackArbitrationCenter
    private let arbitrationCleanupLock: OSAllocatedUnfairLock<(center: PlaybackArbitrationCenter, token: PlaybackArbitrationRegistrationToken?, renderGeneration: AudioRenderGeneration?)>

    var currentTimelinePosition: SampleFrameTime {
        SampleFrameTime(frame: playheadFrame, sampleRate: sessionSampleRate)
    }

    init(
        arbitrationCenter: PlaybackArbitrationCenter = .shared,
        backendMode: EditorPlaybackBackendMode = .playerNodePool,
        scheduler: EditorPCMPlaybackScheduler? = nil
    ) {
        self.arbitrationCenter = arbitrationCenter
        self.backendMode = backendMode
        if let scheduler {
            self.scheduler = scheduler
        } else if backendMode == .playerNodePool {
            self.scheduler = EditorPCMPlaybackScheduler()
        } else {
            self.scheduler = nil
        }
        self.arbitrationCleanupLock = OSAllocatedUnfairLock(initialState: (center: arbitrationCenter, token: nil, renderGeneration: nil))
        let token = arbitrationCenter.registerClient(.audioEditor) { [weak self] in
            self?.pause()
        }
        self.arbitrationCleanupLock.withLock { $0.token = token }
        self.scheduler?.onStateUpdated = { [weak self] snapshot in
            self?.applySchedulerSnapshot(snapshot)
        }
    }

    deinit {
        displayTimer?.invalidate()
        let cleanup = arbitrationCleanupLock.withLock { state -> (center: PlaybackArbitrationCenter, token: PlaybackArbitrationRegistrationToken?, renderGeneration: AudioRenderGeneration?) in
            let copy = state
            state.token = nil
            state.renderGeneration = nil
            return copy
        }
        cleanup.renderGeneration?.callbackGate.close()
        if let retiredGeneration = cleanup.renderGeneration {
            Task.detached {
                await retiredGeneration.callbackGate.waitUntilQuiescent()
            }
        }
        if let token = cleanup.token {
            let center = cleanup.center
            Task { @MainActor in
                center.unregisterClient(token)
            }
        }
    }

    private func applySchedulerSnapshot(_ snapshot: EditorSchedulerSnapshot) {
        let prevFrame = playheadFrame
        sessionSampleRate = snapshot.sampleRate
        isPlaying = snapshot.isPlaying
        isPaused = snapshot.isPaused
        isPreparing = snapshot.isPreparing
        playheadFrame = snapshot.playheadFrame
        playheadTime = snapshot.playheadTime
        meterL = snapshot.meterL
        meterR = snapshot.meterR
        gainReductionDB = snapshot.gainReductionDB
        lastError = snapshot.lastError

        if snapshot.isPlaying && snapshot.playheadFrame != prevFrame {
            onPlayheadChanged?(snapshot.playheadTime)
            onPlayheadFrameChanged?(SampleFrameTime(frame: snapshot.playheadFrame, sampleRate: snapshot.sampleRate))
        }
    }

    func unregisterFromArbitration() {
        let token = arbitrationCleanupLock.withLock { state -> PlaybackArbitrationRegistrationToken? in
            let copy = state.token
            state.token = nil
            return copy
        }
        if let token {
            arbitrationCenter.unregisterClient(token)
        }
    }

    // MARK: Control

    func setLoop(range: ClosedRange<TimeInterval>?, enabled: Bool) {
        if let scheduler, backendMode == .playerNodePool {
            scheduler.setLoop(range: range, enabled: enabled)
            return
        }
        loopBox.set(range: range, enabled: enabled && range != nil)
    }

    func setLoop(frameRange: SampleFrameRange?, enabled: Bool) {
        if let scheduler, backendMode == .playerNodePool {
            scheduler.setLoop(frameRange: frameRange, enabled: enabled)
            return
        }
        loopBox.set(frameRange: frameRange, enabled: enabled && frameRange != nil)
    }

    func play(from time: TimeInterval, project: AudioEditorProject, autoStopAfter: TimeInterval? = nil) {
        let pRate = project.projectSampleRate
        let startFrame = (try? SampleFrameMigration.secondsToFrames(max(0, time), sampleRate: pRate, field: "play.from")) ?? 0
        let stopFrames = autoStopAfter.flatMap {
            try? SampleFrameMigration.secondsToFrames(max(0, $0), sampleRate: pRate, field: "play.autoStopAfter")
        }
        play(fromFrame: startFrame, project: project, autoStopAfterFrames: stopFrames)
    }

    func play(fromFrame startFrame: Int64, project: AudioEditorProject, autoStopAfterFrames: Int64? = nil) {
        arbitrationCenter.notifyPlaybackStarted(by: .audioEditor)
        lastError = nil
        if let scheduler, backendMode == .playerNodePool {
            pendingScrubTask?.cancel()
            pendingScrubTask = nil
            preparedProject = project
            scheduler.play(fromFrame: startFrame, project: project, autoStopAfterFrames: autoStopAfterFrames)
            return
        }

        let pRate = project.projectSampleRate
        let clampedStart = max(0, startFrame)
        sessionSampleRate = pRate
        currentProjectDurationFrames = Self.projectDurationFrames(project)
        autoStopAtFrame = autoStopAfterFrames.map { clampedStart + max(0, $0) }
        playheadFrame = clampedStart
        playheadTime = SampleFrameMigration.framesToSeconds(clampedStart, sampleRate: pRate)
        let gen = generation.bump()
        retireCurrentRenderGeneration()
        isPlaying = false
        isPaused = false
        prepareTask?.cancel()
        cancelCurrentProducer()
        isPreparing = true
        prepareTask = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                if self.preparedProject != project || self.box.with({ _ in true }) == nil {
                    let sources = try await AudioSourceResolver.resolve(project: project)
                    guard gen == self.generation.current else { return false }
                    let s = AudioMixSession(project: project, sources: sources)
                    self.box.set(s)
                    self.preparedProject = project
                }
                guard gen == self.generation.current else { return false }
                self.isPreparing = false
                try await self.beginStreaming(fromFrame: clampedStart, generation: gen, rate: project.sampleRate, projectRate: pRate)
                return true
            } catch is CancellationError {
                return false
            } catch {
                if gen == self.generation.current {
                    self.isPreparing = false
                    self.lastError = error.localizedDescription
                    self.isPlaying = false
                }
                return false
            }
        }
    }

    func resume(project: AudioEditorProject) {
        arbitrationCenter.notifyPlaybackStarted(by: .audioEditor)
        lastError = nil
        if let scheduler, backendMode == .playerNodePool {
            preparedProject = project
            scheduler.resume(project: project)
            return
        }
        play(fromFrame: playheadFrame, project: project, autoStopAfterFrames: nil)
    }

    func seek(to time: TimeInterval, project: AudioEditorProject) {
        let frame = (try? SampleFrameMigration.secondsToFrames(max(0, time), sampleRate: project.projectSampleRate, field: "seek.to")) ?? 0
        seek(toFrame: frame, project: project)
    }

    func seek(toFrame frame: Int64, project: AudioEditorProject) {
        pendingScrubTask?.cancel()
        pendingScrubTask = nil
        if let scheduler, backendMode == .playerNodePool {
            preparedProject = project
            scheduler.seek(toFrame: frame, project: project)
            return
        }

        let clamped = max(0, frame)
        sessionSampleRate = project.projectSampleRate
        playheadFrame = clamped
        playheadTime = SampleFrameMigration.framesToSeconds(clamped, sampleRate: project.projectSampleRate)
        if isPlaying || isPreparing {
            play(fromFrame: clamped, project: project, autoStopAfterFrames: nil)
        }
    }

    /// Short audible burst for scrubbing while the playhead is dragged (throttled to coalesce drag bursts).
    func scrub(to time: TimeInterval, project: AudioEditorProject) {
        let pRate = project.projectSampleRate
        let targetFrame = (try? SampleFrameMigration.secondsToFrames(max(0, time), sampleRate: pRate, field: "scrub.to")) ?? 0
        let burstFrames = Int64((0.12 * Double(pRate.hz)).rounded())
        sessionSampleRate = pRate
        playheadFrame = targetFrame
        playheadTime = time
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastScrubTimestamp
        if elapsed >= scrubThrottleSeconds {
            lastScrubTimestamp = now
            pendingScrubTask?.cancel()
            pendingScrubTask = nil
            play(fromFrame: targetFrame, project: project, autoStopAfterFrames: burstFrames)
        } else {
            let waitNs = UInt64(max(1_000_000, (scrubThrottleSeconds - elapsed) * 1_000_000_000))
            pendingScrubTask?.cancel()
            pendingScrubTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: waitNs)
                guard let self, !Task.isCancelled else { return }
                self.lastScrubTimestamp = CFAbsoluteTimeGetCurrent()
                self.play(fromFrame: targetFrame, project: project, autoStopAfterFrames: burstFrames)
            }
        }
    }

    func pause() {
        pendingScrubTask?.cancel()
        pendingScrubTask = nil
        if let scheduler, backendMode == .playerNodePool {
            scheduler.pause()
            return
        }
        halt(markPaused: true)
    }

    func stop() {
        pendingScrubTask?.cancel()
        pendingScrubTask = nil
        if let scheduler, backendMode == .playerNodePool {
            scheduler.stop()
            return
        }
        halt(markPaused: false)
    }

    func shutdown() {
        pendingScrubTask?.cancel()
        pendingScrubTask = nil
        if let scheduler, backendMode == .playerNodePool {
            scheduler.shutdown()
            return
        }
        halt(markPaused: false)
    }

    private func halt(markPaused: Bool = false) {
        let stopGen = generation.bump()
        pendingScrubTask?.cancel()
        pendingScrubTask = nil
        prepareTask?.cancel()
        retireCurrentRenderGeneration()
        cancelCurrentProducer()
        isPreparing = false
        isPlaying = false
        isPaused = markPaused
        displayTimer?.invalidate()
        displayTimer = nil
        meterL = 0; meterR = 0; gainReductionDB = 0

        if !drainingProducers.isEmpty {
            Task { @MainActor [weak self] in
                await self?.drainProducersIfQuiescent(expectedGeneration: stopGen)
            }
        }
    }

    private func cancelCurrentProducer() {
        guard let activeProducer = producer else { return }
        activeProducer.cancel()
        drainingProducers.append(activeProducer)
        producer = nil
    }

    private func retireCurrentRenderGeneration() {
        if let current = renderGeneration {
            current.callbackGate.close()
            renderGeneration = nil
            retiredRenderGenerations.append(current)
            arbitrationCleanupLock.withLock { $0.renderGeneration = nil }
            Task { @MainActor [weak self] in
                await current.callbackGate.waitUntilQuiescent()
                self?.retiredRenderGenerations.removeAll { $0 === current }
            }
        }
        if engine.isRunning { engine.pause() }
    }

    private func drainProducersIfQuiescent(expectedGeneration: Int?) async {
        if let activeDrain = producerDrainTask {
            await activeDrain.value
        } else if !drainingProducers.isEmpty {
            let drain = Task { @MainActor [weak self] in
                guard let self else { return }
                while !self.drainingProducers.isEmpty {
                    let batch = self.drainingProducers
                    self.drainingProducers.removeAll()
                    for task in batch {
                        task.cancel()
                        await task.value
                    }
                }
                self.producerDrainTask = nil
            }
            producerDrainTask = drain
            await drain.value
        }
        if let expectedGeneration, generation.current != expectedGeneration {
            return
        }
    }

    /// Push project edits to a running session (mute/solo/volume/pan/gain take effect within ~1 s of buffered audio).
    func projectDidChange(_ project: AudioEditorProject) {
        if let scheduler, backendMode == .playerNodePool {
            preparedProject = project
            scheduler.projectDidChange(project)
            return
        }
        guard isPlaying || preparedProject != nil else { return }
        sessionSampleRate = project.projectSampleRate
        currentProjectDurationFrames = Self.projectDurationFrames(project)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try await AudioSourceResolver.resolve(project: project)
                self.box.with { $0.update(project: project, sources: sources) }
                self.preparedProject = project
            } catch {}
        }
    }

    private static func projectDurationFrames(_ project: AudioEditorProject) -> Int64 {
        let pRate = project.projectSampleRate
        var maxFrame: Int64 = 0
        for track in project.tracks {
            for clip in track.clips {
                let endFrame: Int64
                if clip.projectRate == pRate {
                    endFrame = clip.timelineEndFrame
                } else {
                    endFrame = (try? SampleFrameTime.convertInt128(Int128(clip.timelineEndFrame), from: clip.projectRate, to: pRate))
                        ?? clip.timelineEndFrame
                }
                if endFrame > maxFrame { maxFrame = endFrame }
            }
        }
        return maxFrame
    }

    // MARK: Engine plumbing

    private func startEngineIfNeeded(rate: Double, renderGeneration: AudioRenderGeneration) throws {
        if let node = sourceNode {
            engine.stop()
            engine.detach(node)
            sourceNode = nil
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false) else {
            throw ConversionError.invalidInput("Unsupported project sample rate \(rate)")
        }
        let node = Self.makeSourceNode(format: format, renderGeneration: renderGeneration)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        self.renderGeneration = renderGeneration
        arbitrationCleanupLock.withLock { $0.renderGeneration = renderGeneration }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                renderGeneration.callbackGate.close()
                self.renderGeneration = nil
                arbitrationCleanupLock.withLock { $0.renderGeneration = nil }
                engine.stop()
                engine.detach(node)
                sourceNode = nil
                throw error
            }
        }
    }

    private nonisolated static func makeSourceNode(format: AVAudioFormat, renderGeneration: AudioRenderGeneration) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            renderGeneration.render(left: l, right: r, count: Int(frameCount))
            return noErr
        }
    }

    private func beginStreaming(fromFrame startFrame: Int64, generation gen: Int, rate: Double, projectRate: SampleRate) async throws {
        retireCurrentRenderGeneration()
        cancelCurrentProducer()
        await drainProducersIfQuiescent(expectedGeneration: gen)
        guard generation.current == gen, !Task.isCancelled else { return }

        let renderGeneration = AudioRenderGeneration()
        box.with { $0.resetEffectStates() }
        try startEngineIfNeeded(rate: rate, renderGeneration: renderGeneration)
        guard generation.current == gen, !Task.isCancelled else {
            retireCurrentRenderGeneration()
            return
        }

        isPlaying = true
        playheadFrame = startFrame
        playheadTime = SampleFrameMigration.framesToSeconds(startFrame, sampleRate: projectRate)
        let box = self.box
        let counter = self.generation
        let loopBox = self.loopBox
        let tailFrames = Int64((Double(projectRate.hz) * 0.02).rounded())
        let endDurationFrames = currentProjectDurationFrames + tailFrames
        let stopAtFrame = autoStopAtFrame
        producer = Task.detached(priority: .userInitiated) {
            let chunk = 2048
            let left = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
            defer { left.deallocate(); right.deallocate() }
            var posFrame = startFrame
            while !Task.isCancelled, counter.current == gen {
                if renderGeneration.ring.freeFrames < chunk {
                    try? await Task.sleep(nanoseconds: 4_000_000)
                    continue
                }
                var n = chunk
                if let loopBounds = loopBox.resolvedFrameBounds(for: projectRate) {
                    if posFrame >= loopBounds.endFrame || posFrame < loopBounds.startFrame {
                        posFrame = loopBounds.startFrame
                    }
                    let remainingToEnd = loopBounds.endFrame - posFrame
                    n = Int(min(Int64(chunk), max(1, remainingToEnd)))
                } else if posFrame >= endDurationFrames || (stopAtFrame != nil && posFrame >= stopAtFrame!) {
                    if counter.current == gen && !Task.isCancelled {
                        renderGeneration.ring.markFinished()
                    }
                    return
                } else if let stopAt = stopAtFrame {
                    n = Int(min(Int64(chunk), max(1, stopAt - posFrame)))
                }
                let wrote: Bool = box.with { $0.mix(startFrame: posFrame, frameCount: n, left: left, right: right) } != nil
                if !wrote {
                    left.update(repeating: 0, count: n)
                    right.update(repeating: 0, count: n)
                }
                guard !Task.isCancelled, counter.current == gen else { return }
                renderGeneration.ring.write(left: left, right: right, count: n, timelineFrame: posFrame)
                posFrame += Int64(n)
            }
        }
        displayTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func tick() {
        guard isPlaying, let renderGeneration else { return }
        let (frame, drained) = renderGeneration.ring.playbackTimelineFrame()
        if let frame {
            playheadFrame = frame
            let t = SampleFrameMigration.framesToSeconds(frame, sampleRate: sessionSampleRate)
            playheadTime = t
            onPlayheadChanged?(t)
            onPlayheadFrameChanged?(SampleFrameTime(frame: frame, sampleRate: sessionSampleRate))
        }
        let peaks = box.with { s -> (Float, Float, Float) in
            let p = (s.peakL, s.peakR, s.gainReductionDB); s.resetPeaks(); return p
        } ?? (0, 0, 0)
        meterL = max(peaks.0, meterL * 0.85)
        meterR = max(peaks.1, meterR * 0.85)
        gainReductionDB = peaks.2
        if drained { halt() }
    }
}

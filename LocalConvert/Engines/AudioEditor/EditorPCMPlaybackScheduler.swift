import Foundation
import AVFoundation
import os

// MARK: - Semantic Project Diff Classification

enum AudioProjectEditClassification: Equatable, Sendable {
    case noAudioImpact
    case nonStructural
    case structural
}

enum AudioProjectChangeClassifier {
    static func classify(from old: AudioEditorProject, to new: AudioEditorProject) -> AudioProjectEditClassification {
        guard old != new else { return .noAudioImpact }

        if old.projectSampleRate != new.projectSampleRate { return .structural }
        if old.tracks.count != new.tracks.count { return .structural }
        if !effectSlotsStructurallyEqual(old.masterEffects, new.masterEffects) { return .structural }

        let oldAssetsByID = Dictionary(uniqueKeysWithValues: old.mediaAssets.map { ($0.id, $0) })
        let newAssetsByID = Dictionary(uniqueKeysWithValues: new.mediaAssets.map { ($0.id, $0) })

        for (ot, nt) in zip(old.tracks, new.tracks) {
            if ot.id != nt.id { return .structural }
            if ot.clips.count != nt.clips.count { return .structural }
            if !effectSlotsStructurallyEqual(ot.effectSlots, nt.effectSlots) { return .structural }

            for (oc, nc) in zip(ot.clips, nt.clips) {
                if oc.id != nc.id
                    || oc.sourceAssetID != nc.sourceAssetID
                    || oc.timelineStartFrame != nc.timelineStartFrame
                    || oc.sourceStartFrame != nc.sourceStartFrame
                    || oc.durationFrames != nc.durationFrames
                    || oc.projectRate != nc.projectRate
                    || oc.sourceRate != nc.sourceRate
                    || oc.isReversed != nc.isReversed
                    || oc.swapChannels != nc.swapChannels
                    || oc.channelMode != nc.channelMode
                    || oc.effects != nc.effects
                    || !effectSlotsStructurallyEqual(oc.effectSlots, nc.effectSlots) {
                    return .structural
                }
                if let assetID = nc.sourceAssetID {
                    let oldAsset = oldAssetsByID[assetID]
                    let newAsset = newAssetsByID[assetID]
                    if !mediaReferencesAudioEquivalent(oldAsset, newAsset) {
                        return .structural
                    }
                }
            }
        }

        // Check non-structural audible mix/parameter differences
        if old.masterEffects != new.masterEffects || old.trackGroups != new.trackGroups {
            return .nonStructural
        }

        for (ot, nt) in zip(old.tracks, new.tracks) {
            if abs(ot.volume - nt.volume) > 1e-9
                || abs(ot.pan - nt.pan) > 1e-9
                || ot.isMuted != nt.isMuted
                || ot.isSolo != nt.isSolo
                || ot.groupID != nt.groupID
                || ot.effectSlots != nt.effectSlots {
                return .nonStructural
            }
            for (oc, nc) in zip(ot.clips, nt.clips) {
                if abs(oc.gainDB - nc.gainDB) > 1e-9
                    || oc.isMuted != nc.isMuted
                    || oc.fadeInFrames != nc.fadeInFrames
                    || oc.fadeOutFrames != nc.fadeOutFrames
                    || oc.crossfadeCurve != nc.crossfadeCurve
                    || oc.effectSlots != nc.effectSlots {
                    return .nonStructural
                }
            }
        }

        return .noAudioImpact
    }

    private static func effectSlotsStructurallyEqual(_ lhs: [AudioEffectSlot], _ rhs: [AudioEffectSlot]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (l, r) in zip(lhs, rhs) {
            if l.id != r.id || l.kind != r.kind {
                return false
            }
        }
        return true
    }

    private static func mediaReferencesAudioEquivalent(_ lhs: AudioMediaReference?, _ rhs: AudioMediaReference?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let l), .some(let r)):
            return l.path == r.path
                && l.fileSize == r.fileSize
                && abs(l.modificationTime - r.modificationTime) < 1e-6
                && l.sampleRate == r.sampleRate
                && l.channels == r.channels
                && l.contentSHA256 == r.contentSHA256
                && l.durationFrames == r.durationFrames
        default:
            return false
        }
    }
}

// MARK: - Transport Abstraction (AVAudioPlayerNode)

enum EditorSchedulingError: Error, LocalizedError, Equatable, Sendable {
    case invalidFormat(Double)
    case engineNotConfigured
    case invalidBuffer
    case engineStartFailed(String)
    case scheduleFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let rate):
            return "Unsupported Audio Editor playback sample rate \(rate) Hz."
        case .engineNotConfigured:
            return "Audio Editor playback transport is not configured."
        case .invalidBuffer:
            return "Cannot schedule an empty or invalid PCM buffer."
        case .engineStartFailed(let reason):
            return "Audio engine failed to start: \(reason)"
        case .scheduleFailed(let reason):
            return "Audio buffer scheduling failed: \(reason)"
        }
    }
}

@MainActor
protocol EditorPlaybackTransport: AnyObject {
    var isEngineRunning: Bool { get }
    var isNodePlaying: Bool { get }
    var onConfigurationChange: (@MainActor () -> Void)? { get set }

    func configure(sampleRate: Double, channelCount: Int) throws
    func startEngine() throws
    func playNode()
    func pauseNode()
    func stopNode()
    func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer,
        callbackType: AVAudioPlayerNodeCompletionCallbackType,
        completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) throws
    func currentRenderedSampleTime() -> Int64?
}

@MainActor
final class AVAudioEditorPlayerTransport: EditorPlaybackTransport {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var configuredFormat: AVAudioFormat?
    private var isGraphConnected = false
    private let monitorTaskLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    var onConfigurationChange: (@MainActor () -> Void)?

    var isEngineRunning: Bool {
        engine.isRunning
    }

    var isNodePlaying: Bool {
        playerNode.isPlaying
    }

    init() {
        engine.attach(playerNode)
        let targetEngine = engine
        let task = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: targetEngine) {
                guard !Task.isCancelled else { break }
                self?.onConfigurationChange?()
            }
        }
        monitorTaskLock.withLock { $0 = task }
    }

    deinit {
        monitorTaskLock.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    func configure(sampleRate: Double, channelCount: Int) throws {
        let safeChannels = max(1, min(2, channelCount))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(safeChannels),
            interleaved: false
        ) else {
            throw EditorSchedulingError.invalidFormat(sampleRate)
        }

        if let existing = configuredFormat,
           isGraphConnected,
           abs(existing.sampleRate - format.sampleRate) < 0.5,
           existing.channelCount == format.channelCount {
            return
        }

        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        if isGraphConnected {
            engine.disconnectNodeOutput(playerNode)
            isGraphConnected = false
        }

        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        configuredFormat = format
        isGraphConnected = true
    }

    func startEngine() throws {
        guard isGraphConnected else {
            throw EditorSchedulingError.engineNotConfigured
        }
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw EditorSchedulingError.engineStartFailed(error.localizedDescription)
        }
    }

    func playNode() {
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func pauseNode() {
        if playerNode.isPlaying {
            playerNode.pause()
        }
    }

    func stopNode() {
        playerNode.stop()
    }

    func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer,
        callbackType: AVAudioPlayerNodeCompletionCallbackType,
        completion: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) throws {
        guard isGraphConnected else {
            throw EditorSchedulingError.engineNotConfigured
        }
        guard buffer.frameLength > 0 else {
            throw EditorSchedulingError.invalidBuffer
        }
        playerNode.scheduleBuffer(buffer, completionCallbackType: callbackType, completionHandler: completion)
    }

    func currentRenderedSampleTime() -> Int64? {
        guard let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }
        return max(0, playerTime.sampleTime)
    }
}

// MARK: - Scheduler Snapshot & State

enum EditorPlaybackState: Equatable, Sendable {
    case stopped
    case preparing
    case playing
    case paused
    case recovering
    case failed(String)
    case shutDown
}

struct EditorSchedulerSnapshot: Equatable, Sendable {
    let state: EditorPlaybackState
    let playheadFrame: Int64
    let sampleRate: SampleRate
    let meterL: Float
    let meterR: Float
    let gainReductionDB: Float
    let lastError: String?

    var isPlaying: Bool { state == .playing }
    var isPaused: Bool { state == .paused }
    var isPreparing: Bool { state == .preparing || state == .recovering }
    var playheadTime: TimeInterval {
        SampleFrameMigration.framesToSeconds(playheadFrame, sampleRate: sampleRate)
    }
}

// MARK: - Audio Editor Playback Scheduler

@MainActor
final class EditorPCMPlaybackScheduler {
    private struct ScheduledTimelineSegment: Sendable {
        let nodeSampleStart: Int64
        let frameCount: Int
        let timelineStartFrame: Int64
        let isEndOfStream: Bool
        let peakL: Float
        let peakR: Float
        let gainReductionDB: Float
        let token: EditorBufferToken
    }

    private struct LoopConfiguration: Equatable, Sendable {
        var frameRange: SampleFrameRange?
        var timeRange: ClosedRange<TimeInterval>?
        var enabled: Bool

        func resolvedFrameBounds(for rate: SampleRate) -> (startFrame: Int64, endFrame: Int64)? {
            guard enabled else { return nil }
            if let fr = frameRange {
                let aligned = (try? fr.converted(to: rate)) ?? fr
                guard aligned.frameCount > 0 else { return nil }
                return (aligned.startFrame, aligned.endFrame)
            }
            if let tr = timeRange {
                let start = (try? SampleFrameMigration.secondsToFrames(tr.lowerBound, sampleRate: rate, field: "loop.start")) ?? 0
                let end = (try? SampleFrameMigration.secondsToFrames(tr.upperBound, sampleRate: rate, field: "loop.end")) ?? 0
                guard end > start else { return nil }
                return (start, end)
            }
            return nil
        }
    }

    private nonisolated final class TeardownHandles: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<(
            monitor: Task<Void, Never>?,
            transition: Task<Void, Never>?,
            revision: Task<Void, Never>?,
            activePool: EditorPCMBufferPool?
        )>(initialState: (nil, nil, nil, nil))

        func update(
            monitor: Task<Void, Never>?,
            transition: Task<Void, Never>?,
            revision: Task<Void, Never>?,
            activePool: EditorPCMBufferPool?
        ) {
            lock.withLock {
                $0 = (monitor, transition, revision, activePool)
            }
        }

        func teardownNonisolated() {
            let snapshot = lock.withLock { state -> (
                monitor: Task<Void, Never>?,
                transition: Task<Void, Never>?,
                revision: Task<Void, Never>?,
                activePool: EditorPCMBufferPool?
            ) in
                let copy = state
                state = (nil, nil, nil, nil)
                return copy
            }
            snapshot.monitor?.cancel()
            snapshot.transition?.cancel()
            snapshot.revision?.cancel()
            snapshot.activePool?.retireAndQuarantineOutstanding()
        }
    }

    let transport: any EditorPlaybackTransport
    let producer: EditorPCMProducer
    private let poolConfigFactory: (Double) -> EditorPCMPoolConfig
    private let sourceResolver: @Sendable (AudioEditorProject) async throws -> [UUID: ResolvedClipSource]
    private let monitorInterval: Duration
    private let teardownHandles = TeardownHandles()

    private(set) var state: EditorPlaybackState = .stopped
    private(set) var epoch: UInt64 = 0
    private(set) var revision: UInt64 = 1
    private(set) var activePool: EditorPCMBufferPool?
    private(set) var retiredPools: [EditorPCMBufferPool] = []
    private(set) var activeMonitorLoopCount: Int = 0
    private(set) var monitorTickCount: Int = 0
    private(set) var displayedPlayheadFrame: Int64 = 0
    private(set) var sessionSampleRate: SampleRate = .rate48k
    private(set) var meterL: Float = 0
    private(set) var meterR: Float = 0
    private(set) var gainReductionDB: Float = 0
    private(set) var lastError: String?

    private var monitorTask: Task<Void, Never>?
    private var monitorLoopToken: UInt64 = 0
    private var transitionTask: Task<Void, Never>?
    private var transitionTaskToken: UInt64 = 0
    private var revisionTask: Task<Void, Never>?
    private var preparedProject: AudioEditorProject?
    private var resolvedSources: [UUID: ResolvedClipSource] = [:]
    private var loopConfig = LoopConfiguration(frameRange: nil, timeRange: nil, enabled: false)
    private var autoStopAtFrame: Int64?
    private var scheduledSegments: [ScheduledTimelineSegment] = []
    private var totalScheduledNodeFrames: Int64 = 0
    private var lastScheduledTimelineEndFrame: Int64 = 0
    private var eofScheduledToken: EditorBufferToken?
    private var eofPlayedBackConfirmed = false
    private var pausedNeedsRestart = false
    private var startingTokenSequenceForTesting: UInt64 = 1

    var onStateUpdated: (@MainActor (EditorSchedulerSnapshot) -> Void)?

    init(
        transport: (any EditorPlaybackTransport)? = nil,
        producer: EditorPCMProducer = EditorPCMProducer(),
        poolConfigFactory: @escaping (Double) -> EditorPCMPoolConfig = { rate in
            EditorPCMPoolConfig(
                slotCount: EditorPCMPoolConfig.defaultSlotCount,
                framesPerSlot: EditorPCMPoolConfig.defaultFramesPerSlot,
                channelCount: EditorPCMPoolConfig.defaultChannelCount,
                sampleRate: rate
            )
        },
        sourceResolver: @escaping @Sendable (AudioEditorProject) async throws -> [UUID: ResolvedClipSource] = { project in
            try await AudioSourceResolver.resolve(project: project)
        },
        monitorInterval: Duration = .milliseconds(5),
        startingTokenSequence: UInt64 = 1
    ) {
        self.transport = transport ?? AVAudioEditorPlayerTransport()
        self.producer = producer
        self.poolConfigFactory = poolConfigFactory
        self.sourceResolver = sourceResolver
        self.monitorInterval = monitorInterval
        self.startingTokenSequenceForTesting = max(1, startingTokenSequence)

        self.transport.onConfigurationChange = { [weak self] in
            self?.handleConfigurationOrRouteChange()
        }
    }

    deinit {
        teardownHandles.teardownNonisolated()
    }

    func setStartingTokenSequenceForTesting(_ seq: UInt64) {
        startingTokenSequenceForTesting = max(1, seq)
    }

    // MARK: - Transport Control

    func setLoop(range: ClosedRange<TimeInterval>?, enabled: Bool) {
        let newCfg = LoopConfiguration(frameRange: nil, timeRange: range, enabled: enabled && range != nil)
        applyLoopConfigChange(newCfg)
    }

    func setLoop(frameRange: SampleFrameRange?, enabled: Bool) {
        let tRange = frameRange.map {
            SampleFrameMigration.framesToSeconds($0.startFrame, sampleRate: $0.sampleRate)...SampleFrameMigration.framesToSeconds($0.endFrame, sampleRate: $0.sampleRate)
        }
        let newCfg = LoopConfiguration(frameRange: frameRange, timeRange: tRange, enabled: enabled && frameRange != nil)
        applyLoopConfigChange(newCfg)
    }

    private func applyLoopConfigChange(_ newCfg: LoopConfiguration) {
        guard loopConfig != newCfg else { return }
        loopConfig = newCfg

        if state == .playing || state == .preparing || state == .recovering, let project = preparedProject {
            let restartFrame = clampedStartFrameForLoopIfEnabled(displayedPlayheadFrame, project: project)
            play(fromFrame: restartFrame, project: project, autoStopAfterFrames: nil)
        } else if state == .paused {
            pausedNeedsRestart = true
        }
    }

    func play(fromFrame startFrame: Int64, project: AudioEditorProject, autoStopAfterFrames: Int64? = nil) {
        guard state != .shutDown else { return }
        guard epoch < UInt64.max else {
            transitionToFailed("Playback epoch overflow.")
            return
        }

        let targetEpoch = epoch + 1
        epoch = targetEpoch
        revision = 1
        lastError = nil

        let rate = project.projectSampleRate
        sessionSampleRate = rate
        let clampedStart = clampedStartFrameForLoopIfEnabled(max(0, startFrame), project: project)
        autoStopAtFrame = autoStopAfterFrames.map { clampedStart + max(0, $0) }
        displayedPlayheadFrame = clampedStart
        pausedNeedsRestart = false

        cancelControlTasks()
        stopMonitorLoop()
        retireActivePool()
        transport.stopNode()
        resetScheduledTracking(startFrame: clampedStart)
        meterL = 0
        meterR = 0
        gainReductionDB = 0

        let hadFailureBefore = (state == .recovering)
        if !hadFailureBefore {
            state = .preparing
        }
        emitSnapshot()

        let previousProject = preparedProject
        let needsSourceResolution = previousProject.map {
            AudioProjectChangeClassifier.classify(from: $0, to: project) == .structural || resolvedSources.isEmpty
        } ?? true

        let loopBounds = loopConfig.resolvedFrameBounds(for: rate)
        let endDurationFrames = Self.endDurationFrames(for: project)
        let stopAt = autoStopAtFrame
        let config = poolConfigFactory(project.sampleRate)
        let seqSeed = startingTokenSequenceForTesting
        startingTokenSequenceForTesting = 1

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.producer.stopAndDrain(nextEpoch: targetEpoch)
            guard self.epoch == targetEpoch, !Task.isCancelled, self.state != .shutDown else { return }

            do {
                if needsSourceResolution {
                    let sources = try await self.sourceResolver(project)
                    guard self.epoch == targetEpoch, !Task.isCancelled, self.state != .shutDown else { return }
                    self.resolvedSources = sources
                }

                await self.producer.configureSession(
                    project: project,
                    sources: self.resolvedSources,
                    resetEffectStates: true
                )
                guard self.epoch == targetEpoch, !Task.isCancelled, self.state != .shutDown else { return }

                self.preparedProject = project

                let pool = try EditorPCMBufferPool(
                    config: config,
                    epoch: targetEpoch,
                    startingSequence: seqSeed
                )
                self.activePool = pool

                try self.transport.configure(sampleRate: project.sampleRate, channelCount: config.channelCount)
                try self.transport.startEngine()
                guard self.epoch == targetEpoch, !Task.isCancelled, self.state != .shutDown else {
                    self.retireActivePool()
                    return
                }

                await self.producer.startProducing(
                    epoch: targetEpoch,
                    revision: 1,
                    startFrame: clampedStart,
                    projectRate: rate,
                    endDurationFrames: endDurationFrames,
                    autoStopAtFrame: stopAt,
                    loopBounds: loopBounds,
                    pool: pool
                )
                guard self.epoch == targetEpoch, !Task.isCancelled, self.state != .shutDown else {
                    self.retireActivePool()
                    return
                }

                // Wait briefly for first rendered block so node start has initial audio ready.
                for _ in 0..<40 {
                    guard self.epoch == targetEpoch, !Task.isCancelled else { return }
                    if pool.readySlotCount > 0 { break }
                    try? await Task.sleep(for: .milliseconds(2))
                }

                guard self.epoch == targetEpoch, !Task.isCancelled, self.state != .shutDown else { return }

                self.state = .playing
                self.startMonitorLoopIfNeeded()
                await self.pollOnce()
                if self.state == .playing {
                    self.transport.playNode()
                    self.emitSnapshot()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.epoch == targetEpoch, self.state != .shutDown else { return }
                self.transitionToFailed(error.localizedDescription)
            }
        }
        transitionTaskToken &+= 1
        transitionTask = task
        syncTeardownHandles()
    }

    func pause() {
        guard state == .playing || state == .preparing || state == .recovering else { return }
        if state == .preparing || state == .recovering {
            cancelControlTasks()
            pausedNeedsRestart = true
        } else {
            refreshPlayheadFromRenderedSampleTime()
            transport.pauseNode()
        }
        stopMonitorLoop()
        state = .paused
        meterL = 0
        meterR = 0
        gainReductionDB = 0
        syncTeardownHandles()
        emitSnapshot()
    }

    func resume(project: AudioEditorProject) {
        guard state != .shutDown else { return }
        guard state == .paused else {
            play(fromFrame: displayedPlayheadFrame, project: project, autoStopAfterFrames: nil)
            return
        }

        if !pausedNeedsRestart, activePool != nil {
            do {
                if !transport.isEngineRunning {
                    try transport.startEngine()
                }
                transport.playNode()
                state = .playing
                startMonitorLoopIfNeeded()
                emitSnapshot()
                return
            } catch {
                // Fall back to full restart from displayed playhead if engine could not restart in place.
            }
        }

        play(fromFrame: displayedPlayheadFrame, project: project, autoStopAfterFrames: nil)
    }

    func stop() {
        guard state != .shutDown else { return }
        bumpEpoch()
        cancelControlTasks()
        stopMonitorLoop()
        retireActivePool()
        transport.stopNode()
        resetScheduledTracking(startFrame: displayedPlayheadFrame)
        pausedNeedsRestart = false
        meterL = 0
        meterR = 0
        gainReductionDB = 0
        state = .stopped

        let stopEpoch = epoch
        let prod = producer
        Task {
            await prod.stopAndDrain(nextEpoch: stopEpoch)
        }
        syncTeardownHandles()
        emitSnapshot()
    }

    func seek(toFrame frame: Int64, project: AudioEditorProject) {
        guard state != .shutDown else { return }
        let clamped = max(0, frame)
        sessionSampleRate = project.projectSampleRate
        displayedPlayheadFrame = clamped
        autoStopAtFrame = nil

        if state == .playing || state == .preparing || state == .recovering {
            play(fromFrame: clamped, project: project, autoStopAfterFrames: nil)
            return
        }

        if state == .paused {
            bumpEpoch()
            retireActivePool()
            transport.stopNode()
            resetScheduledTracking(startFrame: clamped)
            pausedNeedsRestart = true
            let seekEpoch = epoch
            let prod = producer
            Task {
                await prod.stopAndDrain(nextEpoch: seekEpoch)
            }
        }

        emitSnapshot()
    }

    func projectDidChange(_ newProject: AudioEditorProject) {
        guard state != .shutDown else { return }
        guard let oldProject = preparedProject else {
            if state == .stopped || state == .paused {
                preparedProject = newProject
            }
            return
        }

        let diff = AudioProjectChangeClassifier.classify(from: oldProject, to: newProject)
        switch diff {
        case .noAudioImpact:
            preparedProject = newProject
            return

        case .nonStructural:
            preparedProject = newProject
            sessionSampleRate = newProject.projectSampleRate
            guard revision < UInt64.max else {
                // Roll over cleanly if revision ever saturates.
                let restart = displayedPlayheadFrame
                play(fromFrame: restart, project: newProject, autoStopAfterFrames: nil)
                return
            }
            let nextRevision = revision + 1
            revision = nextRevision

            guard state == .playing, let pool = activePool else {
                if state == .paused {
                    pausedNeedsRestart = true
                }
                return
            }

            // Discard unscheduled stale READY blocks synchronously before launching coalesced revision update.
            _ = pool.discardUnscheduledReadySlots(olderThanRevision: nextRevision)
            let targetEpoch = epoch
            let resumeFrame = lastScheduledTimelineEndFrame
            let sources = resolvedSources
            let prod = producer

            revisionTask?.cancel()
            revisionTask = Task { @MainActor [weak self] in
                guard let self, self.epoch == targetEpoch, !Task.isCancelled else { return }
                await prod.applyNonStructuralRevision(
                    epoch: targetEpoch,
                    revision: nextRevision,
                    project: newProject,
                    sources: sources,
                    pool: pool,
                    resumeFromFrame: resumeFrame
                )
            }
            syncTeardownHandles()

        case .structural:
            preparedProject = newProject
            sessionSampleRate = newProject.projectSampleRate
            if state == .playing || state == .preparing || state == .recovering {
                refreshPlayheadFromRenderedSampleTime()
                let maxProjFrames = max(Int64(0), newProject.durationFrames)
                let restartOrigin = min(displayedPlayheadFrame, maxProjFrames)
                play(fromFrame: restartOrigin, project: newProject, autoStopAfterFrames: nil)
            } else if state == .paused {
                bumpEpoch()
                retireActivePool()
                transport.stopNode()
                pausedNeedsRestart = true
                let structEpoch = epoch
                let prod = producer
                Task {
                    await prod.stopAndDrain(nextEpoch: structEpoch)
                }
            }
        }
    }

    func handleConfigurationOrRouteChange() {
        guard state != .shutDown else { return }
        if state == .playing || state == .preparing || state == .recovering {
            refreshPlayheadFromRenderedSampleTime()
            let resumeFrame = displayedPlayheadFrame
            state = .recovering
            emitSnapshot()
            if let project = preparedProject {
                play(fromFrame: resumeFrame, project: project, autoStopAfterFrames: nil)
            } else {
                transitionToFailed("Audio configuration changed without an active project.")
            }
        } else if state == .paused {
            pausedNeedsRestart = true
            retireActivePool()
            transport.stopNode()
        }
    }

    func shutdown() {
        guard state != .shutDown else { return }
        bumpEpoch()
        cancelControlTasks()
        stopMonitorLoop()
        retireActivePool()
        transport.stopNode()
        resetScheduledTracking(startFrame: displayedPlayheadFrame)
        meterL = 0
        meterR = 0
        gainReductionDB = 0
        state = .shutDown

        let stopEpoch = epoch
        let prod = producer
        Task {
            await prod.stopAndDrain(nextEpoch: stopEpoch)
        }
        syncTeardownHandles()
        emitSnapshot()
    }

    func waitForTransitionCompletion() async {
        while let task = transitionTask {
            let token = transitionTaskToken
            await task.value
            if transitionTask == nil || transitionTaskToken == token {
                break
            }
        }
    }

    func waitForRevisionCoalescing() async {
        await revisionTask?.value
    }

    // MARK: - Single Bounded Monitoring Loop

    private func startMonitorLoopIfNeeded() {
        guard monitorTask == nil else { return }
        let targetEpoch = epoch
        let interval = monitorInterval
        monitorLoopToken &+= 1
        let loopToken = monitorLoopToken
        activeMonitorLoopCount += 1

        monitorTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.monitorLoopToken == loopToken {
                    self.activeMonitorLoopCount = max(0, self.activeMonitorLoopCount - 1)
                    self.monitorTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self,
                      self.epoch == targetEpoch,
                      self.state == .playing else {
                    break
                }
                await self.pollOnce()
                guard !Task.isCancelled,
                      self.epoch == targetEpoch,
                      self.state == .playing else {
                    break
                }
                try? await Task.sleep(for: interval)
            }
        }
        syncTeardownHandles()
    }

    private func stopMonitorLoop() {
        if let task = monitorTask {
            monitorLoopToken &+= 1
            task.cancel()
            monitorTask = nil
            activeMonitorLoopCount = max(0, activeMonitorLoopCount - 1)
        }
    }

    /// Performs one bounded scheduling + reclamation + playhead-update pass.
    /// Exposed internally for deterministic testing.
    func pollOnce() async {
        monitorTickCount += 1

        // Reclaim completed callbacks on retired pools until none remain outstanding.
        for pool in retiredPools {
            _ = pool.pollAndReclaimCompletedSlots()
        }
        retiredPools.removeAll { $0.outstandingCallbackCount == 0 && $0.quarantinedSlotCount == 0 }

        guard state == .playing, let pool = activePool else { return }

        // 1. Reclaim consumed slots so producer can make progress (never moves audible playhead!).
        let pollResult = pool.pollAndReclaimCompletedSlots()
        if let eofToken = eofScheduledToken,
           pollResult.playedBackBlocks.contains(where: { $0.token == eofToken }) {
            eofPlayedBackConfirmed = true
        }

        // 2. Schedule any ready PCM blocks onto AVAudioPlayerNode.
        do {
            while let info = try pool.beginSchedulingNextReady(expectedEpoch: epoch, minRevision: revision) {
                let segmentStart = totalScheduledNodeFrames
                let segment = ScheduledTimelineSegment(
                    nodeSampleStart: segmentStart,
                    frameCount: info.metadata.frameCount,
                    timelineStartFrame: info.metadata.timelineStartFrame,
                    isEndOfStream: info.metadata.isEndOfStream,
                    peakL: info.metadata.peakL,
                    peakR: info.metadata.peakR,
                    gainReductionDB: info.metadata.gainReductionDB,
                    token: info.token
                )
                scheduledSegments.append(segment)
                totalScheduledNodeFrames += Int64(info.metadata.frameCount)
                lastScheduledTimelineEndFrame = info.metadata.timelineStartFrame + Int64(info.metadata.frameCount)
                if info.metadata.isEndOfStream {
                    eofScheduledToken = info.token
                }

                let context = pool.callbackContext
                let slotIdx = info.slotIndex
                let seq = info.token.sequence
                do {
                    try transport.scheduleBuffer(info.buffer, callbackType: info.callbackType) { cbType in
                        context.recordCompletion(slotIndex: slotIdx, tokenSequence: seq, callbackType: cbType)
                    }
                } catch {
                    pool.rollbackScheduledSlotOnFailure(
                        slotIndex: slotIdx,
                        token: info.token,
                        wasSubmittedToAudioNode: false
                    )
                    if let idx = scheduledSegments.lastIndex(where: { $0.token == info.token }) {
                        scheduledSegments.remove(at: idx)
                    }
                    totalScheduledNodeFrames = segmentStart
                    transitionToFailed(error.localizedDescription)
                    return
                }
            }
        } catch EditorTokenError.sequenceOverflow {
            // Safely roll over to a new epoch from current displayed playhead if token sequence reaches UInt64.max.
            if let project = preparedProject {
                play(fromFrame: displayedPlayheadFrame, project: project, autoStopAfterFrames: nil)
            } else {
                transitionToFailed("Buffer token sequence exhausted.")
            }
            return
        } catch {
            transitionToFailed(error.localizedDescription)
            return
        }

        // 3. Update audible playhead and meters from rendered hardware sample time.
        refreshPlayheadFromRenderedSampleTime()

        // 4. Finish cleanly only after EOF block audible playback is confirmed.
        if eofScheduledToken != nil {
            let renderedReachedEOF: Bool
            if let rendered = transport.currentRenderedSampleTime(),
               totalScheduledNodeFrames > 0,
               rendered >= totalScheduledNodeFrames {
                renderedReachedEOF = true
            } else {
                renderedReachedEOF = false
            }
            if eofPlayedBackConfirmed || renderedReachedEOF {
                finishAtEOF()
                return
            }
        }

        emitSnapshot()
    }

    // MARK: - Internal State Helpers

    private func refreshPlayheadFromRenderedSampleTime() {
        guard let renderedSample = transport.currentRenderedSampleTime(),
              !scheduledSegments.isEmpty else {
            return
        }

        var matchedIndex: Int?
        for idx in scheduledSegments.indices {
            let seg = scheduledSegments[idx]
            let segEnd = seg.nodeSampleStart + Int64(seg.frameCount)
            if renderedSample >= seg.nodeSampleStart && renderedSample < segEnd {
                matchedIndex = idx
                break
            }
        }

        let targetIdx = matchedIndex ?? (renderedSample >= totalScheduledNodeFrames ? scheduledSegments.count - 1 : 0)
        let activeSeg = scheduledSegments[targetIdx]
        let offset = max(0, min(Int64(activeSeg.frameCount), renderedSample - activeSeg.nodeSampleStart))
        displayedPlayheadFrame = activeSeg.timelineStartFrame + offset

        meterL = max(activeSeg.peakL, meterL * 0.85)
        meterR = max(activeSeg.peakR, meterR * 0.85)
        gainReductionDB = activeSeg.gainReductionDB

        // Prune already-rendered segments behind targetIdx while keeping at least the active/tail reference.
        if targetIdx > 0 {
            scheduledSegments.removeFirst(targetIdx)
        }
    }

    private func finishAtEOF() {
        bumpEpoch()
        cancelControlTasks()
        stopMonitorLoop()
        retireActivePool()
        transport.stopNode()
        resetScheduledTracking(startFrame: displayedPlayheadFrame)
        pausedNeedsRestart = false
        meterL = 0
        meterR = 0
        gainReductionDB = 0
        state = .stopped

        let stopEpoch = epoch
        let prod = producer
        Task {
            await prod.stopAndDrain(nextEpoch: stopEpoch)
        }
        syncTeardownHandles()
        emitSnapshot()
    }

    private func transitionToFailed(_ message: String) {
        bumpEpoch()
        cancelControlTasks()
        stopMonitorLoop()
        retireActivePool()
        transport.stopNode()
        resetScheduledTracking(startFrame: displayedPlayheadFrame)
        lastError = message
        meterL = 0
        meterR = 0
        gainReductionDB = 0
        state = .failed(message)

        let failEpoch = epoch
        let prod = producer
        Task {
            await prod.stopAndDrain(nextEpoch: failEpoch)
        }
        syncTeardownHandles()
        emitSnapshot()
    }

    private func retireActivePool() {
        guard let pool = activePool else { return }
        pool.retireAndQuarantineOutstanding()
        _ = pool.pollAndReclaimCompletedSlots()
        if pool.outstandingCallbackCount > 0 || pool.quarantinedSlotCount > 0 {
            retiredPools.append(pool)
        }
        activePool = nil
        syncTeardownHandles()
    }

    private func resetScheduledTracking(startFrame: Int64) {
        scheduledSegments.removeAll()
        totalScheduledNodeFrames = 0
        lastScheduledTimelineEndFrame = max(0, startFrame)
        eofScheduledToken = nil
        eofPlayedBackConfirmed = false
    }

    private func cancelControlTasks() {
        transitionTask?.cancel()
        transitionTask = nil
        revisionTask?.cancel()
        revisionTask = nil
    }

    private func bumpEpoch() {
        if epoch < UInt64.max {
            epoch += 1
        }
    }

    private func clampedStartFrameForLoopIfEnabled(_ frame: Int64, project: AudioEditorProject) -> Int64 {
        guard let bounds = loopConfig.resolvedFrameBounds(for: project.projectSampleRate),
              bounds.endFrame > bounds.startFrame else {
            return max(0, frame)
        }
        if frame < bounds.startFrame || frame >= bounds.endFrame {
            return bounds.startFrame
        }
        return frame
    }

    private static func endDurationFrames(for project: AudioEditorProject) -> Int64 {
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
                if endFrame > maxFrame {
                    maxFrame = endFrame
                }
            }
        }
        let tailFrames = Int64((Double(pRate.hz) * 0.02).rounded())
        return maxFrame + tailFrames
    }

    private func syncTeardownHandles() {
        teardownHandles.update(
            monitor: monitorTask,
            transition: transitionTask,
            revision: revisionTask,
            activePool: activePool
        )
    }

    private func emitSnapshot() {
        let snap = EditorSchedulerSnapshot(
            state: state,
            playheadFrame: displayedPlayheadFrame,
            sampleRate: sessionSampleRate,
            meterL: meterL,
            meterR: meterR,
            gainReductionDB: gainReductionDB,
            lastError: lastError
        )
        onStateUpdated?(snap)
    }
}

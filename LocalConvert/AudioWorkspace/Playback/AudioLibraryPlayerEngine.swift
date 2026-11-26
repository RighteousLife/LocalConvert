import Foundation
import AVFoundation
import CoreAudio
import Combine
import os

// MARK: - Injectable Playback Transport Abstraction

@MainActor
protocol AudioPlaybackTransportProtocol: AnyObject {
    func configure(sampleRate: Double, channelCount: Int) throws
    func configure(sampleRate: Double, channelCount: Int, channelLayout: AudioChannelLayoutInfo?) throws
    func setOutputDevice(deviceID: AudioDeviceID?) throws
    func startEngine() throws
    func playNode()
    func pauseNode()
    func stopAndResetNode()
    var volume: Float { get set }
    var rate: Float { get set }
    func scheduleChunk(_ chunk: DecodedPCMChunk, onRendered: @escaping @MainActor () -> Void)
    func currentRenderedFramesSinceReset() -> Int64
}

extension AudioPlaybackTransportProtocol {
    func configure(sampleRate: Double, channelCount: Int, channelLayout: AudioChannelLayoutInfo?) throws {
        try configure(sampleRate: sampleRate, channelCount: channelCount)
    }
}

// MARK: - Real AVAudioEngine Transport (Independent from AudioEditorPlaybackEngine)

@MainActor
final class AVAudioEnginePlaybackTransport: AudioPlaybackTransportProtocol {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let halBackend: any CoreAudioHALBackend
    private var configuredFormat: AVAudioFormat?
    private var configuredLayout: AudioChannelLayoutInfo?
    private var isGraphConnected = false
    private let lifecycleLock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    var onConfigurationInterrupted: (@MainActor () -> Void)?

    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = max(0, min(1, newValue)) }
    }

    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = max(0.25, min(4.0, newValue)) }
    }

    init(halBackend: any CoreAudioHALBackend = SystemCoreAudioHALBackend()) {
        self.halBackend = halBackend
        engine.attach(playerNode)
        engine.attach(timePitch)
        let targetEngine = engine
        let monitorTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: targetEngine) {
                guard !Task.isCancelled else { break }
                self?.onConfigurationInterrupted?()
            }
        }
        lifecycleLock.withLock { $0 = monitorTask }
    }

    deinit {
        lifecycleLock.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    func setOutputDevice(deviceID: AudioDeviceID?) throws {
        let targetID: AudioDeviceID
        if let deviceID {
            targetID = deviceID
        } else if let defaultID = halBackend.defaultOutputDeviceID() {
            targetID = defaultID
        } else {
            throw AudioPlaybackError.engineStartFailed("No default CoreAudio output device available.")
        }

        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        if isGraphConnected {
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
            isGraphConnected = false
        }

        do {
            try engine.outputNode.auAudioUnit.setDeviceID(targetID)
        } catch {
            throw AudioPlaybackError.engineStartFailed(
                "Failed to configure audio output device \(targetID): \(error.localizedDescription)"
            )
        }

        if let format = configuredFormat {
            engine.connect(playerNode, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            engine.prepare()
            isGraphConnected = true
        }
    }

    func configure(sampleRate: Double, channelCount: Int) throws {
        try configure(sampleRate: sampleRate, channelCount: channelCount, channelLayout: nil)
    }

    func configure(sampleRate: Double, channelCount: Int, channelLayout: AudioChannelLayoutInfo?) throws {
        let safeChannels = max(1, channelCount)
        guard let format = AudioChannelLayoutInfo.makePlaybackFormat(
            sampleRate: sampleRate,
            channelCount: safeChannels,
            channelLayout: channelLayout
        ) else {
            throw AudioPlaybackError.engineStartFailed(
                "Unable to build AVAudioFormat for \(sampleRate) Hz / \(safeChannels) ch (\(channelLayout?.normalizedName ?? "unknown"))."
            )
        }

        let layoutsGaplessCompatible = configuredLayout != nil
            && channelLayout != nil
            && configuredLayout?.isGaplessCompatible(with: channelLayout!) == true

        if let current = configuredFormat,
           isGraphConnected,
           current.sampleRate == format.sampleRate,
           current.channelCount == format.channelCount,
           layoutsGaplessCompatible {
            return
        }

        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        if isGraphConnected {
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
            isGraphConnected = false
        }

        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
        configuredFormat = format
        configuredLayout = channelLayout
        isGraphConnected = true
    }

    func startEngine() throws {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw AudioPlaybackError.engineStartFailed(error.localizedDescription)
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

    func stopAndResetNode() {
        playerNode.stop()
    }

    func scheduleChunk(_ chunk: DecodedPCMChunk, onRendered: @escaping @MainActor () -> Void) {
        guard let buffer = chunk.makeAVAudioPCMBuffer() else {
            onRendered()
            return
        }
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in
                onRendered()
            }
        }
    }

    func currentRenderedFramesSinceReset() -> Int64 {
        guard let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return max(0, playerTime.sampleTime)
    }
}

// MARK: - Independent Audio Library Player Engine

@MainActor
final class AudioLibraryPlayerEngine: ObservableObject {
    static let chunkFrameCount = 8_192
    static let maxChunksInFlight = 4
    static let maxPreloadBufferedChunks = 2

    typealias DecoderLoader = @Sendable (URL, FileFormat?) async throws -> any AudioPlaybackDecoderProtocol

    private struct PreloadedTrackState {
        let trackToken: UInt64
        let assetID: UUID
        let url: URL
        let fileFormat: FileFormat?
        let decoder: any AudioPlaybackDecoderProtocol
        let streamInfo: DecodedAudioStreamInfo
        var bufferedChunks: [DecodedPCMChunk]
        var scheduledChunkCount: Int = 0
        var submittedFrames: Int64 = 0
        var decoderReachedEOF: Bool
        var isScheduledOnNode: Bool = false
    }

    @Published private(set) var activeAssetID: UUID?
    @Published private(set) var activeURL: URL?
    @Published private(set) var streamInfo: DecodedAudioStreamInfo?
    @Published private(set) var playbackState: PlaybackTransportState = .stopped
    @Published private(set) var position: SourceFrameTime?
    @Published private(set) var totalFrames: Int64 = 0
    @Published private(set) var volume: Double = 1.0
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var preMuteVolume: Double = 1.0
    @Published private(set) var playbackRate: Double = 1.0

    var onTrackEnded: (@MainActor () -> Void)?
    var onGaplessTrackTransitioned: (@MainActor (UUID) -> Void)?

    var isGaplessArmed: Bool {
        preloadedTrack != nil
    }

    var preloadedAssetID: UUID? {
        preloadedTrack?.assetID
    }

    private let transport: any AudioPlaybackTransportProtocol
    private let decoderLoader: DecoderLoader

    private var decoder: (any AudioPlaybackDecoderProtocol)?
    private var generation: UInt64 = 0
    private var trackTokenCounter: UInt64 = 0
    private var activeTrackToken: UInt64 = 0
    private var feedTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var preloadGeneration: UInt64 = 0
    private var preloadedTrack: PreloadedTrackState?
    private var seekAnchorFrame: Int64 = 0
    private var transportFrameOriginOffset: Int64 = 0
    private var activeFramesSubmittedSinceOrigin: Int64 = 0
    private var inFlightChunkCount: Int = 0
    private var decoderReachedEOF = false
    private let teardownLock = OSAllocatedUnfairLock<(
        feed: Task<Void, Never>?,
        progress: Task<Void, Never>?,
        preload: Task<Void, Never>?,
        decoder: (any AudioPlaybackDecoderProtocol)?,
        preloadedDecoder: (any AudioPlaybackDecoderProtocol)?
    )>(initialState: (nil, nil, nil, nil, nil))

    init(
        transport: (any AudioPlaybackTransportProtocol)? = nil,
        decoderLoader: @escaping DecoderLoader = { url, fmt in
            try await AudioPlaybackDecoderFactory.openDecoder(url: url, format: fmt)
        }
    ) {
        self.transport = transport ?? AVAudioEnginePlaybackTransport()
        self.decoderLoader = decoderLoader
        if let realTransport = self.transport as? AVAudioEnginePlaybackTransport {
            realTransport.onConfigurationInterrupted = { [weak self] in
                self?.handleEngineConfigChange()
            }
        }
    }

    deinit {
        let state = teardownLock.withLock { current -> (
            feed: Task<Void, Never>?,
            progress: Task<Void, Never>?,
            preload: Task<Void, Never>?,
            decoder: (any AudioPlaybackDecoderProtocol)?,
            preloadedDecoder: (any AudioPlaybackDecoderProtocol)?
        ) in
            let copy = current
            current = (nil, nil, nil, nil, nil)
            return copy
        }
        state.feed?.cancel()
        state.progress?.cancel()
        state.preload?.cancel()
        if let dec = state.decoder {
            Task { await dec.close() }
        }
        if let preDec = state.preloadedDecoder {
            Task { await preDec.close() }
        }
    }

    private func syncTeardownSnapshot() {
        let f = feedTask
        let p = progressTask
        let pre = preloadTask
        let d = decoder
        let preD = preloadedTrack?.decoder
        teardownLock.withLock {
            $0 = (f, p, pre, d, preD)
        }
    }

    var durationSeconds: Double {
        guard let info = streamInfo else { return 0 }
        return Double(totalFrames) / Double(info.sampleRate.hz)
    }

    var currentSeconds: Double {
        position?.raw.derivedSeconds ?? 0
    }

    var progressFraction: Double {
        guard totalFrames > 0, let frame = position?.frame else { return 0 }
        return max(0.0, min(1.0, Double(frame) / Double(totalFrames)))
    }

    func snapshotSession(outputDeviceUID: String? = nil, outputDeviceName: String = "System Default") -> PlaybackSession {
        let clampedTotal = max(0, totalFrames)
        let clampedVolume = volume.isFinite ? max(0.0, min(1.0, volume)) : 1.0
        let clampedPreMute = preMuteVolume.isFinite ? max(0.0, min(1.0, preMuteVolume)) : 1.0
        let clampedRate = playbackRate.isFinite ? max(0.25, min(4.0, playbackRate)) : 1.0
        return (try? PlaybackSession(
            activeAssetID: activeAssetID,
            playbackState: playbackState,
            position: position,
            totalFrames: clampedTotal,
            volume: clampedVolume,
            isMuted: isMuted,
            preMuteVolume: clampedPreMute,
            playbackRate: clampedRate,
            outputDeviceUID: outputDeviceUID,
            outputDeviceName: outputDeviceName
        )) ?? .systemDefault
    }

    // MARK: - Loading & Lifecycle

    func load(url: URL, assetID: UUID?, fileFormat: FileFormat? = nil, autoPlay: Bool = false) async throws {
        generation &+= 1
        let myGen = generation

        cancelBackgroundTasks()
        clearPreloadStateSync(closeDecoder: true)
        transport.stopAndResetNode()
        inFlightChunkCount = 0
        decoderReachedEOF = false
        transportFrameOriginOffset = 0
        activeFramesSubmittedSinceOrigin = 0
        trackTokenCounter &+= 1
        activeTrackToken = trackTokenCounter

        if let oldDecoder = decoder {
            decoder = nil
            syncTeardownSnapshot()
            await oldDecoder.close()
        }

        guard myGen == generation else { throw CancellationError() }

        activeAssetID = assetID
        activeURL = url
        streamInfo = nil
        totalFrames = 0
        seekAnchorFrame = 0
        position = nil
        playbackState = .loading

        do {
            let openedDecoder = try await decoderLoader(url, fileFormat)
            if myGen != generation || Task.isCancelled {
                await openedDecoder.close()
                throw CancellationError()
            }

            let info = openedDecoder.streamInfo
            try transport.configure(
                sampleRate: Double(info.sampleRate.hz),
                channelCount: info.channelCount,
                channelLayout: info.channelLayout
            )
            applyAudioOutputSettings()

            decoder = openedDecoder
            syncTeardownSnapshot()
            streamInfo = info
            totalFrames = info.totalFrames
            seekAnchorFrame = 0
            position = try SourceFrameTime(frame: 0, sampleRate: info.sampleRate)
            playbackState = .paused

            if autoPlay {
                try play()
            }
        } catch is CancellationError {
            if myGen == generation {
                playbackState = .stopped
            }
            throw CancellationError()
        } catch {
            if myGen == generation {
                let message = error.localizedDescription
                playbackState = .error(message)
                StructuredDiagnostics.recordAudioEvent(
                    category: .audioPlayer,
                    severity: .validation,
                    stage: "load_track",
                    assetID: assetID,
                    fileExtension: url.pathExtension,
                    message: message
                )
            }
            throw error
        }
    }

    // MARK: - Gapless Pre-loading

    /// Pre-opens and pre-decodes the initial bounded chunks of the next queue track when format matches seamlessly.
    /// Cross-rate or channel-count mismatches leave gapless disarmed so the safe pause/reconfigure/resume fallback executes.
    func preloadNextTrack(url: URL, assetID: UUID, fileFormat: FileFormat? = nil) {
        guard streamInfo != nil, decoder != nil else { return }
        if preloadedTrack?.assetID == assetID && preloadedTrack?.url == url {
            return
        }

        clearPreloadedNextTrack()

        preloadGeneration &+= 1
        let myPreGen = preloadGeneration
        let myTrackGen = generation
        let loader = decoderLoader

        preloadTask = Task { @MainActor [weak self] in
            do {
                let nextDecoder = try await loader(url, fileFormat)
                guard let self,
                      !Task.isCancelled,
                      myPreGen == self.preloadGeneration,
                      myTrackGen == self.generation,
                      let activeInfo = self.streamInfo else {
                    await nextDecoder.close()
                    return
                }

                let nextInfo = nextDecoder.streamInfo
                guard nextInfo.sampleRate == activeInfo.sampleRate,
                      nextInfo.channelCount == activeInfo.channelCount,
                      nextInfo.sampleRate.hz > 0,
                      nextInfo.channelCount > 0,
                      let activeLayout = activeInfo.channelLayout,
                      let nextLayout = nextInfo.channelLayout,
                      activeLayout.isGaplessCompatible(with: nextLayout) else {
                    await nextDecoder.close()
                    return
                }

                var buffered: [DecodedPCMChunk] = []
                var nextEOF = false
                for _ in 0..<Self.maxPreloadBufferedChunks {
                    try Task.checkCancellation()
                    if let chunk = try await nextDecoder.readNextChunk(maxFrames: Self.chunkFrameCount) {
                        buffered.append(chunk)
                    } else {
                        nextEOF = true
                        break
                    }
                }

                guard !Task.isCancelled,
                      myPreGen == self.preloadGeneration,
                      myTrackGen == self.generation else {
                    await nextDecoder.close()
                    return
                }

                self.trackTokenCounter &+= 1
                self.preloadedTrack = PreloadedTrackState(
                    trackToken: self.trackTokenCounter,
                    assetID: assetID,
                    url: url,
                    fileFormat: fileFormat,
                    decoder: nextDecoder,
                    streamInfo: nextInfo,
                    bufferedChunks: buffered,
                    scheduledChunkCount: 0,
                    submittedFrames: 0,
                    decoderReachedEOF: nextEOF,
                    isScheduledOnNode: false
                )
                self.preloadTask = nil
                self.syncTeardownSnapshot()

                if case .playing = self.playbackState,
                   self.decoderReachedEOF,
                   self.feedTask == nil {
                    self.startFeedLoopIfNeeded()
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, myPreGen == self.preloadGeneration else { return }
                self.preloadTask = nil
                self.preloadedTrack = nil
                self.syncTeardownSnapshot()
                StructuredDiagnostics.recordAudioEvent(
                    category: .audioPlayer,
                    severity: .validation,
                    stage: "gapless_preload",
                    assetID: assetID,
                    fileExtension: url.pathExtension,
                    message: error.localizedDescription
                )
            }
        }
        syncTeardownSnapshot()
    }

    func waitForPendingPreload() async {
        await preloadTask?.value
    }

    func clearPreloadedNextTrack() {
        preloadGeneration &+= 1
        let wasScheduled = preloadedTrack?.isScheduledOnNode ?? false
        clearPreloadStateSync(closeDecoder: true)

        if wasScheduled, case .playing = playbackState, let activeDecoder = decoder {
            let rendered = max(0, transport.currentRenderedFramesSinceReset() - transportFrameOriginOffset)
            let resumeFrame = min(max(0, totalFrames), seekAnchorFrame + rendered)
            generation &+= 1
            let newGen = generation
            cancelBackgroundTasks()
            transport.stopAndResetNode()
            inFlightChunkCount = 0
            decoderReachedEOF = false
            transportFrameOriginOffset = 0
            activeFramesSubmittedSinceOrigin = 0
            seekAnchorFrame = resumeFrame

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await activeDecoder.seek(toFrame: resumeFrame)
                    guard newGen == self.generation, case .playing = self.playbackState else { return }
                    try self.transport.startEngine()
                    self.applyAudioOutputSettings()
                    self.transport.playNode()
                    self.startFeedLoopIfNeeded()
                    self.startProgressLoop()
                } catch {
                    if newGen == self.generation {
                        self.playbackState = .error(error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Transport Controls

    func play() throws {
        guard decoder != nil, streamInfo != nil else { return }
        if case .playing = playbackState { return }

        do {
            try transport.startEngine()
            applyAudioOutputSettings()
            transport.playNode()
            playbackState = .playing
            startFeedLoopIfNeeded()
            startProgressLoop()
        } catch {
            playbackState = .error(error.localizedDescription)
            throw error
        }
    }

    func pause() {
        guard case .playing = playbackState else { return }
        updateRenderedPositionSnapshot()
        transport.pauseNode()
        progressTask?.cancel()
        progressTask = nil
        playbackState = .paused
    }

    func resume() throws {
        guard case .paused = playbackState, decoder != nil else { return }
        try play()
    }

    func togglePlayPause() throws {
        switch playbackState {
        case .playing:
            pause()
        case .paused:
            try resume()
        case .stopped, .error:
            try play()
        case .loading:
            break
        }
    }

    func stop() async {
        generation &+= 1
        cancelBackgroundTasks()
        clearPreloadStateSync(closeDecoder: true)
        transport.stopAndResetNode()
        inFlightChunkCount = 0
        decoderReachedEOF = false
        transportFrameOriginOffset = 0
        activeFramesSubmittedSinceOrigin = 0
        seekAnchorFrame = 0
        if let info = streamInfo {
            position = try? SourceFrameTime(frame: 0, sampleRate: info.sampleRate)
        } else {
            position = nil
        }
        if let decoder {
            try? await decoder.seek(toFrame: 0)
        }
        playbackState = .stopped
    }

    func unload() async {
        generation &+= 1
        cancelBackgroundTasks()
        clearPreloadStateSync(closeDecoder: true)
        transport.stopAndResetNode()
        inFlightChunkCount = 0
        decoderReachedEOF = false
        transportFrameOriginOffset = 0
        activeFramesSubmittedSinceOrigin = 0
        if let old = decoder {
            decoder = nil
            syncTeardownSnapshot()
            await old.close()
        }
        activeAssetID = nil
        activeURL = nil
        streamInfo = nil
        totalFrames = 0
        seekAnchorFrame = 0
        position = nil
        playbackState = .stopped
    }

    // MARK: - Sample-Frame Accurate Seeking

    func seek(toSeconds seconds: Double) async throws {
        guard seconds.isFinite else { return }
        guard let info = streamInfo else { return }
        let clampedSec = max(0.0, seconds)
        let targetFrame = Int64((clampedSec * Double(info.sampleRate.hz)).rounded())
        let targetTime = try SourceFrameTime(frame: targetFrame, sampleRate: info.sampleRate)
        try await seek(to: targetTime)
    }

    func seek(to frameTime: SourceFrameTime) async throws {
        guard let decoder, let info = streamInfo else { return }

        generation &+= 1
        let myGen = generation

        let convertedRaw = try frameTime.raw.converted(to: info.sampleRate)
        let upperBound = max(0, totalFrames)
        let clampedFrame = max(0, min(convertedRaw.frame, upperBound))
        let clampedPosition = try SourceFrameTime(frame: clampedFrame, sampleRate: info.sampleRate)

        let shouldResumePlayback: Bool
        if case .playing = playbackState {
            shouldResumePlayback = true
        } else {
            shouldResumePlayback = false
        }

        cancelBackgroundTasks()
        clearPreloadStateSync(closeDecoder: true)
        transport.stopAndResetNode()
        inFlightChunkCount = 0
        decoderReachedEOF = false
        transportFrameOriginOffset = 0
        activeFramesSubmittedSinceOrigin = 0

        try await decoder.seek(toFrame: clampedFrame)
        guard myGen == generation, !Task.isCancelled else { return }

        seekAnchorFrame = clampedFrame
        position = clampedPosition

        if shouldResumePlayback {
            try transport.startEngine()
            applyAudioOutputSettings()
            transport.playNode()
            playbackState = .playing
            startFeedLoopIfNeeded()
            startProgressLoop()
        } else if case .stopped = playbackState {
            playbackState = .paused
        }
    }

    // MARK: - Volume, Mute & Speed

    func setVolume(_ newVolume: Double) {
        let clamped = newVolume.isFinite ? max(0.0, min(1.0, newVolume)) : 1.0
        volume = clamped
        if clamped > 0 {
            preMuteVolume = clamped
            if isMuted {
                isMuted = false
            }
        }
        applyAudioOutputSettings()
    }

    func setMuted(_ muted: Bool) {
        if muted && !isMuted {
            if volume > 0 { preMuteVolume = volume }
            isMuted = true
        } else if !muted && isMuted {
            isMuted = false
            if volume == 0 {
                volume = max(0.1, preMuteVolume)
            }
        }
        applyAudioOutputSettings()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setPlaybackRate(_ newRate: Double) {
        let clamped = newRate.isFinite ? max(0.25, min(4.0, newRate)) : 1.0
        playbackRate = clamped
        applyAudioOutputSettings()
    }

    func restorePausedPositionIfLoaded(_ targetSeconds: Double) async {
        guard totalFrames > 0, targetSeconds > 0 else { return }
        try? await seek(toSeconds: targetSeconds)
        if case .playing = playbackState {
            pause()
        }
    }

    // MARK: - Output Device Routing & Graph Reconfiguration

    func setOutputDevice(deviceID: AudioDeviceID?) async throws {
        let wasPlaying: Bool
        if case .playing = playbackState {
            wasPlaying = true
        } else {
            wasPlaying = false
        }

        let savedFrame = position?.frame ?? seekAnchorFrame
        let savedInfo = streamInfo

        generation &+= 1
        let myGen = generation

        cancelBackgroundTasks()
        clearPreloadStateSync(closeDecoder: true)
        transport.stopAndResetNode()
        inFlightChunkCount = 0
        decoderReachedEOF = false
        transportFrameOriginOffset = 0
        activeFramesSubmittedSinceOrigin = 0

        do {
            try transport.setOutputDevice(deviceID: deviceID)

            guard let decoder, let info = savedInfo else {
                return
            }

            try transport.configure(
                sampleRate: Double(info.sampleRate.hz),
                channelCount: info.channelCount,
                channelLayout: info.channelLayout
            )
            try await decoder.seek(toFrame: savedFrame)
            guard myGen == generation, !Task.isCancelled else { return }

            seekAnchorFrame = savedFrame
            position = try SourceFrameTime(frame: savedFrame, sampleRate: info.sampleRate)

            if wasPlaying {
                try transport.startEngine()
                applyAudioOutputSettings()
                transport.playNode()
                playbackState = .playing
                startFeedLoopIfNeeded()
                startProgressLoop()
            }
        } catch is CancellationError {
            playbackState = .stopped
            throw CancellationError()
        } catch {
            if myGen == generation {
                playbackState = .error(error.localizedDescription)
                StructuredDiagnostics.recordAudioEvent(
                    category: .audioPlayer,
                    severity: .internalError,
                    stage: "output_device_switch",
                    assetID: activeAssetID,
                    fileExtension: activeURL?.pathExtension,
                    message: "Audio output device reconfiguration failed."
                )
            }
            throw error
        }
    }

    // MARK: - Internal Streaming Feed & Position Tracking

    private func applyAudioOutputSettings() {
        transport.volume = isMuted ? 0.0 : Float(volume)
        transport.rate = Float(playbackRate)
    }

    private func cancelBackgroundTasks() {
        feedTask?.cancel()
        feedTask = nil
        progressTask?.cancel()
        progressTask = nil
        syncTeardownSnapshot()
    }

    private func clearPreloadStateSync(closeDecoder: Bool) {
        preloadGeneration &+= 1
        preloadTask?.cancel()
        preloadTask = nil
        if let old = preloadedTrack {
            preloadedTrack = nil
            if closeDecoder {
                let dec = old.decoder
                Task { await dec.close() }
            }
        }
        syncTeardownSnapshot()
    }

    private func startFeedLoopIfNeeded() {
        guard feedTask == nil, decoder != nil else { return }
        let myGen = generation

        feedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while myGen == self.generation, !Task.isCancelled {
                guard case .playing = self.playbackState else { break }

                if !self.decoderReachedEOF {
                    guard let activeDecoder = self.decoder else { break }
                    let preScheduled = self.preloadedTrack?.scheduledChunkCount ?? 0
                    if self.inFlightChunkCount + preScheduled >= Self.maxChunksInFlight {
                        try? await Task.sleep(for: .milliseconds(25))
                        continue
                    }

                    do {
                        let expectedToken = self.activeTrackToken
                        guard let chunk = try await activeDecoder.readNextChunk(maxFrames: Self.chunkFrameCount) else {
                            guard myGen == self.generation, self.activeTrackToken == expectedToken else { continue }
                            self.decoderReachedEOF = true
                            if self.preloadedTrack != nil {
                                continue
                            } else {
                                self.checkNaturalCompletion(expectedGeneration: myGen)
                                break
                            }
                        }
                        guard myGen == self.generation, !Task.isCancelled, self.activeTrackToken == expectedToken else { break }
                        self.inFlightChunkCount += 1
                        self.activeFramesSubmittedSinceOrigin += Int64(chunk.frameCount)
                        self.transport.scheduleChunk(chunk) { [weak self] in
                            self?.handleChunkRendered(expectedGeneration: myGen, trackToken: expectedToken)
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard myGen == self.generation else { return }
                        self.playbackState = .error(error.localizedDescription)
                        self.progressTask?.cancel()
                        self.progressTask = nil
                        StructuredDiagnostics.recordAudioEvent(
                            category: .audioPlayer,
                            severity: .internalError,
                            stage: "decode_stream",
                            assetID: self.activeAssetID,
                            fileExtension: self.activeURL?.pathExtension,
                            message: error.localizedDescription
                        )
                        return
                    }
                } else if var preloaded = self.preloadedTrack {
                    let preToken = preloaded.trackToken
                    if preloaded.bufferedChunks.isEmpty && preloaded.decoderReachedEOF {
                        preloaded.isScheduledOnNode = true
                        self.preloadedTrack = preloaded
                        if self.inFlightChunkCount == 0 {
                            self.promotePreloadedTrackIfReady(expectedGeneration: myGen)
                            continue
                        }
                        break
                    }

                    let totalInFlight = self.inFlightChunkCount + preloaded.scheduledChunkCount
                    if totalInFlight >= Self.maxChunksInFlight {
                        try? await Task.sleep(for: .milliseconds(25))
                        continue
                    }

                    let nextChunk: DecodedPCMChunk?
                    if !preloaded.bufferedChunks.isEmpty {
                        nextChunk = preloaded.bufferedChunks.removeFirst()
                        self.preloadedTrack = preloaded
                    } else {
                        do {
                            let decoded = try await preloaded.decoder.readNextChunk(maxFrames: Self.chunkFrameCount)
                            guard myGen == self.generation,
                                  !Task.isCancelled,
                                  var refreshed = self.preloadedTrack,
                                  refreshed.trackToken == preToken else { break }
                            if let decoded {
                                nextChunk = decoded
                            } else {
                                refreshed.decoderReachedEOF = true
                                self.preloadedTrack = refreshed
                                continue
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            if let failed = self.preloadedTrack, failed.trackToken == preToken {
                                self.preloadedTrack = nil
                                self.syncTeardownSnapshot()
                                Task { await failed.decoder.close() }
                                StructuredDiagnostics.recordAudioEvent(
                                    category: .audioPlayer,
                                    severity: .validation,
                                    stage: "gapless_decode_stream",
                                    assetID: failed.assetID,
                                    fileExtension: failed.url.pathExtension,
                                    message: error.localizedDescription
                                )
                            }
                            self.checkNaturalCompletion(expectedGeneration: myGen)
                            break
                        }
                    }

                    if let chunk = nextChunk {
                        guard myGen == self.generation,
                              var currentPre = self.preloadedTrack,
                              currentPre.trackToken == preToken else { break }
                        currentPre.scheduledChunkCount += 1
                        currentPre.submittedFrames += Int64(chunk.frameCount)
                        currentPre.isScheduledOnNode = true
                        self.preloadedTrack = currentPre
                        self.transport.scheduleChunk(chunk) { [weak self] in
                            self?.handleChunkRendered(expectedGeneration: myGen, trackToken: preToken)
                        }
                    }
                } else {
                    self.checkNaturalCompletion(expectedGeneration: myGen)
                    break
                }
            }
            if myGen == self.generation {
                self.feedTask = nil
                self.syncTeardownSnapshot()
            }
        }
        syncTeardownSnapshot()
    }

    private func handleChunkRendered(expectedGeneration: UInt64, trackToken: UInt64) {
        guard expectedGeneration == generation else { return }
        if trackToken == activeTrackToken {
            inFlightChunkCount = max(0, inFlightChunkCount - 1)
            checkNaturalCompletion(expectedGeneration: expectedGeneration)
        } else if var pre = preloadedTrack, pre.trackToken == trackToken {
            pre.scheduledChunkCount = max(0, pre.scheduledChunkCount - 1)
            preloadedTrack = pre
        }
    }

    private func checkNaturalCompletion(expectedGeneration: UInt64) {
        guard expectedGeneration == generation,
              decoderReachedEOF,
              inFlightChunkCount == 0 else { return }

        guard case .playing = playbackState else { return }

        if preloadedTrack != nil {
            promotePreloadedTrackIfReady(expectedGeneration: expectedGeneration)
            return
        }

        progressTask?.cancel()
        progressTask = nil
        feedTask = nil
        if let info = streamInfo {
            position = try? SourceFrameTime(frame: totalFrames, sampleRate: info.sampleRate)
        }
        playbackState = .stopped
        onTrackEnded?()
    }

    private func promotePreloadedTrackIfReady(expectedGeneration: UInt64) {
        guard expectedGeneration == generation,
              let pre = preloadedTrack else { return }

        let oldDecoder = decoder
        preloadedTrack = nil

        transportFrameOriginOffset += activeFramesSubmittedSinceOrigin
        activeFramesSubmittedSinceOrigin = pre.submittedFrames

        decoder = pre.decoder
        activeTrackToken = pre.trackToken
        activeAssetID = pre.assetID
        activeURL = pre.url
        streamInfo = pre.streamInfo
        totalFrames = pre.streamInfo.totalFrames
        seekAnchorFrame = 0
        position = try? SourceFrameTime(frame: 0, sampleRate: pre.streamInfo.sampleRate)
        inFlightChunkCount = pre.scheduledChunkCount
        decoderReachedEOF = pre.decoderReachedEOF && pre.bufferedChunks.isEmpty
        syncTeardownSnapshot()

        if let oldDecoder {
            Task { await oldDecoder.close() }
        }

        // If any pre-decoded buffers remain in preloadedTrack (e.g., active finished synchronously before feedLoop pushed them), schedule them immediately.
        for bufferedChunk in pre.bufferedChunks {
            inFlightChunkCount += 1
            activeFramesSubmittedSinceOrigin += Int64(bufferedChunk.frameCount)
            let token = activeTrackToken
            transport.scheduleChunk(bufferedChunk) { [weak self] in
                self?.handleChunkRendered(expectedGeneration: expectedGeneration, trackToken: token)
            }
        }

        onGaplessTrackTransitioned?(pre.assetID)

        if decoderReachedEOF && inFlightChunkCount == 0 {
            checkNaturalCompletion(expectedGeneration: expectedGeneration)
        } else if !decoderReachedEOF && feedTask == nil {
            startFeedLoopIfNeeded()
        }
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        let myGen = generation
        progressTask = Task { @MainActor [weak self] in
            while let self, myGen == self.generation, !Task.isCancelled {
                if case .playing = self.playbackState {
                    self.updateRenderedPositionSnapshot()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        syncTeardownSnapshot()
    }

    private func updateRenderedPositionSnapshot() {
        guard let info = streamInfo else { return }
        let rendered = max(0, transport.currentRenderedFramesSinceReset() - transportFrameOriginOffset)
        let frame = min(max(0, seekAnchorFrame + rendered), max(0, totalFrames))
        position = try? SourceFrameTime(frame: frame, sampleRate: info.sampleRate)
    }

    private func handleEngineConfigChange() {
        if case .playing = playbackState {
            pause()
        }
    }
}

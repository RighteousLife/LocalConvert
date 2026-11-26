import Foundation
import Combine
import CoreAudio
import os

@MainActor
final class PlaybackCoordinator: ObservableObject {
    let engine: AudioLibraryPlayerEngine
    let queueManager: PlaybackQueueManager
    let persistence: PlaybackStatePersistence
    let outputDeviceMonitor: CoreAudioOutputDeviceMonitor
    let arbitrationCenter: PlaybackArbitrationCenter
    private let database: AudioLibraryDatabase

    @Published private(set) var currentTrack: AudioLibraryRecord?
    @Published private(set) var queueRecords: [AudioLibraryRecord] = []
    @Published private(set) var lastErrorMessage: String?

    private var cancellables: Set<AnyCancellable> = []
    private var persistenceTask: Task<Void, Never>?
    private var arbitrationToken: PlaybackArbitrationRegistrationToken?
    private var supersededByArbitrationDuringLoad = false
    private let arbitrationCleanupLock: OSAllocatedUnfairLock<(center: PlaybackArbitrationCenter, token: PlaybackArbitrationRegistrationToken?)>
    private let scopedURLLock = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let preloadedScopedURLLock = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private var preloadCoordinatorTask: Task<Void, Never>?

    deinit {
        preloadCoordinatorTask?.cancel()
        let arb = arbitrationCleanupLock.withLock { state -> (center: PlaybackArbitrationCenter, token: PlaybackArbitrationRegistrationToken?) in
            let copy = state
            state.token = nil
            return copy
        }
        if let token = arb.token {
            let center = arb.center
            Task { @MainActor in
                center.unregisterClient(token)
            }
        }
        let url = scopedURLLock.withLock { u -> URL? in
            let copy = u
            u = nil
            return copy
        }
        url?.stopAccessingSecurityScopedResource()
        let preURL = preloadedScopedURLLock.withLock { u -> URL? in
            let copy = u
            u = nil
            return copy
        }
        preURL?.stopAccessingSecurityScopedResource()
    }

    init(
        database: AudioLibraryDatabase,
        engine: AudioLibraryPlayerEngine? = nil,
        queueManager: PlaybackQueueManager = PlaybackQueueManager(),
        persistence: PlaybackStatePersistence = PlaybackStatePersistence(),
        outputDeviceMonitor: CoreAudioOutputDeviceMonitor = CoreAudioOutputDeviceMonitor(),
        arbitrationCenter: PlaybackArbitrationCenter = .shared
    ) {
        self.database = database
        self.engine = engine ?? AudioLibraryPlayerEngine()
        self.queueManager = queueManager
        self.persistence = persistence
        self.outputDeviceMonitor = outputDeviceMonitor
        self.arbitrationCenter = arbitrationCenter
        self.arbitrationCleanupLock = OSAllocatedUnfairLock(initialState: (center: arbitrationCenter, token: nil))

        self.engine.onTrackEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleNaturalTrackCompletion()
            }
        }

        self.engine.onGaplessTrackTransitioned = { [weak self] transitionedID in
            Task { @MainActor [weak self] in
                await self?.handleGaplessTrackTransitioned(to: transitionedID)
            }
        }

        let registeredToken = arbitrationCenter.registerClient(.audioLibraryPlayer) { [weak self] in
            self?.pauseFromArbitration()
        }
        self.arbitrationToken = registeredToken
        self.arbitrationCleanupLock.withLock { $0.token = registeredToken }

        self.outputDeviceMonitor.onActiveDeviceDisconnected = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                await self?.handleActiveOutputDeviceDisconnected()
            }
        }

        self.outputDeviceMonitor.onDefaultDeviceChanged = { [weak self] newDefault in
            Task { @MainActor [weak self] in
                await self?.handleDefaultOutputDeviceChanged(newDefault)
            }
        }

        self.outputDeviceMonitor.onActiveDeviceSampleRateChanged = { [weak self] device in
            Task { @MainActor [weak self] in
                await self?.handleActiveDeviceSampleRateChanged(device)
            }
        }

        self.engine.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.queueManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.outputDeviceMonitor.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Output Device Routing

    var availableOutputDevices: [AudioOutputDevice] {
        outputDeviceMonitor.availableDevices
    }

    var selectedOutputDeviceUID: String? {
        outputDeviceMonitor.selectedDeviceUID
    }

    var activeOutputDevice: AudioOutputDevice? {
        outputDeviceMonitor.activeOutputDevice
    }

    @discardableResult
    func selectOutputDevice(uid: String?) async -> Bool {
        lastErrorMessage = nil
        guard outputDeviceMonitor.selectDevice(uid: uid) else {
            lastErrorMessage = "Selected audio output device is unavailable."
            return false
        }

        let targetDeviceID: AudioDeviceID? = uid.flatMap { _ in
            outputDeviceMonitor.activeOutputDevice?.deviceID
        }

        do {
            try await engine.setOutputDevice(deviceID: targetDeviceID)
            schedulePersistSession()
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Restoration (Never Auto-Plays on Relaunch)

    func restoreSavedSessionIfPresent() async {
        guard let restored = await persistence.loadRestoredState() else { return }
        outputDeviceMonitor.refreshDevices()

        let savedUID = restored.session.outputDeviceUID
        var fellBackToSystemDefault = false
        if let savedUID {
            if outputDeviceMonitor.selectDevice(uid: savedUID),
               let device = outputDeviceMonitor.activeOutputDevice {
                do {
                    try await engine.setOutputDevice(deviceID: device.deviceID)
                } catch {
                    lastErrorMessage = error.localizedDescription
                }
            } else {
                _ = outputDeviceMonitor.selectDevice(uid: nil)
                if outputDeviceMonitor.defaultDevice != nil {
                    do {
                        try await engine.setOutputDevice(deviceID: nil)
                    } catch {
                        lastErrorMessage = error.localizedDescription
                    }
                }
                fellBackToSystemDefault = true
            }
        } else {
            _ = outputDeviceMonitor.selectDevice(uid: nil)
        }

        queueManager.restore(queue: restored.queue)
        engine.setVolume(restored.session.volume)
        engine.setMuted(restored.session.isMuted)
        engine.setPlaybackRate(restored.session.playbackRate)
        await refreshQueueRecordSnapshots()

        guard let activeID = restored.session.activeAssetID ?? queueManager.currentTrackID else {
            if fellBackToSystemDefault {
                try? await persistence.save(queue: queueManager.queue, session: currentSessionSnapshot())
            }
            return
        }
        if let rec = try? await database.fetchAsset(id: activeID) {
            currentTrack = rec
            let url = resolvePlayableURL(for: rec.asset)
            if FileManager.default.fileExists(atPath: url.path) {
                try? await engine.load(url: url, assetID: rec.asset.id, fileFormat: rec.asset.fileFormat, autoPlay: false)
                if let savedPos = restored.session.position, savedPos.frame > 0 {
                    await engine.restorePausedPositionIfLoaded(savedPos.raw.derivedSeconds)
                }
            }
        }

        if fellBackToSystemDefault {
            try? await persistence.save(queue: queueManager.queue, session: currentSessionSnapshot())
        }
    }

    // MARK: - Play & Queue Operations

    func playTrack(_ record: AudioLibraryRecord, withinRecords collection: [AudioLibraryRecord]? = nil) async {
        let contextList = (collection?.isEmpty == false) ? collection! : [record]
        let ids = contextList.map(\.asset.id)
        let idx = contextList.firstIndex(where: { $0.asset.id == record.asset.id }) ?? 0
        queueManager.setQueue(trackIDs: ids, startIndex: idx)
        await refreshQueueRecordSnapshots()
        await loadAndPlayCurrentQueueTrack()
    }

    func playQueue(records: [AudioLibraryRecord], startAt index: Int = 0) async {
        guard !records.isEmpty else { return }
        queueManager.setQueue(trackIDs: records.map(\.asset.id), startIndex: index)
        await refreshQueueRecordSnapshots()
        await loadAndPlayCurrentQueueTrack()
    }

    func enqueueNext(_ record: AudioLibraryRecord) async {
        queueManager.playNext(record.asset.id)
        await refreshQueueRecordSnapshots()
        await refreshPreloadIfNeeded()
        schedulePersistSession()
    }

    func enqueue(_ records: [AudioLibraryRecord]) async {
        let wasEmpty = queueManager.orderedTrackIDs.isEmpty
        queueManager.enqueue(records.map(\.asset.id))
        await refreshQueueRecordSnapshots()
        if wasEmpty {
            await loadAndPlayCurrentQueueTrack()
        } else {
            await refreshPreloadIfNeeded()
            schedulePersistSession()
        }
    }

    func selectQueueIndex(_ index: Int) async {
        guard queueManager.selectTrack(at: index) != nil else { return }
        await loadAndPlayCurrentQueueTrack()
    }

    func removeQueueEntry(at index: Int) async {
        let result = queueManager.remove(at: index)
        await refreshQueueRecordSnapshots()
        if result.removedCurrent {
            if result.replacementID != nil {
                await loadAndPlayCurrentQueueTrack()
            } else {
                await stop()
            }
        } else {
            await refreshPreloadIfNeeded()
            schedulePersistSession()
        }
    }

    func moveQueueEntries(fromOffsets source: IndexSet, toOffset destination: Int) async {
        queueManager.move(fromOffsets: source, toOffset: destination)
        await refreshQueueRecordSnapshots()
        await refreshPreloadIfNeeded()
        schedulePersistSession()
    }

    func clearQueue() async {
        queueManager.clear()
        await refreshQueueRecordSnapshots()
        await stop()
    }

    func unregisterFromArbitration() {
        let token = arbitrationCleanupLock.withLock { state -> PlaybackArbitrationRegistrationToken? in
            let copy = state.token
            state.token = nil
            return copy
        }
        arbitrationToken = nil
        if let token {
            arbitrationCenter.unregisterClient(token)
        }
    }

    // MARK: - Transport Actions

    func togglePlayPause() async {
        do {
            if engine.streamInfo == nil, let curID = queueManager.currentTrackID {
                await loadTrack(assetID: curID, autoPlay: true)
                return
            }
            let willStart: Bool
            switch engine.playbackState {
            case .paused, .stopped, .error:
                willStart = true
            case .playing, .loading:
                willStart = false
            }
            if willStart {
                supersededByArbitrationDuringLoad = false
                arbitrationCenter.notifyPlaybackStarted(by: .audioLibraryPlayer)
            }
            try engine.togglePlayPause()
            if case .playing = engine.playbackState {
                await preloadNextTrackIfAvailable()
            }
            schedulePersistSession()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func pause() {
        engine.pause()
        schedulePersistSession()
    }

    func stop() async {
        supersededByArbitrationDuringLoad = false
        preloadCoordinatorTask?.cancel()
        preloadCoordinatorTask = nil
        await engine.unload()
        releaseScopedAccess()
        releasePreloadedScopedAccess()
        currentTrack = nil
        schedulePersistSession()
    }

    func next() async {
        guard let nextID = queueManager.stepNext() else {
            await stop()
            return
        }
        await loadTrack(assetID: nextID, autoPlay: true)
    }

    func previous() async {
        switch queueManager.stepPrevious(elapsedSeconds: engine.currentSeconds) {
        case .restartCurrent:
            try? await engine.seek(toSeconds: 0)
            if case .paused = engine.playbackState {
                supersededByArbitrationDuringLoad = false
                arbitrationCenter.notifyPlaybackStarted(by: .audioLibraryPlayer)
                try? engine.play()
                await preloadNextTrackIfAvailable()
            }
            schedulePersistSession()
        case .loadTrack(let prevID):
            await loadTrack(assetID: prevID, autoPlay: true)
        case .stop:
            await stop()
        }
    }

    func seek(toSeconds seconds: Double) async {
        do {
            try await engine.seek(toSeconds: seconds)
            await refreshPreloadIfNeeded()
            schedulePersistSession()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func seek(to frameTime: SourceFrameTime) async {
        do {
            try await engine.seek(to: frameTime)
            await refreshPreloadIfNeeded()
            schedulePersistSession()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func setVolume(_ vol: Double) {
        engine.setVolume(vol)
        schedulePersistSession()
    }

    func toggleMute() {
        engine.toggleMute()
        schedulePersistSession()
    }

    func setPlaybackRate(_ rate: Double) {
        engine.setPlaybackRate(rate)
        schedulePersistSession()
    }

    func cycleRepeatMode() {
        queueManager.cycleRepeatMode()
        schedulePreloadRefreshTask()
        schedulePersistSession()
    }

    func toggleShuffle() {
        queueManager.setShuffleEnabled(!queueManager.queue.isShuffleEnabled)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshQueueRecordSnapshots()
            await self.refreshPreloadIfNeeded()
        }
        schedulePersistSession()
    }

    func flushPersistedSession() async {
        persistenceTask?.cancel()
        try? await persistence.save(queue: queueManager.queue, session: currentSessionSnapshot())
    }

    // MARK: - Internal Coordination & Error/Missing-File Handling

    private func handleActiveOutputDeviceDisconnected() async {
        lastErrorMessage = nil
        if outputDeviceMonitor.defaultDevice != nil {
            do {
                try await engine.setOutputDevice(deviceID: nil)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        } else {
            await engine.stop()
        }
        schedulePersistSession()
    }

    private func handleDefaultOutputDeviceChanged(_ newDefault: AudioOutputDevice?) async {
        guard outputDeviceMonitor.selectedDeviceUID == nil,
              newDefault != nil else { return }
        do {
            try await engine.setOutputDevice(deviceID: nil)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func handleActiveDeviceSampleRateChanged(_ device: AudioOutputDevice) async {
        guard engine.streamInfo != nil else { return }
        let targetID: AudioDeviceID? = outputDeviceMonitor.selectedDeviceUID == nil ? nil : device.deviceID
        do {
            try await engine.setOutputDevice(deviceID: targetID)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func currentSessionSnapshot() -> PlaybackSession {
        let selectedUID = outputDeviceMonitor.selectedDeviceUID
        let deviceName: String
        if let selectedUID,
           let matched = outputDeviceMonitor.availableDevices.first(where: { $0.uid == selectedUID }) {
            deviceName = matched.name
        } else {
            deviceName = "System Default"
        }
        return engine.snapshotSession(outputDeviceUID: selectedUID, outputDeviceName: deviceName)
    }

    private func handleNaturalTrackCompletion() async {
        releasePreloadedScopedAccess()
        guard let nextID = queueManager.advanceOnTrackEnd() else {
            schedulePersistSession()
            return
        }
        await loadTrack(assetID: nextID, autoPlay: true)
    }

    private func handleGaplessTrackTransitioned(to transitionedID: UUID) async {
        guard queueManager.commitGaplessAdvance(to: transitionedID) else {
            releasePreloadedScopedAccess()
            await loadAndPlayCurrentQueueTrack()
            return
        }

        let promotedURL = preloadedScopedURLLock.withLock { u -> URL? in
            let copy = u
            u = nil
            return copy
        }
        let prevURL = scopedURLLock.withLock { u -> URL? in
            let copy = u
            u = promotedURL
            return copy
        }
        if let prevURL, prevURL != promotedURL {
            prevURL.stopAccessingSecurityScopedResource()
        }

        try? await database.recordPlayback(assetID: transitionedID)
        if let rec = try? await database.fetchAsset(id: transitionedID) {
            currentTrack = rec
        }
        schedulePersistSession()
        await preloadNextTrackIfAvailable()
    }

    private func schedulePreloadRefreshTask() {
        preloadCoordinatorTask?.cancel()
        preloadCoordinatorTask = Task { @MainActor [weak self] in
            await self?.refreshPreloadIfNeeded()
        }
    }

    private func refreshPreloadIfNeeded() async {
        guard case .playing = engine.playbackState else {
            engine.clearPreloadedNextTrack()
            releasePreloadedScopedAccess()
            return
        }
        await preloadNextTrackIfAvailable()
    }

    private func preloadNextTrackIfAvailable() async {
        guard case .playing = engine.playbackState,
              let nextID = queueManager.peekNextTrackID() else {
            engine.clearPreloadedNextTrack()
            releasePreloadedScopedAccess()
            return
        }

        if engine.preloadedAssetID == nextID {
            return
        }

        releasePreloadedScopedAccess()
        guard let rec = try? await database.fetchAsset(id: nextID) else {
            engine.clearPreloadedNextTrack()
            return
        }
        let url = resolvePlayableURL(for: rec.asset)
        if url.startAccessingSecurityScopedResource() {
            preloadedScopedURLLock.withLock { $0 = url }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            releasePreloadedScopedAccess()
            engine.clearPreloadedNextTrack()
            return
        }
        engine.preloadNextTrack(url: url, assetID: rec.asset.id, fileFormat: rec.asset.fileFormat)
    }

    private func loadAndPlayCurrentQueueTrack() async {
        guard let id = queueManager.currentTrackID else {
            await stop()
            return
        }
        await loadTrack(assetID: id, autoPlay: true)
    }

    private func pauseFromArbitration() {
        supersededByArbitrationDuringLoad = true
        pause()
    }

    private func loadTrack(assetID: UUID, autoPlay: Bool) async {
        lastErrorMessage = nil
        preloadCoordinatorTask?.cancel()
        preloadCoordinatorTask = nil
        releasePreloadedScopedAccess()

        guard let rec = try? await database.fetchAsset(id: assetID) else {
            lastErrorMessage = "Selected track no longer exists in the library."
            return
        }
        currentTrack = rec

        releaseScopedAccess()
        let url = resolvePlayableURL(for: rec.asset)
        if url.startAccessingSecurityScopedResource() {
            scopedURLLock.withLock { $0 = url }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            releaseScopedAccess()
            try? await database.markAssetsStatus(ids: [rec.asset.id], status: .missing)
            let msg = "Track file is missing from disk: \(rec.asset.displayFilename)"
            lastErrorMessage = msg
            StructuredDiagnostics.recordAudioEvent(
                category: .audioPlayer,
                severity: .validation,
                stage: "missing_source",
                assetID: rec.asset.id,
                fileExtension: rec.asset.fileExtension,
                message: "Audio playback skipped because source file is missing."
            )
            schedulePersistSession()
            return
        }

        if autoPlay {
            supersededByArbitrationDuringLoad = false
            arbitrationCenter.notifyPlaybackStarted(by: .audioLibraryPlayer)
        }

        do {
            try await engine.load(url: url, assetID: rec.asset.id, fileFormat: rec.asset.fileFormat, autoPlay: false)
            if autoPlay && !supersededByArbitrationDuringLoad {
                arbitrationCenter.notifyPlaybackStarted(by: .audioLibraryPlayer)
                try engine.play()
                try? await database.recordPlayback(assetID: rec.asset.id)
                if let refreshed = try? await database.fetchAsset(id: rec.asset.id) {
                    currentTrack = refreshed
                }
                await preloadNextTrackIfAvailable()
            }
            schedulePersistSession()
        } catch is CancellationError {
            return
        } catch {
            releaseScopedAccess()
            lastErrorMessage = error.localizedDescription
            schedulePersistSession()
        }
    }

    private func releaseScopedAccess() {
        let prev = scopedURLLock.withLock { u -> URL? in
            let copy = u
            u = nil
            return copy
        }
        prev?.stopAccessingSecurityScopedResource()
    }

    private func releasePreloadedScopedAccess() {
        let prev = preloadedScopedURLLock.withLock { u -> URL? in
            let copy = u
            u = nil
            return copy
        }
        let activeURL = scopedURLLock.withLock { $0 }
        if let prev, prev != activeURL {
            prev.stopAccessingSecurityScopedResource()
        }
    }

    private func resolvePlayableURL(for asset: AudioAsset) -> URL {
        if let bookmarkData = asset.bookmarkData,
           let resolved = AudioLibraryBookmarkHelper.resolveBookmark(bookmarkData),
           FileManager.default.fileExists(atPath: resolved.url.path) {
            return resolved.url
        }
        return URL(fileURLWithPath: asset.canonicalPath)
    }

    private func refreshQueueRecordSnapshots() async {
        let all = (try? await database.fetchAllAssets()) ?? []
        let map = Dictionary(all.map { ($0.asset.id, $0) }, uniquingKeysWith: { first, _ in first })
        queueRecords = queueManager.orderedTrackIDs.compactMap { map[$0] }
    }

    private func schedulePersistSession() {
        persistenceTask?.cancel()
        let queueSnapshot = queueManager.queue
        let sessionSnapshot = currentSessionSnapshot()
        let store = persistence
        persistenceTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? await store.save(queue: queueSnapshot, session: sessionSnapshot)
        }
    }
}

import XCTest
import CoreAudio
import AVFoundation
@testable import LocalConvert

// MARK: - Stage 1 Mock CoreAudio HAL Backend

/// Synchronization invariant: all mutable device/listener state is guarded by `lock`.
private final class MockCoreAudioHALBackend: CoreAudioHALBackend, @unchecked Sendable {
    struct DeviceRecord {
        var deviceID: AudioDeviceID
        var uid: String?
        var name: String?
        var outputChannels: Int
        var isAlive: Bool
        var sampleRate: Double?
    }

    private struct ListenerRegistration {
        let token: CoreAudioListenerToken
        let handler: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var devices: [AudioDeviceID: DeviceRecord] = [:]
    private var defaultOutputID: AudioDeviceID?
    private var activeListeners: [UUID: ListenerRegistration] = [:]
    private var totalAddedCount = 0
    private var totalRemovedCount = 0

    func setDevices(_ records: [DeviceRecord], defaultID: AudioDeviceID?) {
        lock.lock()
        devices = Dictionary(uniqueKeysWithValues: records.map { ($0.deviceID, $0) })
        defaultOutputID = defaultID
        lock.unlock()
    }

    func updateDevice(_ id: AudioDeviceID, _ transform: (inout DeviceRecord) -> Void) {
        lock.lock()
        if var existing = devices[id] {
            transform(&existing)
            devices[id] = existing
        }
        lock.unlock()
    }

    func removeDevice(_ id: AudioDeviceID) {
        lock.lock()
        devices.removeValue(forKey: id)
        if defaultOutputID == id {
            defaultOutputID = devices.keys.sorted().first
        }
        lock.unlock()
    }

    func setDefaultOutputID(_ id: AudioDeviceID?) {
        lock.lock()
        defaultOutputID = id
        lock.unlock()
    }

    func triggerPropertyChange(objectID: AudioObjectID? = nil, selector: AudioObjectPropertySelector? = nil) {
        lock.lock()
        let matches = activeListeners.values.filter { reg in
            (objectID == nil || reg.token.objectID == objectID) &&
            (selector == nil || reg.token.selector == selector)
        }.map(\.handler)
        lock.unlock()

        for handler in matches {
            handler()
        }
    }

    func listenerMetrics() -> (active: Int, added: Int, removed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (activeListeners.count, totalAddedCount, totalRemovedCount)
    }

    // MARK: CoreAudioHALBackend

    func allDeviceIDs() -> [AudioDeviceID] {
        lock.lock()
        defer { lock.unlock() }
        return Array(devices.keys).sorted()
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        return defaultOutputID
    }

    func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return devices[deviceID]?.outputChannels ?? 0
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return devices[deviceID]?.isAlive ?? false
    }

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return devices[deviceID]?.uid
    }

    func deviceName(for deviceID: AudioDeviceID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return devices[deviceID]?.name
    }

    func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return devices[deviceID]?.sampleRate
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        let token = CoreAudioListenerToken(id: UUID(), objectID: objectID, selector: selector, scope: scope)
        lock.lock()
        activeListeners[token.id] = ListenerRegistration(token: token, handler: handler)
        totalAddedCount += 1
        lock.unlock()
        return token
    }

    func removePropertyListener(_ token: CoreAudioListenerToken) {
        lock.lock()
        if activeListeners.removeValue(forKey: token.id) != nil {
            totalRemovedCount += 1
        }
        lock.unlock()
    }
}

// MARK: - Stage 2 Mock Routing Playback Transport

@MainActor
private final class MockRoutingPlaybackTransport: AudioPlaybackTransportProtocol {
    var configuredSampleRate: Double = 0
    var configuredChannelCount: Int = 0
    var routedDeviceIDs: [AudioDeviceID?] = []
    var shouldFailNextSetDevice = false
    var shouldFailNextStartEngine = false
    var isEngineRunning = false
    var isNodePlaying = false
    var volume: Float = 1.0
    var rate: Float = 1.0
    var resetCount = 0
    var scheduledItems: [(frameCount: Int, completion: @MainActor () -> Void)] = []
    var renderedFramesSinceReset: Int64 = 0

    func configure(sampleRate: Double, channelCount: Int) throws {
        configuredSampleRate = sampleRate
        configuredChannelCount = channelCount
    }

    func setOutputDevice(deviceID: AudioDeviceID?) throws {
        routedDeviceIDs.append(deviceID)
        if shouldFailNextSetDevice {
            shouldFailNextSetDevice = false
            throw AudioPlaybackError.engineStartFailed("Simulated CoreAudio device routing failure")
        }
    }

    func startEngine() throws {
        if shouldFailNextStartEngine {
            shouldFailNextStartEngine = false
            throw AudioPlaybackError.engineStartFailed("Simulated AVAudioEngine start failure")
        }
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
        scheduledItems.append((chunk.frameCount, onRendered))
    }

    func currentRenderedFramesSinceReset() -> Int64 {
        renderedFramesSinceReset
    }
}

// MARK: - Phase 64 Test Suite

final class Phase64AudioPlayerTests: XCTestCase {
    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase64Player-\(UUID().uuidString)")
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
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Stage 1 Tests: CoreAudioOutputDeviceMonitor

    @MainActor
    func testCoreAudioMonitorFilteringEnumerationDefaultDisconnectAndListenerLifecycle() async throws {
        let hal = MockCoreAudioHALBackend()
        hal.setDevices([
            .init(deviceID: 10, uid: "uid-speakers", name: "Built-In Speakers", outputChannels: 2, isAlive: true, sampleRate: 48_000),
            .init(deviceID: 11, uid: "uid-usb-dac", name: "USB Reference DAC", outputChannels: 2, isAlive: true, sampleRate: 96_000),
            .init(deviceID: 12, uid: "uid-mic", name: "Input Microphone", outputChannels: 0, isAlive: true, sampleRate: 48_000),
            .init(deviceID: 13, uid: "uid-dead", name: "Dead Output", outputChannels: 2, isAlive: false, sampleRate: 48_000),
            .init(deviceID: 14, uid: "uid-badrate", name: "Invalid Sample Rate", outputChannels: 2, isAlive: true, sampleRate: nil),
            .init(deviceID: 15, uid: nil, name: "Missing UID", outputChannels: 2, isAlive: true, sampleRate: 44_100)
        ], defaultID: 10)

        var disconnectEvents: [(String, String?)] = []
        var defaultChanges: [String?] = []
        var sampleRateChanges: [(String, Double)] = []

        var monitor: CoreAudioOutputDeviceMonitor? = CoreAudioOutputDeviceMonitor(backend: hal)
        monitor?.onActiveDeviceDisconnected = { uid, fallback in
            disconnectEvents.append((uid, fallback?.uid))
        }
        monitor?.onDefaultDeviceChanged = { next in
            defaultChanges.append(next?.uid)
        }
        monitor?.onActiveDeviceSampleRateChanged = { device in
            sampleRateChanges.append((device.uid, device.nominalSampleRateHz))
        }

        // Before startMonitoring(): filtered enumeration only, 0 listeners
        XCTAssertEqual(monitor?.availableDevices.map(\.uid), ["uid-speakers", "uid-usb-dac"])
        XCTAssertEqual(monitor?.defaultDevice?.uid, "uid-speakers")
        XCTAssertEqual(hal.listenerMetrics().active, 0)

        monitor?.startMonitoring()
        monitor?.startMonitoring() // idempotent check
        XCTAssertEqual(monitor?.isMonitoring, true)
        let startedMetrics = hal.listenerMetrics()
        XCTAssertGreaterThan(startedMetrics.active, 0)

        // Device selection & invalid UID rejection
        XCTAssertFalse(monitor?.selectDevice(uid: "uid-nonexistent") ?? true)
        XCTAssertTrue(monitor?.selectDevice(uid: "uid-usb-dac") ?? false)
        XCTAssertEqual(monitor?.activeOutputDevice?.uid, "uid-usb-dac")
        XCTAssertEqual(monitor?.activeOutputDevice?.nominalSampleRateHz, 96_000)

        // Active device sample-rate change notification
        hal.updateDevice(11) { $0.sampleRate = 192_000 }
        hal.triggerPropertyChange(objectID: 11, selector: kAudioDevicePropertyNominalSampleRate)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sampleRateChanges.count, 1)
        XCTAssertEqual(sampleRateChanges.first?.0, "uid-usb-dac")
        XCTAssertEqual(sampleRateChanges.first?.1, 192_000)

        // Default output device switch notification
        hal.setDefaultOutputID(11)
        hal.triggerPropertyChange(selector: kAudioHardwarePropertyDefaultOutputDevice)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(monitor?.defaultDevice?.uid, "uid-usb-dac")
        XCTAssertEqual(defaultChanges.last ?? nil, "uid-usb-dac")

        // Switch default back to speakers, then hot-unplug active USB DAC -> fallback to system default
        hal.setDefaultOutputID(10)
        hal.triggerPropertyChange(selector: kAudioHardwarePropertyDefaultOutputDevice)
        try await Task.sleep(for: .milliseconds(50))

        hal.removeDevice(11)
        hal.triggerPropertyChange(selector: kAudioHardwarePropertyDevices)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(monitor?.selectedDeviceUID)
        XCTAssertEqual(monitor?.activeOutputDevice?.uid, "uid-speakers")
        XCTAssertEqual(disconnectEvents.count, 1)
        XCTAssertEqual(disconnectEvents.first?.0, "uid-usb-dac")
        XCTAssertEqual(disconnectEvents.first?.1, "uid-speakers")

        // Stop monitoring removes all registered listeners symmetrically
        monitor?.stopMonitoring()
        XCTAssertEqual(monitor?.isMonitoring, false)
        let stoppedMetrics = hal.listenerMetrics()
        XCTAssertEqual(stoppedMetrics.active, 0)
        XCTAssertEqual(stoppedMetrics.added, stoppedMetrics.removed)

        // Deinit cleanup removes listeners even if caller didn't call stopMonitoring explicitly
        monitor?.startMonitoring()
        XCTAssertGreaterThan(hal.listenerMetrics().active, 0)
        monitor = nil
        let afterDeinit = hal.listenerMetrics()
        XCTAssertEqual(afterDeinit.active, 0)
        XCTAssertEqual(afterDeinit.added, afterDeinit.removed)
    }

    @MainActor
    func testLiveHostCoreAudioReadOnlyEnumerationSmoke() {
        let monitor = CoreAudioOutputDeviceMonitor()
        monitor.startMonitoring()
        monitor.refreshDevices()

        for device in monitor.availableDevices {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertGreaterThan(device.outputChannelCount, 0)
            XCTAssertGreaterThan(device.nominalSampleRateHz, 0)
            XCTAssertTrue(device.nominalSampleRateHz.isFinite)
        }

        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isMonitoring)
    }

    // MARK: - Stage 2 Tests: AVAudioEngine Output Device Routing & Session Persistence

    @MainActor
    func testOutputDeviceSelectionSystemDefaultPersistenceRestorationAndFallback() async throws {
        let folder = sandbox.temporaryURL.appendingPathComponent("RoutingLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wavURL = folder.appendingPathComponent("reference_tone.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 48_000)
        )

        let hal1 = MockCoreAudioHALBackend()
        hal1.setDevices([
            .init(deviceID: 100, uid: "uid-speakers", name: "Built-In Speakers", outputChannels: 2, isAlive: true, sampleRate: 48_000),
            .init(deviceID: 200, uid: "uid-studio-dac", name: "Studio USB DAC", outputChannels: 2, isAlive: true, sampleRate: 96_000)
        ], defaultID: 100)

        let transport1 = MockRoutingPlaybackTransport()
        let monitor1 = CoreAudioOutputDeviceMonitor(backend: hal1)
        let coord1 = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport1,
            outputDeviceMonitor: monitor1
        )
        await coord1.ensureInitialized()
        await coord1.libraryStore.addFolderAndScan(url: folder)
        let track = try XCTUnwrap(coord1.libraryStore.displayedRecords.first)

        await coord1.playbackCoordinator.playTrack(track)
        XCTAssertEqual(coord1.playbackCoordinator.engine.playbackState, .playing)

        // 1. Select Studio DAC -> routes transport to deviceID 200 and preserves playing state
        let didSelectDAC = await coord1.playbackCoordinator.selectOutputDevice(uid: "uid-studio-dac")
        XCTAssertTrue(didSelectDAC)
        XCTAssertEqual(transport1.routedDeviceIDs.last ?? nil, 200)
        XCTAssertEqual(coord1.playbackCoordinator.selectedOutputDeviceUID, "uid-studio-dac")
        XCTAssertEqual(coord1.playbackCoordinator.engine.playbackState, .playing)

        // Flush session and verify real device UID & name persisted on disk
        await coord1.playbackCoordinator.flushPersistedSession()
        let persistence = PlaybackStatePersistence(stateFileURL: AppStoragePaths.audioPlayerStateURL)
        let persisted = await persistence.loadRestoredState()
        XCTAssertEqual(persisted?.session.outputDeviceUID, "uid-studio-dac")
        XCTAssertEqual(persisted?.session.outputDeviceName, "Studio USB DAC")

        // Switch back to System Default -> passes `nil` default routing instruction
        let didSelectDefault = await coord1.playbackCoordinator.selectOutputDevice(uid: nil)
        XCTAssertTrue(didSelectDefault)
        XCTAssertEqual(transport1.routedDeviceIDs.count >= 2, true)
        XCTAssertNil(transport1.routedDeviceIDs.last ?? AudioDeviceID(999))
        XCTAssertNil(coord1.playbackCoordinator.selectedOutputDeviceUID)

        // Switch back to DAC and flush before relaunch test
        _ = await coord1.playbackCoordinator.selectOutputDevice(uid: "uid-studio-dac")
        await coord1.playbackCoordinator.flushPersistedSession()
        monitor1.stopMonitoring()
        await coord1.playbackCoordinator.engine.unload()

        // 2. Relaunch WITH Studio DAC present (even with changed transient AudioDeviceID 305) -> resolves UID without autoplay
        let hal2 = MockCoreAudioHALBackend()
        hal2.setDevices([
            .init(deviceID: 100, uid: "uid-speakers", name: "Built-In Speakers", outputChannels: 2, isAlive: true, sampleRate: 48_000),
            .init(deviceID: 305, uid: "uid-studio-dac", name: "Studio USB DAC", outputChannels: 2, isAlive: true, sampleRate: 96_000)
        ], defaultID: 100)
        let transport2 = MockRoutingPlaybackTransport()
        let monitor2 = CoreAudioOutputDeviceMonitor(backend: hal2)
        let coord2 = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport2,
            outputDeviceMonitor: monitor2
        )
        await coord2.ensureInitialized()
        XCTAssertEqual(coord2.playbackCoordinator.selectedOutputDeviceUID, "uid-studio-dac")
        XCTAssertEqual(transport2.routedDeviceIDs.last ?? nil, 305)
        XCTAssertEqual(coord2.playbackCoordinator.engine.playbackState, .paused)
        XCTAssertFalse(transport2.isNodePlaying)
        monitor2.stopMonitoring()
        await coord2.playbackCoordinator.engine.unload()

        // 3. Relaunch with saved DAC missing -> falls back to System Default without autoplay and updates persisted session
        let hal3 = MockCoreAudioHALBackend()
        hal3.setDevices([
            .init(deviceID: 100, uid: "uid-speakers", name: "Built-In Speakers", outputChannels: 2, isAlive: true, sampleRate: 48_000)
        ], defaultID: 100)
        let transport3 = MockRoutingPlaybackTransport()
        let monitor3 = CoreAudioOutputDeviceMonitor(backend: hal3)
        let coord3 = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport3,
            outputDeviceMonitor: monitor3
        )
        await coord3.ensureInitialized()
        XCTAssertNil(coord3.playbackCoordinator.selectedOutputDeviceUID)
        XCTAssertTrue(transport3.routedDeviceIDs.contains { $0 == nil })
        XCTAssertEqual(coord3.playbackCoordinator.engine.playbackState, .paused)
        XCTAssertFalse(transport3.isNodePlaying)
        let restoredFallback = await persistence.loadRestoredState()
        XCTAssertNil(restoredFallback?.session.outputDeviceUID)
        XCTAssertEqual(restoredFallback?.session.outputDeviceName, "System Default")

        monitor3.stopMonitoring()
        await coord1.database.close()
        await coord2.database.close()
        await coord3.database.close()
    }

    @MainActor
    func testOutputDeviceDisconnectFallbackAndFailedReconfigurationNeverFalsePlaying() async throws {
        let folder = sandbox.temporaryURL.appendingPathComponent("DisconnectLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wavURL = folder.appendingPathComponent("disconnect_tone.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 48_000)
        )

        let hal = MockCoreAudioHALBackend()
        hal.setDevices([
            .init(deviceID: 10, uid: "uid-speakers", name: "Built-In Speakers", outputChannels: 2, isAlive: true, sampleRate: 48_000),
            .init(deviceID: 20, uid: "uid-headphones", name: "USB Headphones", outputChannels: 2, isAlive: true, sampleRate: 48_000)
        ], defaultID: 10)

        let transport = MockRoutingPlaybackTransport()
        let monitor = CoreAudioOutputDeviceMonitor(backend: hal)
        let coord = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport,
            outputDeviceMonitor: monitor
        )
        await coord.ensureInitialized()
        await coord.libraryStore.addFolderAndScan(url: folder)
        let track = try XCTUnwrap(coord.libraryStore.displayedRecords.first)

        _ = await coord.playbackCoordinator.selectOutputDevice(uid: "uid-headphones")
        await coord.playbackCoordinator.playTrack(track)
        XCTAssertEqual(coord.playbackCoordinator.engine.playbackState, .playing)

        // Hot-unplug headphones mid-playback -> monitor falls back & routes transport to System Default (`nil`)
        hal.removeDevice(20)
        hal.triggerPropertyChange(selector: kAudioHardwarePropertyDevices)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertNil(coord.playbackCoordinator.selectedOutputDeviceUID)
        XCTAssertEqual(transport.routedDeviceIDs.contains { $0 == nil }, true)

        // Simulate failed reconfiguration during device switch -> MUST enter `.error`, NEVER falsely remain `.playing`
        transport.shouldFailNextSetDevice = true
        let failedSwitch = await coord.playbackCoordinator.selectOutputDevice(uid: nil)
        XCTAssertFalse(failedSwitch)
        XCTAssertFalse(transport.isNodePlaying)
        if case .error = coord.playbackCoordinator.engine.playbackState {
            // Expected coherent error state
        } else {
            XCTFail("Expected engine.playbackState == .error on failed device switch, got \(coord.playbackCoordinator.engine.playbackState)")
        }

        monitor.stopMonitoring()
        await coord.database.close()
    }

    // MARK: - Stage 3 Tests: Bidirectional Playback Arbitration & Non-Destructive Preservation

    @MainActor
    func testBidirectionalArbitrationPreservesEditorStateAndLibraryQueue() async throws {
        PlaybackArbitrationCenter.shared.setAutoPauseEnabled(true)
        defer { PlaybackArbitrationCenter.shared.setAutoPauseEnabled(true) }

        let folder = sandbox.temporaryURL.appendingPathComponent("ArbitrationLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let libWavA = folder.appendingPathComponent("lib_a.wav")
        let libWavB = folder.appendingPathComponent("lib_b.wav")
        let editorWav = sandbox.temporaryURL.appendingPathComponent("editor_source.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: libWavA,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 96_000)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: libWavB,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 96_000)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: editorWav,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 96_000)
        )

        // Setup isolated UndoRedoCoordinator + real AudioEditorStore with imported clip
        let undoCoordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.applicationSupportURL.appendingPathComponent("UndoHistory", isDirectory: true),
            artifactManager: RecoveryArtifactManager(
                baseDirectoryURL: sandbox.applicationSupportURL.appendingPathComponent("RecoveryArtifacts", isDirectory: true)
            )
        )
        let editorStore = AudioEditorStore(undoCoordinator: undoCoordinator)
        let builtMediaRef = await AudioEditorStore.buildMediaReference(for: editorWav)
        let mediaRef = try XCTUnwrap(builtMediaRef)
        let trackID = try XCTUnwrap(editorStore.selectedTrackID)
        editorStore.performMutation(type: .clipImport, title: "Import Arbitration Clip") { p in
            AudioEditingService.addClip(&p, asset: mediaRef, trackID: trackID, at: 0) != nil
        }
        let editorContext = OperationContext.audioEditor(projectID: editorStore.project.id)
        for _ in 0..<25 where undoCoordinator.undoEntries(for: editorContext).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        editorStore.timeline.setPlayhead(0.75, maxTime: editorStore.project.duration)
        editorStore.isDirty = false // Simulate clean saved state before arbitration

        let expectedProject = editorStore.project
        let expectedClips = editorStore.project.tracks.flatMap(\.clips)
        let expectedPlayhead = editorStore.timeline.playheadTime
        let expectedUndoEntries = undoCoordinator.undoEntries(for: editorContext)
        XCTAssertEqual(expectedUndoEntries.count, 1)
        let expectedDirty = editorStore.isDirty

        // Setup Audio Workspace Coordinator using shared arbitration center
        let hal = MockCoreAudioHALBackend()
        hal.setDevices([
            .init(deviceID: 1, uid: "uid-main", name: "Built-In Output", outputChannels: 2, isAlive: true, sampleRate: 48_000)
        ], defaultID: 1)
        let libTransport = MockRoutingPlaybackTransport()
        let workspace = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: libTransport,
            outputDeviceMonitor: CoreAudioOutputDeviceMonitor(backend: hal),
            arbitrationCenter: .shared
        )
        defer {
            editorStore.playbackEngine.pause()
            editorStore.playbackEngine.unregisterFromArbitration()
            workspace.playbackCoordinator.unregisterFromArbitration()
            workspace.playbackCoordinator.outputDeviceMonitor.stopMonitoring()
        }

        await workspace.ensureInitialized()
        await workspace.libraryStore.addFolderAndScan(url: folder)
        let records = workspace.libraryStore.displayedRecords
        XCTAssertEqual(records.count, 2)

        // 1. Start Library playback and seek to 0.5s
        await workspace.playbackCoordinator.playQueue(records: records, startAt: 0)
        await workspace.playbackCoordinator.seek(toSeconds: 0.5)
        XCTAssertEqual(workspace.playbackCoordinator.engine.playbackState, .playing)
        let expectedQueueOrder = workspace.playbackCoordinator.queueManager.orderedTrackIDs
        let expectedSeekSeconds = workspace.playbackCoordinator.engine.currentSeconds

        // 2. Start Editor playback -> MUST pause Library non-destructively while keeping queue & seek intact
        editorStore.playFromCurrentPosition()
        XCTAssertEqual(workspace.playbackCoordinator.engine.playbackState, .paused)
        XCTAssertFalse(libTransport.isNodePlaying)
        XCTAssertEqual(workspace.playbackCoordinator.queueManager.orderedTrackIDs, expectedQueueOrder)
        XCTAssertEqual(workspace.playbackCoordinator.engine.currentSeconds, expectedSeekSeconds, accuracy: 0.02)

        // Wait for Editor async audio preparation/play startup (if hardware output permits)
        for _ in 0..<25 {
            if editorStore.playbackEngine.isPlaying || editorStore.playbackEngine.lastError != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        // Record playhead right before arbitration pauses Editor -> pause must NOT reset/move playhead
        let playheadBeforeArbitrationPause = editorStore.timeline.playheadTime

        // 3. Resume Library playback -> MUST pause active Editor non-destructively!
        await workspace.playbackCoordinator.togglePlayPause()
        XCTAssertEqual(workspace.playbackCoordinator.engine.playbackState, .playing)
        XCTAssertFalse(editorStore.playbackEngine.isPlaying)
        XCTAssertFalse(editorStore.playbackEngine.isPreparing)

        // 4. Verify Editor project, clips, playhead, undo history, and isDirty remained 100% untouched by pause
        XCTAssertEqual(editorStore.project, expectedProject)
        XCTAssertEqual(editorStore.project.tracks.flatMap(\.clips), expectedClips)
        XCTAssertEqual(editorStore.timeline.playheadTime, playheadBeforeArbitrationPause, accuracy: 0.005)
        XCTAssertGreaterThanOrEqual(editorStore.timeline.playheadTime, expectedPlayhead - 0.0001)
        XCTAssertEqual(undoCoordinator.undoEntries(for: editorContext).map(\.id), expectedUndoEntries.map(\.id))
        XCTAssertEqual(editorStore.isDirty, expectedDirty)

        await workspace.database.close()
    }

    @MainActor
    func testArbitrationRapidAlternatingDisabledAutoPauseAndUnregistrationLifecycle() async throws {
        let folder = sandbox.temporaryURL.appendingPathComponent("IsolatedArbLib", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wavURL = folder.appendingPathComponent("arb_track.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 48_000)
        )

        let center = PlaybackArbitrationCenter()
        let hal = MockCoreAudioHALBackend()
        hal.setDevices([
            .init(deviceID: 1, uid: "uid-main", name: "Built-In", outputChannels: 2, isAlive: true, sampleRate: 48_000)
        ], defaultID: 1)

        var editorActive = false
        var editorPauseCount = 0
        var editorToken: PlaybackArbitrationRegistrationToken? = center.registerClient(.audioEditor) {
            editorActive = false
            editorPauseCount += 1
        }

        let transport = MockRoutingPlaybackTransport()
        let coord: AudioWorkspaceCoordinator? = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport,
            outputDeviceMonitor: CoreAudioOutputDeviceMonitor(backend: hal),
            arbitrationCenter: center
        )
        let workspace = try XCTUnwrap(coord)
        await workspace.ensureInitialized()
        await workspace.libraryStore.addFolderAndScan(url: folder)
        let track = try XCTUnwrap(workspace.libraryStore.displayedRecords.first)

        // Rapid alternating playback starts with auto-pause ENABLED -> never leaves both active, zero infinite loops
        for i in 0..<6 {
            if i.isMultiple(of: 2) {
                await workspace.playbackCoordinator.playTrack(track)
                XCTAssertFalse(editorActive, "Editor must be paused whenever Library plays")
                XCTAssertEqual(workspace.playbackCoordinator.engine.playbackState, .playing)
            } else {
                editorActive = true
                center.notifyPlaybackStarted(by: .audioEditor)
                XCTAssertNotEqual(workspace.playbackCoordinator.engine.playbackState, .playing, "Library must pause whenever Editor starts")
            }
            let bothActive = editorActive && (workspace.playbackCoordinator.engine.playbackState == .playing)
            XCTAssertFalse(bothActive)
        }

        // Disabled auto-pause allows BOTH playback systems to play simultaneously
        center.setAutoPauseEnabled(false)
        await workspace.playbackCoordinator.playTrack(track)
        editorActive = true
        center.notifyPlaybackStarted(by: .audioEditor)
        XCTAssertTrue(editorActive)
        XCTAssertEqual(workspace.playbackCoordinator.engine.playbackState, .playing)

        // Re-enable auto-pause, verify client unregistration prevents stale callbacks, and verify deinit cleanup
        center.setAutoPauseEnabled(true)
        if let tok = editorToken {
            center.unregisterClient(tok)
            editorToken = nil
        }
        let pausesBefore = editorPauseCount
        await workspace.playbackCoordinator.playTrack(track)
        XCTAssertEqual(editorPauseCount, pausesBefore, "Unregistered client must never receive pause callback")

        // Deallocate client using real AudioPlaybackEngine + isolated center -> weak closure + deinit unregister cleanly
        do {
            var weakEngine: AudioPlaybackEngine? = AudioPlaybackEngine(arbitrationCenter: center)
            XCTAssertNotNil(weakEngine)
            let countWhileAlive = center.registeredClientCount
            XCTAssertGreaterThanOrEqual(countWhileAlive, 2)
            weakEngine = nil
            XCTAssertNil(weakEngine)
        }
        try await Task.sleep(for: .milliseconds(40))
        workspace.playbackCoordinator.unregisterFromArbitration()
        workspace.playbackCoordinator.outputDeviceMonitor.stopMonitoring()
        await workspace.database.close()
        XCTAssertEqual(center.registeredClientCount, 0)
    }
}

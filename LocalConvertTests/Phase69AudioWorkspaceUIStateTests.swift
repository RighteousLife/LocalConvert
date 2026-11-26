import XCTest
import SwiftUI
import AppKit
import Combine
import CoreAudio
import AVFoundation
@testable import LocalConvert

// MARK: - Test Doubles for Stage C UI & Integration

private final class StageCMockHALBackend: CoreAudioHALBackend, @unchecked Sendable {
    struct Entry {
        var deviceID: AudioDeviceID
        var uid: String
        var name: String
        var channels: Int
        var isAlive: Bool
        var sampleRate: Double
    }

    private let lock = NSLock()
    private var entries: [AudioDeviceID: Entry] = [:]
    private var defaultID: AudioDeviceID?
    private var listeners: [UUID: @Sendable () -> Void] = [:]

    func configure(entries: [Entry], defaultID: AudioDeviceID?) {
        lock.lock()
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.deviceID, $0) })
        self.defaultID = defaultID
        lock.unlock()
    }

    func allDeviceIDs() -> [AudioDeviceID] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.keys).sorted()
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        lock.lock(); defer { lock.unlock() }
        return defaultID
    }

    func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries[deviceID]?.channels ?? 0
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[deviceID]?.isAlive ?? false
    }

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[deviceID]?.uid
    }

    func deviceName(for deviceID: AudioDeviceID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[deviceID]?.name
    }

    func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return entries[deviceID]?.sampleRate
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
        listeners[token.id] = handler
        lock.unlock()
        return token
    }

    func removePropertyListener(_ token: CoreAudioListenerToken) {
        lock.lock()
        listeners.removeValue(forKey: token.id)
        lock.unlock()
    }
}

@MainActor
private final class StageCMockTransport: AudioPlaybackTransportProtocol {
    var volume: Float = 1.0
    var rate: Float = 1.0
    var selectedDeviceIDs: [AudioDeviceID?] = []
    var renderedFrames: Int64 = 0

    func configure(sampleRate: Double, channelCount: Int) throws {}
    func setOutputDevice(deviceID: AudioDeviceID?) throws {
        selectedDeviceIDs.append(deviceID)
    }
    func startEngine() throws {}
    func playNode() {}
    func pauseNode() {}
    func stopAndResetNode() {}
    func scheduleChunk(_ chunk: DecodedPCMChunk, onRendered: @escaping @MainActor () -> Void) {
        renderedFrames += Int64(chunk.frameCount)
    }
    func currentRenderedFramesSinceReset() -> Int64 { renderedFrames }
}

// MARK: - Phase 69 Suite

final class Phase69AudioWorkspaceUIStateTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase69-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        MetadataRegistry.shared.register(provider: AudioMetadataProvider())
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

    @MainActor
    private func makeCoordinator(
        hal: StageCMockHALBackend? = nil,
        transport: StageCMockTransport? = nil
    ) -> AudioWorkspaceCoordinator {
        let monitor = hal.map { CoreAudioOutputDeviceMonitor(backend: $0) }
        return AudioWorkspaceCoordinator(
            databaseURL: sandbox.applicationSupportURL.appendingPathComponent("library.sqlite"),
            artworkDirectoryURL: sandbox.cachesURL.appendingPathComponent("artwork", isDirectory: true),
            playerStateURL: sandbox.applicationSupportURL.appendingPathComponent("player_state.json"),
            transport: transport ?? StageCMockTransport(),
            outputDeviceMonitor: monitor
        )
    }

    private func writeWAVFile(
        named filename: String,
        in directory: URL,
        durationSeconds: Double = 1.2,
        sampleRate: Double = 48_000,
        frequency: Double = 440.0
    ) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let frameCount = Int(durationSeconds * sampleRate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buf.frameLength = AVAudioFrameCount(frameCount)
        if let ch = buf.floatChannelData {
            for i in 0..<frameCount {
                let s = Float(0.35 * sin(2.0 * .pi * frequency * Double(i) / sampleRate))
                ch[0][i] = s
                ch[1][i] = s
            }
        }
        try file.write(from: buf)
        return url
    }

    // MARK: - 1. Unified Workspace Shell & Zero View-Update Publishes

    @MainActor
    func testUnifiedWorkspaceShellModesAndZeroViewUpdatePublishes() throws {
        let coordinator = makeCoordinator()
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.temporaryURL.appendingPathComponent("j"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.temporaryURL.appendingPathComponent("a"))
        )
        let editorStore = AudioEditorStore(undoCoordinator: undoCoord)

        var coordPublishes = 0
        let c1 = coordinator.objectWillChange.sink { _ in coordPublishes += 1 }
        var editorPublishes = 0
        let c2 = editorStore.objectWillChange.sink { _ in editorPublishes += 1 }
        defer { c1.cancel(); c2.cancel() }

        let view = AudioWorkspaceRootView(coordinator: coordinator, editorStore: editorStore) {
            Text("Embedded Tools Placeholder")
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(coordPublishes, 0, "AudioWorkspaceRootView layout must not synchronously mutate coordinator state")
        XCTAssertEqual(editorPublishes, 0, "AudioWorkspaceRootView layout must not synchronously mutate editorStore state")

        for mode in AudioWorkspaceMode.allCases {
            coordinator.activeMode = mode
            let beforeCoord = coordPublishes
            let beforeEditor = editorPublishes
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(coordPublishes, beforeCoord, "Switching to \(mode.rawValue) must not cause synchronous re-publish during layout")
            XCTAssertEqual(editorPublishes, beforeEditor)
        }
    }

    // MARK: - 2. MissingFileReconciler: Detection, Bookmark Recovery & Relink

    @MainActor
    func testMissingFileReconcilerDetectionBookmarkRecoveryAndVerifiedRelinkWithoutSourceMutation() async throws {
        let musicDir = sandbox.temporaryURL.appendingPathComponent("Music", isDirectory: true)
        let movedDir = sandbox.temporaryURL.appendingPathComponent("MovedMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: movedDir, withIntermediateDirectories: true)

        let wavURL = try writeWAVFile(named: "track_one.wav", in: musicDir, durationSeconds: 1.0)
        let originalSHA = try MissingFileReconciler.computeFullContentSHA256(url: wavURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: wavURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let coordinator = makeCoordinator()
        let store = coordinator.libraryStore

        let extractor = AudioMetadataExtractor()
        let extracted = try await extractor.extract(url: wavURL, canonicalPath: wavURL.path)
        var asset = extracted.asset
        asset.contentSHA256 = originalSHA
        asset.bookmarkData = nil // Force missing detection without bookmark fallback first
        try await store.database.upsertAssets([AudioLibraryRecord(asset: asset, metadata: extracted.metadata)])

        // 1. Delete original location -> reconciler marks missing
        let relocatedURL = movedDir.appendingPathComponent("track_one_moved.wav")
        try FileManager.default.moveItem(at: wavURL, to: relocatedURL)

        let rawReport1 = await store.reconcileMissingFiles()
        let report1 = try XCTUnwrap(rawReport1)
        XCTAssertEqual(report1.markedMissingCount, 1)
        XCTAssertEqual(report1.missingAssetIDs, [extracted.asset.id])
        XCTAssertEqual(store.missingFileCount, 1)

        // 2. Scan moved folder for relink candidates -> finds exact SHA-256 match
        let candidates = await store.scanFolderForMissingRelinks(folderURL: movedDir)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].confidence, RelinkMatchConfidence.exactContentHash)

        // 3. Relink explicitly -> marks .ok, refreshes hash & leaves source file untouched
        let rawOutcome = await store.relinkMissingAsset(assetID: extracted.asset.id, to: candidates[0].url)
        let outcome = try XCTUnwrap(rawOutcome)
        XCTAssertEqual(outcome.confidence, RelinkMatchConfidence.exactContentHash)
        XCTAssertEqual(outcome.contentSHA256, originalSHA)
        XCTAssertEqual(store.missingFileCount, 0)

        let afterRelinkSHA = try MissingFileReconciler.computeFullContentSHA256(url: relocatedURL)
        XCTAssertEqual(afterRelinkSHA, originalSHA, "Relinking must never modify source audio file bytes")
        XCTAssertEqual(size, candidates[0].fileSizeBytes)

        // 4. Verify bookmark auto-recovery when moved again with a valid security-scoped/file bookmark
        let movedAgainURL = musicDir.appendingPathComponent("track_one_restored.wav")
        try FileManager.default.moveItem(at: relocatedURL, to: movedAgainURL)
        let rawReport2 = await store.reconcileMissingFiles()
        let report2 = try XCTUnwrap(rawReport2)
        XCTAssertEqual(report2.autoRecoveredViaBookmarkCount, 1)
        XCTAssertEqual(report2.markedMissingCount, 0)
    }

    // MARK: - 3. DuplicateDetector: Exact Binary & Normalized Metadata (±1s)

    @MainActor
    func testDuplicateDetectorExactBinaryAndNormalizedMetadataWithOneSecondTolerance() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("Dupes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let srcA = try writeWAVFile(named: "a.wav", in: dir, durationSeconds: 2.0, frequency: 440)
        let srcB = dir.appendingPathComponent("a_copy.wav")
        try FileManager.default.copyItem(at: srcA, to: srcB)

        // Different bytes (880Hz) within ±1.0s duration tolerance (2.0s vs 2.7s), normalized title/artist match
        let metaNear = try writeWAVFile(named: "meta_near.wav", in: dir, durationSeconds: 2.7, frequency: 880)
        // Same normalized title/artist but > 1.0s away (4.5s) -> must NOT cluster with 2.0s/2.7s
        let metaFar = try writeWAVFile(named: "meta_far.wav", in: dir, durationSeconds: 4.5, frequency: 880)

        let recA = try AudioLibraryRecord(
            asset: AudioAsset(
                canonicalPath: srcA.path,
                displayFilename: "a.wav",
                fileExtension: "wav",
                formatRawValue: "wav",
                fileSizeBytes: Int64(try Data(contentsOf: srcA).count),
                modificationTime: 1000,
                sampleRate: .rate48k,
                channelCount: 2,
                bitDepth: 32,
                frameCount: 96_000,
                durationSeconds: 2.0,
                isLosslessCodec: true,
                codecName: "pcm_f32le"
            ),
            metadata: AudioMetadata(title: "Café   Song", artist: "Élodie")
        )

        let recB = try AudioLibraryRecord(
            asset: AudioAsset(
                canonicalPath: srcB.path,
                displayFilename: "a_copy.wav",
                fileExtension: "wav",
                formatRawValue: "wav",
                fileSizeBytes: Int64(try Data(contentsOf: srcB).count),
                modificationTime: 1000,
                sampleRate: .rate48k,
                channelCount: 2,
                bitDepth: 32,
                frameCount: 96_000,
                durationSeconds: 2.0,
                isLosslessCodec: true,
                codecName: "pcm_f32le"
            ),
            metadata: AudioMetadata(title: "Café   Song", artist: "Élodie")
        )

        let recNear = try AudioLibraryRecord(
            asset: AudioAsset(
                canonicalPath: metaNear.path,
                displayFilename: "meta_near.wav",
                fileExtension: "wav",
                formatRawValue: "wav",
                fileSizeBytes: Int64(try Data(contentsOf: metaNear).count),
                modificationTime: 1000,
                sampleRate: .rate48k,
                channelCount: 2,
                bitDepth: 32,
                frameCount: 129_600,
                durationSeconds: 2.7,
                isLosslessCodec: true,
                codecName: "pcm_f32le"
            ),
            metadata: AudioMetadata(title: "cafe song", artist: "  elodie ")
        )

        let recFar = try AudioLibraryRecord(
            asset: AudioAsset(
                canonicalPath: metaFar.path,
                displayFilename: "meta_far.wav",
                fileExtension: "wav",
                formatRawValue: "wav",
                fileSizeBytes: Int64(try Data(contentsOf: metaFar).count),
                modificationTime: 1000,
                sampleRate: .rate48k,
                channelCount: 2,
                bitDepth: 32,
                frameCount: 216_000,
                durationSeconds: 4.5,
                isLosslessCodec: true,
                codecName: "pcm_f32le"
            ),
            metadata: AudioMetadata(title: "Cafe Song", artist: "Elodie")
        )

        let detector = DuplicateDetector()
        let report = await detector.detectDuplicates(in: [recA, recB, recNear, recFar])

        XCTAssertEqual(report.exactBinaryGroups.count, 1)
        XCTAssertEqual(Set(report.exactBinaryGroups[0].records.map { $0.asset.id }), Set([recA.asset.id, recB.asset.id]))

        XCTAssertEqual(report.normalizedMetadataGroups.count, 1)
        let metaIDs = Set(report.normalizedMetadataGroups[0].records.map { $0.asset.id })
        XCTAssertTrue(metaIDs.contains(recNear.asset.id))
        XCTAssertTrue(metaIDs.contains(recA.asset.id) || metaIDs.contains(recB.asset.id))
        XCTAssertFalse(metaIDs.contains(recFar.asset.id), "Tracks differing by > 1.0 second must not be grouped as duplicates")
    }

    // MARK: - 4. Inspector Metadata Origin Separation (DB-Only vs Explicit Write)

    @MainActor
    func testLibraryInspectorMetadataOriginSeparationAndNonDestructiveDatabaseSave() async throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("Inspector", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wavURL = try writeWAVFile(named: "notes_only.wav", in: dir)
        let beforeSHA = try MissingFileReconciler.computeFullContentSHA256(url: wavURL)

        let coordinator = makeCoordinator()
        let store = coordinator.libraryStore
        let asset = try AudioAsset(
            canonicalPath: wavURL.path,
            displayFilename: "notes_only.wav",
            fileExtension: "wav",
            formatRawValue: "wav",
            fileSizeBytes: Int64(try Data(contentsOf: wavURL).count),
            modificationTime: 1000,
            sampleRate: .rate48k,
            channelCount: 2,
            bitDepth: 32,
            frameCount: 57_600,
            durationSeconds: 1.2,
            isLosslessCodec: true,
            codecName: "pcm_f32le"
        )
        let rec = AudioLibraryRecord(asset: asset, metadata: AudioMetadata(title: "Original", metadataOrigin: .embeddedAndIndexed))
        try await store.database.upsertAssets([rec])
        await store.reloadMetadataAndTracks()

        var updatedMeta = rec.metadata
        updatedMeta.title = "Custom Library Title"
        updatedMeta.comment = "Stage C DB note"
        let ok = await store.saveLibraryOnlyMetadata(assetID: asset.id, metadata: updatedMeta)
        XCTAssertTrue(ok)

        let fetchedRelinked = try await store.database.fetchAsset(id: asset.id)
        let reloaded = try XCTUnwrap(fetchedRelinked)
        XCTAssertEqual(reloaded.metadata.title, "Custom Library Title")
        XCTAssertEqual(reloaded.metadata.metadataOrigin, MetadataOrigin.libraryOnlyOverride)

        let afterSHA = try MissingFileReconciler.computeFullContentSHA256(url: wavURL)
        XCTAssertEqual(beforeSHA, afterSHA, "DB-only metadata save must never alter source audio file on disk")

        // Render AudioLibraryInspectorView inside NSHostingView and ensure zero layout publishes
        var pubCount = 0
        let cancel = store.objectWillChange.sink { _ in pubCount += 1 }
        defer { cancel.cancel() }

        let host = NSHostingView(rootView: AudioLibraryInspectorView(store: store, record: reloaded))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(pubCount, 0)
    }

    // MARK: - 5. Output Device Picker, Disconnect Fallback & Arbitration Preference

    @MainActor
    func testAudioOutputDevicePickerSelectionDisconnectFallbackAndAutoPausePreference() async throws {
        let hal = StageCMockHALBackend()
        hal.configure(
            entries: [
                .init(deviceID: 10, uid: "built-in-speakers", name: "MacBook Pro Speakers", channels: 2, isAlive: true, sampleRate: 48_000),
                .init(deviceID: 20, uid: "usb-dac", name: "USB Studio DAC", channels: 2, isAlive: true, sampleRate: 96_000)
            ],
            defaultID: 10
        )
        let transport = StageCMockTransport()
        let coordinator = makeCoordinator(hal: hal, transport: transport)
        let playback = coordinator.playbackCoordinator

        // Select specific USB DAC
        let didSelect = await playback.selectOutputDevice(uid: "usb-dac")
        XCTAssertTrue(didSelect)
        XCTAssertEqual(playback.selectedOutputDeviceUID, "usb-dac")
        XCTAssertEqual(transport.selectedDeviceIDs.last, 20)

        // Simulate disconnect of USB DAC -> falls back cleanly to System Default without corrupting state
        hal.configure(
            entries: [
                .init(deviceID: 10, uid: "built-in-speakers", name: "MacBook Pro Speakers", channels: 2, isAlive: true, sampleRate: 48_000)
            ],
            defaultID: 10
        )
        playback.outputDeviceMonitor.refreshDevices()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(playback.selectedOutputDeviceUID)
        XCTAssertEqual(playback.activeOutputDevice?.uid, "built-in-speakers")

        // Auto-pause preference synchronization with PlaybackArbitrationCenter
        let suite = try XCTUnwrap(UserDefaults(suiteName: sandbox.userDefaultsSuiteName))
        let settings = AppSettings(defaults: suite)
        settings.audioAutoPauseArbitration = false
        XCTAssertFalse(PlaybackArbitrationCenter.shared.isAutoPauseEnabled)
        settings.audioAutoPauseArbitration = true
        XCTAssertTrue(PlaybackArbitrationCenter.shared.isAutoPauseEnabled)

        // Host AudioOutputDevicePicker cleanly
        let host = NSHostingView(rootView: AudioOutputDevicePicker(playback: playback))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 340)
        host.layoutSubtreeIfNeeded()
    }

    // MARK: - 6. Modular Library & Player Views Host Cleanly Without View-Update Warnings

    @MainActor
    func testModularLibraryAndPlayerViewsLayoutCleanly() throws {
        let coordinator = makeCoordinator()
        var publishes = 0
        let cancel = coordinator.objectWillChange.sink { _ in publishes += 1 }
        defer { cancel.cancel() }

        let views: [AnyView] = [
            AnyView(AudioLibrarySidebarView(coordinator: coordinator, store: coordinator.libraryStore)),
            AnyView(AudioLibraryTrackListView(coordinator: coordinator, store: coordinator.libraryStore, playback: coordinator.playbackCoordinator)),
            AnyView(AudioPlayerBarView(coordinator: coordinator, playback: coordinator.playbackCoordinator)),
            AnyView(AudioPlaybackQueuePopover(coordinator: coordinator, playback: coordinator.playbackCoordinator)),
            AnyView(LibraryMissingRelinkSheet(store: coordinator.libraryStore))
        ]

        for view in views {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 820, height: 500)
            host.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(publishes, 0, "Modular Stage C Library and Player views must not emit objectWillChange during layout")
    }
}

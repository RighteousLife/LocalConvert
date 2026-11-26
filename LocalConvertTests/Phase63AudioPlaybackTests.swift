import XCTest
import CoreAudio
import AVFoundation
@testable import LocalConvert

// MARK: - Deterministic Headless Playback Transport for Unit/Integration Tests

@MainActor
private final class MockPlaybackTransport: AudioPlaybackTransportProtocol {
    struct ScheduledItem {
        let frameCount: Int
        let completion: @MainActor () -> Void
    }

    var configuredSampleRate: Double = 0
    var configuredChannelCount: Int = 0
    var selectedDeviceID: AudioDeviceID?
    var setOutputDeviceCallCount = 0
    var isEngineRunning = false
    var isNodePlaying = false
    var volume: Float = 1.0
    var rate: Float = 1.0
    var resetCount = 0
    var scheduledItems: [ScheduledItem] = []
    var maxObservedScheduledQueue = 0
    var totalScheduledFrames: Int64 = 0
    var renderedFramesSinceReset: Int64 = 0

    func configure(sampleRate: Double, channelCount: Int) throws {
        configuredSampleRate = sampleRate
        configuredChannelCount = channelCount
    }

    func setOutputDevice(deviceID: AudioDeviceID?) throws {
        selectedDeviceID = deviceID
        setOutputDeviceCallCount += 1
    }

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
        totalScheduledFrames = 0
        renderedFramesSinceReset = 0
    }

    func scheduleChunk(_ chunk: DecodedPCMChunk, onRendered: @escaping @MainActor () -> Void) {
        totalScheduledFrames += Int64(chunk.frameCount)
        scheduledItems.append(ScheduledItem(frameCount: chunk.frameCount, completion: onRendered))
        maxObservedScheduledQueue = max(maxObservedScheduledQueue, scheduledItems.count)
    }

    func currentRenderedFramesSinceReset() -> Int64 {
        renderedFramesSinceReset
    }

    func completeNextScheduledChunk() {
        guard !scheduledItems.isEmpty else { return }
        let next = scheduledItems.removeFirst()
        renderedFramesSinceReset += Int64(next.frameCount)
        next.completion()
    }

    func drainAllScheduledChunks() {
        while !scheduledItems.isEmpty {
            completeNextScheduledChunk()
        }
    }
}

final class Phase63AudioPlaybackTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase63Play-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
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

    @MainActor
    func testRealDecodersAcrossNativeAndFFmpegFormatsIncludingSeek() async throws {
        let resolvedFFmpeg = await BundledFFmpegProvider().findFFmpegPath()
        let ffmpegPath = try XCTUnwrap(resolvedFFmpeg)

        // Generate real deterministic fixtures for native (.wav, .aiff, .flac, .alac, .mp3) & FFmpeg (.ogg, .opus)
        let wavURL = sandbox.temporaryURL.appendingPathComponent("tone.wav")
        let aiffURL = sandbox.temporaryURL.appendingPathComponent("tone.aiff")
        let flacURL = sandbox.temporaryURL.appendingPathComponent("tone.flac")
        let alacURL = sandbox.temporaryURL.appendingPathComponent("tone.m4a")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 48_000)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: aiffURL,
            spec: .init(format: .aiff, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 48_000)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: flacURL,
            spec: .init(format: .flac, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 48_000)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: alacURL,
            spec: .init(format: .alac, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 48_000)
        )

        let mp3URL = sandbox.temporaryURL.appendingPathComponent("tone.mp3")
        try await Self.runFFmpeg(ffmpegPath: ffmpegPath, args: [
            "-y", "-v", "error", "-i", wavURL.path, "-c:a", "libmp3lame", "-b:a", "192k", mp3URL.path
        ])
        let oggURL = sandbox.temporaryURL.appendingPathComponent("tone.ogg")
        try await Self.runFFmpeg(ffmpegPath: ffmpegPath, args: [
            "-y", "-v", "error", "-i", wavURL.path, "-c:a", "vorbis", "-strict", "-2", oggURL.path
        ])
        let opusURL = sandbox.temporaryURL.appendingPathComponent("tone.opus")
        try await Self.runFFmpeg(ffmpegPath: ffmpegPath, args: [
            "-y", "-v", "error", "-i", wavURL.path, "-c:a", "libopus", opusURL.path
        ])

        let decoderCases: [(URL, FileFormat, AudioDecoderBackend)] = [
            (wavURL, .wav, .nativeAVAudioFile),
            (aiffURL, .aiff, .nativeAVAudioFile),
            (flacURL, .flac, .nativeAVAudioFile),
            (alacURL, .alac, .nativeAVAudioFile),
            (mp3URL, .mp3, .nativeAVAudioFile),
            (oggURL, .ogg, .bundledFFmpeg),
            (opusURL, .opus, .bundledFFmpeg)
        ]

        for (url, format, expectedBackend) in decoderCases {
            let decoder = try await AudioPlaybackDecoderFactory.openDecoder(url: url, format: format)
            XCTAssertEqual(decoder.streamInfo.backend, expectedBackend)
            XCTAssertGreaterThan(decoder.streamInfo.totalFrames, 0)

            let firstChunk = try await decoder.readNextChunk(maxFrames: 4_096)
            XCTAssertNotNil(firstChunk, "First chunk empty for \(format.rawValue)")
            XCTAssertGreaterThan(firstChunk?.frameCount ?? 0, 0)

            // Seek to midpoint and read next chunk
            let midpoint = decoder.streamInfo.totalFrames / 2
            try await decoder.seek(toFrame: midpoint)
            let seekedChunk = try await decoder.readNextChunk(maxFrames: 4_096)
            XCTAssertNotNil(seekedChunk, "Seek chunk empty for \(format.rawValue)")
            await decoder.close()
        }

        // Unsupported image/document file must fail cleanly
        let badFile = sandbox.temporaryURL.appendingPathComponent("not_audio.txt")
        try Data("text".utf8).write(to: badFile)
        do {
            _ = try await AudioPlaybackDecoderFactory.openDecoder(url: badFile)
            XCTFail("Expected unsupportedFormat error")
        } catch let error as AudioPlaybackError {
            XCTAssertEqual(error, .unsupportedFormat("txt"))
        }

        // Corrupt FLAC must throw decode/open failure without crashing
        let corruptFlac = sandbox.temporaryURL.appendingPathComponent("corrupt_play.flac")
        try Data("fLaC_BROKEN_STREAM".utf8).write(to: corruptFlac)
        do {
            _ = try await AudioPlaybackDecoderFactory.openDecoder(url: corruptFlac, format: .flac)
            XCTFail("Expected open failure on corrupt.flac")
        } catch is AudioPlaybackError {
            // Expected
        }
    }

    @MainActor
    func testPlayerEngineStateMachineSeekingCancellationAndBoundedBuffers() async throws {
        // 2 seconds @ 48 kHz = 96,000 frames (multiple 8,192-frame chunks)
        let wavURL = sandbox.temporaryURL.appendingPathComponent("long_song.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: wavURL,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 96_000)
        )

        let transport = MockPlaybackTransport()
        let engine = AudioLibraryPlayerEngine(transport: transport)
        var endCount = 0
        engine.onTrackEnded = { endCount += 1 }

        let id = UUID()
        try await engine.load(url: wavURL, assetID: id, fileFormat: .wav, autoPlay: false)
        XCTAssertEqual(engine.playbackState, .paused)
        XCTAssertEqual(engine.totalFrames, 96_000)
        XCTAssertEqual(engine.position?.frame, 0)

        try engine.play()
        XCTAssertEqual(engine.playbackState, .playing)
        try await Task.sleep(for: .milliseconds(80))

        // Bounded in-flight chunk scheduling (never decodes whole song into unbounded buffers)
        XCTAssertLessThanOrEqual(transport.maxObservedScheduledQueue, AudioLibraryPlayerEngine.maxChunksInFlight)
        XCTAssertGreaterThan(transport.scheduledItems.count, 0)

        // Pause -> Seek via SourceFrameTime (convert 1000ms @ 44.1kHz -> 48kHz = 48,000 frames) -> Resume
        engine.pause()
        XCTAssertEqual(engine.playbackState, .paused)
        let targetInOtherRate = try SourceFrameTime(frame: 44_100, sampleRate: .rate44_1k)
        try await engine.seek(to: targetInOtherRate)
        XCTAssertEqual(engine.playbackState, .paused)
        XCTAssertEqual(engine.position?.frame, 48_000)
        XCTAssertEqual(engine.position?.sampleRate, .rate48k)

        // Clamp seek past end cleanly
        try await engine.seek(toSeconds: 999.0)
        XCTAssertEqual(engine.position?.frame, 96_000)

        // Seek back to 48,000 frames, resume and drain to natural end of track
        try await engine.seek(toSeconds: 1.0)
        let resetsBeforePlay = transport.resetCount
        try engine.resume()
        XCTAssertEqual(engine.playbackState, .playing)
        XCTAssertGreaterThanOrEqual(resetsBeforePlay, 2)

        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(25))
            transport.drainAllScheduledChunks()
            if case .stopped = engine.playbackState { break }
        }
        XCTAssertEqual(engine.playbackState, .stopped)
        XCTAssertEqual(endCount, 1)

        // Rapid track switch / cancellation mid-load leaves clean state with zero stale callbacks
        let loadTask = Task {
            try await engine.load(url: wavURL, assetID: UUID(), fileFormat: .wav, autoPlay: true)
        }
        loadTask.cancel()
        try? await loadTask.value
        await engine.unload()
        XCTAssertEqual(engine.playbackState, .stopped)
        XCTAssertNil(engine.streamInfo)
    }

    @MainActor
    func testQueueManagerRepeatShuffleReorderAndSessionPersistenceWithoutAutoPlay() async throws {
        let qm = PlaybackQueueManager()
        let id1 = UUID(), id2 = UUID(), id3 = UUID()

        qm.setQueue(trackIDs: [id1, id2, id3], startIndex: 0)
        XCTAssertEqual(qm.currentTrackID, id1)

        // Shuffle keeps current track at index 0 and preserves originalOrderIDs when toggled OFF
        qm.setShuffleEnabled(true)
        XCTAssertEqual(qm.queue.activeOrderIDs.first, id1)
        XCTAssertEqual(Set(qm.queue.activeOrderIDs), Set([id1, id2, id3]))
        XCTAssertEqual(qm.queue.originalOrderIDs, [id1, id2, id3])

        qm.setShuffleEnabled(false)
        XCTAssertEqual(qm.queue.activeOrderIDs, [id1, id2, id3])
        XCTAssertEqual(qm.queue.currentIndex, 0)

        // Repeat modes
        qm.setRepeatMode(.one)
        XCTAssertEqual(qm.advanceOnTrackEnd(), id1)
        qm.setRepeatMode(.all)
        _ = qm.selectTrack(at: 2)
        XCTAssertEqual(qm.advanceOnTrackEnd(), id1)
        qm.setRepeatMode(.off)
        _ = qm.selectTrack(at: 2)
        XCTAssertNil(qm.advanceOnTrackEnd())

        // Play Next & Reorder & Remove
        qm.setQueue(trackIDs: [id1, id2], startIndex: 0)
        qm.playNext(id3) // [id1, id3, id2]
        XCTAssertEqual(qm.orderedTrackIDs, [id1, id3, id2])
        qm.move(fromOffsets: IndexSet(integer: 2), toOffset: 1) // [id1, id2, id3]
        XCTAssertEqual(qm.orderedTrackIDs, [id1, id2, id3])
        let removal = qm.remove(at: 0) // removing active index 0 advances replacement to id2
        XCTAssertTrue(removal.removedCurrent)
        XCTAssertEqual(removal.replacementID, id2)

        // Persistence save & relaunch restore (NEVER auto-plays!)
        let persistence = PlaybackStatePersistence(stateFileURL: AppStoragePaths.audioPlayerStateURL)
        let savedPos = try SourceFrameTime(frame: 12_000, sampleRate: .rate48k)
        let playingSession = try PlaybackSession(
            activeAssetID: id2,
            playbackState: .playing,
            position: savedPos,
            totalFrames: 48_000,
            volume: 0.65,
            isMuted: false,
            preMuteVolume: 0.65,
            playbackRate: 1.25
        )
        try await persistence.save(queue: qm.queue, session: playingSession)

        let restored = await persistence.loadRestoredState()
        XCTAssertEqual(restored?.session.playbackState, .paused, "Relaunch restore must never retain .playing state")
        XCTAssertEqual(restored?.session.activeAssetID, id2)
        XCTAssertEqual(restored?.session.position, savedPos)
        XCTAssertEqual(restored?.session.volume, 0.65)
        XCTAssertEqual(restored?.session.playbackRate, 1.25)
        XCTAssertEqual(restored?.queue.activeOrderIDs, [id2, id3])
    }

    @MainActor
    func testEndToEndWorkspaceIntegrationPlaylistPlaySearchAndRestoreWithoutAutoPlay() async throws {
        let folder = sandbox.temporaryURL.appendingPathComponent("IntegratedLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let trackA = folder.appendingPathComponent("trackA.wav")
        let trackB = folder.appendingPathComponent("trackB.aiff")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: trackA,
            spec: .init(format: .wav, sampleRate: 48_000, frameCount: 48_000)
        )
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: trackB,
            spec: .init(format: .aiff, sampleRate: 48_000, frameCount: 48_000)
        )

        let transport1 = MockPlaybackTransport()
        let coordinator = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport1
        )
        await coordinator.ensureInitialized()
        await coordinator.libraryStore.addFolderAndScan(url: folder)
        XCTAssertEqual(coordinator.libraryStore.displayedRecords.count, 2)

        // Create playlist and add both tracks
        let recs = coordinator.libraryStore.displayedRecords
        let pl = await coordinator.libraryStore.createPlaylist(name: "Session Picks", initialAssetIDs: recs.map(\.asset.id))
        let createdPlaylist = try XCTUnwrap(pl)

        await coordinator.playPlaylist(createdPlaylist)
        if case .playing = coordinator.playbackCoordinator.engine.playbackState {
            // Expected playing inside coordinator
        } else {
            XCTFail("Expected coordinator playback engine to enter .playing")
        }

        await coordinator.playbackCoordinator.seek(toSeconds: 0.4)
        await coordinator.playbackCoordinator.flushPersistedSession()
        await coordinator.playbackCoordinator.engine.unload()

        // Deleting playlist keeps underlying disk files completely intact
        await coordinator.libraryStore.deletePlaylist(id: createdPlaylist.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trackB.path))

        // Simulate app relaunch in second coordinator instance: restores track & seek position paused (NEVER auto-playing)
        let transport2 = MockPlaybackTransport()
        let relaunched = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport2
        )
        await relaunched.ensureInitialized()
        XCTAssertEqual(relaunched.playbackCoordinator.engine.playbackState, .paused)
        XCTAssertFalse(transport2.isNodePlaying)
        XCTAssertEqual(relaunched.playbackCoordinator.engine.currentSeconds, 0.4, accuracy: 0.02)

        await coordinator.database.close()
        await relaunched.database.close()
    }

    @MainActor
    func testAudioCollectionBookmarkStoreBrowsingAndSanitizedDiagnostics() async throws {
        StructuredDiagnostics.clearRecentEvents()
        let resolvedFFmpeg = await BundledFFmpegProvider().findFFmpegPath()
        let ffmpegPath = try XCTUnwrap(resolvedFFmpeg)

        let folder = sandbox.temporaryURL.appendingPathComponent("SensitiveArtistFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Security-scoped bookmark creation & resolution round-trip
        let bookmarkData = AudioLibraryBookmarkHelper.createBookmark(for: folder)
        if let bookmarkData {
            let resolved = AudioLibraryBookmarkHelper.resolveBookmark(bookmarkData)
            XCTAssertEqual(
                resolved?.url.resolvingSymlinksInPath().standardizedFileURL.path,
                folder.resolvingSymlinksInPath().standardizedFileURL.path
            )
        }

        let rawWav = folder.appendingPathComponent("secret_source.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: rawWav,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 24, frameCount: 9_600)
        )
        let taggedFlac = folder.appendingPathComponent("SecretTrackTitle.flac")
        try await Self.runFFmpeg(ffmpegPath: ffmpegPath, args: [
            "-y", "-v", "error", "-i", rawWav.path,
            "-c:a", "flac",
            "-metadata", "title=SecretTrackTitle",
            "-metadata", "artist=ConfidentialArtist",
            "-metadata", "album=HiddenAlbum",
            "-metadata", "genre=Classical",
            taggedFlac.path
        ])
        try FileManager.default.removeItem(at: rawWav)

        let transport = MockPlaybackTransport()
        let coordinator = AudioWorkspaceCoordinator(
            databaseURL: AppStoragePaths.audioLibraryDatabaseURL,
            artworkDirectoryURL: AppStoragePaths.audioArtworkCacheDirectory,
            playerStateURL: AppStoragePaths.audioPlayerStateURL,
            transport: transport
        )
        await coordinator.ensureInitialized()
        await coordinator.libraryStore.addFolderAndScan(url: folder)
        XCTAssertEqual(coordinator.libraryStore.displayedRecords.count, 1)
        XCTAssertEqual(coordinator.libraryStore.allArtists, ["ConfidentialArtist"])
        XCTAssertEqual(coordinator.libraryStore.allAlbums, ["HiddenAlbum"])
        XCTAssertEqual(coordinator.libraryStore.allGenres, ["Classical"])

        // Custom smart collection persistence & resolution
        let colFilter = try AudioCollectionFilter(losslessOnly: true)
        let col = await coordinator.libraryStore.createSmartCollection(name: "My Lossless", filter: colFilter)
        let createdCol = try XCTUnwrap(col)
        XCTAssertEqual(coordinator.libraryStore.smartCollections.map(\.id), [createdCol.id])

        // Sidebar section switching
        coordinator.libraryStore.sidebarSection = .artists
        coordinator.libraryStore.selectedCategoryFilter = "ConfidentialArtist"
        await coordinator.libraryStore.reloadMetadataAndTracks()
        XCTAssertEqual(coordinator.libraryStore.displayedRecords.count, 1)

        coordinator.libraryStore.sidebarSection = .collection(createdCol.id)
        await coordinator.libraryStore.reloadMetadataAndTracks()
        XCTAssertEqual(coordinator.libraryStore.displayedRecords.count, 1)

        // Delete tagged file and attempt playback -> marks missing cleanly and logs ONLY redacted diagnostics
        let assetID = coordinator.libraryStore.displayedRecords[0].asset.id
        try FileManager.default.removeItem(at: taggedFlac)
        await coordinator.playbackCoordinator.playTrack(coordinator.libraryStore.displayedRecords[0])
        let updated = try await coordinator.database.fetchAsset(id: assetID)
        XCTAssertEqual(updated?.asset.status, .missing)

        let diagSummary = StructuredDiagnostics.exportSanitizedSummary(limit: 50)
        XCTAssertFalse(diagSummary.contains("SecretTrackTitle"))
        XCTAssertFalse(diagSummary.contains("ConfidentialArtist"))
        XCTAssertFalse(diagSummary.contains("HiddenAlbum"))
        XCTAssertFalse(diagSummary.contains(folder.path))

        // Real AVAudioEnginePlaybackTransport construction + format configuration smoke check (without starting audio hardware output)
        let realTransport = AVAudioEnginePlaybackTransport()
        try realTransport.configure(sampleRate: 48_000, channelCount: 2)
        realTransport.volume = 0.5
        realTransport.rate = 1.0
        XCTAssertEqual(realTransport.volume, 0.5, accuracy: 0.01)

        await coordinator.database.close()
    }

    private static func runFFmpeg(ffmpegPath: String, args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        let out = try await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: 15)
        XCTAssertEqual(out.terminationStatus, 0, "FFmpeg failed: \(String(data: out.stderr, encoding: .utf8) ?? "")")
    }
}

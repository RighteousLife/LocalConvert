import XCTest
import AVFoundation
import CryptoKit
@testable import LocalConvert

final class Phase62AudioDomainFoundationTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase62-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDownWithError() throws {
        OutputReservationCoordinator.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        StructuredDiagnostics.clearRecentEvents()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - 1. Sample-Frame Mathematics & Coordinate Domains

    func testSampleRateValidationBoundaries() throws {
        XCTAssertEqual(try SampleRate(1).hz, 1)
        XCTAssertEqual(try SampleRate(768_000).hz, 768_000)
        XCTAssertEqual(SampleRate.rate44_1k.hz, 44_100)
        XCTAssertEqual(SampleRate.rate48k.hz, 48_000)
        XCTAssertEqual(SampleRate.rate96k.hz, 96_000)
        XCTAssertEqual(SampleRate.rate192k.hz, 192_000)

        XCTAssertThrowsError(try SampleRate(0)) { error in
            XCTAssertEqual(error as? SampleFrameError, .invalidSampleRate(0))
        }
        XCTAssertThrowsError(try SampleRate(-48_000)) { error in
            XCTAssertEqual(error as? SampleFrameError, .invalidSampleRate(-48_000))
        }
        XCTAssertThrowsError(try SampleRate(768_001)) { error in
            XCTAssertEqual(error as? SampleFrameError, .invalidSampleRate(768_001))
        }
    }

    func testSampleFrameConversionsAndHalfAwayFromZeroTies() throws {
        // Same-rate exact conversion
        let srcSame = try SourceFrameTime(frame: 123_456, sampleRate: .rate48k)
        XCTAssertEqual(try srcSame.converted(to: .rate48k).frame, 123_456)

        // Exact cross-rate boundaries: 441 frames @ 44.1kHz == 480 frames @ 48kHz == 960 @ 96kHz == 1920 @ 192kHz (10 ms)
        let t441 = SampleFrameTime(frame: 441, sampleRate: .rate44_1k)
        let t48 = try t441.converted(to: .rate48k)
        let t96 = try t48.converted(to: .rate96k)
        let t192 = try t96.converted(to: .rate192k)
        let backTo441 = try t192.converted(to: .rate44_1k)
        XCTAssertEqual(t48.frame, 480)
        XCTAssertEqual(t96.frame, 960)
        XCTAssertEqual(t192.frame, 1_920)
        XCTAssertEqual(backTo441.frame, 441)

        // 48k -> 44.1k exact 1 second boundary
        let oneSec48 = SampleFrameTime(frame: 48_000, sampleRate: .rate48k)
        XCTAssertEqual(try oneSec48.converted(to: .rate44_1k).frame, 44_100)

        // Exact half-frame rounding tie (+1.5 -> +2): 1 frame @ 1000 Hz -> 1500 Hz
        let r1000 = try SampleRate(1_000)
        let r1500 = try SampleRate(1_500)
        XCTAssertEqual(try SampleFrameTime(frame: 1, sampleRate: r1000).converted(to: r1500).frame, 2)
        // Below half (1.2 -> 1): 1 frame @ 44.1kHz -> 48kHz = 480/441 = 1.088 -> 1
        XCTAssertEqual(try SampleFrameTime(frame: 1, sampleRate: .rate44_1k).converted(to: .rate48k).frame, 1)

        // Negative signed delta half-frame tie (-1.5 -> -2) & (-2.5 -> -3)
        let negDelta1 = FrameDelta(frames: -1, sampleRate: r1000)
        XCTAssertEqual(try negDelta1.converted(to: r1500).frames, -2)
        let negDeltaEven = FrameDelta(frames: -5, sampleRate: try SampleRate(2_000))
        XCTAssertEqual(try negDeltaEven.converted(to: r1000).frames, -3)

        // Shifting TimelineFrameTime by negative delta stays >= 0, fails when crossing below 0
        let pos = try TimelineFrameTime(frame: 480, sampleRate: .rate48k)
        let shifted = try pos.offset(by: FrameDelta(frames: -441, sampleRate: .rate44_1k))
        XCTAssertEqual(shifted.frame, 0)
        XCTAssertThrowsError(try pos.offset(by: FrameDelta(frames: -481, sampleRate: .rate48k))) { error in
            XCTAssertEqual(error as? SampleFrameError, .negativeFrameNotAllowed(-1))
        }
    }

    func testNegativeNonDeltaFrameRejectionAndOverflowUnderflow() throws {
        XCTAssertThrowsError(try SourceFrameTime(frame: -1, sampleRate: .rate48k)) {
            XCTAssertEqual($0 as? SampleFrameError, .negativeFrameNotAllowed(-1))
        }
        XCTAssertThrowsError(try TimelineFrameTime(frame: -10, sampleRate: .rate48k)) {
            XCTAssertEqual($0 as? SampleFrameError, .negativeFrameNotAllowed(-10))
        }
        XCTAssertThrowsError(try RenderFrameTime(frame: -42, sampleRate: .rate96k)) {
            XCTAssertEqual($0 as? SampleFrameError, .negativeFrameNotAllowed(-42))
        }

        // Cross-rate Int64 overflow when scaling up large Int64 values
        let nearMax = SampleFrameTime(frame: Int64.max / 2 + 100, sampleRate: .rate48k)
        XCTAssertThrowsError(try nearMax.converted(to: .rate96k)) {
            XCTAssertEqual($0 as? SampleFrameError, .integerOverflow)
        }

        // Cross-rate Int64 underflow on large negative delta
        let nearMin = FrameDelta(frames: Int64.min / 2 - 100, sampleRate: .rate48k)
        XCTAssertThrowsError(try nearMin.converted(to: .rate96k)) {
            XCTAssertEqual($0 as? SampleFrameError, .integerUnderflow)
        }
        XCTAssertThrowsError(try FrameDelta(frames: Int64.min, sampleRate: .rate48k).negated()) {
            XCTAssertEqual($0 as? SampleFrameError, .integerOverflow)
        }

        // Addition overflow
        let maxTime = SampleFrameTime(frame: Int64.max - 10, sampleRate: .rate48k)
        XCTAssertThrowsError(try maxTime.adding(FrameDelta(frames: 11, sampleRate: .rate48k))) {
            XCTAssertEqual($0 as? SampleFrameError, .integerOverflow)
        }
    }

    func testInt128CrossRateComparisonsAndRangeInvariants() throws {
        // Equal physical time across different sample rates (including large 64-bit values)
        let a = try SourceFrameTime(frame: 441_000_000_000, sampleRate: .rate44_1k)
        let b = try SourceFrameTime(frame: 480_000_000_000, sampleRate: .rate48k)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)

        // Ordering when rounded conversion might tie, exact Int128 distinguishes cleanly
        let r3 = try SampleRate(3)
        let r6 = try SampleRate(6)
        let exactThird = SampleFrameTime(frame: 1, sampleRate: r3)     // 2/6
        let half = SampleFrameTime(frame: 3, sampleRate: r6)           // 3/6
        let aboveHalf = SampleFrameTime(frame: 1, sampleRate: try SampleRate(2)) // 3/6
        XCTAssertTrue(exactThird < half)
        XCTAssertEqual(half, aboveHalf)
        XCTAssertEqual(half.hashValue, aboveHalf.hashValue)

        // Zero-length SampleFrameRange
        let emptyRange = try SampleFrameRange(startFrame: 480, frameCount: 0, sampleRate: .rate48k)
        XCTAssertTrue(emptyRange.isEmpty)
        XCTAssertEqual(emptyRange.endFrame, 480)
        XCTAssertThrowsError(try emptyRange.validateNonEmptyForExport()) {
            XCTAssertEqual($0 as? SampleFrameError, .emptyExportRange)
        }

        // Range-end overflow & invalid negative length
        XCTAssertThrowsError(try SampleFrameRange(startFrame: Int64.max - 5, frameCount: 6, sampleRate: .rate48k)) {
            XCTAssertEqual($0 as? SampleFrameError, .integerOverflow)
        }
        XCTAssertThrowsError(try SampleFrameRange(startFrame: 0, frameCount: -1, sampleRate: .rate48k)) {
            XCTAssertEqual($0 as? SampleFrameError, .invalidRangeLength(-1))
        }
    }

    // MARK: - 2. Codable Invariant Safety

    func testCodableRoundTripsAndInvariantRejection() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Valid round-trips
        let validRange = try SampleFrameRange(startFrame: 1_024, frameCount: 4_096, sampleRate: .rate96k)
        let decodedRange = try decoder.decode(SampleFrameRange.self, from: encoder.encode(validRange))
        XCTAssertEqual(decodedRange, validRange)

        let validAsset = try AudioAsset(
            canonicalPath: sandbox.temporaryURL.appendingPathComponent("track.flac").path,
            displayFilename: "track.flac",
            fileExtension: "flac",
            formatRawValue: FileFormat.flac.rawValue,
            fileSizeBytes: 2_048,
            modificationTime: 1_700_000_000,
            sampleRate: .rate96k,
            channelCount: 2,
            bitDepth: 24,
            frameCount: 96_000,
            isLosslessCodec: true,
            codecName: "flac",
            rating: 5
        )
        let decodedAsset = try decoder.decode(AudioAsset.self, from: encoder.encode(validAsset))
        XCTAssertEqual(decodedAsset, validAsset)

        let validConfig = try AudioExportConfiguration(
            exportMode: .losslessFormatReRender,
            scope: .selectedRange,
            outputFormat: .wav,
            sampleRate: .rate48k,
            bitDepth: .int24,
            bitrateKbps: 320,
            channelCount: 2
        )
        XCTAssertEqual(try decoder.decode(AudioExportConfiguration.self, from: encoder.encode(validConfig)), validConfig)

        let validQueue = try PlaybackQueue(
            originalOrderIDs: [validAsset.id],
            activeOrderIDs: [validAsset.id],
            currentIndex: 0,
            repeatMode: .all,
            isShuffleEnabled: false
        )
        XCTAssertEqual(try decoder.decode(PlaybackQueue.self, from: encoder.encode(validQueue)), validQueue)

        let validSession = try PlaybackSession(
            activeAssetID: validAsset.id,
            playbackState: .paused,
            position: try SourceFrameTime(frame: 480, sampleRate: .rate96k),
            totalFrames: 96_000,
            volume: 0.75,
            isMuted: false,
            preMuteVolume: 0.75,
            playbackRate: 1.0
        )
        XCTAssertEqual(try decoder.decode(PlaybackSession.self, from: encoder.encode(validSession)), validSession)

        // Invalid JSON payloads MUST fail decoding cleanly
        let invalidJSONPayloads: [(Decodable.Type, String)] = [
            (SampleRate.self, "0"),
            (SampleRate.self, "768001"),
            (SourceFrameTime.self, #"{"frame":-1,"sampleRate":48000}"#),
            (TimelineFrameTime.self, #"{"frame":-100,"sampleRate":44100}"#),
            (SampleFrameRange.self, #"{"startFrame":-1,"frameCount":10,"sampleRate":48000}"#),
            (SampleFrameRange.self, #"{"startFrame":0,"frameCount":-5,"sampleRate":48000}"#),
            (SampleFrameRange.self, #"{"startFrame":9223372036854775800,"frameCount":20,"sampleRate":48000}"#),
            (PlaybackSession.self, #"{"totalFrames":-1,"volume":0.5,"preMuteVolume":0.5,"playbackRate":1.0}"#),
            (PlaybackSession.self, #"{"totalFrames":10,"volume":1.5,"preMuteVolume":0.5,"playbackRate":1.0}"#),
            (PlaybackSession.self, #"{"totalFrames":10,"volume":0.5,"preMuteVolume":0.5,"playbackRate":9.0}"#),
            (PlaybackQueue.self, #"{"originalOrderIDs":[],"activeOrderIDs":[],"currentIndex":0}"#),
            (AudioExportConfiguration.self, #"{"exportMode":"losslessFormatReRender","scope":"Entire Project Mix","outputFormat":"png","sampleRate":48000,"bitDepth":24,"bitrateKbps":320,"channelCount":2,"preserveMetadata":true,"loudnessNormalizeEnabled":false,"targetLUFS":-14.0,"truePeakCeilingDBTP":-1.0,"ditheringPolicy":"autoTPDFWhenDownquantizing","validateOutput":true}"#),
            (AudioAsset.self, "{corrupt json")
        ]

        for (type, json) in invalidJSONPayloads {
            let data = Data(json.utf8)
            XCTAssertThrowsError(try decoder.decode(type, from: data), "Malformed JSON should fail invariant validation for \(type): \(json)")
        }
    }

    // MARK: - 3. OutputReservationCoordinator Extraction & Dual Compatibility

    func testConcurrentReservationOwnershipAndDeferReleaseAcrossWorkspaces() async throws {
        let dir = sandbox.outputsURL
        let concurrentCount = 12

        // Concurrent reservations to identical target must yield strictly distinct paths
        let reservedURLs = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<concurrentCount {
                group.addTask {
                    try OutputReservationCoordinator.reserveUniqueOutputURL(
                        directory: dir,
                        baseName: "concurrent_mix",
                        extension: "wav",
                        policy: .createUnique
                    )
                }
            }
            var urls: [URL] = []
            for try await url in group {
                urls.append(url)
            }
            return urls
        }

        XCTAssertEqual(Set(reservedURLs.map(\.path)).count, concurrentCount)
        XCTAssertTrue(reservedURLs.contains(dir.appendingPathComponent("concurrent_mix.wav")))

        // Releasing restores base name availability when file does not exist on disk
        for url in reservedURLs {
            OutputReservationCoordinator.releaseReservedOutputURL(url)
        }
        let reacquired = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: dir,
            baseName: "concurrent_mix",
            extension: "wav",
            policy: .createUnique
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(reacquired) }
        XCTAssertEqual(reacquired.lastPathComponent, "concurrent_mix.wav")

        // Concurrent .overwrite in same batch deduplicates second claimant rather than clobbering
        let overwrite1 = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: dir,
            baseName: "overwrite_same_batch",
            extension: "mp4",
            policy: .overwrite
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(overwrite1) }
        let overwrite2 = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: dir,
            baseName: "overwrite_same_batch",
            extension: "mp4",
            policy: .overwrite
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(overwrite2) }
        XCTAssertNotEqual(overwrite1, overwrite2)
    }

    func testConversionShimsSourceProtectionVideoTrimAndExternalCollisionHandling() throws {
        let fm = FileManager.default
        let sourceURL = sandbox.temporaryURL.appendingPathComponent("clip.mp4")
        try Data("SOURCE_DATA".utf8).write(to: sourceURL)

        // 1. Source protection via ConversionManager forwarding shim when policy != .overwrite
        var uniqueOpts = ConversionOptions.default
        uniqueOpts.overwriteExisting = false
        let reservedSameDir = try ConversionManager.reserveOutputURL(
            for: sourceURL,
            format: .mp4,
            in: sandbox.temporaryURL,
            options: uniqueOpts
        )
        defer { ConversionManager.releaseReservedOutputURL(reservedSameDir) }
        XCTAssertNotEqual(reservedSameDir.standardizedFileURL, sourceURL.standardizedFileURL)

        // 2. Video trim non-overwrite protection even when overwriteExisting == true
        var trimOpts = ConversionOptions.default
        trimOpts.overwriteExisting = true
        trimOpts.videoTrim = VideoTrimRange(startMilliseconds: 0, endMilliseconds: 1_000)
        trimOpts.customOptions["output_suffix"] = ""
        let trimmedTemp = sandbox.temporaryURL.appendingPathComponent("trimmed_temp.mp4")
        try Data("TRIMMED_DATA".utf8).write(to: trimmedTemp)

        let finalizedTrimURL = try ConversionManager.finalizeOutputFile(
            from: trimmedTemp,
            for: sourceURL,
            format: .mp4,
            in: sandbox.temporaryURL,
            options: trimOpts
        )
        XCTAssertNotEqual(finalizedTrimURL.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "SOURCE_DATA")

        // 3. External post-reservation collision under .createUnique refuses overwrite cleanly
        let raceTarget = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: sandbox.outputsURL,
            baseName: "race_collision",
            extension: "wav",
            policy: .createUnique
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(raceTarget) }
        try Data("EXTERNAL_PROCESS_FILE".utf8).write(to: raceTarget)

        let stagedTemp = sandbox.temporaryURL.appendingPathComponent("staged_race.wav")
        try Data("STAGED_OUTPUT".utf8).write(to: stagedTemp)
        XCTAssertThrowsError(
            try OutputReservationCoordinator.moveOrReplaceTempFile(stagedTemp, to: raceTarget, policy: .createUnique)
        ) { error in
            XCTAssertEqual(error as? ConversionError, .outputFileAlreadyExists(raceTarget))
        }
        XCTAssertEqual(try String(contentsOf: raceTarget, encoding: .utf8), "EXTERNAL_PROCESS_FILE")

        // 4. Release reservation from step 3, then test atomic overwrite commit via replaceItemAt when .overwrite explicitly selected
        OutputReservationCoordinator.releaseReservedOutputURL(raceTarget)
        try fm.removeItem(at: raceTarget)
        try Data("OLD_FILE".utf8).write(to: raceTarget)
        let committedOverwrite = try OutputReservationCoordinator.finalizeOutputFile(
            from: stagedTemp,
            directory: sandbox.outputsURL,
            baseName: "race_collision",
            extension: "wav",
            policy: .overwrite
        )
        XCTAssertEqual(committedOverwrite.standardizedFileURL, raceTarget.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: raceTarget, encoding: .utf8), "STAGED_OUTPUT")

        // 5. Stale temporary cleanup
        let staleArtifact = sandbox.temporaryURL.appendingPathComponent("LocalConvertAudio_stale.wav")
        try Data("STALE".utf8).write(to: staleArtifact)
        let removed = ConversionManager.cleanStaleTemporaryFiles(in: sandbox.temporaryURL, olderThan: -1)
        XCTAssertGreaterThanOrEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: staleArtifact.path))
    }

    func testDecoupledAudioExportServiceUsesCoordinatorWithoutOverwritingSource() async throws {
        let srcURL = sandbox.temporaryURL.appendingPathComponent("export_source.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: srcURL,
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 24_000)
        )
        let sourceHashBefore = SHA256.hash(data: try Data(contentsOf: srcURL))

        let ref = AudioMediaReference(
            id: UUID(),
            path: srcURL.path,
            displayName: srcURL.lastPathComponent,
            fileSize: 96_044,
            modificationTime: Date().timeIntervalSince1970,
            duration: 0.5,
            sampleRate: 48_000,
            channels: 2,
            bookmarkData: nil
        )
        let clip = AudioClip(sourceAssetID: ref.id, name: "Clip", timelineStart: 0, sourceStart: 0, duration: 0.5)
        let project = AudioEditorProject(name: "Phase62", sampleRate: 48_000, tracks: [AudioTrack(name: "Track 1", clips: [clip])], mediaAssets: [ref])

        let req = AudioExportRequest(
            scope: .entireProject,
            outputFormat: .wav,
            sampleRate: 48_000,
            bitDepth: 16,
            channels: 2,
            applyDitheringOn16Bit: true,
            validateOutput: true,
            outputDirectory: sandbox.outputsURL,
            baseFileName: "audio_ws_export"
        )
        let res1 = try await AudioExportService.export(project: project, request: req)
        let res2 = try await AudioExportService.export(project: project, request: req)
        XCTAssertEqual(res1.outputURLs.count, 1)
        XCTAssertEqual(res2.outputURLs.count, 1)
        XCTAssertNotEqual(res1.outputURLs[0], res2.outputURLs[0])

        let sourceHashAfter = SHA256.hash(data: try Data(contentsOf: srcURL))
        XCTAssertEqual(sourceHashBefore, sourceHashAfter)
    }

    // MARK: - 4. AppStoragePaths Isolation & Production Resolution

    func testAppStoragePathsAudioWorkspaceResolutionAndSandboxRedirection() {
        // Production resolution check (pure helper, zero filesystem writes to ~/Library)
        let prodAppSupport = URL(fileURLWithPath: "/tmp/mock_user/Library/Application Support", isDirectory: true)
        let prodCaches = URL(fileURLWithPath: "/tmp/mock_user/Library/Caches", isDirectory: true)
        let prodPaths = AppStoragePaths.resolveAudioWorkspacePaths(
            isTesting: false,
            sandboxRoot: sandbox.rootURL,
            applicationSupportBase: prodAppSupport,
            cachesBase: prodCaches,
            bundleID: "com.localconvert.app"
        )
        XCTAssertEqual(
            prodPaths.libraryDatabaseURL.path,
            "/tmp/mock_user/Library/Application Support/com.localconvert.app/AudioLibrary/library.sqlite"
        )
        XCTAssertEqual(
            prodPaths.waveformCacheDirectory.path,
            "/tmp/mock_user/Library/Caches/com.localconvert.app/AudioWaveformCache"
        )

        // Active test sandbox redirection + idempotent directory creation
        let dbURL1 = AppStoragePaths.audioLibraryDatabaseURL
        let dbURL2 = AppStoragePaths.audioLibraryDatabaseURL
        XCTAssertEqual(dbURL1, dbURL2)
        XCTAssertTrue(dbURL1.path.hasPrefix(sandbox.rootURL.standardizedFileURL.path))
        XCTAssertFalse(dbURL1.path.contains("/Library/Application Support/com.localconvert.app"))

        let wfDir = AppStoragePaths.audioWaveformCacheDirectory
        let playerURL = AppStoragePaths.audioPlayerStateURL
        let stagingDir = AppStoragePaths.audioExportStagingDirectory
        XCTAssertTrue(wfDir.path.hasPrefix(sandbox.rootURL.standardizedFileURL.path))
        XCTAssertTrue(playerURL.path.hasPrefix(sandbox.rootURL.standardizedFileURL.path))
        XCTAssertTrue(stagingDir.path.hasPrefix(sandbox.rootURL.standardizedFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wfDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL1.deletingLastPathComponent().path))
        // SQLite DB file itself must NOT exist in Phase 62
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL1.path))
    }

    // MARK: - 5. StructuredDiagnostics Categories & Privacy Redaction

    func testAudioDiagnosticCategoriesAndPrivacyRedaction() {
        StructuredDiagnostics.clearRecentEvents()

        let audioEvt = StructuredDiagnostics.record(
            category: .audioLibrary,
            severity: .validation,
            stage: "index",
            operationID: "op-1",
            filename: "/Users/alice/Music/SecretAlbum/My Private Demo.flac",
            message: "Failed reading title=Private Demo Song, artist=Alice Doe, lyrics='Hidden verse' at /Volumes/AudioDrive/Library/file.flac",
            isVerboseEnabled: false,
            directoryOverride: sandbox.logsURL
        )
        XCTAssertEqual(audioEvt.category, .audioLibrary)
        XCTAssertEqual(audioEvt.sanitizedFilename, "[REDACTED_AUDIO_FILE].flac")
        XCTAssertFalse(audioEvt.formattedLine.contains("My Private Demo"))
        XCTAssertFalse(audioEvt.formattedLine.contains("Alice"))
        XCTAssertFalse(audioEvt.formattedLine.contains("Private Demo Song"))
        XCTAssertFalse(audioEvt.formattedLine.contains("Hidden verse"))
        XCTAssertFalse(audioEvt.formattedLine.contains("/Volumes/AudioDrive"))

        // Opaque recordAudioEvent helper
        let playerEvt = StructuredDiagnostics.recordAudioEvent(
            category: .audioPlayer,
            severity: .info,
            stage: "load",
            assetID: UUID(),
            fileExtension: "wav",
            message: "artist=Bob album=Vault loaded",
            isVerboseEnabled: false,
            directoryOverride: sandbox.logsURL
        )
        XCTAssertEqual(playerEvt.category, .audioPlayer)
        XCTAssertFalse(playerEvt.formattedLine.contains("Bob"))
        XCTAssertFalse(playerEvt.formattedLine.contains("Vault"))

        // Existing Conversion category behavior preserved (keeps filename lastPathComponent)
        let convEvt = StructuredDiagnostics.record(
            category: .conversion,
            severity: .info,
            stage: "export",
            filename: "/Users/alice/Documents/sample.png",
            message: "Converted /Users/alice/Documents/sample.png",
            isVerboseEnabled: false,
            directoryOverride: sandbox.logsURL
        )
        XCTAssertEqual(convEvt.sanitizedFilename, "sample.png")
        XCTAssertFalse(convEvt.message.contains("/Users/alice"))
        XCTAssertTrue(DiagnosticCategory.audioWaveform.isAudioWorkspaceCategory)
        XCTAssertTrue(DiagnosticCategory.audioEditor.isAudioWorkspaceCategory)
    }

    // MARK: - 6. SyntheticAudioFixtureWriter Verification

    func testSyntheticAudioFixturesDeterminismHeadersCancellationAndUnsupportedError() async throws {
        let cases: [(SyntheticAudioFixtureFormat, String, Int, Int, Int, Int64)] = [
            (.wav, "wav", 44_100, 2, 16, 4_410),
            (.wav, "wav", 48_000, 2, 24, 4_800),
            (.aiff, "aiff", 48_000, 2, 16, 4_800),
            (.alac, "m4a", 48_000, 2, 16, 4_800),
            (.flac, "flac", 48_000, 2, 16, 4_800)
        ]

        for (fmt, ext, sr, ch, depth, frames) in cases {
            let url1 = sandbox.temporaryURL.appendingPathComponent("fixture1_\(fmt.rawValue)_\(sr).\(ext)")
            let url2 = sandbox.temporaryURL.appendingPathComponent("fixture2_\(fmt.rawValue)_\(sr).\(ext)")
            let spec = SyntheticAudioFixtureWriter.Spec(
                format: fmt,
                sampleRate: sr,
                channelCount: ch,
                bitDepth: depth,
                frameCount: frames
            )

            _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(to: url1, spec: spec)
            _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(to: url2, spec: spec)

            let av1 = try AVAudioFile(forReading: url1)
            let av2 = try AVAudioFile(forReading: url2)
            XCTAssertEqual(Int(av1.fileFormat.sampleRate), sr)
            XCTAssertEqual(Int(av1.fileFormat.channelCount), ch)
            XCTAssertEqual(av1.length, frames, "Frame count mismatch for \(fmt.rawValue)")
            XCTAssertEqual(av2.length, frames)

            // Verify decoded PCM frames are 100% deterministic across runs
            guard let buf1 = AVAudioPCMBuffer(pcmFormat: av1.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let buf2 = AVAudioPCMBuffer(pcmFormat: av2.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else {
                XCTFail("Buffer allocation failed")
                return
            }
            try av1.read(into: buf1)
            try av2.read(into: buf2)
            XCTAssertEqual(buf1.frameLength, buf2.frameLength)
            if let ch1 = buf1.floatChannelData, let ch2 = buf2.floatChannelData {
                for i in 0..<Int(buf1.frameLength) {
                    XCTAssertEqual(ch1[0][i], ch2[0][i], accuracy: 1e-6)
                }
            }
        }

        // Unsupported format rejection (.ape encode)
        let badURL = sandbox.temporaryURL.appendingPathComponent("bad.ape")
        do {
            _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
                to: badURL,
                spec: SyntheticAudioFixtureWriter.Spec(format: .ape)
            )
            XCTFail("Expected unsupportedFormat error for .ape")
        } catch let error as SyntheticAudioFixtureError {
            XCTAssertEqual(error, .unsupportedFormat("ape"))
        }

        // Cancellation cleanup
        let cancelURL = sandbox.temporaryURL.appendingPathComponent("cancelled_audio.flac")
        let task = Task {
            try await SyntheticAudioFixtureWriter.writeAudioFixture(
                to: cancelURL,
                spec: SyntheticAudioFixtureWriter.Spec(format: .flac, sampleRate: 96_000, frameCount: 4_800_000)
            )
        }
        try await Task.sleep(for: .milliseconds(15))
        task.cancel()
        let cancelledResult = await task.result
        switch cancelledResult {
        case .success:
            XCTFail("Cancelled fixture write must not succeed")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelURL.path), "Cancelled write must remove output file")
    }
}

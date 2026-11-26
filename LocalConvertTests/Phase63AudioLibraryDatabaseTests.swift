import XCTest
import SQLite3
@testable import LocalConvert

final class Phase63AudioLibraryDatabaseTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var dbURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase63DB-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        dbURL = AppStoragePaths.audioLibraryDatabaseURL
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

    func testInitializationWALForeignKeysSchemaVersionAndFutureVersionRejection() async throws {
        // Lazy initialization: DB file should not exist yet before opening
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))

        let db = AudioLibraryDatabase(databaseURL: dbURL)
        try await db.ensureInitialized()

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, AudioLibraryDatabase.currentSchemaVersion)
        let journal = try await db.journalMode()
        XCTAssertEqual(journal.lowercased(), "wal")
        let fk = try await db.foreignKeysEnabled()
        XCTAssertTrue(fk)
        let ftsAvailable = await db.isFTS5Available
        XCTAssertTrue(ftsAvailable)
        let integrity = try await db.verifyIntegrity(full: true)
        XCTAssertTrue(integrity.isHealthy)
        await db.close()

        // Future schema version (> currentSchemaVersion) must fail cleanly
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version = 99;", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(raw)

        let incompatibleDB = AudioLibraryDatabase(databaseURL: dbURL)
        do {
            try await incompatibleDB.ensureInitialized()
            XCTFail("Expected unsupportedSchemaVersion error")
        } catch let error as AudioLibraryDatabaseError {
            XCTAssertEqual(
                error,
                .unsupportedSchemaVersion(found: 99, maximumSupported: AudioLibraryDatabase.currentSchemaVersion)
            )
        }
        await incompatibleDB.close()
    }

    func testTransactionRollbackAtomicityCascadeAndPlaylistPositionCompaction() async throws {
        let db = AudioLibraryDatabase(databaseURL: dbURL)
        let rootDir = sandbox.temporaryURL.appendingPathComponent("MusicRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)

        // Failed multi-statement transaction must roll back inserted root folder cleanly
        let transientRoot = try LibraryRootFolder(path: rootDir.appendingPathComponent("RollbackOnly").path)
        do {
            try await db.runFailTestTransaction(insertingFolder: transientRoot, thenFailWithSQL: "INVALID SQL SYNTAX;")
            XCTFail("Expected SQL error")
        } catch is AudioLibraryDatabaseError {
            // Expected rollback
        }
        let fetchedRootsAfterRollback = try await db.fetchRootFolders()
        XCTAssertTrue(fetchedRootsAfterRollback.isEmpty)

        // Seed 3 assets and a playlist with duplicate + distinct positions
        let a1 = try makeRecord(name: "TrackA.flac", title: "Alpha", artist: "Artist 1", dir: rootDir)
        let a2 = try makeRecord(name: "TrackB.flac", title: "Beta", artist: "Artist 2", dir: rootDir)
        let a3 = try makeRecord(name: "TrackC.flac", title: "Gamma", artist: "Artist 3", dir: rootDir)
        try await db.upsertAssets([a1, a2, a3])

        let playlist = try await db.createPlaylist(name: "Test Mix")
        // Intentional sequence [a1, a2, a1, a3]
        try await db.setPlaylistAssets(playlistID: playlist.id, assetIDs: [a1.id, a2.id, a1.id, a3.id])

        // Re-upserting a1 with updated metadata MUST preserve playlist membership (ON CONFLICT(id) DO UPDATE, never DELETE+INSERT)
        var a1Updated = a1
        a1Updated.metadata.title = "Alpha Remastered"
        try await db.upsertAssets([a1Updated])

        var loadedPlaylists = try await db.fetchPlaylists()
        XCTAssertEqual(loadedPlaylists.first?.orderedAssetIDs, [a1.id, a2.id, a1.id, a3.id])

        // Deleting a1 must CASCADE remove both occurrences of a1 and re-compact remaining positions -> [a2, a3]
        try await db.deleteAsset(id: a1.id)
        loadedPlaylists = try await db.fetchPlaylists()
        XCTAssertEqual(loadedPlaylists.first?.orderedAssetIDs, [a2.id, a3.id])

        await db.close()

        // Reopen database and confirm state persisted cleanly
        let reopened = AudioLibraryDatabase(databaseURL: dbURL)
        let reopenedPlaylists = try await reopened.fetchPlaylists()
        XCTAssertEqual(reopenedPlaylists.first?.orderedAssetIDs, [a2.id, a3.id])
        let reopenedAssets = try await reopened.fetchAllAssets()
        XCTAssertEqual(reopenedAssets.count, 2)
        await reopened.close()
    }

    func testFTS5AndLikeFallbackSearchEquivalenceRebuildAndCollectionFiltering() async throws {
        let ftsURL = sandbox.temporaryURL.appendingPathComponent("fts.sqlite")
        let likeURL = sandbox.temporaryURL.appendingPathComponent("like.sqlite")

        let ftsDB = AudioLibraryDatabase(databaseURL: ftsURL, forceDisableFTS5: false)
        let likeDB = AudioLibraryDatabase(databaseURL: likeURL, forceDisableFTS5: true)

        try await ftsDB.ensureInitialized()
        try await likeDB.ensureInitialized()
        let ftsOn = await ftsDB.isFTS5Available
        let likeOn = await likeDB.isFTS5Available
        XCTAssertTrue(ftsOn)
        XCTAssertFalse(likeOn)

        let dir = sandbox.temporaryURL.appendingPathComponent("Corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let rec1 = try makeRecord(
            name: "so_what_96k.flac",
            title: "So What",
            artist: "Miles Davis",
            album: "Kind of Blue",
            genre: "Jazz",
            sampleRate: .rate96k,
            bitDepth: 24,
            isLossless: true,
            isFavorite: true,
            rating: 5,
            dir: dir
        )
        let rec2 = try makeRecord(
            name: "cello_suite_1.mp3",
            title: "Prelude in G",
            artist: "Johann Sebastian Bach",
            album: "Solo Suites",
            genre: "Classical",
            sampleRate: .rate44_1k,
            bitDepth: nil,
            isLossless: false,
            isFavorite: false,
            rating: 4,
            dir: dir
        )
        let rec3 = try makeRecord(
            name: "100%_special_quote.wav",
            title: "Midnight Blue_Test",
            artist: "Bill Evans",
            album: "Waltz for Debby",
            genre: "Jazz",
            sampleRate: .rate48k,
            bitDepth: 24,
            isLossless: true,
            isFavorite: true,
            rating: 3,
            dir: dir
        )

        try await ftsDB.upsertAssets([rec1, rec2, rec3])
        try await likeDB.upsertAssets([rec1, rec2, rec3])

        let queries = ["Miles", "Miles Kind", "Jazz", "Prelude", "so_what", "%", "quoted'test \"or\" AND"]
        for query in queries {
            let rFTS = Set(try await ftsDB.searchAssets(query: query).map(\.id))
            let rLike = Set(try await likeDB.searchAssets(query: query).map(\.id))
            XCTAssertEqual(rFTS, rLike, "Search mismatch between FTS5 and LIKE fallback for query '\(query)'")
        }

        // Collection filter checks (favorites + lossless + hi-res)
        let hiResFilter = try AudioCollectionFilter(losslessOnly: true, hiResOnly: true)
        let hiResMatches = try await likeDB.fetchAssets(matching: hiResFilter, sortField: .sampleRate, ascending: false)
        XCTAssertEqual(hiResMatches.map(\.id), [rec1.id, rec3.id])

        // FTS rebuild executes cleanly without duplicating rows
        try await ftsDB.rebuildFTSIndex()
        let afterRebuild = try await ftsDB.searchAssets(query: "Miles Davis")
        XCTAssertEqual(afterRebuild.map(\.id), [rec1.id])

        await ftsDB.close()
        await likeDB.close()
    }

    func testCorruptDatabaseQuarantineAndCleanRecovery() async throws {
        let corruptURL = sandbox.temporaryURL.appendingPathComponent("corrupt_lib.sqlite")
        try Data("THIS_IS_NOT_A_VALID_SQLITE_FILE_HEADER_CORRUPTED_BYTES".utf8).write(to: corruptURL)

        let db = AudioLibraryDatabase(databaseURL: corruptURL)
        let recovery = try await db.recoverFromCorruptionIfNeeded(fullCheck: true)
        XCTAssertTrue(recovery.isHealthy)
        XCTAssertTrue(recovery.recoveredFromCorruption)

        // Original corrupt file was moved into Quarantine/ and clean database now functions normally
        let quarantineDir = corruptURL.deletingLastPathComponent().appendingPathComponent("Quarantine", isDirectory: true)
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(atPath: quarantineDir.path)
        XCTAssertFalse(quarantinedFiles.isEmpty)

        let summary = try await db.librarySummary()
        XCTAssertEqual(summary.totalAssetCount, 0)
        await db.close()
    }

    // MARK: - Helpers

    private func makeRecord(
        name: String,
        title: String?,
        artist: String?,
        album: String? = nil,
        genre: String? = nil,
        sampleRate: SampleRate = .rate48k,
        bitDepth: Int? = 24,
        isLossless: Bool = true,
        isFavorite: Bool = false,
        rating: Int = 0,
        dir: URL
    ) throws -> AudioLibraryRecord {
        let asset = try AudioAsset(
            canonicalPath: dir.appendingPathComponent(name).path,
            displayFilename: name,
            fileExtension: URL(fileURLWithPath: name).pathExtension,
            formatRawValue: URL(fileURLWithPath: name).pathExtension,
            fileSizeBytes: 4096,
            modificationTime: 1_700_000_000,
            sampleRate: sampleRate,
            channelCount: 2,
            bitDepth: bitDepth,
            frameCount: Int64(sampleRate.hz) * 10,
            isLosslessCodec: isLossless,
            codecName: URL(fileURLWithPath: name).pathExtension,
            isFavorite: isFavorite,
            rating: rating
        )
        let meta = AudioMetadata(title: title, artist: artist, album: album, genre: genre)
        return AudioLibraryRecord(asset: asset, metadata: meta)
    }
}

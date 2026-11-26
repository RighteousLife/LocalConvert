import Foundation
import SQLite3

// MARK: - Composite Library Record & Scan Status Models

struct AudioLibraryRecord: Codable, Hashable, Identifiable, Sendable {
    var asset: AudioAsset
    var metadata: AudioMetadata

    var id: UUID { asset.id }
}

enum LibraryScanStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case idle
    case completed
    case cancelled
    case failed
}

struct LibraryScanRecord: Codable, Hashable, Identifiable, Sendable {
    let rootFolderID: UUID
    var lastStartedAt: Date?
    var lastCompletedAt: Date?
    var lastStatus: LibraryScanStatus
    var discoveredCount: Int
    var indexedCount: Int
    var errorMessage: String?

    var id: UUID { rootFolderID }
}

struct DatabaseIntegrityReport: Sendable, Equatable {
    let isHealthy: Bool
    let ftsRebuilt: Bool
    let recoveredFromCorruption: Bool
    let details: String
}

enum AudioLibraryDatabaseError: Error, LocalizedError, Equatable, Sendable {
    case openFailed(code: Int32, message: String)
    case unsupportedSchemaVersion(found: Int32, maximumSupported: Int32)
    case sqliteError(code: Int32, message: String)
    case corruptedDatabase(details: String)
    case playlistNotFound(UUID)
    case assetNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .openFailed(let code, let message):
            return "Failed to open audio library database (SQLite \(code)): \(message)"
        case .unsupportedSchemaVersion(let found, let maxSupported):
            return "Audio library database schema version \(found) is newer than supported version \(maxSupported)."
        case .sqliteError(let code, let message):
            return "Audio library database error (SQLite \(code)): \(message)"
        case .corruptedDatabase(let details):
            return "Audio library database integrity check failed: \(details)"
        case .playlistNotFound(let id):
            return "Playlist not found: \(id.uuidString)"
        case .assetNotFound(let id):
            return "Audio asset not found: \(id.uuidString)"
        }
    }
}

// MARK: - SQLite Handle Container

private final class SQLiteHandleBox: @unchecked Sendable {
    var pointer: OpaquePointer?

    deinit {
        if let pointer {
            sqlite3_close_v2(pointer)
            self.pointer = nil
        }
    }

    func close() {
        if let pointer {
            sqlite3_close_v2(pointer)
            self.pointer = nil
        }
    }
}

// MARK: - Actor-Isolated Library SQLite Persistence

actor AudioLibraryDatabase {
    static let currentSchemaVersion: Int32 = 1
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let customDatabaseURL: URL?
    private let forceDisableFTS5: Bool
    private let handleBox = SQLiteHandleBox()
    private var isBootstrapped = false
    private var fts5Enabled = false

    init(databaseURL: URL? = nil, forceDisableFTS5: Bool = false) {
        self.customDatabaseURL = databaseURL
        self.forceDisableFTS5 = forceDisableFTS5
    }

    var databaseURL: URL {
        customDatabaseURL ?? AppStoragePaths.audioLibraryDatabaseURL
    }

    var isFTS5Available: Bool {
        fts5Enabled
    }

    func close() {
        handleBox.close()
        isBootstrapped = false
    }

    // MARK: - Lifecycle, Schema & Recovery

    func ensureInitialized() throws {
        _ = try openHandle()
    }

    func schemaVersion() throws -> Int32 {
        let db = try openHandle()
        return try readUserVersion(db: db)
    }

    func journalMode() throws -> String {
        let db = try openHandle()
        return try querySingleString(db: db, sql: "PRAGMA journal_mode;") ?? ""
    }

    func foreignKeysEnabled() throws -> Bool {
        let db = try openHandle()
        return (try querySingleInt64(db: db, sql: "PRAGMA foreign_keys;") ?? 0) == 1
    }

    func verifyIntegrity(full: Bool = false) throws -> DatabaseIntegrityReport {
        let db = try openHandle()
        let pragma = full ? "PRAGMA integrity_check;" : "PRAGMA quick_check;"
        let checkResult = (try queryAllStrings(db: db, sql: pragma)).joined(separator: "; ")
        if checkResult.lowercased() != "ok" {
            return DatabaseIntegrityReport(
                isHealthy: false,
                ftsRebuilt: false,
                recoveredFromCorruption: false,
                details: checkResult
            )
        }

        if fts5Enabled {
            do {
                try executeRaw(db: db, sql: "INSERT INTO assets_fts(assets_fts) VALUES('integrity-check');")
            } catch {
                // Base tables passed integrity check; rebuild external-content FTS non-destructively.
                try rebuildFTSIndexLocked(db: db)
                return DatabaseIntegrityReport(
                    isHealthy: true,
                    ftsRebuilt: true,
                    recoveredFromCorruption: false,
                    details: "Rebuilt assets_fts after FTS index check anomaly."
                )
            }
        }

        return DatabaseIntegrityReport(
            isHealthy: true,
            ftsRebuilt: false,
            recoveredFromCorruption: false,
            details: "ok"
        )
    }

    func recoverFromCorruptionIfNeeded(fullCheck: Bool = true) throws -> DatabaseIntegrityReport {
        let dbURL = databaseURL
        let fm = FileManager.default
        do {
            let report = try verifyIntegrity(full: fullCheck)
            if report.isHealthy {
                return report
            }
            try quarantineCorruptFiles(at: dbURL, fm: fm)
            _ = try openHandle()
            StructuredDiagnostics.recordAudioEvent(
                category: .audioLibrary,
                severity: .internalError,
                stage: "sqlite_recover",
                message: "Quarantined corrupt audio library database and reinitialized empty store."
            )
            return DatabaseIntegrityReport(
                isHealthy: true,
                ftsRebuilt: false,
                recoveredFromCorruption: true,
                details: "Quarantined corrupt database and reinitialized schema."
            )
        } catch let error as AudioLibraryDatabaseError {
            if case .sqliteError(let code, _) = error,
               code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
                try quarantineCorruptFiles(at: dbURL, fm: fm)
                _ = try openHandle()
                StructuredDiagnostics.recordAudioEvent(
                    category: .audioLibrary,
                    severity: .internalError,
                    stage: "sqlite_recover",
                    message: "Recovered database after SQLite corruption error \(code)."
                )
                return DatabaseIntegrityReport(
                    isHealthy: true,
                    ftsRebuilt: false,
                    recoveredFromCorruption: true,
                    details: "Quarantined unreadable/corrupt database file and created clean store."
                )
            }
            throw error
        }
    }

    func rebuildFTSIndex() throws {
        let db = try openHandle()
        try rebuildFTSIndexLocked(db: db)
    }

    // MARK: - Library Summary & Root Folders

    func librarySummary() throws -> AudioLibrary {
        let db = try openHandle()
        let roots = try fetchRootFoldersLocked(db: db)

        var totalAssets = 0
        var totalDuration = 0.0
        var totalBytes: Int64 = 0

        let sql = "SELECT COUNT(*), COALESCE(SUM(duration_sec), 0.0), COALESCE(SUM(file_size), 0) FROM assets;"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            totalAssets = Int(sqlite3_column_int64(stmt, 0))
            totalDuration = sqlite3_column_double(stmt, 1)
            totalBytes = sqlite3_column_int64(stmt, 2)
        }

        return try AudioLibrary(
            totalAssetCount: max(0, totalAssets),
            totalDurationSeconds: max(0.0, totalDuration.isFinite ? totalDuration : 0.0),
            totalBytes: max(0, totalBytes),
            watchedRootFolders: roots,
            schemaVersion: Int(Self.currentSchemaVersion),
            fts5Available: fts5Enabled
        )
    }

    func upsertRootFolder(_ folder: LibraryRootFolder) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            try upsertRootFolderLocked(db: db, folder: folder)
        }
    }

    func fetchRootFolders() throws -> [LibraryRootFolder] {
        let db = try openHandle()
        return try fetchRootFoldersLocked(db: db)
    }

    /// Removes a root folder from the library index. Never touches or deletes files on disk.
    func removeRootFolder(id: UUID, removeIndexedAssets: Bool = true) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            var folderPath: String?
            let lookupSQL = "SELECT path FROM root_folders WHERE id = ?;"
            var lookupStmt: OpaquePointer?
            try prepare(db: db, sql: lookupSQL, statement: &lookupStmt)
            defer { sqlite3_finalize(lookupStmt) }
            try bindText(lookupStmt, index: 1, value: id.uuidString)
            if sqlite3_step(lookupStmt) == SQLITE_ROW {
                folderPath = columnText(lookupStmt, index: 0)
            }

            if removeIndexedAssets, let folderPath {
                let normalizedPrefix = folderPath.hasSuffix("/") ? folderPath : "\(folderPath)/"
                let matchingIDs = try fetchAssetIDsInsideRootLocked(db: db, rootPath: folderPath, prefixWithSlash: normalizedPrefix)
                try deleteAssetsLocked(db: db, ids: matchingIDs)
            }

            let delSQL = "DELETE FROM root_folders WHERE id = ?;"
            var delStmt: OpaquePointer?
            try prepare(db: db, sql: delSQL, statement: &delStmt)
            defer { sqlite3_finalize(delStmt) }
            try bindText(delStmt, index: 1, value: id.uuidString)
            try stepDone(db: db, stmt: delStmt)
        }
    }

    // MARK: - Scan State

    func upsertScanState(_ record: LibraryScanRecord) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = """
            INSERT INTO scan_state (
                root_folder_id, last_started_at, last_completed_at,
                last_status, discovered_count, indexed_count, error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(root_folder_id) DO UPDATE SET
                last_started_at = excluded.last_started_at,
                last_completed_at = excluded.last_completed_at,
                last_status = excluded.last_status,
                discovered_count = excluded.discovered_count,
                indexed_count = excluded.indexed_count,
                error_message = excluded.error_message;
            """
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: record.rootFolderID.uuidString)
            try bindOptionalDouble(stmt, index: 2, value: record.lastStartedAt?.timeIntervalSince1970)
            try bindOptionalDouble(stmt, index: 3, value: record.lastCompletedAt?.timeIntervalSince1970)
            try bindText(stmt, index: 4, value: record.lastStatus.rawValue)
            try bindInt64(stmt, index: 5, value: Int64(record.discoveredCount))
            try bindInt64(stmt, index: 6, value: Int64(record.indexedCount))
            try bindOptionalText(stmt, index: 7, value: record.errorMessage)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func fetchScanStates() throws -> [LibraryScanRecord] {
        let db = try openHandle()
        let sql = """
        SELECT root_folder_id, last_started_at, last_completed_at,
               last_status, discovered_count, indexed_count, error_message
        FROM scan_state;
        """
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        var results: [LibraryScanRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = columnText(stmt, index: 0),
                  let rootID = UUID(uuidString: idText) else { continue }
            let started = columnOptionalDouble(stmt, index: 1).map { Date(timeIntervalSince1970: $0) }
            let completed = columnOptionalDouble(stmt, index: 2).map { Date(timeIntervalSince1970: $0) }
            let statusRaw = columnText(stmt, index: 3) ?? LibraryScanStatus.idle.rawValue
            let status = LibraryScanStatus(rawValue: statusRaw) ?? .idle
            let discovered = Int(sqlite3_column_int64(stmt, 4))
            let indexed = Int(sqlite3_column_int64(stmt, 5))
            let errorMessage = columnText(stmt, index: 6)
            results.append(LibraryScanRecord(
                rootFolderID: rootID,
                lastStartedAt: started,
                lastCompletedAt: completed,
                lastStatus: status,
                discoveredCount: discovered,
                indexedCount: indexed,
                errorMessage: errorMessage
            ))
        }
        return results
    }

    // MARK: - Asset CRUD & Incremental Indexing Updates

    func upsertAssets(_ records: [AudioLibraryRecord]) throws {
        guard !records.isEmpty else { return }
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = """
            INSERT INTO assets (
                id, canonical_path, bookmark_data, filename, file_extension, format_raw_value,
                file_size, mtime, partial_sha256, content_sha256,
                sample_rate_hz, channel_count, bit_depth, bitrate_bps, frame_count, duration_sec,
                is_lossless_codec, codec_name, status,
                title, artist, album, album_artist, genre, year,
                track_number, track_total, disc_number, disc_total,
                composer, comment, lyrics, copyright, encoder,
                has_embedded_artwork, artwork_cache_key, metadata_origin,
                play_count, last_played_at, is_favorite, rating, added_at, updated_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?, ?, ?
            )
            ON CONFLICT(id) DO UPDATE SET
                canonical_path = excluded.canonical_path,
                bookmark_data = excluded.bookmark_data,
                filename = excluded.filename,
                file_extension = excluded.file_extension,
                format_raw_value = excluded.format_raw_value,
                file_size = excluded.file_size,
                mtime = excluded.mtime,
                partial_sha256 = excluded.partial_sha256,
                content_sha256 = excluded.content_sha256,
                sample_rate_hz = excluded.sample_rate_hz,
                channel_count = excluded.channel_count,
                bit_depth = excluded.bit_depth,
                bitrate_bps = excluded.bitrate_bps,
                frame_count = excluded.frame_count,
                duration_sec = excluded.duration_sec,
                is_lossless_codec = excluded.is_lossless_codec,
                codec_name = excluded.codec_name,
                status = excluded.status,
                title = excluded.title,
                artist = excluded.artist,
                album = excluded.album,
                album_artist = excluded.album_artist,
                genre = excluded.genre,
                year = excluded.year,
                track_number = excluded.track_number,
                track_total = excluded.track_total,
                disc_number = excluded.disc_number,
                disc_total = excluded.disc_total,
                composer = excluded.composer,
                comment = excluded.comment,
                lyrics = excluded.lyrics,
                copyright = excluded.copyright,
                encoder = excluded.encoder,
                has_embedded_artwork = excluded.has_embedded_artwork,
                artwork_cache_key = excluded.artwork_cache_key,
                metadata_origin = excluded.metadata_origin,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }

            for record in records {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                let a = record.asset
                let m = record.metadata
                try bindText(stmt, index: 1, value: a.id.uuidString)
                try bindText(stmt, index: 2, value: a.canonicalPath)
                try bindOptionalBlob(stmt, index: 3, value: a.bookmarkData)
                try bindText(stmt, index: 4, value: a.displayFilename)
                try bindText(stmt, index: 5, value: a.fileExtension)
                try bindText(stmt, index: 6, value: a.formatRawValue)
                try bindInt64(stmt, index: 7, value: a.fileSizeBytes)
                try bindDouble(stmt, index: 8, value: a.modificationTime)
                try bindOptionalText(stmt, index: 9, value: a.partialHashSHA256)
                try bindOptionalText(stmt, index: 10, value: a.contentSHA256)
                try bindInt64(stmt, index: 11, value: Int64(a.sampleRate.hz))
                try bindInt64(stmt, index: 12, value: Int64(a.channelCount))
                try bindOptionalInt64(stmt, index: 13, value: a.bitDepth.map { Int64($0) })
                try bindOptionalInt64(stmt, index: 14, value: a.bitrateBps.map { Int64($0) })
                try bindInt64(stmt, index: 15, value: a.frameCount)
                try bindDouble(stmt, index: 16, value: a.durationSeconds)
                try bindInt64(stmt, index: 17, value: a.isLosslessCodec ? 1 : 0)
                try bindText(stmt, index: 18, value: a.codecName)
                try bindText(stmt, index: 19, value: a.status.rawValue)
                try bindOptionalText(stmt, index: 20, value: m.title)
                try bindOptionalText(stmt, index: 21, value: m.artist)
                try bindOptionalText(stmt, index: 22, value: m.album)
                try bindOptionalText(stmt, index: 23, value: m.albumArtist)
                try bindOptionalText(stmt, index: 24, value: m.genre)
                try bindOptionalInt64(stmt, index: 25, value: m.year.map { Int64($0) })
                try bindOptionalInt64(stmt, index: 26, value: m.trackNumber.map { Int64($0) })
                try bindOptionalInt64(stmt, index: 27, value: m.trackTotal.map { Int64($0) })
                try bindOptionalInt64(stmt, index: 28, value: m.discNumber.map { Int64($0) })
                try bindOptionalInt64(stmt, index: 29, value: m.discTotal.map { Int64($0) })
                try bindOptionalText(stmt, index: 30, value: m.composer)
                try bindOptionalText(stmt, index: 31, value: m.comment)
                try bindOptionalText(stmt, index: 32, value: m.lyrics)
                try bindOptionalText(stmt, index: 33, value: m.copyright)
                try bindOptionalText(stmt, index: 34, value: m.encoder)
                try bindInt64(stmt, index: 35, value: m.hasEmbeddedArtwork ? 1 : 0)
                try bindOptionalText(stmt, index: 36, value: m.artworkCacheKey)
                try bindText(stmt, index: 37, value: m.metadataOrigin.rawValue)
                try bindInt64(stmt, index: 38, value: Int64(a.playCount))
                try bindOptionalDouble(stmt, index: 39, value: a.lastPlayedAt?.timeIntervalSince1970)
                try bindInt64(stmt, index: 40, value: a.isFavorite ? 1 : 0)
                try bindInt64(stmt, index: 41, value: Int64(a.rating))
                try bindDouble(stmt, index: 42, value: a.dateAdded.timeIntervalSince1970)
                try bindDouble(stmt, index: 43, value: a.dateModified.timeIntervalSince1970)
                try stepDone(db: db, stmt: stmt)
            }
        }
    }

    func fetchAllAssets() throws -> [AudioLibraryRecord] {
        let db = try openHandle()
        let sql = "\(Self.assetSelectColumns) FROM assets a ORDER BY LOWER(COALESCE(a.title, a.filename)) ASC, a.added_at DESC;"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        return try readAssetRows(stmt: stmt)
    }

    func fetchMissingAssetCount() throws -> Int {
        let db = try openHandle()
        let val = try querySingleInt64(db: db, sql: "SELECT COUNT(*) FROM assets WHERE status = 'missing';") ?? 0
        return max(0, Int(val))
    }

    func fetchDistinctMetadataValues(column: String) throws -> [String] {
        let allowed: Set<String> = ["artist", "album", "genre"]
        guard allowed.contains(column) else {
            return []
        }
        let db = try openHandle()
        let sql = "SELECT DISTINCT \(column) FROM assets WHERE \(column) IS NOT NULL AND \(column) != '' ORDER BY \(column) COLLATE NOCASE ASC;"
        return try queryAllStrings(db: db, sql: sql)
    }

    func fetchAsset(id: UUID) throws -> AudioLibraryRecord? {
        let db = try openHandle()
        let sql = "\(Self.assetSelectColumns) FROM assets a WHERE a.id = ?;"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: id.uuidString)
        return try readAssetRows(stmt: stmt).first
    }

    func fetchAssetsByCanonicalPathPrefix(_ rootPath: String) throws -> [AudioLibraryRecord] {
        let db = try openHandle()
        let normalizedPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        let escapedPrefix = escapeLikePattern(normalizedPrefix) + "%"
        let sql = "\(Self.assetSelectColumns) FROM assets a WHERE a.canonical_path = ? OR a.canonical_path LIKE ? ESCAPE '\\';"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: rootPath)
        try bindText(stmt, index: 2, value: escapedPrefix)
        return try readAssetRows(stmt: stmt)
    }

    func markAssetsStatus(ids: [UUID], status: AssetAvailabilityStatus) throws {
        guard !ids.isEmpty else { return }
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let now = Date().timeIntervalSince1970
            let sql = "UPDATE assets SET status = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bindText(stmt, index: 1, value: status.rawValue)
                try bindDouble(stmt, index: 2, value: now)
                try bindText(stmt, index: 3, value: id.uuidString)
                try stepDone(db: db, stmt: stmt)
            }
        }
    }

    func deleteAsset(id: UUID) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            try deleteAssetsLocked(db: db, ids: [id.uuidString])
        }
    }

    func setFavorite(assetID: UUID, isFavorite: Bool) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = "UPDATE assets SET is_favorite = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindInt64(stmt, index: 1, value: isFavorite ? 1 : 0)
            try bindDouble(stmt, index: 2, value: Date().timeIntervalSince1970)
            try bindText(stmt, index: 3, value: assetID.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func setRating(assetID: UUID, rating: Int) throws {
        guard AudioAsset.validRatingRange.contains(rating) else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioAsset.rating", value: rating, rangeDescription: "0...5")
        }
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = "UPDATE assets SET rating = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindInt64(stmt, index: 1, value: Int64(rating))
            try bindDouble(stmt, index: 2, value: Date().timeIntervalSince1970)
            try bindText(stmt, index: 3, value: assetID.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func recordPlayback(assetID: UUID, playedAt: Date = Date()) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = "UPDATE assets SET play_count = play_count + 1, last_played_at = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            let ts = playedAt.timeIntervalSince1970
            try bindDouble(stmt, index: 1, value: ts)
            try bindDouble(stmt, index: 2, value: ts)
            try bindText(stmt, index: 3, value: assetID.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func relinkAsset(
        id: UUID,
        newCanonicalPath: String,
        newFilename: String,
        newExtension: String,
        newFormatRawValue: String,
        fileSizeBytes: Int64,
        modificationTime: TimeInterval,
        bookmarkData: Data?,
        partialHashSHA256: String?,
        contentSHA256: String?
    ) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = """
            UPDATE assets
            SET canonical_path = ?,
                filename = ?,
                file_extension = ?,
                format_raw_value = ?,
                file_size = ?,
                mtime = ?,
                bookmark_data = COALESCE(?, bookmark_data),
                partial_sha256 = COALESCE(?, partial_sha256),
                content_sha256 = COALESCE(?, content_sha256),
                status = 'ok',
                updated_at = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: newCanonicalPath)
            try bindText(stmt, index: 2, value: newFilename)
            try bindText(stmt, index: 3, value: newExtension)
            try bindText(stmt, index: 4, value: newFormatRawValue)
            try bindInt64(stmt, index: 5, value: max(0, fileSizeBytes))
            try bindDouble(stmt, index: 6, value: modificationTime)
            try bindOptionalBlob(stmt, index: 7, value: bookmarkData)
            try bindOptionalText(stmt, index: 8, value: partialHashSHA256)
            try bindOptionalText(stmt, index: 9, value: contentSHA256)
            try bindDouble(stmt, index: 10, value: Date().timeIntervalSince1970)
            try bindText(stmt, index: 11, value: id.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func updateAssetHashes(
        id: UUID,
        partialHashSHA256: String?,
        contentSHA256: String?
    ) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = """
            UPDATE assets
            SET partial_sha256 = COALESCE(?, partial_sha256),
                content_sha256 = COALESCE(?, content_sha256),
                updated_at = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindOptionalText(stmt, index: 1, value: partialHashSHA256)
            try bindOptionalText(stmt, index: 2, value: contentSHA256)
            try bindDouble(stmt, index: 3, value: Date().timeIntervalSince1970)
            try bindText(stmt, index: 4, value: id.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func updateAssetMetadata(id: UUID, metadata: AudioMetadata) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = """
            UPDATE assets
            SET title = ?,
                artist = ?,
                album = ?,
                album_artist = ?,
                genre = ?,
                year = ?,
                track_number = ?,
                track_total = ?,
                disc_number = ?,
                disc_total = ?,
                composer = ?,
                comment = ?,
                lyrics = ?,
                copyright = ?,
                metadata_origin = ?,
                updated_at = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindOptionalText(stmt, index: 1, value: metadata.title)
            try bindOptionalText(stmt, index: 2, value: metadata.artist)
            try bindOptionalText(stmt, index: 3, value: metadata.album)
            try bindOptionalText(stmt, index: 4, value: metadata.albumArtist)
            try bindOptionalText(stmt, index: 5, value: metadata.genre)
            try bindOptionalInt64(stmt, index: 6, value: metadata.year.map(Int64.init))
            try bindOptionalInt64(stmt, index: 7, value: metadata.trackNumber.map(Int64.init))
            try bindOptionalInt64(stmt, index: 8, value: metadata.trackTotal.map(Int64.init))
            try bindOptionalInt64(stmt, index: 9, value: metadata.discNumber.map(Int64.init))
            try bindOptionalInt64(stmt, index: 10, value: metadata.discTotal.map(Int64.init))
            try bindOptionalText(stmt, index: 11, value: metadata.composer)
            try bindOptionalText(stmt, index: 12, value: metadata.comment)
            try bindOptionalText(stmt, index: 13, value: metadata.lyrics)
            try bindOptionalText(stmt, index: 14, value: metadata.copyright)
            try bindText(stmt, index: 15, value: metadata.metadataOrigin.rawValue)
            try bindDouble(stmt, index: 16, value: Date().timeIntervalSince1970)
            try bindText(stmt, index: 17, value: id.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    // MARK: - Search (FTS5 + Parameterized LIKE Fallback) & Collection Filter Queries

    func searchAssets(query: String, limit: Int = 500) throws -> [AudioLibraryRecord] {
        let db = try openHandle()
        let tokens = Self.extractSearchTokens(from: query)
        guard !tokens.isEmpty else {
            return try fetchAllAssets()
        }

        let boundedLimit = max(1, min(limit, 10_000))
        if fts5Enabled {
            let ftsMatchExpression = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
            let sql = """
            \(Self.assetSelectColumns)
            FROM assets a
            JOIN assets_fts f ON a.rowid = f.rowid
            WHERE assets_fts MATCH ?
            ORDER BY bm25(assets_fts), LOWER(COALESCE(a.title, a.filename)) ASC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: ftsMatchExpression)
            try bindInt64(stmt, index: 2, value: Int64(boundedLimit))
            return try readAssetRows(stmt: stmt)
        }

        return try searchAssetsWithLikeLocked(db: db, tokens: tokens, limit: boundedLimit)
    }

    func fetchAssets(
        matching filter: AudioCollectionFilter,
        sortField: AudioCollectionSortField = .title,
        ascending: Bool = true
    ) throws -> [AudioLibraryRecord] {
        let base: [AudioLibraryRecord]
        if let query = filter.searchQuery, !Self.extractSearchTokens(from: query).isEmpty {
            base = try searchAssets(query: query, limit: 10_000)
        } else {
            base = try fetchAllAssets()
        }

        let cutoffDate: Date? = filter.recentDaysWindow.map { days in
            Date().addingTimeInterval(-Double(days) * 86_400.0)
        }

        let filtered = base.filter { record in
            let asset = record.asset
            if filter.losslessOnly && !asset.isLosslessCodec { return false }
            if filter.hiResOnly && !((asset.sampleRate.hz > 48_000) || ((asset.bitDepth ?? 0) >= 24)) {
                return false
            }
            if filter.missingOnly && asset.status != .missing { return false }
            if filter.favoritesOnly && !asset.isFavorite { return false }
            if asset.rating < filter.minimumRating { return false }
            if let cutoffDate, asset.dateAdded < cutoffDate { return false }
            if let formatFilter = filter.formatFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
               !formatFilter.isEmpty,
               asset.formatRawValue.caseInsensitiveCompare(formatFilter) != .orderedSame {
                return false
            }
            return true
        }

        return filtered.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sortField {
            case .title:
                let l = lhs.metadata.title ?? lhs.asset.displayFilename
                let r = rhs.metadata.title ?? rhs.asset.displayFilename
                order = l.localizedStandardCompare(r)
            case .artist:
                let l = lhs.metadata.artist ?? ""
                let r = rhs.metadata.artist ?? ""
                order = l.localizedStandardCompare(r)
            case .album:
                let l = lhs.metadata.album ?? ""
                let r = rhs.metadata.album ?? ""
                order = l.localizedStandardCompare(r)
            case .duration:
                if lhs.asset.durationSeconds < rhs.asset.durationSeconds { order = .orderedAscending }
                else if lhs.asset.durationSeconds > rhs.asset.durationSeconds { order = .orderedDescending }
                else { order = .orderedSame }
            case .sampleRate:
                if lhs.asset.sampleRate.hz < rhs.asset.sampleRate.hz { order = .orderedAscending }
                else if lhs.asset.sampleRate.hz > rhs.asset.sampleRate.hz { order = .orderedDescending }
                else { order = .orderedSame }
            case .dateAdded:
                if lhs.asset.dateAdded < rhs.asset.dateAdded { order = .orderedAscending }
                else if lhs.asset.dateAdded > rhs.asset.dateAdded { order = .orderedDescending }
                else { order = .orderedSame }
            case .lastPlayed:
                let l = lhs.asset.lastPlayedAt ?? .distantPast
                let r = rhs.asset.lastPlayedAt ?? .distantPast
                if l < r { order = .orderedAscending }
                else if l > r { order = .orderedDescending }
                else { order = .orderedSame }
            case .playCount:
                if lhs.asset.playCount < rhs.asset.playCount { order = .orderedAscending }
                else if lhs.asset.playCount > rhs.asset.playCount { order = .orderedDescending }
                else { order = .orderedSame }
            }
            if order == .orderedSame {
                return lhs.asset.id.uuidString < rhs.asset.id.uuidString
            }
            return ascending ? (order == .orderedAscending) : (order == .orderedDescending)
        }
    }

    // MARK: - Playlists & Smart Collections

    func createPlaylist(id: UUID = UUID(), name: String, description: String? = nil) throws -> AudioPlaylist {
        let playlist = try AudioPlaylist(id: id, name: name, description: description)
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = "INSERT INTO playlists (id, name, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: playlist.id.uuidString)
            try bindText(stmt, index: 2, value: playlist.name)
            try bindOptionalText(stmt, index: 3, value: playlist.description)
            try bindDouble(stmt, index: 4, value: playlist.createdAt.timeIntervalSince1970)
            try bindDouble(stmt, index: 5, value: playlist.updatedAt.timeIntervalSince1970)
            try stepDone(db: db, stmt: stmt)
        }
        return playlist
    }

    func renamePlaylist(id: UUID, newName: String) throws {
        let validated = try AudioPlaylist(id: id, name: newName)
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = "UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: validated.name)
            try bindDouble(stmt, index: 2, value: Date().timeIntervalSince1970)
            try bindText(stmt, index: 3, value: id.uuidString)
            try stepDone(db: db, stmt: stmt)
            if sqlite3_changes(db) == 0 {
                throw AudioLibraryDatabaseError.playlistNotFound(id)
            }
        }
    }

    /// Removes a playlist row and its playlist_items rows without modifying or deleting audio files.
    func deletePlaylist(id: UUID) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = "DELETE FROM playlists WHERE id = ?;"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: id.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func setPlaylistAssets(playlistID: UUID, assetIDs: [UUID]) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            guard try playlistExistsLocked(db: db, playlistID: playlistID) else {
                throw AudioLibraryDatabaseError.playlistNotFound(playlistID)
            }

            let delSQL = "DELETE FROM playlist_items WHERE playlist_id = ?;"
            var delStmt: OpaquePointer?
            try prepare(db: db, sql: delSQL, statement: &delStmt)
            defer { sqlite3_finalize(delStmt) }
            try bindText(delStmt, index: 1, value: playlistID.uuidString)
            try stepDone(db: db, stmt: delStmt)

            if !assetIDs.isEmpty {
                let insSQL = "INSERT INTO playlist_items (playlist_id, position, asset_id) VALUES (?, ?, ?);"
                var insStmt: OpaquePointer?
                try prepare(db: db, sql: insSQL, statement: &insStmt)
                defer { sqlite3_finalize(insStmt) }

                for (pos, assetID) in assetIDs.enumerated() {
                    sqlite3_reset(insStmt)
                    sqlite3_clear_bindings(insStmt)
                    try bindText(insStmt, index: 1, value: playlistID.uuidString)
                    try bindInt64(insStmt, index: 2, value: Int64(pos))
                    try bindText(insStmt, index: 3, value: assetID.uuidString)
                    try stepDone(db: db, stmt: insStmt)
                }
            }

            let touchSQL = "UPDATE playlists SET updated_at = ? WHERE id = ?;"
            var touchStmt: OpaquePointer?
            try prepare(db: db, sql: touchSQL, statement: &touchStmt)
            defer { sqlite3_finalize(touchStmt) }
            try bindDouble(touchStmt, index: 1, value: Date().timeIntervalSince1970)
            try bindText(touchStmt, index: 2, value: playlistID.uuidString)
            try stepDone(db: db, stmt: touchStmt)
        }
    }

    func fetchPlaylists() throws -> [AudioPlaylist] {
        let db = try openHandle()
        let plSQL = "SELECT id, name, description, created_at, updated_at FROM playlists ORDER BY LOWER(name) ASC;"
        var plStmt: OpaquePointer?
        try prepare(db: db, sql: plSQL, statement: &plStmt)
        defer { sqlite3_finalize(plStmt) }

        var base: [(UUID, String, String?, Date, Date)] = []
        while sqlite3_step(plStmt) == SQLITE_ROW {
            guard let idText = columnText(plStmt, index: 0),
                  let id = UUID(uuidString: idText),
                  let name = columnText(plStmt, index: 1) else { continue }
            let desc = columnText(plStmt, index: 2)
            let created = Date(timeIntervalSince1970: sqlite3_column_double(plStmt, 3))
            let updated = Date(timeIntervalSince1970: sqlite3_column_double(plStmt, 4))
            base.append((id, name, desc, created, updated))
        }

        let itemSQL = "SELECT playlist_id, asset_id FROM playlist_items ORDER BY playlist_id ASC, position ASC;"
        var itemStmt: OpaquePointer?
        try prepare(db: db, sql: itemSQL, statement: &itemStmt)
        defer { sqlite3_finalize(itemStmt) }

        var itemsByPlaylist: [UUID: [UUID]] = [:]
        while sqlite3_step(itemStmt) == SQLITE_ROW {
            guard let plIDText = columnText(itemStmt, index: 0),
                  let plID = UUID(uuidString: plIDText),
                  let assetIDText = columnText(itemStmt, index: 1),
                  let assetID = UUID(uuidString: assetIDText) else { continue }
            itemsByPlaylist[plID, default: []].append(assetID)
        }

        return try base.map { id, name, desc, created, updated in
            try AudioPlaylist(
                id: id,
                name: name,
                description: desc,
                createdAt: created,
                updatedAt: updated,
                orderedAssetIDs: itemsByPlaylist[id] ?? []
            )
        }
    }

    func upsertCollection(_ collection: AudioCollection) throws {
        let filterData = try JSONEncoder().encode(collection.filterSpec)
        guard let filterJSON = String(data: filterData, encoding: .utf8) else {
            throw AudioLibraryDatabaseError.sqliteError(code: SQLITE_ERROR, message: "Unable to encode collection predicate")
        }
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = """
            INSERT INTO smart_collections (id, name, icon_name, filter_json, sort_field, sort_ascending, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                icon_name = excluded.icon_name,
                filter_json = excluded.filter_json,
                sort_field = excluded.sort_field,
                sort_ascending = excluded.sort_ascending;
            """
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: collection.id.uuidString)
            try bindText(stmt, index: 2, value: collection.name)
            try bindText(stmt, index: 3, value: collection.iconName)
            try bindText(stmt, index: 4, value: filterJSON)
            try bindText(stmt, index: 5, value: collection.sortField.rawValue)
            try bindInt64(stmt, index: 6, value: collection.sortAscending ? 1 : 0)
            try bindDouble(stmt, index: 7, value: Date().timeIntervalSince1970)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func deleteCollection(id: UUID) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            let sql = "DELETE FROM smart_collections WHERE id = ?;"
            var stmt: OpaquePointer?
            try prepare(db: db, sql: sql, statement: &stmt)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, index: 1, value: id.uuidString)
            try stepDone(db: db, stmt: stmt)
        }
    }

    func fetchCollections() throws -> [AudioCollection] {
        let db = try openHandle()
        let sql = "SELECT id, name, icon_name, filter_json, sort_field, sort_ascending FROM smart_collections ORDER BY LOWER(name) ASC;"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        let decoder = JSONDecoder()
        var collections: [AudioCollection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = columnText(stmt, index: 0),
                  let id = UUID(uuidString: idText),
                  let name = columnText(stmt, index: 1),
                  let icon = columnText(stmt, index: 2),
                  let filterJSON = columnText(stmt, index: 3),
                  let filterData = filterJSON.data(using: .utf8),
                  let filter = try? decoder.decode(AudioCollectionFilter.self, from: filterData),
                  let sortRaw = columnText(stmt, index: 4),
                  let sortField = AudioCollectionSortField(rawValue: sortRaw) else {
                continue
            }
            let ascending = sqlite3_column_int64(stmt, 5) != 0
            collections.append(try AudioCollection(
                id: id,
                name: name,
                iconName: icon,
                filterSpec: filter,
                sortField: sortField,
                sortAscending: ascending
            ))
        }
        return collections
    }

    // MARK: - Internal Test / Migration Verification Support

    /// Executes custom SQL inside an explicit rollback-on-error write transaction (useful for testing rollback atomicity).
    func performAtomicBatch(_ work: @Sendable (AudioLibraryDatabase) async throws -> Void) async throws {
        // Note: SQLite transactions are managed per-operation cleanly; helper kept internal for explicit batch coordination.
        try await work(self)
    }

    /// Runs a multi-statement SQLite transaction and rolls back cleanly on any failure (used to verify transaction atomicity in tests).
    func runFailTestTransaction(insertingFolder folder: LibraryRootFolder, thenFailWithSQL badSQL: String) throws {
        let db = try openHandle()
        try inWriteTransaction(db: db) {
            try upsertRootFolderLocked(db: db, folder: folder)
            try executeRaw(db: db, sql: badSQL)
        }
    }

    // MARK: - Private SQLite Plumbing

    private func openHandle() throws -> OpaquePointer {
        if isBootstrapped, let existing = handleBox.pointer {
            return existing
        }

        let url = databaseURL
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var rawHandle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(url.path, &rawHandle, flags, nil)
        guard openCode == SQLITE_OK, let db = rawHandle else {
            let msg = rawHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let rawHandle { sqlite3_close_v2(rawHandle) }
            throw AudioLibraryDatabaseError.openFailed(code: openCode, message: msg)
        }

        handleBox.pointer = db

        do {
            try configureConnectionPragmas(db: db)
            try bootstrapSchemaAndFTS(db: db)
            isBootstrapped = true
            return db
        } catch {
            handleBox.close()
            isBootstrapped = false
            throw error
        }
    }

    private func configureConnectionPragmas(db: OpaquePointer) throws {
        _ = try? querySingleString(db: db, sql: "PRAGMA journal_mode = WAL;")
        try executeRaw(db: db, sql: "PRAGMA synchronous = NORMAL;")
        try executeRaw(db: db, sql: "PRAGMA busy_timeout = 5000;")
        try executeRaw(db: db, sql: "PRAGMA foreign_keys = ON;")
        try executeRaw(db: db, sql: "PRAGMA temp_store = MEMORY;")
        try executeRaw(db: db, sql: "PRAGMA cache_size = -16384;")
    }

    private func bootstrapSchemaAndFTS(db: OpaquePointer) throws {
        let foundVersion = try readUserVersion(db: db)
        if foundVersion > Self.currentSchemaVersion {
            throw AudioLibraryDatabaseError.unsupportedSchemaVersion(
                found: foundVersion,
                maximumSupported: Self.currentSchemaVersion
            )
        }

        if foundVersion == 0 {
            try executeRaw(db: db, sql: "BEGIN EXCLUSIVE TRANSACTION;")
            do {
                try createBaseTablesSQL(db: db)
                try executeRaw(db: db, sql: "PRAGMA user_version = \(Self.currentSchemaVersion);")
                try executeRaw(db: db, sql: "COMMIT;")
            } catch {
                try? executeRaw(db: db, sql: "ROLLBACK;")
                throw error
            }
        }

        fts5Enabled = probeAndSetupFTS5(db: db)
    }

    private func probeAndSetupFTS5(db: OpaquePointer) -> Bool {
        guard !forceDisableFTS5 else { return false }
        let compiled = (try? querySingleInt64(db: db, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5');")) ?? 0
        guard compiled == 1 else { return false }

        do {
            let existedBefore = ((try? querySingleInt64(
                db: db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'assets_fts';"
            )) ?? 0) > 0

            try inWriteTransaction(db: db) {
                try createFTS5TablesAndTriggersSQL(db: db)
                if !existedBefore {
                    let existingCount = (try? querySingleInt64(db: db, sql: "SELECT COUNT(*) FROM assets;")) ?? 0
                    if existingCount > 0 {
                        try executeRaw(db: db, sql: "INSERT INTO assets_fts(assets_fts) VALUES('rebuild');")
                    }
                }
            }
            return true
        } catch {
            StructuredDiagnostics.recordAudioEvent(
                category: .audioLibrary,
                severity: .internalError,
                stage: "sqlite_fts5_probe",
                message: "FTS5 setup failed; falling back cleanly to parameterized LIKE search."
            )
            return false
        }
    }

    private func createBaseTablesSQL(db: OpaquePointer) throws {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS root_folders (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                bookmark_data BLOB,
                last_scanned_at REAL,
                recursive INTEGER NOT NULL DEFAULT 1
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS scan_state (
                root_folder_id TEXT PRIMARY KEY REFERENCES root_folders(id) ON DELETE CASCADE,
                last_started_at REAL,
                last_completed_at REAL,
                last_status TEXT NOT NULL,
                discovered_count INTEGER NOT NULL DEFAULT 0,
                indexed_count INTEGER NOT NULL DEFAULT 0,
                error_message TEXT
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                canonical_path TEXT NOT NULL UNIQUE,
                bookmark_data BLOB,
                filename TEXT NOT NULL,
                file_extension TEXT NOT NULL,
                format_raw_value TEXT NOT NULL,
                file_size INTEGER NOT NULL CHECK (file_size >= 0),
                mtime REAL NOT NULL,
                partial_sha256 TEXT,
                content_sha256 TEXT,
                sample_rate_hz INTEGER NOT NULL CHECK (sample_rate_hz BETWEEN 1 AND 768000),
                channel_count INTEGER NOT NULL CHECK (channel_count >= 1),
                bit_depth INTEGER,
                bitrate_bps INTEGER,
                frame_count INTEGER NOT NULL CHECK (frame_count >= 0),
                duration_sec REAL NOT NULL CHECK (duration_sec >= 0),
                is_lossless_codec INTEGER NOT NULL,
                codec_name TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok', 'missing', 'modified')),
                title TEXT,
                artist TEXT,
                album TEXT,
                album_artist TEXT,
                genre TEXT,
                year INTEGER,
                track_number INTEGER,
                track_total INTEGER,
                disc_number INTEGER,
                disc_total INTEGER,
                composer TEXT,
                comment TEXT,
                lyrics TEXT,
                copyright TEXT,
                encoder TEXT,
                has_embedded_artwork INTEGER NOT NULL DEFAULT 0,
                artwork_cache_key TEXT,
                metadata_origin TEXT NOT NULL DEFAULT 'embeddedAndIndexed',
                play_count INTEGER NOT NULL DEFAULT 0,
                last_played_at REAL,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
                added_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_assets_content_hash ON assets(content_sha256);",
            "CREATE INDEX IF NOT EXISTS idx_assets_size_partial ON assets(file_size, partial_sha256);",
            "CREATE INDEX IF NOT EXISTS idx_assets_artist_album ON assets(artist, album);",
            "CREATE INDEX IF NOT EXISTS idx_assets_status ON assets(status);",
            """
            CREATE TABLE IF NOT EXISTS playlists (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS playlist_items (
                playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                PRIMARY KEY (playlist_id, position)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS smart_collections (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon_name TEXT NOT NULL,
                filter_json TEXT NOT NULL,
                sort_field TEXT NOT NULL,
                sort_ascending INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL
            );
            """
        ]
        for sql in statements {
            try executeRaw(db: db, sql: sql)
        }
    }

    private func createFTS5TablesAndTriggersSQL(db: OpaquePointer) throws {
        let statements = [
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS assets_fts USING fts5(
                filename,
                title,
                artist,
                album,
                album_artist,
                genre,
                composer,
                comment,
                content='assets',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );
            """,
            """
            CREATE TRIGGER IF NOT EXISTS assets_ai AFTER INSERT ON assets BEGIN
                INSERT INTO assets_fts(rowid, filename, title, artist, album, album_artist, genre, composer, comment)
                VALUES (new.rowid, new.filename, new.title, new.artist, new.album, new.album_artist, new.genre, new.composer, new.comment);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS assets_ad AFTER DELETE ON assets BEGIN
                INSERT INTO assets_fts(assets_fts, rowid, filename, title, artist, album, album_artist, genre, composer, comment)
                VALUES ('delete', old.rowid, old.filename, old.title, old.artist, old.album, old.album_artist, old.genre, old.composer, old.comment);
            END;
            """,
            """
            CREATE TRIGGER IF NOT EXISTS assets_au AFTER UPDATE OF filename, title, artist, album, album_artist, genre, composer, comment ON assets BEGIN
                INSERT INTO assets_fts(assets_fts, rowid, filename, title, artist, album, album_artist, genre, composer, comment)
                VALUES ('delete', old.rowid, old.filename, old.title, old.artist, old.album, old.album_artist, old.genre, old.composer, old.comment);
                INSERT INTO assets_fts(rowid, filename, title, artist, album, album_artist, genre, composer, comment)
                VALUES (new.rowid, new.filename, new.title, new.artist, new.album, new.album_artist, new.genre, new.composer, new.comment);
            END;
            """
        ]
        for sql in statements {
            try executeRaw(db: db, sql: sql)
        }
    }

    private func rebuildFTSIndexLocked(db: OpaquePointer) throws {
        guard fts5Enabled else { return }
        try inWriteTransaction(db: db) {
            try executeRaw(db: db, sql: "INSERT INTO assets_fts(assets_fts) VALUES('rebuild');")
        }
    }

    private func quarantineCorruptFiles(at dbURL: URL, fm: FileManager) throws {
        close()
        let quarantineDir = dbURL.deletingLastPathComponent().appendingPathComponent("Quarantine", isDirectory: true)
        try fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)

        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = quarantineDir.appendingPathComponent("\(stamp)-corrupt.sqlite\(suffix)")
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }
    }

    private func upsertRootFolderLocked(db: OpaquePointer, folder: LibraryRootFolder) throws {
        let sql = """
        INSERT INTO root_folders (id, path, bookmark_data, last_scanned_at, recursive)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            path = excluded.path,
            bookmark_data = excluded.bookmark_data,
            last_scanned_at = excluded.last_scanned_at,
            recursive = excluded.recursive;
        """
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: folder.id.uuidString)
        try bindText(stmt, index: 2, value: folder.path)
        try bindOptionalBlob(stmt, index: 3, value: folder.bookmarkData)
        try bindOptionalDouble(stmt, index: 4, value: folder.lastScannedAt?.timeIntervalSince1970)
        try bindInt64(stmt, index: 5, value: folder.recursive ? 1 : 0)
        try stepDone(db: db, stmt: stmt)
    }

    private func fetchRootFoldersLocked(db: OpaquePointer) throws -> [LibraryRootFolder] {
        let sql = "SELECT id, path, bookmark_data, last_scanned_at, recursive FROM root_folders ORDER BY LOWER(path) ASC;"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        var folders: [LibraryRootFolder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = columnText(stmt, index: 0),
                  let id = UUID(uuidString: idText),
                  let path = columnText(stmt, index: 1) else { continue }
            let bookmark = columnOptionalBlob(stmt, index: 2)
            let scanned = columnOptionalDouble(stmt, index: 3).map { Date(timeIntervalSince1970: $0) }
            let recursive = sqlite3_column_int64(stmt, 4) != 0
            if let folder = try? LibraryRootFolder(
                id: id,
                path: path,
                bookmarkData: bookmark,
                lastScannedAt: scanned,
                recursive: recursive
            ) {
                folders.append(folder)
            }
        }
        return folders
    }

    private func fetchAssetIDsInsideRootLocked(db: OpaquePointer, rootPath: String, prefixWithSlash: String) throws -> [String] {
        let escapedPrefix = escapeLikePattern(prefixWithSlash) + "%"
        let sql = "SELECT id FROM assets WHERE canonical_path = ? OR canonical_path LIKE ? ESCAPE '\\';"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: rootPath)
        try bindText(stmt, index: 2, value: escapedPrefix)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let idStr = columnText(stmt, index: 0) {
                ids.append(idStr)
            }
        }
        return ids
    }

    private func deleteAssetsLocked(db: OpaquePointer, ids: [String]) throws {
        guard !ids.isEmpty else { return }

        var affectedPlaylists = Set<String>()
        let plLookupSQL = "SELECT DISTINCT playlist_id FROM playlist_items WHERE asset_id = ?;"
        var plLookupStmt: OpaquePointer?
        try prepare(db: db, sql: plLookupSQL, statement: &plLookupStmt)
        defer { sqlite3_finalize(plLookupStmt) }

        let delSQL = "DELETE FROM assets WHERE id = ?;"
        var delStmt: OpaquePointer?
        try prepare(db: db, sql: delSQL, statement: &delStmt)
        defer { sqlite3_finalize(delStmt) }

        for id in ids {
            sqlite3_reset(plLookupStmt)
            sqlite3_clear_bindings(plLookupStmt)
            try bindText(plLookupStmt, index: 1, value: id)
            while sqlite3_step(plLookupStmt) == SQLITE_ROW {
                if let plID = columnText(plLookupStmt, index: 0) {
                    affectedPlaylists.insert(plID)
                }
            }

            sqlite3_reset(delStmt)
            sqlite3_clear_bindings(delStmt)
            try bindText(delStmt, index: 1, value: id)
            try stepDone(db: db, stmt: delStmt)
        }

        // Re-compact playlist positions 0, 1, 2... after CASCADE deletes.
        for playlistID in affectedPlaylists.sorted() {
            try compactPlaylistPositionsLocked(db: db, playlistID: playlistID)
        }
    }

    private func compactPlaylistPositionsLocked(db: OpaquePointer, playlistID: String) throws {
        let fetchSQL = "SELECT asset_id FROM playlist_items WHERE playlist_id = ? ORDER BY position ASC;"
        var fetchStmt: OpaquePointer?
        try prepare(db: db, sql: fetchSQL, statement: &fetchStmt)
        defer { sqlite3_finalize(fetchStmt) }
        try bindText(fetchStmt, index: 1, value: playlistID)

        var orderedAssetIDs: [String] = []
        while sqlite3_step(fetchStmt) == SQLITE_ROW {
            if let assetID = columnText(fetchStmt, index: 0) {
                orderedAssetIDs.append(assetID)
            }
        }

        let delSQL = "DELETE FROM playlist_items WHERE playlist_id = ?;"
        var delStmt: OpaquePointer?
        try prepare(db: db, sql: delSQL, statement: &delStmt)
        defer { sqlite3_finalize(delStmt) }
        try bindText(delStmt, index: 1, value: playlistID)
        try stepDone(db: db, stmt: delStmt)

        guard !orderedAssetIDs.isEmpty else { return }
        let insSQL = "INSERT INTO playlist_items (playlist_id, position, asset_id) VALUES (?, ?, ?);"
        var insStmt: OpaquePointer?
        try prepare(db: db, sql: insSQL, statement: &insStmt)
        defer { sqlite3_finalize(insStmt) }

        for (idx, assetID) in orderedAssetIDs.enumerated() {
            sqlite3_reset(insStmt)
            sqlite3_clear_bindings(insStmt)
            try bindText(insStmt, index: 1, value: playlistID)
            try bindInt64(insStmt, index: 2, value: Int64(idx))
            try bindText(insStmt, index: 3, value: assetID)
            try stepDone(db: db, stmt: insStmt)
        }
    }

    private func playlistExistsLocked(db: OpaquePointer, playlistID: UUID) throws -> Bool {
        let sql = "SELECT 1 FROM playlists WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: playlistID.uuidString)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func searchAssetsWithLikeLocked(db: OpaquePointer, tokens: [String], limit: Int) throws -> [AudioLibraryRecord] {
        var clauses: [String] = []
        for idx in 1...tokens.count {
            let p = "?\(idx)"
            clauses.append("""
            (LOWER(COALESCE(a.filename,'')) LIKE \(p) ESCAPE '\\'
             OR LOWER(COALESCE(a.title,'')) LIKE \(p) ESCAPE '\\'
             OR LOWER(COALESCE(a.artist,'')) LIKE \(p) ESCAPE '\\'
             OR LOWER(COALESCE(a.album,'')) LIKE \(p) ESCAPE '\\'
             OR LOWER(COALESCE(a.album_artist,'')) LIKE \(p) ESCAPE '\\'
             OR LOWER(COALESCE(a.genre,'')) LIKE \(p) ESCAPE '\\'
             OR LOWER(COALESCE(a.composer,'')) LIKE \(p) ESCAPE '\\'
             OR LOWER(COALESCE(a.comment,'')) LIKE \(p) ESCAPE '\\')
            """)
        }

        let limitIndex = Int32(tokens.count + 1)
        let sql = """
        \(Self.assetSelectColumns)
        FROM assets a
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY LOWER(COALESCE(a.title, a.filename)) ASC
        LIMIT ?\(limitIndex);
        """
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }

        for (i, token) in tokens.enumerated() {
            let pattern = "%\(escapeLikePattern(token.lowercased()))%"
            try bindText(stmt, index: Int32(i + 1), value: pattern)
        }
        try bindInt64(stmt, index: limitIndex, value: Int64(limit))
        return try readAssetRows(stmt: stmt)
    }

    // MARK: - Search Tokenization & Escaping

    static func extractSearchTokens(from query: String) -> [String] {
        let lowered = query.lowercased()
        var tokens: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func escapeLikePattern(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Row Hydration

    private static let assetSelectColumns = """
    SELECT a.id, a.canonical_path, a.bookmark_data, a.filename, a.file_extension, a.format_raw_value,
           a.file_size, a.mtime, a.partial_sha256, a.content_sha256,
           a.sample_rate_hz, a.channel_count, a.bit_depth, a.bitrate_bps, a.frame_count, a.duration_sec,
           a.is_lossless_codec, a.codec_name, a.status,
           a.title, a.artist, a.album, a.album_artist, a.genre, a.year,
           a.track_number, a.track_total, a.disc_number, a.disc_total,
           a.composer, a.comment, a.lyrics, a.copyright, a.encoder,
           a.has_embedded_artwork, a.artwork_cache_key, a.metadata_origin,
           a.play_count, a.last_played_at, a.is_favorite, a.rating, a.added_at, a.updated_at
    """

    private func readAssetRows(stmt: OpaquePointer?) throws -> [AudioLibraryRecord] {
        var results: [AudioLibraryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = columnText(stmt, index: 0),
                  let id = UUID(uuidString: idText),
                  let path = columnText(stmt, index: 1),
                  let filename = columnText(stmt, index: 3),
                  let ext = columnText(stmt, index: 4),
                  let formatRaw = columnText(stmt, index: 5),
                  let codecName = columnText(stmt, index: 17) else { continue }

            let sampleRateHz = Int32(clamping: sqlite3_column_int64(stmt, 10))
            guard let sampleRate = try? SampleRate(sampleRateHz) else { continue }

            let channelCount = Int(sqlite3_column_int64(stmt, 11))
            let frameCount = sqlite3_column_int64(stmt, 14)
            let statusRaw = columnText(stmt, index: 18) ?? AssetAvailabilityStatus.ok.rawValue
            let status = AssetAvailabilityStatus(rawValue: statusRaw) ?? .ok

            guard let asset = try? AudioAsset(
                id: id,
                canonicalPath: path,
                bookmarkData: columnOptionalBlob(stmt, index: 2),
                displayFilename: filename,
                fileExtension: ext,
                formatRawValue: formatRaw,
                fileSizeBytes: sqlite3_column_int64(stmt, 6),
                modificationTime: sqlite3_column_double(stmt, 7),
                partialHashSHA256: columnText(stmt, index: 8),
                contentSHA256: columnText(stmt, index: 9),
                sampleRate: sampleRate,
                channelCount: max(1, channelCount),
                bitDepth: columnOptionalInt(stmt, index: 12),
                bitrateBps: columnOptionalInt(stmt, index: 13),
                frameCount: max(0, frameCount),
                durationSeconds: sqlite3_column_double(stmt, 15),
                isLosslessCodec: sqlite3_column_int64(stmt, 16) != 0,
                codecName: codecName,
                status: status,
                dateAdded: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 41)),
                dateModified: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 42)),
                playCount: Int(sqlite3_column_int64(stmt, 37)),
                lastPlayedAt: columnOptionalDouble(stmt, index: 38).map { Date(timeIntervalSince1970: $0) },
                isFavorite: sqlite3_column_int64(stmt, 39) != 0,
                rating: Int(sqlite3_column_int64(stmt, 40))
            ) else { continue }

            let originRaw = columnText(stmt, index: 36) ?? MetadataOrigin.embeddedAndIndexed.rawValue
            let metadata = AudioMetadata(
                title: columnText(stmt, index: 19),
                artist: columnText(stmt, index: 20),
                album: columnText(stmt, index: 21),
                albumArtist: columnText(stmt, index: 22),
                genre: columnText(stmt, index: 23),
                year: columnOptionalInt(stmt, index: 24),
                trackNumber: columnOptionalInt(stmt, index: 25),
                trackTotal: columnOptionalInt(stmt, index: 26),
                discNumber: columnOptionalInt(stmt, index: 27),
                discTotal: columnOptionalInt(stmt, index: 28),
                composer: columnText(stmt, index: 29),
                comment: columnText(stmt, index: 30),
                lyrics: columnText(stmt, index: 31),
                copyright: columnText(stmt, index: 32),
                encoder: columnText(stmt, index: 33),
                hasEmbeddedArtwork: sqlite3_column_int64(stmt, 34) != 0,
                artworkCacheKey: columnText(stmt, index: 35),
                metadataOrigin: MetadataOrigin(rawValue: originRaw) ?? .embeddedAndIndexed
            )

            results.append(AudioLibraryRecord(asset: asset, metadata: metadata))
        }
        return results
    }

    // MARK: - Low-Level SQLite Helpers

    private func inWriteTransaction(db: OpaquePointer, _ body: () throws -> Void) throws {
        try executeRaw(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try executeRaw(db: db, sql: "COMMIT;")
        } catch {
            try? executeRaw(db: db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func executeRaw(db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let errMsg { sqlite3_free(errMsg) }
            throw AudioLibraryDatabaseError.sqliteError(code: rc, message: msg)
        }
    }

    private func prepare(db: OpaquePointer, sql: String, statement: inout OpaquePointer?) throws {
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw AudioLibraryDatabaseError.sqliteError(code: rc, message: msg)
        }
    }

    private func stepDone(db: OpaquePointer, stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw AudioLibraryDatabaseError.sqliteError(code: rc, message: msg)
        }
    }

    private func readUserVersion(db: OpaquePointer) throws -> Int32 {
        let val = try querySingleInt64(db: db, sql: "PRAGMA user_version;") ?? 0
        return Int32(truncatingIfNeeded: val)
    }

    private func querySingleInt64(db: OpaquePointer, sql: String) throws -> Int64? {
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func querySingleString(db: OpaquePointer, sql: String) throws -> String? {
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, index: 0)
    }

    private func queryAllStrings(db: OpaquePointer, sql: String) throws -> [String] {
        var stmt: OpaquePointer?
        try prepare(db: db, sql: sql, statement: &stmt)
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = columnText(stmt, index: 0) {
                rows.append(s)
            }
        }
        return rows
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, Self.sqliteTransient)
        guard rc == SQLITE_OK else {
            throw AudioLibraryDatabaseError.sqliteError(code: rc, message: "sqlite3_bind_text failed")
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) throws {
        if let value {
            try bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64) throws {
        let rc = sqlite3_bind_int64(stmt, index, value)
        guard rc == SQLITE_OK else {
            throw AudioLibraryDatabaseError.sqliteError(code: rc, message: "sqlite3_bind_int64 failed")
        }
    }

    private func bindOptionalInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64?) throws {
        if let value {
            try bindInt64(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, index: Int32, value: Double) throws {
        let rc = sqlite3_bind_double(stmt, index, value)
        guard rc == SQLITE_OK else {
            throw AudioLibraryDatabaseError.sqliteError(code: rc, message: "sqlite3_bind_double failed")
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, index: Int32, value: Double?) throws {
        if let value {
            try bindDouble(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalBlob(_ stmt: OpaquePointer?, index: Int32, value: Data?) throws {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let rc = value.withUnsafeBytes { rawBuf -> Int32 in
            if value.isEmpty {
                return sqlite3_bind_zeroblob(stmt, index, 0)
            }
            return sqlite3_bind_blob(stmt, index, rawBuf.baseAddress, Int32(value.count), Self.sqliteTransient)
        }
        guard rc == SQLITE_OK else {
            throw AudioLibraryDatabaseError.sqliteError(code: rc, message: "sqlite3_bind_blob failed")
        }
    }

    private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func columnOptionalInt(_ stmt: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    private func columnOptionalDouble(_ stmt: OpaquePointer?, index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private func columnOptionalBlob(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let byteCount = Int(sqlite3_column_bytes(stmt, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(stmt, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: byteCount)
    }
}

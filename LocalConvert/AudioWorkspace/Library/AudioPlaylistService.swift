import Foundation

/// Transactional playlist manager preserving exact ordering.
/// Explicit Duplicate Policy: Playlists allow the same asset ID to appear multiple times
/// at distinct positions; removals can target either an exact position index or all occurrences.
/// Deleting or modifying a playlist never alters or deletes underlying audio files on disk.
actor AudioPlaylistService {
    private let database: AudioLibraryDatabase

    init(database: AudioLibraryDatabase) {
        self.database = database
    }

    func fetchPlaylists() async throws -> [AudioPlaylist] {
        try await database.fetchPlaylists()
    }

    func createPlaylist(name: String, description: String? = nil, initialAssetIDs: [UUID] = []) async throws -> AudioPlaylist {
        let created = try await database.createPlaylist(name: name, description: description)
        if !initialAssetIDs.isEmpty {
            try await database.setPlaylistAssets(playlistID: created.id, assetIDs: initialAssetIDs)
        }
        return try await fetchPlaylist(id: created.id) ?? created
    }

    func renamePlaylist(id: UUID, newName: String) async throws {
        try await database.renamePlaylist(id: id, newName: newName)
    }

    func deletePlaylist(id: UUID) async throws {
        try await database.deletePlaylist(id: id)
    }

    func appendAssets(_ assetIDs: [UUID], to playlistID: UUID) async throws -> AudioPlaylist {
        guard !assetIDs.isEmpty else {
            if let current = try await fetchPlaylist(id: playlistID) { return current }
            throw AudioLibraryDatabaseError.playlistNotFound(playlistID)
        }
        guard var playlist = try await fetchPlaylist(id: playlistID) else {
            throw AudioLibraryDatabaseError.playlistNotFound(playlistID)
        }
        playlist.orderedAssetIDs.append(contentsOf: assetIDs)
        try await database.setPlaylistAssets(playlistID: playlistID, assetIDs: playlist.orderedAssetIDs)
        return try await fetchPlaylist(id: playlistID) ?? playlist
    }

    func removeEntry(atIndex index: Int, from playlistID: UUID) async throws -> AudioPlaylist {
        guard var playlist = try await fetchPlaylist(id: playlistID) else {
            throw AudioLibraryDatabaseError.playlistNotFound(playlistID)
        }
        guard playlist.orderedAssetIDs.indices.contains(index) else {
            throw AudioDomainValidationError.invalidIndex(index: index, count: playlist.orderedAssetIDs.count)
        }
        playlist.orderedAssetIDs.remove(at: index)
        try await database.setPlaylistAssets(playlistID: playlistID, assetIDs: playlist.orderedAssetIDs)
        return try await fetchPlaylist(id: playlistID) ?? playlist
    }

    func removeAllOccurrences(ofAssetID assetID: UUID, from playlistID: UUID) async throws -> AudioPlaylist {
        guard var playlist = try await fetchPlaylist(id: playlistID) else {
            throw AudioLibraryDatabaseError.playlistNotFound(playlistID)
        }
        playlist.orderedAssetIDs.removeAll { $0 == assetID }
        try await database.setPlaylistAssets(playlistID: playlistID, assetIDs: playlist.orderedAssetIDs)
        return try await fetchPlaylist(id: playlistID) ?? playlist
    }

    func moveEntries(in playlistID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) async throws -> AudioPlaylist {
        guard var playlist = try await fetchPlaylist(id: playlistID) else {
            throw AudioLibraryDatabaseError.playlistNotFound(playlistID)
        }
        var items = playlist.orderedAssetIDs
        let validSource = IndexSet(source.filter { items.indices.contains($0) })
        let moving = validSource.map { items[$0] }
        for index in validSource.sorted(by: >) {
            items.remove(at: index)
        }
        let adjustedOffset = destination - validSource.filter { $0 < destination }.count
        let clampedOffset = max(0, min(adjustedOffset, items.count))
        items.insert(contentsOf: moving, at: clampedOffset)
        playlist.orderedAssetIDs = items
        try await database.setPlaylistAssets(playlistID: playlistID, assetIDs: items)
        return try await fetchPlaylist(id: playlistID) ?? playlist
    }

    func resolveRecords(for playlistID: UUID) async throws -> [AudioLibraryRecord] {
        guard let playlist = try await fetchPlaylist(id: playlistID) else {
            throw AudioLibraryDatabaseError.playlistNotFound(playlistID)
        }
        let all = try await database.fetchAllAssets()
        let byID = Dictionary(all.map { ($0.asset.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.orderedAssetIDs.compactMap { byID[$0] }
    }

    private func fetchPlaylist(id: UUID) async throws -> AudioPlaylist? {
        let all = try await database.fetchPlaylists()
        return all.first { $0.id == id }
    }
}

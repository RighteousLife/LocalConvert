import Foundation
import Combine

enum AudioLibrarySidebarSection: Hashable, Sendable {
    case allTracks
    case recentlyAdded
    case recentlyPlayed
    case artists
    case albums
    case genres
    case favorites
    case lossless
    case hiRes
    case missingFiles
    case duplicates
    case playlist(UUID)
    case collection(UUID)
    case folder(UUID)
}

enum AudioLibraryQuickFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case lossless = "Lossless"
    case hiRes = "Hi-Res"

    var id: String { rawValue }
}

@MainActor
final class AudioLibraryStore: ObservableObject {
    let database: AudioLibraryDatabase
    let artworkProvider: AudioArtworkProvider
    let searchService: AudioLibrarySearchService
    let collectionService: AudioCollectionService
    let playlistService: AudioPlaylistService
    let indexCoordinator: AudioLibraryIndexCoordinator
    let reconciler: MissingFileReconciler
    let duplicateDetector: DuplicateDetector

    @Published private(set) var displayedRecords: [AudioLibraryRecord] = []
    @Published private(set) var allArtists: [String] = []
    @Published private(set) var allAlbums: [String] = []
    @Published private(set) var allGenres: [String] = []
    @Published private(set) var rootFolders: [LibraryRootFolder] = []
    @Published private(set) var scanStatesByRootID: [UUID: LibraryScanRecord] = [:]
    @Published private(set) var playlists: [AudioPlaylist] = []
    @Published private(set) var smartCollections: [AudioCollection] = []
    @Published private(set) var summary: AudioLibrary?
    @Published private(set) var fts5Available: Bool = true
    @Published private(set) var missingFileCount: Int = 0
    @Published private(set) var duplicateReport: AudioDuplicateReport = .empty
    @Published private(set) var lastReconcileReport: MissingFileReconcileReport?

    @Published var sidebarSection: AudioLibrarySidebarSection = .allTracks
    @Published var selectedCategoryFilter: String? = nil
    @Published var quickFilter: AudioLibraryQuickFilter = .all
    @Published var searchQuery: String = ""
    @Published var sortField: AudioCollectionSortField = .title
    @Published var sortAscending: Bool = true
    @Published var selectedAssetIDs: Set<UUID> = []
    @Published var inspectedAssetID: UUID? = nil

    @Published private(set) var isLoading = false
    @Published private(set) var isScanning = false
    @Published private(set) var isCheckingDuplicates = false
    @Published private(set) var scanProgress: LibraryScanProgress?
    @Published private(set) var lastScanReport: LibraryScanReport?
    @Published var errorMessage: String?

    private var refreshGeneration: UInt64 = 0

    init(
        database: AudioLibraryDatabase,
        artworkProvider: AudioArtworkProvider
    ) {
        self.database = database
        self.artworkProvider = artworkProvider
        self.searchService = AudioLibrarySearchService(database: database)
        self.collectionService = AudioCollectionService(database: database)
        self.playlistService = AudioPlaylistService(database: database)
        let scanner = AudioLibraryScanner(database: database, artworkProvider: artworkProvider)
        self.indexCoordinator = AudioLibraryIndexCoordinator(database: database, scanner: scanner)
        self.reconciler = MissingFileReconciler(database: database)
        self.duplicateDetector = DuplicateDetector()
    }

    var primaryInspectedRecord: AudioLibraryRecord? {
        if let id = inspectedAssetID,
           let match = displayedRecords.first(where: { $0.asset.id == id }) {
            return match
        }
        if let firstSelected = selectedAssetIDs.first,
           let match = displayedRecords.first(where: { $0.asset.id == firstSelected }) {
            return match
        }
        return displayedRecords.first
    }

    func loadAndRefresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await database.recoverFromCorruptionIfNeeded(fullCheck: false)
            fts5Available = await database.isFTS5Available
            _ = try? await reconciler.reconcileAllAssets()
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadMetadataAndTracks() async {
        refreshGeneration &+= 1
        let gen = refreshGeneration

        do {
            async let rootsTask = database.fetchRootFolders()
            async let scansTask = database.fetchScanStates()
            async let playlistsTask = playlistService.fetchPlaylists()
            async let collectionsTask = collectionService.fetchCustomCollections()
            async let summaryTask = database.librarySummary()
            async let artistsTask = searchService.distinctArtists()
            async let albumsTask = searchService.distinctAlbums()
            async let genresTask = searchService.distinctGenres()
            async let missingCountTask = database.fetchMissingAssetCount()

            let roots = try await rootsTask
            let scans = try await scansTask
            let lists = try await playlistsTask
            let cols = try await collectionsTask
            let libSummary = try await summaryTask
            let artists = try await artistsTask
            let albums = try await albumsTask
            let genres = try await genresTask
            let missingCount = try await missingCountTask
            let tracks = try await resolveDisplayedRecords()

            guard gen == refreshGeneration else { return }

            self.rootFolders = roots
            self.scanStatesByRootID = Dictionary(scans.map { ($0.rootFolderID, $0) }, uniquingKeysWith: { _, latest in latest })
            self.playlists = lists
            self.smartCollections = cols
            self.summary = libSummary
            self.fts5Available = libSummary.fts5Available
            self.allArtists = artists
            self.allAlbums = albums
            self.allGenres = genres
            self.missingFileCount = missingCount
            self.displayedRecords = tracks
            self.errorMessage = nil
        } catch {
            guard gen == refreshGeneration else { return }
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Missing File Reconciliation & Relinking

    @discardableResult
    func reconcileMissingFiles() async -> MissingFileReconcileReport? {
        do {
            let report = try await reconciler.reconcileAllAssets()
            lastReconcileReport = report
            await reloadMetadataAndTracks()
            return report
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func relinkMissingAsset(assetID: UUID, to url: URL) async -> RelinkOutcome? {
        do {
            let outcome = try await reconciler.relinkAsset(assetID: assetID, to: url)
            await reloadMetadataAndTracks()
            return outcome
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func scanFolderForMissingRelinks(folderURL: URL) async -> [RelinkCandidate] {
        do {
            let missing = try await database.fetchAssets(matching: try AudioCollectionFilter(missingOnly: true))
            return try await reconciler.scanFolderForCandidates(folderURL: folderURL, missingAssets: missing)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    // MARK: - Duplicate Hygiene

    func refreshDuplicates() async {
        isCheckingDuplicates = true
        defer { isCheckingDuplicates = false }
        do {
            let all = try await database.fetchAllAssets()
            let report = await duplicateDetector.detectDuplicates(in: all, database: database)
            duplicateReport = report
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Explicit Metadata Inspection & Persistence

    @discardableResult
    func saveLibraryOnlyMetadata(assetID: UUID, metadata: AudioMetadata) async -> Bool {
        var libraryMeta = metadata
        libraryMeta.metadataOrigin = .libraryOnlyOverride
        do {
            try await database.updateAssetMetadata(id: assetID, metadata: libraryMeta)
            await reloadMetadataAndTracks()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func writeEmbeddedTagsToFile(
        assetID: UUID,
        metadata: AudioMetadata,
        metadataManager: MetadataManager = .shared
    ) async -> Bool {
        guard let existing = try? await database.fetchAsset(id: assetID) else {
            errorMessage = "Audio asset could not be found in Library."
            return false
        }
        let targetURL = resolveInspectableURL(for: existing.asset)
        let scoped = targetURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { targetURL.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            errorMessage = "Source audio file is missing on disk. Relink the file before writing embedded tags."
            return false
        }

        await metadataManager.load(url: targetURL)
        guard let caps = metadataManager.capabilities, caps.canWrite else {
            errorMessage = "Embedded tag writing is not supported for this container format; save as Library Notes instead."
            return false
        }

        metadataManager.updateField(id: "title", value: metadata.title.map { .string($0) })
        metadataManager.updateField(id: "artist", value: metadata.artist.map { .string($0) })
        metadataManager.updateField(id: "album", value: metadata.album.map { .string($0) })
        metadataManager.updateField(id: "albumArtist", value: metadata.albumArtist.map { .string($0) })
        metadataManager.updateField(id: "genre", value: metadata.genre.map { .string($0) })
        metadataManager.updateField(id: "year", value: metadata.year.map { .integer($0) })
        metadataManager.updateField(id: "comment", value: metadata.comment.map { .string($0) })

        let saved = await metadataManager.saveInPlace(context: .metadata)
        guard saved else {
            errorMessage = metadataManager.errorMessage ?? "Failed to write embedded tags."
            return false
        }

        var embeddedMeta = metadata
        embeddedMeta.metadataOrigin = .embeddedAndIndexed
        do {
            if let fullHash = try? MissingFileReconciler.computeFullContentSHA256(url: targetURL) {
                let partial = MissingFileReconciler.computePartialSHA256(url: targetURL)
                try await database.updateAssetHashes(id: assetID, partialHashSHA256: partial, contentSHA256: fullHash)
            }
            try await database.updateAssetMetadata(id: assetID, metadata: embeddedMeta)
            await reloadMetadataAndTracks()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func resolveInspectableURL(for asset: AudioAsset) -> URL {
        if let bookmarkData = asset.bookmarkData,
           let resolved = AudioLibraryBookmarkHelper.resolveBookmark(bookmarkData),
           FileManager.default.fileExists(atPath: resolved.url.path) {
            return resolved.url
        }
        return URL(fileURLWithPath: asset.canonicalPath)
    }

    // MARK: - Folder Management & Scanning

    func importDroppedURLs(_ urls: [URL], intoPlaylistID playlistID: UUID? = nil) async {
        let fm = FileManager.default
        var foldersToAdd: [URL] = []
        var filesToIndex: [URL] = []

        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    foldersToAdd.append(url)
                } else if AudioLibraryFormatSupport.resolveAudioFormat(for: url) != nil {
                    filesToIndex.append(url)
                }
            }
        }

        for folderURL in foldersToAdd {
            await addFolderAndScan(url: folderURL, recursive: true)
        }

        guard !filesToIndex.isEmpty else { return }
        let extractor = AudioMetadataExtractor()
        var importedRecords: [AudioLibraryRecord] = []
        var importedIDs: [UUID] = []
        for fileURL in filesToIndex {
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { fileURL.stopAccessingSecurityScopedResource() }
            }
            let canonical = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = try? await database.fetchAllAssets().first(where: { $0.asset.canonicalPath == canonical.path }) {
                importedIDs.append(existing.asset.id)
                continue
            }
            let bookmark = AudioLibraryBookmarkHelper.createBookmark(for: canonical)
            if let extracted = try? await extractor.extract(
                url: canonical,
                canonicalPath: canonical.path,
                bookmarkData: bookmark,
                artworkProvider: artworkProvider
            ) {
                let rec = AudioLibraryRecord(asset: extracted.asset, metadata: extracted.metadata)
                importedRecords.append(rec)
                importedIDs.append(extracted.asset.id)
            }
        }

        do {
            if !importedRecords.isEmpty {
                try await database.upsertAssets(importedRecords)
            }
            if let playlistID, !importedIDs.isEmpty {
                _ = try await playlistService.appendAssets(importedIDs, to: playlistID)
            }
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFolderAndScan(url: URL, recursive: Bool = true) async {
        do {
            let folder = try await indexCoordinator.addFolder(url: url, recursive: recursive)
            sidebarSection = .folder(folder.id)
            selectedCategoryFilter = nil
            await reloadMetadataAndTracks()
            await rescanFolder(id: folder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFolder(id: UUID) async {
        do {
            try await indexCoordinator.removeFolder(id: id)
            if case .folder(id) = sidebarSection {
                sidebarSection = .allTracks
            }
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rescanFolder(id: UUID) async {
        isScanning = true
        scanProgress = nil
        defer { isScanning = false }
        do {
            let report = try await indexCoordinator.rescanRoot(id: id) { [weak self] prog in
                self?.scanProgress = prog
            }
            lastScanReport = report
            if let scanErr = report.errorMessage {
                errorMessage = scanErr
            }
        } catch is CancellationError {
            scanProgress = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadMetadataAndTracks()
    }

    func rescanAllFolders() async {
        isScanning = true
        scanProgress = nil
        defer { isScanning = false }
        do {
            let reports = try await indexCoordinator.rescanAll { [weak self] prog in
                self?.scanProgress = prog
            }
            lastScanReport = reports.last
            if let firstErr = reports.compactMap(\.errorMessage).first {
                errorMessage = firstErr
            }
        } catch is CancellationError {
            scanProgress = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadMetadataAndTracks()
    }

    func cancelActiveScan() {
        indexCoordinator.cancelScan()
        isScanning = false
        scanProgress = nil
    }

    // MARK: - Library Mutations (Non-Destructive to Source Files)

    func toggleFavorite(assetID: UUID) async {
        do {
            guard let rec = try await database.fetchAsset(id: assetID) else { return }
            try await database.setFavorite(assetID: assetID, isFavorite: !rec.asset.isFavorite)
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRating(assetID: UUID, rating: Int) async {
        do {
            try await database.setRating(assetID: assetID, rating: rating)
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAssetFromLibrary(id: UUID) async {
        do {
            try await database.deleteAsset(id: id)
            selectedAssetIDs.remove(id)
            if inspectedAssetID == id { inspectedAssetID = nil }
            await reloadMetadataAndTracks()
            if case .duplicates = sidebarSection {
                await refreshDuplicates()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Playlists & Collections

    func createPlaylist(name: String, initialAssetIDs: [UUID] = []) async -> AudioPlaylist? {
        do {
            let created = try await playlistService.createPlaylist(name: name, initialAssetIDs: initialAssetIDs)
            await reloadMetadataAndTracks()
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renamePlaylist(id: UUID, newName: String) async {
        do {
            try await playlistService.renamePlaylist(id: id, newName: newName)
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePlaylist(id: UUID) async {
        do {
            try await playlistService.deletePlaylist(id: id)
            if case .playlist(id) = sidebarSection {
                sidebarSection = .allTracks
            }
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addAssets(_ assetIDs: [UUID], toPlaylist playlistID: UUID) async {
        do {
            _ = try await playlistService.appendAssets(assetIDs, to: playlistID)
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePlaylistEntry(atIndex index: Int, from playlistID: UUID) async {
        do {
            _ = try await playlistService.removeEntry(atIndex: index, from: playlistID)
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func movePlaylistEntries(in playlistID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) async {
        do {
            _ = try await playlistService.moveEntries(in: playlistID, fromOffsets: source, toOffset: destination)
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSmartCollection(name: String, filter: AudioCollectionFilter) async -> AudioCollection? {
        do {
            let created = try await collectionService.createCollection(name: name, filter: filter, sortField: sortField, sortAscending: sortAscending)
            await reloadMetadataAndTracks()
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteSmartCollection(id: UUID) async {
        do {
            try await collectionService.deleteCollection(id: id)
            if case .collection(id) = sidebarSection {
                sidebarSection = .allTracks
            }
            await reloadMetadataAndTracks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private Query Resolution

    private func resolveDisplayedRecords() async throws -> [AudioLibraryRecord] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        let rawList: [AudioLibraryRecord]
        switch sidebarSection {
        case .allTracks:
            rawList = try await searchService.search(query: trimmedQuery, sortField: sortField, ascending: sortAscending)

        case .recentlyAdded:
            let filter = try AudioCollectionFilter(recentDaysWindow: 30)
            rawList = try await searchService.search(query: trimmedQuery, filter: filter, sortField: .dateAdded, ascending: false)

        case .recentlyPlayed:
            let base = try await searchService.search(query: trimmedQuery, sortField: .lastPlayed, ascending: false)
            rawList = base.filter { $0.asset.playCount > 0 || $0.asset.lastPlayedAt != nil }

        case .artists:
            let base = try await searchService.search(query: trimmedQuery, sortField: sortField, ascending: sortAscending)
            if let artist = selectedCategoryFilter {
                rawList = base.filter { $0.metadata.artist == artist }
            } else {
                rawList = base
            }

        case .albums:
            let base = try await searchService.search(query: trimmedQuery, sortField: sortField, ascending: sortAscending)
            if let album = selectedCategoryFilter {
                rawList = base.filter { $0.metadata.album == album }
            } else {
                rawList = base
            }

        case .genres:
            let base = try await searchService.search(query: trimmedQuery, sortField: sortField, ascending: sortAscending)
            if let genre = selectedCategoryFilter {
                rawList = base.filter { $0.metadata.genre == genre }
            } else {
                rawList = base
            }

        case .favorites:
            let filter = try AudioCollectionFilter(favoritesOnly: true)
            rawList = try await searchService.search(query: trimmedQuery, filter: filter, sortField: sortField, ascending: sortAscending)

        case .lossless:
            let filter = try AudioCollectionFilter(losslessOnly: true)
            rawList = try await searchService.search(query: trimmedQuery, filter: filter, sortField: sortField, ascending: sortAscending)

        case .hiRes:
            let filter = try AudioCollectionFilter(hiResOnly: true)
            rawList = try await searchService.search(query: trimmedQuery, filter: filter, sortField: sortField, ascending: sortAscending)

        case .missingFiles:
            let filter = try AudioCollectionFilter(missingOnly: true)
            rawList = try await searchService.search(query: trimmedQuery, filter: filter, sortField: sortField, ascending: sortAscending)

        case .duplicates:
            rawList = try await searchService.search(query: trimmedQuery, sortField: sortField, ascending: sortAscending)

        case .playlist(let playlistID):
            let entries = try await playlistService.resolveRecords(for: playlistID)
            guard !trimmedQuery.isEmpty else {
                rawList = entries
                break
            }
            let tokens = AudioLibraryDatabase.extractSearchTokens(from: trimmedQuery)
            rawList = entries.filter { rec in
                let haystack = [
                    rec.asset.displayFilename,
                    rec.metadata.title ?? "",
                    rec.metadata.artist ?? "",
                    rec.metadata.album ?? "",
                    rec.metadata.genre ?? ""
                ].joined(separator: " ").lowercased()
                return tokens.allSatisfy { haystack.contains($0) }
            }

        case .collection(let collectionID):
            let collections = try await collectionService.fetchCustomCollections()
            guard let col = collections.first(where: { $0.id == collectionID }) else { return [] }
            rawList = try await collectionService.resolveTracks(for: col, searchOverride: trimmedQuery)

        case .folder(let folderID):
            let folders = try await database.fetchRootFolders()
            guard let folder = folders.first(where: { $0.id == folderID }) else { return [] }
            let folderRecords = try await database.fetchAssetsByCanonicalPathPrefix(folder.path)
            let ids = Set(folderRecords.map(\.asset.id))
            rawList = try await searchService.search(query: trimmedQuery, sortField: sortField, ascending: sortAscending)
                .filter { ids.contains($0.asset.id) }
        }

        return applyQuickFilter(rawList)
    }

    private func applyQuickFilter(_ records: [AudioLibraryRecord]) -> [AudioLibraryRecord] {
        switch quickFilter {
        case .all:
            return records
        case .lossless:
            return records.filter { $0.asset.isLosslessCodec }
        case .hiRes:
            return records.filter { $0.asset.sampleRate.hz > 48_000 || ($0.asset.bitDepth ?? 0) >= 24 }
        }
    }
}

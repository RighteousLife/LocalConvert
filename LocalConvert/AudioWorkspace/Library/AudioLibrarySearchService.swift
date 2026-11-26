import Foundation

actor AudioLibrarySearchService {
    private let database: AudioLibraryDatabase

    init(database: AudioLibraryDatabase) {
        self.database = database
    }

    func search(
        query: String,
        filter: AudioCollectionFilter? = nil,
        sortField: AudioCollectionSortField = .title,
        ascending: Bool = true
    ) async throws -> [AudioLibraryRecord] {
        let fallbackFilter = try AudioCollectionFilter()
        var effectiveFilter = filter ?? fallbackFilter
        effectiveFilter.searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await database.fetchAssets(matching: effectiveFilter, sortField: sortField, ascending: ascending)
    }

    func distinctArtists() async throws -> [String] {
        let vals = try await database.fetchDistinctMetadataValues(column: "artist")
        return vals.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func distinctAlbums() async throws -> [String] {
        let vals = try await database.fetchDistinctMetadataValues(column: "album")
        return vals.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func distinctGenres() async throws -> [String] {
        let vals = try await database.fetchDistinctMetadataValues(column: "genre")
        return vals.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

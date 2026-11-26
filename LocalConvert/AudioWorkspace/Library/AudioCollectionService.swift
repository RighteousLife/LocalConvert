import Foundation

actor AudioCollectionService {
    private let database: AudioLibraryDatabase

    init(database: AudioLibraryDatabase) {
        self.database = database
    }

    func fetchCustomCollections() async throws -> [AudioCollection] {
        try await database.fetchCollections()
    }

    func saveCollection(_ collection: AudioCollection) async throws {
        try await database.upsertCollection(collection)
    }

    func createCollection(
        name: String,
        iconName: String = "music.note.list",
        filter: AudioCollectionFilter,
        sortField: AudioCollectionSortField = .title,
        sortAscending: Bool = true
    ) async throws -> AudioCollection {
        let collection = try AudioCollection(
            name: name,
            iconName: iconName,
            filterSpec: filter,
            sortField: sortField,
            sortAscending: sortAscending
        )
        try await database.upsertCollection(collection)
        return collection
    }

    func deleteCollection(id: UUID) async throws {
        try await database.deleteCollection(id: id)
    }

    func resolveTracks(for collection: AudioCollection, searchOverride: String? = nil) async throws -> [AudioLibraryRecord] {
        var filter = collection.filterSpec
        if let searchOverride, !searchOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filter.searchQuery = searchOverride
        }
        return try await database.fetchAssets(
            matching: filter,
            sortField: collection.sortField,
            ascending: collection.sortAscending
        )
    }
}

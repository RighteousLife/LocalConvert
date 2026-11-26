import Foundation

@MainActor
final class AudioLibraryIndexCoordinator {
    private let database: AudioLibraryDatabase
    private let scanner: AudioLibraryScanner
    private var activeScanTask: Task<[LibraryScanReport], Error>?

    init(database: AudioLibraryDatabase, scanner: AudioLibraryScanner) {
        self.database = database
        self.scanner = scanner
    }

    var isScanning: Bool {
        activeScanTask != nil
    }

    func addFolder(url: URL, recursive: Bool = true) async throws -> LibraryRootFolder {
        let stdURL = url.resolvingSymlinksInPath().standardizedFileURL
        let bookmark = AudioLibraryBookmarkHelper.createBookmark(for: url)
        let existing = try await database.fetchRootFolders()
        if var match = existing.first(where: { $0.path == stdURL.path }) {
            match.bookmarkData = bookmark ?? match.bookmarkData
            match.recursive = recursive
            try await database.upsertRootFolder(match)
            return match
        }
        let folder = try LibraryRootFolder(
            path: stdURL.path,
            bookmarkData: bookmark,
            lastScannedAt: nil,
            recursive: recursive
        )
        try await database.upsertRootFolder(folder)
        return folder
    }

    /// Removes the root folder from the library database without modifying or deleting files on disk.
    func removeFolder(id: UUID) async throws {
        cancelScan()
        try await database.removeRootFolder(id: id, removeIndexedAssets: true)
    }

    func rescanRoot(
        id: UUID,
        onProgress: @escaping @MainActor (LibraryScanProgress) -> Void
    ) async throws -> LibraryScanReport {
        let folders = try await database.fetchRootFolders()
        guard let root = folders.first(where: { $0.id == id }) else {
            throw AudioDomainValidationError.emptyIdentifierOrPath("RootFolder(\(id.uuidString))")
        }
        let reports = try await runScanTask(roots: [root], onProgress: onProgress)
        guard let first = reports.first else {
            throw CancellationError()
        }
        return first
    }

    func rescanAll(
        onProgress: @escaping @MainActor (LibraryScanProgress) -> Void
    ) async throws -> [LibraryScanReport] {
        let folders = try await database.fetchRootFolders()
        return try await runScanTask(roots: folders, onProgress: onProgress)
    }

    func cancelScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
    }

    private func runScanTask(
        roots: [LibraryRootFolder],
        onProgress: @escaping @MainActor (LibraryScanProgress) -> Void
    ) async throws -> [LibraryScanReport] {
        activeScanTask?.cancel()

        let task = Task<[LibraryScanReport], Error> { [scanner] in
            var reports: [LibraryScanReport] = []
            for root in roots {
                try Task.checkCancellation()
                let report = try await scanner.scanRootFolder(root) { progress in
                    await MainActor.run {
                        onProgress(progress)
                    }
                }
                reports.append(report)
            }
            return reports
        }
        activeScanTask = task

        defer {
            if activeScanTask == task {
                activeScanTask = nil
            }
        }
        return try await task.value
    }
}

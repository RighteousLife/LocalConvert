import Foundation
import CryptoKit

// MARK: - Duplicate File Scanner Models

enum DuplicateKeepPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case newest = "Keep Newest"
    case oldest = "Keep Oldest"

    var id: String { rawValue }
}

struct DuplicateScanOptions: Equatable, Sendable {
    var includeSubdirectories: Bool = true
    var skipHiddenFiles: Bool = true
    var minimumFileSizeBytes: Int64 = 1
    var chunkSize: Int = 262_144 // 256 KiB bounded-memory read

    static let `default` = DuplicateScanOptions()
}

struct DuplicateFileEntry: Identifiable, Equatable, Hashable, Sendable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    let fileName: String
    let fileSize: Int64
    let modificationDate: Date
    let creationDate: Date
}

struct DuplicateGroup: Identifiable, Equatable, Sendable {
    var id: String { "\(fileSize)-\(sha256Hex)" }
    let fileSize: Int64
    let sha256Hex: String
    let entries: [DuplicateFileEntry]

    var reclaimableBytes: Int64 {
        guard entries.count > 1 else { return 0 }
        return fileSize * Int64(entries.count - 1)
    }

    func keeperEntry(policy: DuplicateKeepPolicy) -> DuplicateFileEntry? {
        guard !entries.isEmpty else { return nil }
        switch policy {
        case .newest:
            return entries.max { lhs, rhs in
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate < rhs.modificationDate
                }
                if lhs.creationDate != rhs.creationDate {
                    return lhs.creationDate < rhs.creationDate
                }
                return lhs.url.path > rhs.url.path
            }
        case .oldest:
            return entries.min { lhs, rhs in
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate < rhs.modificationDate
                }
                if lhs.creationDate != rhs.creationDate {
                    return lhs.creationDate < rhs.creationDate
                }
                return lhs.url.path < rhs.url.path
            }
        }
    }

    func removableEntries(policy: DuplicateKeepPolicy) -> [DuplicateFileEntry] {
        guard let keeper = keeperEntry(policy: policy) else { return [] }
        return entries.filter { $0.id != keeper.id }
    }
}

struct DuplicateScanProgress: Equatable, Sendable {
    let scannedFiles: Int
    let candidateFilesToHash: Int
    let hashedFiles: Int
}

struct DuplicateScanResult: Equatable, Sendable {
    let rootDirectory: URL
    let scannedFileCount: Int
    let hashedFileCount: Int
    let groups: [DuplicateGroup]

    var totalDuplicateFiles: Int {
        groups.reduce(0) { $0 + max(0, $1.entries.count - 1) }
    }

    var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

struct DuplicateTrashFailure: Equatable, Sendable {
    let url: URL
    let reason: String
}

struct DuplicateTrashResult: Equatable, Sendable {
    let trashedURLs: [URL]
    let reclaimedBytes: Int64
    let failures: [DuplicateTrashFailure]
}

enum DuplicateScannerError: LocalizedError, Equatable, Sendable {
    case directoryNotFound(URL)
    case notADirectory(URL)
    case cannotTrashAllCopiesInGroup(String)
    case noFilesSelected

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let url):
            return String(localized: "Folder not found: \(url.lastPathComponent)")
        case .notADirectory(let url):
            return String(localized: "Selected item is not a folder: \(url.lastPathComponent)")
        case .cannotTrashAllCopiesInGroup:
            return String(localized: "At least one copy in each duplicate group must remain kept.")
        case .noFilesSelected:
            return String(localized: "No duplicate files are selected to move to Trash.")
        }
    }
}

// MARK: - Duplicate File Scanner Engine

enum DuplicateFileScannerEngine: Sendable {

    typealias TrashHandler = @Sendable (URL) throws -> URL?

    static let liveTrashHandler: TrashHandler = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    static func scan(
        directoryURL: URL,
        options: DuplicateScanOptions = .default,
        progress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) async throws -> DuplicateScanResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try scanSynchronously(
                directoryURL: directoryURL,
                options: options,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func scanSynchronously(
        directoryURL: URL,
        options: DuplicateScanOptions = .default,
        fileManager: FileManager = .default,
        progress: (@Sendable (DuplicateScanProgress) -> Void)? = nil
    ) throws -> DuplicateScanResult {
        let resolvedRoot = directoryURL.standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedRoot.path, isDirectory: &isDir) else {
            throw DuplicateScannerError.directoryNotFound(resolvedRoot)
        }
        guard isDir.boolValue else {
            throw DuplicateScannerError.notADirectory(resolvedRoot)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeSubdirectories {
            enumOptions.insert(.skipsSubdirectoryDescendants)
        }
        if options.skipHiddenFiles {
            enumOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = fileManager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: keys,
            options: enumOptions
        ) else {
            return DuplicateScanResult(
                rootDirectory: resolvedRoot,
                scannedFileCount: 0,
                hashedFileCount: 0,
                groups: []
            )
        }

        var scannedCount = 0
        var bucketsBySize: [Int64: [DuplicateFileEntry]] = [:]

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()

            let name = fileURL.lastPathComponent
            if name == ".DS_Store" {
                continue
            }
            if options.skipHiddenFiles && name.hasPrefix(".") {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                continue
            }
            guard values?.isRegularFile == true else {
                continue
            }

            let size = Int64(values?.fileSize ?? 0)
            scannedCount += 1
            guard size >= options.minimumFileSizeBytes else {
                continue
            }

            let modDate = values?.contentModificationDate ?? Date.distantPast
            let createDate = values?.creationDate ?? modDate
            let entry = DuplicateFileEntry(
                url: fileURL.standardizedFileURL,
                fileName: name,
                fileSize: size,
                modificationDate: modDate,
                creationDate: createDate
            )
            bucketsBySize[size, default: []].append(entry)
        }

        let candidateBuckets = bucketsBySize.filter { $0.value.count >= 2 }
        let totalCandidates = candidateBuckets.values.reduce(0) { $0 + $1.count }
        progress?(DuplicateScanProgress(
            scannedFiles: scannedCount,
            candidateFilesToHash: totalCandidates,
            hashedFiles: 0
        ))

        var hashedCount = 0
        var groups: [DuplicateGroup] = []

        for size in candidateBuckets.keys.sorted(by: >) {
            guard let candidates = candidateBuckets[size] else { continue }
            var byHash: [String: [DuplicateFileEntry]] = [:]

            for entry in candidates {
                try Task.checkCancellation()
                let hash: String
                do {
                    hash = try computeSHA256(for: entry.url, chunkSize: options.chunkSize)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
                hashedCount += 1
                byHash[hash, default: []].append(entry)

                if hashedCount == totalCandidates || hashedCount % 8 == 0 {
                    progress?(DuplicateScanProgress(
                        scannedFiles: scannedCount,
                        candidateFilesToHash: totalCandidates,
                        hashedFiles: hashedCount
                    ))
                }
            }

            for (hash, matchedEntries) in byHash where matchedEntries.count >= 2 {
                let sortedEntries = matchedEntries.sorted { lhs, rhs in
                    if lhs.modificationDate != rhs.modificationDate {
                        return lhs.modificationDate > rhs.modificationDate
                    }
                    return lhs.url.path < rhs.url.path
                }
                groups.append(
                    DuplicateGroup(
                        fileSize: size,
                        sha256Hex: hash,
                        entries: sortedEntries
                    )
                )
            }
        }

        groups.sort { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return lhs.sha256Hex < rhs.sha256Hex
        }

        return DuplicateScanResult(
            rootDirectory: resolvedRoot,
            scannedFileCount: scannedCount,
            hashedFileCount: hashedCount,
            groups: groups
        )
    }

    static func computeSHA256(for url: URL, chunkSize: Int = 262_144) throws -> String {
        let effectiveChunkSize = max(4096, chunkSize)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let shouldContinue: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: effectiveChunkSize), !chunk.isEmpty else {
                    return false
                }
                hasher.update(data: chunk)
                return true
            }
            if !shouldContinue {
                break
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func selectDuplicatesToTrash(
        in groups: [DuplicateGroup],
        policy: DuplicateKeepPolicy
    ) -> Set<URL> {
        var result: Set<URL> = []
        for group in groups {
            for entry in group.removableEntries(policy: policy) {
                result.insert(entry.url.standardizedFileURL)
            }
        }
        return result
    }

    static func trashDuplicates(
        in groups: [DuplicateGroup],
        selectedURLs: Set<URL>,
        trashHandler: TrashHandler = liveTrashHandler
    ) throws -> DuplicateTrashResult {
        let selectedKeys = Set(selectedURLs.map { normalizedPathKey(for: $0) })
        guard !selectedKeys.isEmpty else {
            throw DuplicateScannerError.noFilesSelected
        }

        var targetsToTrash: [DuplicateFileEntry] = []
        var seenTargetKeys: Set<String> = []

        for group in groups {
            let groupMatches = group.entries.filter { selectedKeys.contains(normalizedPathKey(for: $0.url)) }
            guard !groupMatches.isEmpty else { continue }

            // Safety invariant: NEVER delete every copy in a duplicate group
            let remainingCount = group.entries.count - groupMatches.count
            guard remainingCount >= 1 else {
                throw DuplicateScannerError.cannotTrashAllCopiesInGroup(group.sha256Hex)
            }

            for entry in groupMatches {
                let key = normalizedPathKey(for: entry.url)
                if seenTargetKeys.insert(key).inserted {
                    targetsToTrash.append(entry)
                }
            }
        }

        guard !targetsToTrash.isEmpty else {
            throw DuplicateScannerError.noFilesSelected
        }

        var trashedURLs: [URL] = []
        var reclaimedBytes: Int64 = 0
        var failures: [DuplicateTrashFailure] = []

        for entry in targetsToTrash {
            do {
                _ = try trashHandler(entry.url)
                trashedURLs.append(entry.url)
                reclaimedBytes += entry.fileSize
            } catch {
                failures.append(DuplicateTrashFailure(url: entry.url, reason: error.localizedDescription))
            }
        }

        return DuplicateTrashResult(
            trashedURLs: trashedURLs,
            reclaimedBytes: reclaimedBytes,
            failures: failures
        )
    }

    private static func normalizedPathKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

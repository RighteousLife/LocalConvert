import Foundation
import CryptoKit

// MARK: - Reconcile & Relink Models

enum RelinkMatchConfidence: String, Codable, Hashable, CaseIterable, Sendable {
    case exactContentHash
    case partialHashAndSize
    case sizeAndDuration
    case unverifiedReplacement

    var displayLabel: String {
        switch self {
        case .exactContentHash: return "Exact Content Match"
        case .partialHashAndSize: return "Header & Size Match"
        case .sizeAndDuration: return "Size Match"
        case .unverifiedReplacement: return "Manual Selection"
        }
    }

    var systemImage: String {
        switch self {
        case .exactContentHash: return "checkmark.seal.fill"
        case .partialHashAndSize: return "checkmark.circle.fill"
        case .sizeAndDuration: return "questionmark.circle.fill"
        case .unverifiedReplacement: return "exclamationmark.triangle.fill"
        }
    }
}

struct RelinkCandidate: Identifiable, Hashable, Sendable {
    var id: String { "\(assetID.uuidString)::\(url.path)" }
    let assetID: UUID
    let url: URL
    let confidence: RelinkMatchConfidence
    let fileSizeBytes: Int64
    let contentSHA256: String?
}

struct RelinkOutcome: Equatable, Sendable {
    let assetID: UUID
    let updatedURL: URL
    let confidence: RelinkMatchConfidence
    let contentSHA256: String
    let refreshedBookmark: Bool
}

struct MissingFileReconcileReport: Equatable, Sendable {
    let checkedCount: Int
    let autoRecoveredViaBookmarkCount: Int
    let markedMissingCount: Int
    let missingAssetIDs: [UUID]
    let recoveredAssetIDs: [UUID]
}

enum MissingFileReconcileError: Error, LocalizedError, Equatable, Sendable {
    case assetNotFound(UUID)
    case candidateNotFound(String)
    case unsupportedAudioFormat(String)

    var errorDescription: String? {
        switch self {
        case .assetNotFound(let id):
            return "Audio library entry (\(id.uuidString)) could not be found."
        case .candidateNotFound(let path):
            return "Selected replacement file does not exist: \(path)"
        case .unsupportedAudioFormat(let ext):
            return "Selected file is not a supported audio format (.\(ext))."
        }
    }
}

// MARK: - MissingFileReconciler

actor MissingFileReconciler {
    private static let streamChunkBytes = 65_536

    private let database: AudioLibraryDatabase

    init(database: AudioLibraryDatabase) {
        self.database = database
    }

    /// Streams file bytes in bounded 64 KiB chunks to compute the exact SHA-256 without loading huge files into RAM.
    static func computeFullContentSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: streamChunkBytes) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func computePartialSHA256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: streamChunkBytes)) ?? Data()
        let digest = SHA256.hash(data: chunk)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies indexed track availability and automatically recovers moved files whose
    /// security-scoped bookmark resolves cleanly on disk without modifying source files.
    func reconcileAllAssets() async throws -> MissingFileReconcileReport {
        let allRecords = try await database.fetchAllAssets()
        let fm = FileManager.default
        var missingIDs: [UUID] = []
        var restoredOKIDs: [UUID] = []
        var recoveredBookmarkIDs: [UUID] = []

        for record in allRecords {
            try Task.checkCancellation()
            let asset = record.asset
            if fm.fileExists(atPath: asset.canonicalPath) {
                if asset.status == .missing {
                    restoredOKIDs.append(asset.id)
                }
                continue
            }

            if let bookmarkData = asset.bookmarkData,
               let resolved = AudioLibraryBookmarkHelper.resolveBookmark(bookmarkData) {
                let scoped = resolved.url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { resolved.url.stopAccessingSecurityScopedResource() }
                }
                let canonicalResolved = resolved.url.standardizedFileURL.resolvingSymlinksInPath()
                if fm.fileExists(atPath: canonicalResolved.path),
                   let fmt = AudioLibraryFormatSupport.resolveAudioFormat(for: canonicalResolved) {
                    let attrs = (try? fm.attributesOfItem(atPath: canonicalResolved.path)) ?? [:]
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? asset.fileSizeBytes
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? asset.modificationTime
                    let refreshedBookmark = AudioLibraryBookmarkHelper.createBookmark(for: canonicalResolved) ?? bookmarkData
                    let partialHash = asset.partialHashSHA256 ?? Self.computePartialSHA256(url: canonicalResolved)
                    let fullHash = (try? Self.computeFullContentSHA256(url: canonicalResolved)) ?? asset.contentSHA256

                    try await database.relinkAsset(
                        id: asset.id,
                        newCanonicalPath: canonicalResolved.path,
                        newFilename: canonicalResolved.lastPathComponent,
                        newExtension: canonicalResolved.pathExtension.lowercased(),
                        newFormatRawValue: fmt.rawValue,
                        fileSizeBytes: size,
                        modificationTime: mtime,
                        bookmarkData: refreshedBookmark,
                        partialHashSHA256: partialHash,
                        contentSHA256: fullHash
                    )
                    recoveredBookmarkIDs.append(asset.id)
                    continue
                }
            }

            if asset.status != .missing {
                missingIDs.append(asset.id)
            }
        }

        if !restoredOKIDs.isEmpty {
            try await database.markAssetsStatus(ids: restoredOKIDs, status: .ok)
        }
        if !missingIDs.isEmpty {
            try await database.markAssetsStatus(ids: missingIDs, status: .missing)
        }

        let currentMissing = try await database.fetchAssets(matching: AudioCollectionFilter(missingOnly: true))
        return MissingFileReconcileReport(
            checkedCount: allRecords.count,
            autoRecoveredViaBookmarkCount: recoveredBookmarkIDs.count,
            markedMissingCount: currentMissing.count,
            missingAssetIDs: currentMissing.map(\.asset.id),
            recoveredAssetIDs: recoveredBookmarkIDs
        )
    }

    /// Manually relinks a missing asset to `candidateURL` after verifying content SHA-256 / size
    /// and storing a fresh security-scoped bookmark without altering the source audio file.
    func relinkAsset(assetID: UUID, to candidateURL: URL) async throws -> RelinkOutcome {
        guard let existing = try await database.fetchAsset(id: assetID) else {
            throw MissingFileReconcileError.assetNotFound(assetID)
        }

        let scoped = candidateURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { candidateURL.stopAccessingSecurityScopedResource() }
        }

        let canonicalURL = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: canonicalURL.path) else {
            throw MissingFileReconcileError.candidateNotFound(canonicalURL.path)
        }
        guard let detectedFormat = AudioLibraryFormatSupport.resolveAudioFormat(for: canonicalURL) else {
            throw MissingFileReconcileError.unsupportedAudioFormat(canonicalURL.pathExtension)
        }

        let attrs = try fm.attributesOfItem(atPath: canonicalURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
        let partialHash = Self.computePartialSHA256(url: canonicalURL)
        let fullHash = try Self.computeFullContentSHA256(url: canonicalURL)
        let bookmark = AudioLibraryBookmarkHelper.createBookmark(for: canonicalURL)

        let confidence = Self.evaluateConfidence(
            existingAsset: existing.asset,
            candidateSize: size,
            candidatePartialHash: partialHash,
            candidateFullHash: fullHash
        )

        try await database.relinkAsset(
            id: assetID,
            newCanonicalPath: canonicalURL.path,
            newFilename: canonicalURL.lastPathComponent,
            newExtension: canonicalURL.pathExtension.lowercased(),
            newFormatRawValue: detectedFormat.rawValue,
            fileSizeBytes: size,
            modificationTime: mtime,
            bookmarkData: bookmark,
            partialHashSHA256: partialHash,
            contentSHA256: fullHash
        )

        return RelinkOutcome(
            assetID: assetID,
            updatedURL: canonicalURL,
            confidence: confidence,
            contentSHA256: fullHash,
            refreshedBookmark: bookmark != nil
        )
    }

    /// Scans `folderURL` for candidate files matching any of `missingAssets` by size & SHA-256.
    func scanFolderForCandidates(
        folderURL: URL,
        missingAssets: [AudioLibraryRecord]
    ) async throws -> [RelinkCandidate] {
        guard !missingAssets.isEmpty else { return [] }

        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { folderURL.stopAccessingSecurityScopedResource() }
        }

        let canonicalRoot = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonicalRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let missingBySize = Dictionary(grouping: missingAssets, by: \.asset.fileSizeBytes)
        let discoveredURLs = Self.discoverAudioURLs(in: canonicalRoot)

        var candidates: [RelinkCandidate] = []
        for candidateURL in discoveredURLs {
            try Task.checkCancellation()
            let attrs = (try? fm.attributesOfItem(atPath: candidateURL.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            guard let matchedBySize = missingBySize[size], !matchedBySize.isEmpty else {
                continue
            }

            let partial = Self.computePartialSHA256(url: candidateURL)
            let full = try? Self.computeFullContentSHA256(url: candidateURL)

            for record in matchedBySize {
                let confidence = Self.evaluateConfidence(
                    existingAsset: record.asset,
                    candidateSize: size,
                    candidatePartialHash: partial,
                    candidateFullHash: full
                )
                candidates.append(RelinkCandidate(
                    assetID: record.asset.id,
                    url: candidateURL,
                    confidence: confidence,
                    fileSizeBytes: size,
                    contentSHA256: full
                ))
            }
        }

        return candidates.sorted { lhs, rhs in
            let rank: (RelinkMatchConfidence) -> Int = { conf in
                switch conf {
                case .exactContentHash: return 0
                case .partialHashAndSize: return 1
                case .sizeAndDuration: return 2
                case .unverifiedReplacement: return 3
                }
            }
            if rank(lhs.confidence) != rank(rhs.confidence) {
                return rank(lhs.confidence) < rank(rhs.confidence)
            }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    private static func discoverAudioURLs(in canonicalRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var discoveredURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true || vals?.isRegularFile != true {
                continue
            }
            guard AudioLibraryFormatSupport.resolveAudioFormat(for: fileURL) != nil else { continue }
            discoveredURLs.append(fileURL.standardizedFileURL.resolvingSymlinksInPath())
        }
        return discoveredURLs
    }

    private static func evaluateConfidence(
        existingAsset: AudioAsset,
        candidateSize: Int64,
        candidatePartialHash: String?,
        candidateFullHash: String?
    ) -> RelinkMatchConfidence {
        if let expectedFull = existingAsset.contentSHA256,
           let actualFull = candidateFullHash,
           !expectedFull.isEmpty,
           expectedFull == actualFull {
            return .exactContentHash
        }
        if let expectedPartial = existingAsset.partialHashSHA256,
           let actualPartial = candidatePartialHash,
           !expectedPartial.isEmpty,
           expectedPartial == actualPartial,
           existingAsset.fileSizeBytes == candidateSize {
            return .partialHashAndSize
        }
        if existingAsset.fileSizeBytes == candidateSize {
            return .sizeAndDuration
        }
        return .unverifiedReplacement
    }
}

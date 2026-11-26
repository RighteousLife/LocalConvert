import Foundation
import CryptoKit
import os.log

// MARK: - Recovery Artifact Models

struct StagedArtifact: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let contentSHA256: String
    let byteSize: Int64
    let originalFilename: String
    let createdAt: Date
}

struct RecoveryArtifactRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let contentSHA256: String
    let relativeBlobPath: String
    let byteSize: Int64
    let originalFilename: String
    let createdAt: Date
    var lastAccessedAt: Date
}

struct RecoveryArtifactManifest: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    var records: [UUID: RecoveryArtifactRecord]
}

enum RecoveryArtifactError: LocalizedError, Sendable, Equatable {
    case sourceFileMissing(URL)
    case artifactNotFound(UUID)
    case blobMissingOnDisk(UUID)
    case destinationOccupied(URL)
    case sourceOverwriteForbidden(URL)
    case artifactExceedsStorageBudget(byteSize: Int64, budgetBytes: Int64)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .sourceFileMissing(let url):
            return "Source file missing for recovery staging: \(url.lastPathComponent)"
        case .artifactNotFound(let id):
            return "Recovery artifact \(id.uuidString) is no longer available."
        case .blobMissingOnDisk(let id):
            return "Recovery blob for artifact \(id.uuidString) is missing on disk."
        case .destinationOccupied(let url):
            return "Cannot restore '\(url.lastPathComponent)' because another file already exists there."
        case .sourceOverwriteForbidden(let url):
            return "Refusing to overwrite original source file '\(url.lastPathComponent)' during recovery."
        case .artifactExceedsStorageBudget(let size, let budget):
            return "Artifact (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) exceeds configured undo storage budget (\(ByteCountFormatter.string(fromByteCount: budget, countStyle: .file)))."
        case .ioFailure(let msg):
            return "Recovery storage error: \(msg)"
        }
    }
}

// MARK: - Recovery Artifact Manager Actor

/// Content-addressed, deduplicated staging store under `Application Support/<bundleID>/RecoveryArtifacts/`.
/// NEVER uses `FileManager.default.temporaryDirectory` (preventing deletion by `OutputManager.cleanupTemporaryFiles`).
/// Guarantees pinned artifacts referenced by active/undone entries are NEVER evicted behind the coordinator's back.
actor RecoveryArtifactManager {

    static let shared = RecoveryArtifactManager()

    private let logger = Logger(subsystem: "com.localconvert.app", category: "RecoveryArtifactManager")
    let baseDirectoryURL: URL
    private let blobsDirectoryURL: URL
    private let manifestFileURL: URL

    private var manifest: RecoveryArtifactManifest
    private var pinnedArtifactIDs: Set<UUID> = []

    /// Default storage root: `~/Library/Application Support/<bundleID>/RecoveryArtifacts/` (sandboxed under tests).
    static func defaultDirectoryURL() -> URL {
        AppStoragePaths.recoveryArtifactsDirectory
    }

    init(baseDirectoryURL: URL? = nil) {
        let root = baseDirectoryURL ?? Self.defaultDirectoryURL()
        self.baseDirectoryURL = root
        self.blobsDirectoryURL = root.appendingPathComponent("blobs", isDirectory: true)
        self.manifestFileURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        try? FileManager.default.createDirectory(at: self.blobsDirectoryURL, withIntermediateDirectories: true)
        self.manifest = Self.loadManifest(from: self.manifestFileURL)
    }

    // MARK: - Staging APIs

    /// Moves an application-managed output file into content-addressed staging (zero duplicate disk copy).
    /// If an identical SHA-256 blob already exists, removes `sourceURL` and shares the deduplicated blob.
    func stageFileByMoving(
        from sourceURL: URL,
        originalFilename: String? = nil,
        maxStorageBudgetBytes: Int64? = nil
    ) async throws -> StagedArtifact {
        let std = sourceURL.standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: std.path) else {
            throw RecoveryArtifactError.sourceFileMissing(std)
        }
        let attrs = try fm.attributesOfItem(atPath: std.path)
        let byteSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if let budget = maxStorageBudgetBytes, byteSize > budget {
            throw RecoveryArtifactError.artifactExceedsStorageBudget(byteSize: byteSize, budgetBytes: budget)
        }
        guard let digest = FileIdentitySnapshot.streamingSHA256Hex(url: std) else {
            throw RecoveryArtifactError.ioFailure("Failed to hash \(std.lastPathComponent)")
        }

        let relativeBlobPath = "blobs/\(digest).blob"
        let blobURL = baseDirectoryURL.appendingPathComponent(relativeBlobPath)

        if fm.fileExists(atPath: blobURL.path) {
            // Deduplicated hit: remove moved file cleanly
            try fm.removeItem(at: std)
        } else {
            try fm.createDirectory(at: blobsDirectoryURL, withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: std, to: blobURL)
            } catch {
                // Cross-volume fallback: atomic copy then remove source
                let tmpBlob = blobsDirectoryURL.appendingPathComponent(".\(digest).tmp-\(UUID().uuidString)")
                try fm.copyItem(at: std, to: tmpBlob)
                _ = try fm.replaceItemAt(blobURL, withItemAt: tmpBlob)
                try fm.removeItem(at: std)
            }
        }

        let artifactID = UUID()
        let now = Date()
        let record = RecoveryArtifactRecord(
            id: artifactID,
            contentSHA256: digest,
            relativeBlobPath: relativeBlobPath,
            byteSize: byteSize,
            originalFilename: originalFilename ?? std.lastPathComponent,
            createdAt: now,
            lastAccessedAt: now
        )
        manifest.records[artifactID] = record
        persistManifest()

        return StagedArtifact(
            id: artifactID,
            contentSHA256: digest,
            byteSize: byteSize,
            originalFilename: record.originalFilename,
            createdAt: now
        )
    }

    /// Copies a file into content-addressed staging without altering the source (e.g., pre-edit backup).
    func stageFileByCopying(
        from sourceURL: URL,
        maxStorageBudgetBytes: Int64? = nil
    ) async throws -> StagedArtifact {
        let std = sourceURL.standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: std.path) else {
            throw RecoveryArtifactError.sourceFileMissing(std)
        }
        let attrs = try fm.attributesOfItem(atPath: std.path)
        let byteSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if let budget = maxStorageBudgetBytes, byteSize > budget {
            throw RecoveryArtifactError.artifactExceedsStorageBudget(byteSize: byteSize, budgetBytes: budget)
        }
        guard let digest = FileIdentitySnapshot.streamingSHA256Hex(url: std) else {
            throw RecoveryArtifactError.ioFailure("Failed to hash \(std.lastPathComponent)")
        }

        let relativeBlobPath = "blobs/\(digest).blob"
        let blobURL = baseDirectoryURL.appendingPathComponent(relativeBlobPath)

        if !fm.fileExists(atPath: blobURL.path) {
            try fm.createDirectory(at: blobsDirectoryURL, withIntermediateDirectories: true)
            let tmpBlob = blobsDirectoryURL.appendingPathComponent(".\(digest).tmp-\(UUID().uuidString)")
            try fm.copyItem(at: std, to: tmpBlob)
            try fm.moveItem(at: tmpBlob, to: blobURL)
        }

        let artifactID = UUID()
        let now = Date()
        let record = RecoveryArtifactRecord(
            id: artifactID,
            contentSHA256: digest,
            relativeBlobPath: relativeBlobPath,
            byteSize: byteSize,
            originalFilename: std.lastPathComponent,
            createdAt: now,
            lastAccessedAt: now
        )
        manifest.records[artifactID] = record
        persistManifest()

        return StagedArtifact(
            id: artifactID,
            contentSHA256: digest,
            byteSize: byteSize,
            originalFilename: std.lastPathComponent,
            createdAt: now
        )
    }

    /// Stages an in-memory snapshot (e.g., album artwork or stripped raw metadata sidecar).
    func stageData(
        _ data: Data,
        filenameHint: String,
        maxStorageBudgetBytes: Int64? = nil
    ) async throws -> StagedArtifact {
        let byteSize = Int64(data.count)
        if let budget = maxStorageBudgetBytes, byteSize > budget {
            throw RecoveryArtifactError.artifactExceedsStorageBudget(byteSize: byteSize, budgetBytes: budget)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let relativeBlobPath = "blobs/\(digest).blob"
        let blobURL = baseDirectoryURL.appendingPathComponent(relativeBlobPath)

        if !FileManager.default.fileExists(atPath: blobURL.path) {
            try FileManager.default.createDirectory(at: blobsDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: blobURL, options: .atomic)
        }

        let artifactID = UUID()
        let now = Date()
        let record = RecoveryArtifactRecord(
            id: artifactID,
            contentSHA256: digest,
            relativeBlobPath: relativeBlobPath,
            byteSize: byteSize,
            originalFilename: filenameHint,
            createdAt: now,
            lastAccessedAt: now
        )
        manifest.records[artifactID] = record
        persistManifest()

        return StagedArtifact(
            id: artifactID,
            contentSHA256: digest,
            byteSize: byteSize,
            originalFilename: filenameHint,
            createdAt: now
        )
    }

    // MARK: - Restoration & Reads

    /// Restores a staged artifact to `destinationURL` without deleting the underlying blob
    /// (since undo/redo may still reference it). Caller must explicitly guard `protectedSourceURLs`.
    @discardableResult
    func restoreFile(
        artifactID: UUID,
        to destinationURL: URL,
        protectedSourceURLs: [URL] = [],
        allowOverwrite: Bool = false
    ) async throws -> URL {
        guard var record = manifest.records[artifactID] else {
            throw RecoveryArtifactError.artifactNotFound(artifactID)
        }
        let dest = destinationURL.standardizedFileURL
        let resolvedDest = dest.resolvingSymlinksInPath()
        for protected in protectedSourceURLs {
            if protected.standardizedFileURL == dest || protected.standardizedFileURL.resolvingSymlinksInPath() == resolvedDest {
                throw RecoveryArtifactError.sourceOverwriteForbidden(dest)
            }
        }

        let blobURL = baseDirectoryURL.appendingPathComponent(record.relativeBlobPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: blobURL.path) else {
            throw RecoveryArtifactError.blobMissingOnDisk(artifactID)
        }

        if fm.fileExists(atPath: dest.path) && !allowOverwrite {
            throw RecoveryArtifactError.destinationOccupied(dest)
        }

        let parent = dest.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let siblingTmp = parent.appendingPathComponent(".\(dest.lastPathComponent).restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: siblingTmp) }

        try fm.copyItem(at: blobURL, to: siblingTmp)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: siblingTmp)
        } else {
            try fm.moveItem(at: siblingTmp, to: dest)
        }

        record.lastAccessedAt = Date()
        manifest.records[artifactID] = record
        persistManifest()
        return dest
    }

    func readData(artifactID: UUID) async throws -> Data {
        guard var record = manifest.records[artifactID] else {
            throw RecoveryArtifactError.artifactNotFound(artifactID)
        }
        let blobURL = baseDirectoryURL.appendingPathComponent(record.relativeBlobPath)
        guard FileManager.default.fileExists(atPath: blobURL.path) else {
            throw RecoveryArtifactError.blobMissingOnDisk(artifactID)
        }
        record.lastAccessedAt = Date()
        manifest.records[artifactID] = record
        return try Data(contentsOf: blobURL)
    }

    func hasArtifact(id: UUID) -> Bool {
        guard let record = manifest.records[id] else { return false }
        let blobURL = baseDirectoryURL.appendingPathComponent(record.relativeBlobPath)
        return FileManager.default.fileExists(atPath: blobURL.path)
    }

    func uniqueBlobCount() -> Int {
        Set(manifest.records.values.map(\.relativeBlobPath)).count
    }

    // MARK: - Pinning, Reference Counting & Bounded Eviction

    /// Synchronizes pinned IDs from `UndoRedoCoordinator` (all `referencedArtifactIDs` in active `undoStack` + `redoStack`).
    func syncPinnedArtifacts(_ ids: Set<UUID>) {
        pinnedArtifactIDs = ids
    }

    /// Releases a single artifact when its owning command is permanently discarded.
    /// Deletes the underlying blob ONLY if zero remaining manifest records reference that SHA-256 blob.
    func releaseArtifact(id: UUID) {
        pinnedArtifactIDs.remove(id)
        guard let removed = manifest.records.removeValue(forKey: id) else { return }
        deleteBlobIfUnreferenced(relativePath: removed.relativeBlobPath)
        persistManifest()
    }

    /// Computes deduplicated on-disk byte usage across all unique blobs currently in manifest.
    func totalDiskUsageBytes() -> Int64 {
        var uniqueSizes: [String: Int64] = [:]
        for record in manifest.records.values {
            uniqueSizes[record.relativeBlobPath] = record.byteSize
        }
        return uniqueSizes.values.reduce(0, +)
    }

    /// Evicts ONLY unpinned artifacts (oldest `lastAccessedAt` first) until `totalDiskUsageBytes() <= maxBytes`
    /// or no unpinned artifacts remain. NEVER deletes blobs still referenced by `pinnedArtifactIDs`.
    @discardableResult
    func evictUnpinned(downTo maxBytes: Int64) -> Int64 {
        let unpinnedSorted = manifest.records.values
            .filter { !pinnedArtifactIDs.contains($0.id) }
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }

        var evictedRecordCount = 0
        for record in unpinnedSorted {
            if totalDiskUsageBytes() <= maxBytes { break }
            manifest.records.removeValue(forKey: record.id)
            deleteBlobIfUnreferenced(relativePath: record.relativeBlobPath)
            evictedRecordCount += 1
        }
        if evictedRecordCount > 0 {
            persistManifest()
        }
        return totalDiskUsageBytes()
    }

    /// Removes orphaned `.blob` files on disk not referenced by any record in `manifest.json`.
    func reconcileOrphanedBlobs() {
        let fm = FileManager.default
        let referencedPaths = Set(manifest.records.values.map(\.relativeBlobPath))
        guard let files = try? fm.contentsOfDirectory(at: blobsDirectoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            let rel = "blobs/\(file.lastPathComponent)"
            if !referencedPaths.contains(rel) {
                try? fm.removeItem(at: file)
            }
        }
    }

    func removeAllUnpinned() {
        let unpinned = manifest.records.keys.filter { !pinnedArtifactIDs.contains($0) }
        for id in unpinned {
            if let removed = manifest.records.removeValue(forKey: id) {
                deleteBlobIfUnreferenced(relativePath: removed.relativeBlobPath)
            }
        }
        reconcileOrphanedBlobs()
        persistManifest()
    }

    // MARK: - Private Persistence Helpers

    private func deleteBlobIfUnreferenced(relativePath: String) {
        let stillReferenced = manifest.records.values.contains { $0.relativeBlobPath == relativePath }
        if !stillReferenced {
            let blobURL = baseDirectoryURL.appendingPathComponent(relativePath)
            try? FileManager.default.removeItem(at: blobURL)
        }
    }

    private static func loadManifest(from url: URL) -> RecoveryArtifactManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RecoveryArtifactManifest(schemaVersion: RecoveryArtifactManifest.currentSchemaVersion, records: [:])
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RecoveryArtifactManifest.self, from: data)
        } catch {
            let ts = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("manifest.corrupted.\(ts).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return RecoveryArtifactManifest(schemaVersion: RecoveryArtifactManifest.currentSchemaVersion, records: [:])
        }
    }

    private func persistManifest() {
        do {
            try FileManager.default.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(to: manifestFileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist recovery manifest: \(error.localizedDescription, privacy: .public)")
        }
    }
}

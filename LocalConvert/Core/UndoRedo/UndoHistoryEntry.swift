import Foundation
import CryptoKit

// MARK: - Entry Lifecycle State

enum UndoEntryState: String, Codable, Sendable, Equatable {
    /// Currently applied on the active undo stack (`undoStack`).
    case applied
    /// Currently undone on the active redo stack (`redoStack`).
    case undone
    /// Archived off the active chain (e.g., displaced by a new branch, evicted by capacity, or irreversible audit).
    case archived
    /// Previously active entry invalidated because a target file/artifact is missing or modified externally.
    case stale
}

enum UndoArchiveReason: String, Codable, Sendable, Equatable {
    case branchedNewOperation = "Replaced by new edit branch"
    case evictedByCapacity = "Evicted by history limit"
    case evictedByStorageBudget = "Evicted to stay within storage limit"
    case sessionEnded = "Session-only operation expired on restart"
    case inherentlyIrreversible = "Irreversible operation"
    case fileInvalidated = "Target file missing or changed externally"
}

// MARK: - File Identity & Bookmark Snapshot

/// Captures file identity without duplicating file contents in memory.
/// Used to verify file identity before reversing renames, moves, Trash restores, or output deletions.
struct FileIdentitySnapshot: Codable, Sendable, Equatable, Hashable {
    let standardizedPath: String
    /// Security-scoped or standard macOS bookmark data when available (future sandbox readiness + alias tracking).
    let bookmarkData: Data?
    /// Volume-local `URLResourceKey.fileResourceIdentifierKey` archived securely via `NSKeyedArchiver`.
    let fileResourceIdentifierData: Data?
    let fileSizeBytes: Int64?
    let modificationDate: Date?
    /// Optional SHA-256 hex digest (computed for staged/managed outputs or small files).
    let contentSHA256: String?
    /// True if the file is expected to exist at `standardizedPath` right now in the entry's current state.
    let expectedToExist: Bool

    var url: URL {
        URL(fileURLWithPath: standardizedPath)
    }

    static func capture(
        url: URL,
        expectedToExist: Bool = true,
        includeContentHash: Bool = false,
        includeBookmark: Bool = false
    ) -> FileIdentitySnapshot {
        let std = url.standardizedFileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: std.path) else {
            return FileIdentitySnapshot(
                standardizedPath: std.path,
                bookmarkData: nil,
                fileResourceIdentifierData: nil,
                fileSizeBytes: nil,
                modificationDate: nil,
                contentSHA256: nil,
                expectedToExist: expectedToExist
            )
        }

        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        let values = try? std.resourceValues(forKeys: keys)
        let size = values?.fileSize.map { Int64($0) }
        let mtime = values?.contentModificationDate
        let resourceIDData: Data?
        if let resID = values?.fileResourceIdentifier as? NSSecureCoding {
            resourceIDData = try? NSKeyedArchiver.archivedData(withRootObject: resID, requiringSecureCoding: true)
        } else {
            resourceIDData = nil
        }

        let bookmark: Data? = includeBookmark ? (try? std.bookmarkData(options: [.minimalBookmark])) : nil
        let digest: String? = includeContentHash ? Self.streamingSHA256Hex(url: std) : nil

        return FileIdentitySnapshot(
            standardizedPath: std.path,
            bookmarkData: bookmark,
            fileResourceIdentifierData: resourceIDData,
            fileSizeBytes: size,
            modificationDate: mtime,
            contentSHA256: digest,
            expectedToExist: expectedToExist
        )
    }

    /// Validates whether the disk state at `standardizedPath` still matches this snapshot.
    func validateMatchesDisk() -> FileValidationStatus {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: standardizedPath)
        if !expectedToExist {
            return exists ? .unexpectedFileAtDestination(url) : .valid
        }
        guard exists else {
            return .missingFile(url)
        }

        let std = url
        let values = try? std.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        if let expectedSize = fileSizeBytes, let actualSize = values?.fileSize.map({ Int64($0) }), expectedSize != actualSize {
            return .externallyModified(url, detail: "File size changed (\(expectedSize) → \(actualSize) bytes)")
        }
        if let expectedMtime = modificationDate, let actualMtime = values?.contentModificationDate,
           abs(expectedMtime.timeIntervalSince(actualMtime)) > 1.0 {
            return .externallyModified(url, detail: "Modification timestamp changed externally")
        }
        if let expectedResIDData = fileResourceIdentifierData,
           let actualResID = values?.fileResourceIdentifier as? NSSecureCoding,
           let actualResIDData = try? NSKeyedArchiver.archivedData(withRootObject: actualResID, requiringSecureCoding: true),
           expectedResIDData != actualResIDData {
            return .externallyModified(url, detail: "File identity changed externally")
        }
        if let expectedHash = contentSHA256, let actualHash = Self.streamingSHA256Hex(url: std), expectedHash != actualHash {
            return .externallyModified(url, detail: "File contents changed externally")
        }
        return .valid
    }

    static func streamingSHA256Hex(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = (try? handle.read(upToCount: 1_048_576)) ?? Data()
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum FileValidationStatus: Sendable, Equatable {
    case valid
    case missingFile(URL)
    case unexpectedFileAtDestination(URL)
    case externallyModified(URL, detail: String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var failureReason: String? {
        switch self {
        case .valid:
            return nil
        case .missingFile(let url):
            return "File no longer exists at '\(url.lastPathComponent)'."
        case .unexpectedFileAtDestination(let url):
            return "Destination '\(url.lastPathComponent)' is now occupied by another file."
        case .externallyModified(let url, let detail):
            return "'\(url.lastPathComponent)' was modified outside LocalConvert (\(detail))."
        }
    }
}

// MARK: - Undo History Entry

/// Codable, Sendable record representing an entry in active undo/redo chains or archived branches.
struct UndoHistoryEntry: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let operationType: UndoOperationType
    let title: String
    let timestamp: Date
    let context: OperationContext
    let affectedURLs: [URL]
    var isReversible: Bool
    var irreversibilityReason: String?
    let survivesRestart: Bool
    let transactionGroupID: UUID?

    var state: UndoEntryState
    let branchID: UUID
    var archivedAt: Date?
    var archiveReason: UndoArchiveReason?

    var fileReferences: [FileIdentitySnapshot]
    var referencedArtifactIDs: [UUID]
    var persistenceDescriptor: UndoCommandPersistenceDescriptor?

    var affectedSummary: String {
        guard let first = affectedURLs.first else {
            return context.displayName
        }
        if affectedURLs.count == 1 {
            return first.lastPathComponent
        }
        return "\(first.lastPathComponent) +\(affectedURLs.count - 1)"
    }

    init(
        id: UUID,
        operationType: UndoOperationType,
        title: String,
        timestamp: Date,
        context: OperationContext,
        affectedURLs: [URL],
        isReversible: Bool,
        irreversibilityReason: String? = nil,
        survivesRestart: Bool,
        transactionGroupID: UUID? = nil,
        state: UndoEntryState = .applied,
        branchID: UUID,
        archivedAt: Date? = nil,
        archiveReason: UndoArchiveReason? = nil,
        fileReferences: [FileIdentitySnapshot] = [],
        referencedArtifactIDs: [UUID] = [],
        persistenceDescriptor: UndoCommandPersistenceDescriptor? = nil
    ) {
        self.id = id
        self.operationType = operationType
        self.title = title
        self.timestamp = timestamp
        self.context = context
        self.affectedURLs = affectedURLs
        self.isReversible = isReversible
        self.irreversibilityReason = irreversibilityReason
        self.survivesRestart = survivesRestart
        self.transactionGroupID = transactionGroupID
        self.state = state
        self.branchID = branchID
        self.archivedAt = archivedAt
        self.archiveReason = archiveReason
        self.fileReferences = fileReferences
        self.referencedArtifactIDs = referencedArtifactIDs
        self.persistenceDescriptor = persistenceDescriptor
    }

    @MainActor
    init(
        from command: any UndoableCommand,
        state: UndoEntryState = .applied,
        branchID: UUID
    ) {
        let descriptor = command.persistenceDescriptor
        let refs = command.fileIdentitySnapshots
        self.init(
            id: command.id,
            operationType: command.operationType,
            title: command.title,
            timestamp: command.timestamp,
            context: command.context,
            affectedURLs: command.affectedURLs,
            isReversible: command.isReversible,
            irreversibilityReason: command.irreversibilityReason,
            survivesRestart: command.survivesRestart,
            transactionGroupID: command.transactionGroupID,
            state: state,
            branchID: branchID,
            fileReferences: refs,
            referencedArtifactIDs: command.referencedArtifactIDs,
            persistenceDescriptor: descriptor
        )
    }
}

// MARK: - Journal Persistence Schema

struct ContextJournalSnapshot: Codable, Sendable, Equatable {
    let context: OperationContext
    let activeBranchID: UUID
    /// Oldest -> newest applied entries (`undoStack`).
    let undoEntries: [UndoHistoryEntry]
    /// Ordered next-to-redo LAST (`redoStack`, matching LIFO stack order).
    let redoEntries: [UndoHistoryEntry]
    /// Bounded archive of displaced branches and irreversible/stale records.
    let archivedEntries: [UndoHistoryEntry]
}

struct UndoHistoryJournal: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let savedAt: Date
    /// Keyed by `OperationContext.storageKey` for deterministic JSON encoding.
    let contexts: [String: ContextJournalSnapshot]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        savedAt: Date = Date(),
        contexts: [String: ContextJournalSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.contexts = contexts
    }
}

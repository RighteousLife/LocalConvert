import Foundation

// MARK: - Persistence Descriptor & Rehydration

/// Serializable snapshot emitted by commands with `survivesRestart == true`.
/// Enables `UndoRedoCoordinator` to rehydrate live `UndoableCommand` instances across app launches
/// without storing closures or duplicating large media files.
struct UndoCommandPersistenceDescriptor: Codable, Sendable, Equatable {
    /// Stable module-owned discriminator, e.g. `"core.outputCreation"`, `"image.batchRename"`.
    let commandKind: String
    /// Schema version for this command's `payloadData`.
    let schemaVersion: Int
    /// JSON-encoded command-specific state diff / manifest.
    let payloadData: Data
    /// IDs of artifacts staged in `RecoveryArtifactManager` needed for undo or redo.
    let referencedArtifactIDs: [UUID]
    /// Disk identity snapshots used on relaunch (and pre-undo) to detect missing/externally modified files.
    let fileSnapshots: [FileIdentitySnapshot]

    init(
        commandKind: String,
        schemaVersion: Int = 1,
        payloadData: Data,
        referencedArtifactIDs: [UUID] = [],
        fileSnapshots: [FileIdentitySnapshot] = []
    ) {
        self.commandKind = commandKind
        self.schemaVersion = schemaVersion
        self.payloadData = payloadData
        self.referencedArtifactIDs = referencedArtifactIDs
        self.fileSnapshots = fileSnapshots
    }
}

/// Implemented by module services (e.g. `ConversionManager`, `PresetManager`, `AudioEditingService`)
/// and registered with `UndoRedoCoordinator` at startup to reconstruct restart-survivable commands.
@MainActor
protocol UndoCommandRehydrating: Sendable {
    /// Command kinds handled by this rehydrator (must match `UndoCommandPersistenceDescriptor.commandKind`).
    var supportedCommandKinds: Set<String> { get }

    func rehydrateCommand(
        from entry: UndoHistoryEntry,
        descriptor: UndoCommandPersistenceDescriptor,
        artifactManager: RecoveryArtifactManager
    ) async throws -> (any UndoableCommand)?
}

// MARK: - Undoable Command Protocol

/// Core command contract implemented by each module's services (NOT inside a monolithic manager).
/// Isolated to `@MainActor` (matching `UndoRedoCoordinator`, `UndoRedoManager`, and `UndoCommandRehydrating`)
/// so `@MainActor` module classes and value types conform cleanly under Swift 6 strict concurrency.
@MainActor
protocol UndoableCommand: Identifiable, Sendable {
    var id: UUID { get }
    var operationType: UndoOperationType { get }
    var title: String { get }
    var timestamp: Date { get }
    var context: OperationContext { get }
    var affectedURLs: [URL] { get }
    var isReversible: Bool { get }
    /// Non-nil when `isReversible == false`; surfaced in Editing History UI.
    var irreversibilityReason: String? { get }
    var survivesRestart: Bool { get }
    var transactionGroupID: UUID? { get }

    /// Optional persistence descriptor when `survivesRestart == true`.
    var persistenceDescriptor: UndoCommandPersistenceDescriptor? { get }

    /// Artifact IDs currently owned/referenced by this command in `RecoveryArtifactManager`.
    var referencedArtifactIDs: [UUID] { get }

    /// Snapshots checked by `UndoRedoManager` before undoing this command.
    var fileIdentitySnapshots: [FileIdentitySnapshot] { get }

    /// Reverses the operation on `@MainActor`. Throws `UndoRedoError` or domain error on failure.
    func undo() async throws

    /// Re-applies the operation on `@MainActor`.
    func redo() async throws

    /// Releases any staged recovery files when the command is permanently discarded/evicted.
    /// NEVER called when merely undone (because Redo still needs the artifacts).
    func releaseRecoveryArtifacts() async

    /// Optional coalescing hook for continuous controls (sliders, drag gestures, debounced text).
    /// When returning `true`, `coalesced(with:)` is called to fold `newer` into `self` cleanly.
    func canCoalesce(with newer: any UndoableCommand) -> Bool
    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)?
}

extension UndoableCommand {
    var irreversibilityReason: String? { nil }
    var persistenceDescriptor: UndoCommandPersistenceDescriptor? { nil }
    var referencedArtifactIDs: [UUID] { [] }

    var fileIdentitySnapshots: [FileIdentitySnapshot] {
        persistenceDescriptor?.fileSnapshots ?? affectedURLs.map {
            FileIdentitySnapshot.capture(url: $0, expectedToExist: true)
        }
    }

    func releaseRecoveryArtifacts() async {}

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID, let newerGid = newer.transactionGroupID else {
            return false
        }
        return gid == newerGid
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        nil
    }
}

// MARK: - Compound Transaction Command

/// Wraps a sequence of commands committed inside a single `beginTransaction` / `endTransaction` scope.
/// Undoes in reverse order (with best-effort rollback on partial failure) and redoes in forward order.
@MainActor
final class CompoundUndoCommand: UndoableCommand {
    let id: UUID
    let operationType: UndoOperationType
    let title: String
    let timestamp: Date
    let context: OperationContext
    let transactionGroupID: UUID?
    private(set) var commands: [any UndoableCommand]

    var affectedURLs: [URL] {
        var seen = Set<URL>()
        return commands.flatMap(\.affectedURLs).filter { seen.insert($0.standardizedFileURL).inserted }
    }

    var isReversible: Bool {
        !commands.isEmpty && commands.allSatisfy(\.isReversible)
    }

    var irreversibilityReason: String? {
        commands.first(where: { !$0.isReversible })?.irreversibilityReason
    }

    var survivesRestart: Bool {
        !commands.isEmpty && commands.allSatisfy(\.survivesRestart)
    }

    var referencedArtifactIDs: [UUID] {
        commands.flatMap(\.referencedArtifactIDs)
    }

    var persistenceDescriptor: UndoCommandPersistenceDescriptor? {
        guard survivesRestart else { return nil }
        let childDescriptors = commands.compactMap(\.persistenceDescriptor)
        guard childDescriptors.count == commands.count,
              let data = try? JSONEncoder().encode(CompoundPayload(children: childDescriptors, childEntries: commands.map {
                  ChildMeta(id: $0.id, operationType: $0.operationType, title: $0.title, timestamp: $0.timestamp, affectedURLs: $0.affectedURLs)
              })) else {
            return nil
        }
        return UndoCommandPersistenceDescriptor(
            commandKind: Self.commandKind,
            schemaVersion: 1,
            payloadData: data,
            referencedArtifactIDs: referencedArtifactIDs,
            fileSnapshots: childDescriptors.flatMap(\.fileSnapshots)
        )
    }

    static let commandKind = "core.compound"

    struct ChildMeta: Codable, Sendable {
        let id: UUID
        let operationType: UndoOperationType
        let title: String
        let timestamp: Date
        let affectedURLs: [URL]
    }

    struct CompoundPayload: Codable, Sendable {
        let children: [UndoCommandPersistenceDescriptor]
        let childEntries: [ChildMeta]
    }

    init(
        id: UUID = UUID(),
        title: String,
        operationType: UndoOperationType = .compoundTransaction,
        timestamp: Date = Date(),
        context: OperationContext,
        transactionGroupID: UUID? = nil,
        commands: [any UndoableCommand]
    ) {
        self.id = id
        self.title = title
        self.operationType = operationType
        self.timestamp = timestamp
        self.context = context
        self.transactionGroupID = transactionGroupID
        self.commands = commands
    }

    func undo() async throws {
        var undoneSlice: [any UndoableCommand] = []
        do {
            for cmd in commands.reversed() {
                try await cmd.undo()
                undoneSlice.append(cmd)
            }
        } catch {
            // Best-effort rollback of already-undone children to preserve atomicity
            for rollbackCmd in undoneSlice.reversed() {
                try? await rollbackCmd.redo()
            }
            throw error
        }
    }

    func redo() async throws {
        var redoneSlice: [any UndoableCommand] = []
        do {
            for cmd in commands {
                try await cmd.redo()
                redoneSlice.append(cmd)
            }
        } catch {
            for rollbackCmd in redoneSlice.reversed() {
                try? await rollbackCmd.undo()
            }
            throw error
        }
    }

    func releaseRecoveryArtifacts() async {
        for cmd in commands {
            await cmd.releaseRecoveryArtifacts()
        }
    }
}

// MARK: - Irreversible Audit Command

/// Lightweight descriptor for inherently irreversible operations (e.g., overwriting a user-chosen
/// external file via `NSSavePanel`) so they appear transparently in Editing History with an explanation.
struct IrreversibleAuditCommand: UndoableCommand {
    let id: UUID
    let operationType: UndoOperationType
    let title: String
    let timestamp: Date
    let context: OperationContext
    let affectedURLs: [URL]
    let irreversibilityReason: String?

    var isReversible: Bool { false }
    var survivesRestart: Bool { true }
    var transactionGroupID: UUID? { nil }

    init(
        id: UUID = UUID(),
        operationType: UndoOperationType,
        title: String,
        timestamp: Date = Date(),
        context: OperationContext,
        affectedURLs: [URL],
        reason: String
    ) {
        self.id = id
        self.operationType = operationType
        self.title = title
        self.timestamp = timestamp
        self.context = context
        self.affectedURLs = affectedURLs
        self.irreversibilityReason = reason
    }

    @MainActor func undo() async throws {
        throw UndoRedoError.operationIrreversible(reason: irreversibilityReason ?? "This operation cannot be undone.")
    }

    @MainActor func redo() async throws {
        throw UndoRedoError.operationIrreversible(reason: irreversibilityReason ?? "This operation cannot be redone.")
    }
}

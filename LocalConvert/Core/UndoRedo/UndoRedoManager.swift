import Foundation

// MARK: - Errors & Validation

enum UndoRedoError: LocalizedError, Sendable, Equatable {
    case nothingToUndo
    case nothingToRedo
    case reentrantExecutionBlocked
    case operationIrreversible(reason: String)
    case staleEntry(entryTitle: String, reason: String)
    case executionFailed(operationTitle: String, underlying: String)
    case transactionNotFound(UUID)
    case jumpBlockedByEntry(entryID: UUID, title: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .nothingToUndo:
            return "There is nothing to undo in this context."
        case .nothingToRedo:
            return "There is nothing to redo in this context."
        case .reentrantExecutionBlocked:
            return "Cannot start another undo or redo operation while one is already in progress."
        case .operationIrreversible(let reason):
            return "This operation cannot be undone: \(reason)"
        case .staleEntry(let title, let reason):
            return "Cannot undo or redo '\(title)': \(reason)"
        case .executionFailed(let title, let underlying):
            return "Failed while reversing or reapplying '\(title)': \(underlying)"
        case .transactionNotFound(let id):
            return "Undo transaction \(id.uuidString) is not active."
        case .jumpBlockedByEntry(_, let title, let reason):
            return "Cannot jump across '\(title)': \(reason)"
        }
    }
}

struct JumpValidationResult: Sendable, Equatable {
    enum Direction: Sendable, Equatable {
        case undo(steps: [UndoHistoryEntry])
        case redo(steps: [UndoHistoryEntry])
        case alreadyAtTarget
        case blocked(blockingEntry: UndoHistoryEntry, reason: String)
    }

    let isSafe: Bool
    let direction: Direction
    let willArchiveRedoCount: Int
}

// MARK: - Per-Context Undo/Redo Stack Engine

/// Manages a single `OperationContext` timeline:
/// - `undoStack`: oldest -> newest applied commands (`last` is next to undo).
/// - `redoStack`: LIFO stack of undone commands (`last` is next to redo).
/// - `archivedEntries`: displaced branches, capacity-evicted entries, and irreversible audit entries.
@MainActor
final class UndoRedoManager {

    struct ActiveSlot {
        var entry: UndoHistoryEntry
        var command: (any UndoableCommand)?
    }

    struct PendingTransaction {
        let id: UUID
        let title: String
        let operationType: UndoOperationType
        let startedAt: Date
        var commands: [any UndoableCommand] = []
    }

    let context: OperationContext
    var maxUndoCapacity: Int
    var maxArchivedCapacity: Int

    private(set) var activeBranchID: UUID
    private(set) var undoStack: [ActiveSlot] = []
    private(set) var redoStack: [ActiveSlot] = []
    private(set) var archivedEntries: [UndoHistoryEntry] = []
    private(set) var pendingTransactions: [UUID: PendingTransaction] = [:]

    init(
        context: OperationContext,
        activeBranchID: UUID = UUID(),
        maxUndoCapacity: Int = 100,
        maxArchivedCapacity: Int = 200
    ) {
        self.context = context
        self.activeBranchID = activeBranchID
        self.maxUndoCapacity = max(1, maxUndoCapacity)
        self.maxArchivedCapacity = max(0, maxArchivedCapacity)
    }

    // MARK: - Queries

    var canUndo: Bool {
        guard let top = undoStack.last else { return false }
        return top.entry.isReversible && top.entry.state == .applied && top.command != nil
    }

    var canRedo: Bool {
        guard let top = redoStack.last else { return false }
        return top.entry.isReversible && top.entry.state == .undone && top.command != nil
    }

    var undoTitle: String? {
        undoStack.last.flatMap { ($0.entry.isReversible && $0.entry.state == .applied && $0.command != nil) ? $0.entry.title : nil }
    }

    var redoTitle: String? {
        redoStack.last.flatMap { ($0.entry.isReversible && $0.entry.state == .undone && $0.command != nil) ? $0.entry.title : nil }
    }

    /// Chronological view of the active branch (`undoStack` followed by undone future `redoStack.reversed()`).
    var activeTimelineEntries: [UndoHistoryEntry] {
        undoStack.map(\.entry) + redoStack.reversed().map(\.entry)
    }

    var currentAppliedEntryID: UUID? {
        undoStack.last?.entry.id
    }

    var allPinnedArtifactIDs: Set<UUID> {
        var ids = Set<UUID>()
        for slot in undoStack { ids.formUnion(slot.entry.referencedArtifactIDs) }
        for slot in redoStack { ids.formUnion(slot.entry.referencedArtifactIDs) }
        return ids
    }

    // MARK: - Recording & Branching

    /// Records an already-executed command onto this context's stack.
    /// - If `transactionGroupID` matches an active transaction, buffers it until `endTransaction`.
    /// - If `!command.isReversible`, appends directly to `archivedEntries` as an informational record
    ///   without blocking earlier reversible undo steps on `undoStack`.
    /// - If `!redoStack.isEmpty`, archives the entire undone branch (`archiveReason = .branchedNewOperation`)
    ///   and releases its recovery artifacts instead of silently replaying or losing history.
    func recordExecuted(_ command: any UndoableCommand) async {
        // 1. Buffer inside explicit transaction if active
        if let gid = command.transactionGroupID, var tx = pendingTransactions[gid] {
            tx.commands.append(command)
            pendingTransactions[gid] = tx
            return
        }

        // 2. Irreversible audit operations go straight to archived timeline
        if !command.isReversible {
            var entry = UndoHistoryEntry(from: command, state: .archived, branchID: activeBranchID)
            entry.archivedAt = Date()
            entry.archiveReason = .inherentlyIrreversible
            appendArchived(entry)
            await command.releaseRecoveryArtifacts()
            return
        }

        // 3. Predictable branching: archive undone future operations & start fresh branch ID if needed
        if !redoStack.isEmpty {
            await archiveRedoBranch(reason: .branchedNewOperation)
            activeBranchID = UUID()
        }

        // 4. Coalesce with top undo entry if continuous slider/drag shares transactionGroupID or coalescing rule
        if var top = undoStack.popLast() {
            if let topCmd = top.command,
               top.entry.state == .applied,
               topCmd.canCoalesce(with: command),
               let mergedCmd = topCmd.coalesced(with: command) {
                top = ActiveSlot(
                    entry: UndoHistoryEntry(from: mergedCmd, state: .applied, branchID: top.entry.branchID),
                    command: mergedCmd
                )
                undoStack.append(top)
                await enforceUndoCapacity()
                return
            } else {
                undoStack.append(top)
            }
        }

        let entry = UndoHistoryEntry(from: command, state: .applied, branchID: activeBranchID)
        undoStack.append(ActiveSlot(entry: entry, command: command))
        await enforceUndoCapacity()
    }

    // MARK: - Transaction Grouping (Sliders, Drag Gestures, Multi-Step Edits)

    @discardableResult
    func beginTransaction(
        id: UUID = UUID(),
        title: String,
        operationType: UndoOperationType = .compoundTransaction
    ) -> UUID {
        pendingTransactions[id] = PendingTransaction(
            id: id,
            title: title,
            operationType: operationType,
            startedAt: Date()
        )
        return id
    }

    func endTransaction(id: UUID, commit: Bool = true) async throws {
        guard let tx = pendingTransactions.removeValue(forKey: id) else {
            throw UndoRedoError.transactionNotFound(id)
        }
        guard commit, !tx.commands.isEmpty else {
            for cmd in tx.commands {
                await cmd.releaseRecoveryArtifacts()
            }
            return
        }

        if tx.commands.count == 1, let single = tx.commands.first {
            await recordExecuted(single)
        } else {
            let compound = CompoundUndoCommand(
                title: tx.title,
                operationType: tx.operationType,
                timestamp: tx.startedAt,
                context: context,
                transactionGroupID: tx.id,
                commands: tx.commands
            )
            await recordExecuted(compound)
        }
    }

    // MARK: - Undo / Redo Execution

    func undo() async throws -> UndoHistoryEntry {
        guard let slot = undoStack.last else {
            throw UndoRedoError.nothingToUndo
        }
        guard slot.entry.isReversible, slot.entry.state == .applied, let command = slot.command else {
            throw UndoRedoError.operationIrreversible(
                reason: slot.entry.irreversibilityReason ?? "Operation cannot be undone."
            )
        }

        // Pre-flight staleness check on file snapshots where applicable
        if let staleReason = validateEntrySnapshots(slot.entry) {
            markTopUndoAsStale(reason: staleReason)
            throw UndoRedoError.staleEntry(entryTitle: slot.entry.title, reason: staleReason)
        }

        do {
            try await command.undo()
        } catch let error as UndoRedoError {
            throw error
        } catch {
            throw UndoRedoError.executionFailed(operationTitle: slot.entry.title, underlying: error.localizedDescription)
        }

        var updated = undoStack.removeLast()
        updated.entry.state = .undone
        redoStack.append(updated)
        return updated.entry
    }

    func redo() async throws -> UndoHistoryEntry {
        guard let slot = redoStack.last else {
            throw UndoRedoError.nothingToRedo
        }
        guard slot.entry.isReversible, slot.entry.state == .undone, let command = slot.command else {
            throw UndoRedoError.operationIrreversible(
                reason: slot.entry.irreversibilityReason ?? "Operation cannot be redone."
            )
        }

        do {
            try await command.redo()
        } catch let error as UndoRedoError {
            throw error
        } catch {
            throw UndoRedoError.executionFailed(operationTitle: slot.entry.title, underlying: error.localizedDescription)
        }

        var updated = redoStack.removeLast()
        updated.entry.state = .applied
        undoStack.append(updated)
        return updated.entry
    }

    // MARK: - Jump-to-State Safety

    /// Inspects whether jumping to `targetEntryID` (or `nil` for initial state before first undo entry)
    /// can execute cleanly without crossing any irreversible/stale step.
    func validateJump(to targetEntryID: UUID?) -> JumpValidationResult {
        guard let targetEntryID else {
            if undoStack.isEmpty {
                return JumpValidationResult(isSafe: true, direction: .alreadyAtTarget, willArchiveRedoCount: 0)
            }
            let reversedSlots = Array(undoStack.reversed())
            if let blockerSlot = reversedSlots.first(where: { !$0.entry.isReversible || $0.entry.state == .stale || $0.command == nil }) {
                return JumpValidationResult(
                    isSafe: false,
                    direction: .blocked(
                        blockingEntry: blockerSlot.entry,
                        reason: blockerSlot.entry.irreversibilityReason ?? "Irreversible or unavailable step"
                    ),
                    willArchiveRedoCount: 0
                )
            }
            return JumpValidationResult(isSafe: true, direction: .undo(steps: reversedSlots.map(\.entry)), willArchiveRedoCount: 0)
        }

        if targetEntryID == undoStack.last?.entry.id {
            return JumpValidationResult(isSafe: true, direction: .alreadyAtTarget, willArchiveRedoCount: 0)
        }

        if let undoIdx = undoStack.firstIndex(where: { $0.entry.id == targetEntryID }) {
            let slice = undoStack[(undoIdx + 1)...].reversed()
            if let blockerSlot = slice.first(where: { !$0.entry.isReversible || $0.entry.state == .stale || $0.command == nil }) {
                return JumpValidationResult(
                    isSafe: false,
                    direction: .blocked(
                        blockingEntry: blockerSlot.entry,
                        reason: blockerSlot.entry.irreversibilityReason ?? "Irreversible or unavailable step"
                    ),
                    willArchiveRedoCount: 0
                )
            }
            return JumpValidationResult(isSafe: true, direction: .undo(steps: slice.map(\.entry)), willArchiveRedoCount: 0)
        }

        let chronologicalRedo = Array(redoStack.reversed())
        if let redoIdx = chronologicalRedo.firstIndex(where: { $0.entry.id == targetEntryID }) {
            let slice = chronologicalRedo[0...redoIdx]
            if let blockerSlot = slice.first(where: { !$0.entry.isReversible || $0.entry.state == .stale || $0.command == nil }) {
                return JumpValidationResult(
                    isSafe: false,
                    direction: .blocked(
                        blockingEntry: blockerSlot.entry,
                        reason: blockerSlot.entry.irreversibilityReason ?? "Irreversible or unavailable step"
                    ),
                    willArchiveRedoCount: 0
                )
            }
            return JumpValidationResult(isSafe: true, direction: .redo(steps: slice.map(\.entry)), willArchiveRedoCount: 0)
        }

        let placeholder = UndoHistoryEntry(
            id: targetEntryID,
            operationType: .custom,
            title: "Archived State",
            timestamp: Date(),
            context: context,
            affectedURLs: [],
            isReversible: false,
            survivesRestart: false,
            branchID: activeBranchID
        )
        return JumpValidationResult(
            isSafe: false,
            direction: .blocked(blockingEntry: placeholder, reason: "Target entry is in an archived branch and cannot be jumped to directly."),
            willArchiveRedoCount: 0
        )
    }

    /// Executes sequential undo or redo steps to reach `targetEntryID` (`nil` = initial state).
    /// Halts immediately on the first failed step without skipping intermediates.
    func jumpTo(entryID targetEntryID: UUID?) async throws {
        let plan = validateJump(to: targetEntryID)
        guard plan.isSafe else {
            if case .blocked(let entry, let reason) = plan.direction {
                throw UndoRedoError.jumpBlockedByEntry(entryID: entry.id, title: entry.title, reason: reason)
            }
            return
        }

        switch plan.direction {
        case .alreadyAtTarget:
            return
        case .undo(let steps):
            for _ in steps {
                _ = try await undo()
            }
        case .redo(let steps):
            for _ in steps {
                _ = try await redo()
            }
        case .blocked:
            break
        }
    }

    // MARK: - Capacity, Staleness & Snapshot Export

    func updateMaxUndoCapacity(_ newMax: Int) async {
        maxUndoCapacity = max(1, newMax)
        await enforceUndoCapacity()
    }

    func evictOldestActiveEntryIfPossible() async -> Bool {
        if !undoStack.isEmpty {
            var evicted = undoStack.removeFirst()
            evicted.entry.state = .archived
            evicted.entry.archivedAt = Date()
            evicted.entry.archiveReason = .evictedByStorageBudget
            appendArchived(evicted.entry)
            await evicted.command?.releaseRecoveryArtifacts()
            return true
        }
        if !redoStack.isEmpty {
            var evicted = redoStack.removeFirst()
            evicted.entry.state = .archived
            evicted.entry.archivedAt = Date()
            evicted.entry.archiveReason = .evictedByStorageBudget
            appendArchived(evicted.entry)
            await evicted.command?.releaseRecoveryArtifacts()
            return true
        }
        return false
    }

    func clearAll(includeArchived: Bool = true) async {
        for slot in undoStack { await slot.command?.releaseRecoveryArtifacts() }
        for slot in redoStack { await slot.command?.releaseRecoveryArtifacts() }
        undoStack.removeAll()
        redoStack.removeAll()
        pendingTransactions.removeAll()
        if includeArchived {
            archivedEntries.removeAll()
        }
    }

    func restoreFromSnapshot(
        _ snapshot: ContextJournalSnapshot,
        rehydratedUndo: [ActiveSlot],
        rehydratedRedo: [ActiveSlot],
        migratedArchived: [UndoHistoryEntry]
    ) {
        self.activeBranchID = snapshot.activeBranchID
        self.undoStack = rehydratedUndo
        self.redoStack = rehydratedRedo
        self.archivedEntries = Array((snapshot.archivedEntries + migratedArchived).suffix(maxArchivedCapacity))
    }

    func makeJournalSnapshot() -> ContextJournalSnapshot {
        ContextJournalSnapshot(
            context: context,
            activeBranchID: activeBranchID,
            undoEntries: undoStack.map(\.entry),
            redoEntries: redoStack.map(\.entry),
            archivedEntries: archivedEntries
        )
    }

    @discardableResult
    func refreshStaleness() -> Bool {
        var changed = false
        for i in undoStack.indices where undoStack[i].entry.isReversible {
            if let reason = validateEntrySnapshots(undoStack[i].entry) {
                undoStack[i].entry.state = .stale
                undoStack[i].entry.isReversible = false
                undoStack[i].entry.irreversibilityReason = reason
                changed = true
            }
        }
        return changed
    }

    // MARK: - Private Helpers

    private func validateEntrySnapshots(_ entry: UndoHistoryEntry) -> String? {
        for ref in entry.fileReferences {
            let status = ref.validateMatchesDisk()
            if !status.isValid {
                return status.failureReason
            }
        }
        return nil
    }

    private func markTopUndoAsStale(reason: String) {
        guard !undoStack.isEmpty else { return }
        let idx = undoStack.count - 1
        undoStack[idx].entry.state = .stale
        undoStack[idx].entry.isReversible = false
        undoStack[idx].entry.irreversibilityReason = reason
    }

    private func archiveRedoBranch(reason: UndoArchiveReason) async {
        let now = Date()
        for slot in redoStack.reversed() {
            var archived = slot.entry
            archived.state = .archived
            archived.archivedAt = now
            archived.archiveReason = reason
            appendArchived(archived)
            await slot.command?.releaseRecoveryArtifacts()
        }
        redoStack.removeAll()
    }

    private func enforceUndoCapacity() async {
        while undoStack.count > maxUndoCapacity {
            var oldest = undoStack.removeFirst()
            oldest.entry.state = .archived
            oldest.entry.archivedAt = Date()
            oldest.entry.archiveReason = .evictedByCapacity
            appendArchived(oldest.entry)
            await oldest.command?.releaseRecoveryArtifacts()
        }
    }

    private func appendArchived(_ entry: UndoHistoryEntry) {
        guard maxArchivedCapacity > 0 else { return }
        archivedEntries.append(entry)
        if archivedEntries.count > maxArchivedCapacity {
            archivedEntries.removeFirst(archivedEntries.count - maxArchivedCapacity)
        }
    }
}

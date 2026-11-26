import Foundation
import AppKit
import Combine
import os.log

// MARK: - Undo/Redo Coordinator

/// Global `@MainActor` coordinator managing per-`OperationContext` undo/redo stacks,
/// active context resolution bound to `AppState.selectedTab` + focused Audio Editor project ID,
/// persistent journal storage under `Application Support/<bundleID>/UndoHistory/`,
/// and bounded `RecoveryArtifactManager` synchronization.
@MainActor
final class UndoRedoCoordinator: ObservableObject {

    static let shared = UndoRedoCoordinator()

    private let logger = Logger(subsystem: "com.localconvert.app", category: "UndoRedoCoordinator")

    // MARK: - Published UI Bindings

    @Published private(set) var activeContext: OperationContext? = .convert
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var undoTitle: String? = nil
    @Published private(set) var redoTitle: String? = nil
    @Published private(set) var isExecutingUndoRedo: Bool = false
    @Published var lastError: UndoRedoError? = nil
    /// Incremented whenever any context stack/archive/staleness changes so `EditingHistoryView` refreshes cleanly.
    @Published private(set) var timelineRevision: UInt64 = 0
    /// Controls the window Editing History popover/sheet presentation.
    @Published var isEditingHistoryPresented: Bool = false

    // MARK: - Focus & Context State

    private(set) var currentTab: AppNavigationTab = .convert
    private(set) var isAudioEditorFocused: Bool = false
    private(set) var focusedAudioEditorProjectID: UUID? = nil
    private(set) var focusedContextOverride: OperationContext? = nil

    var undoMenuLabel: String {
        undoTitle.map { "Undo \($0)" } ?? "Undo"
    }

    var redoMenuLabel: String {
        redoTitle.map { "Redo \($0)" } ?? "Redo"
    }

    // MARK: - Storage & Dependencies

    let journalDirectoryURL: URL
    let journalFileURL: URL
    let artifactManager: RecoveryArtifactManager
    private let maxUndoStepsProvider: @MainActor () -> Int
    private let storageBudgetBytesProvider: @MainActor () -> Int64?

    private var managers: [OperationContext: UndoRedoManager] = [:]
    private var rehydratorsByKind: [String: any UndoCommandRehydrating] = [:]
    private var tabSubscription: AnyCancellable?
    private var persistenceTask: Task<Void, Never>?
    private var hasRestoredFromDisk = false

    static func defaultJournalDirectoryURL() -> URL {
        AppStoragePaths.undoHistoryDirectory
    }

    init(
        journalDirectoryURL: URL? = nil,
        artifactManager: RecoveryArtifactManager = .shared,
        maxUndoStepsProvider: (@MainActor () -> Int)? = nil,
        storageBudgetBytesProvider: (@MainActor () -> Int64?)? = nil
    ) {
        let dir = journalDirectoryURL ?? Self.defaultJournalDirectoryURL()
        self.journalDirectoryURL = dir
        self.journalFileURL = dir.appendingPathComponent("journal.json", isDirectory: false)
        self.artifactManager = artifactManager
        self.maxUndoStepsProvider = maxUndoStepsProvider ?? { AppSettings.shared.editingHistoryMaxEntries }
        self.storageBudgetBytesProvider = storageBudgetBytesProvider ?? { AppSettings.shared.recoveryArtifactStorageLimitBytes }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - AppState & Focus Binding

    func bind(to appState: AppState) {
        currentTab = appState.selectedTab
        recomputeActiveContext()
        tabSubscription = appState.$selectedTab
            .removeDuplicates()
            .sink { [weak self] newTab in
                guard let self else { return }
                self.currentTab = newTab
                self.recomputeActiveContext()
            }
    }

    func setAudioEditorFocus(isActive: Bool, projectID: UUID?) {
        isAudioEditorFocused = isActive
        focusedAudioEditorProjectID = projectID
        recomputeActiveContext()
    }

    func setFocusedContextOverride(_ context: OperationContext?) {
        focusedContextOverride = context
        recomputeActiveContext()
    }

    /// Returns the active `NSText`/`NSTextView` undo manager when a text field/search field/editor has focus.
    /// Used so `Cmd+Z` / `Shift+Cmd+Z` NEVER hijack native text editing.
    static func activeTextResponderUndoManager() -> UndoManager? {
        guard let responder = NSApp?.keyWindow?.firstResponder else { return nil }
        if let text = UndoMenuController.activeEditableTextResponder(from: responder) {
            return text.undoManager
        }
        return nil
    }

    // MARK: - Rehydrator Registration & Restart Recovery

    func registerRehydrator(_ rehydrator: any UndoCommandRehydrating) {
        for kind in rehydrator.supportedCommandKinds {
            rehydratorsByKind[kind] = rehydrator
        }
    }

    /// Loads `journal.json`, prunes session-only operations (`survivesRestart == false`),
    /// verifies disk file snapshots & `RecoveryArtifactManager` artifacts, and rehydrates live commands.
    func restorePersistedHistory() async {
        guard !hasRestoredFromDisk else { return }
        hasRestoredFromDisk = true

        await artifactManager.reconcileOrphanedBlobs()

        guard FileManager.default.fileExists(atPath: journalFileURL.path) else {
            refreshPublishedState()
            return
        }

        let journal: UndoHistoryJournal
        do {
            let data = try Data(contentsOf: journalFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            journal = try decoder.decode(UndoHistoryJournal.self, from: data)
        } catch {
            logger.error("Failed to decode UndoHistory journal: \(error.localizedDescription, privacy: .public)")
            let ts = Int(Date().timeIntervalSince1970)
            let backup = journalDirectoryURL.appendingPathComponent("journal.corrupted.\(ts).json")
            try? FileManager.default.copyItem(at: journalFileURL, to: backup)
            refreshPublishedState()
            return
        }

        for (_, snapshot) in journal.contexts {
            let mgr = manager(for: snapshot.context)
            var rehydratedUndo: [UndoRedoManager.ActiveSlot] = []
            var rehydratedRedo: [UndoRedoManager.ActiveSlot] = []
            var migratedArchived: [UndoHistoryEntry] = []

            for rawEntry in snapshot.undoEntries {
                let outcome = await rehydrateSlot(rawEntry, targetState: .applied)
                switch outcome {
                case .active(let slot):
                    rehydratedUndo.append(slot)
                case .archived(let archivedEntry):
                    migratedArchived.append(archivedEntry)
                }
            }

            for rawEntry in snapshot.redoEntries {
                let outcome = await rehydrateSlot(rawEntry, targetState: .undone)
                switch outcome {
                case .active(let slot):
                    rehydratedRedo.append(slot)
                case .archived(let archivedEntry):
                    migratedArchived.append(archivedEntry)
                }
            }

            mgr.restoreFromSnapshot(
                snapshot,
                rehydratedUndo: rehydratedUndo,
                rehydratedRedo: rehydratedRedo,
                migratedArchived: migratedArchived
            )
        }

        await syncPinnedArtifactsAndEnforceBudget()
        refreshPublishedState()
    }

    // MARK: - Command Recording & Transactions

    func record(_ command: any UndoableCommand) async {
        guard !isExecutingUndoRedo else {
            logger.debug("Ignored re-entrant command record '\(command.title, privacy: .public)' during undo/redo execution.")
            return
        }
        let mgr = manager(for: command.context)
        await mgr.recordExecuted(command)
        await syncPinnedArtifactsAndEnforceBudget()
        refreshPublishedState()
        schedulePersist()
    }

    @discardableResult
    func beginTransaction(
        id: UUID = UUID(),
        title: String,
        context: OperationContext,
        operationType: UndoOperationType = .compoundTransaction
    ) -> UUID {
        manager(for: context).beginTransaction(id: id, title: title, operationType: operationType)
    }

    func endTransaction(id: UUID, context: OperationContext, commit: Bool = true) async {
        do {
            try await manager(for: context).endTransaction(id: id, commit: commit)
            await syncPinnedArtifactsAndEnforceBudget()
            refreshPublishedState()
            schedulePersist()
        } catch let err as UndoRedoError {
            lastError = err
        } catch {
            lastError = .executionFailed(operationTitle: "Transaction", underlying: error.localizedDescription)
        }
    }

    // MARK: - Undo / Redo / Jump

    func undo(in context: OperationContext? = nil) async {
        guard let targetContext = context ?? activeContext else { return }
        guard !isExecutingUndoRedo else {
            lastError = .reentrantExecutionBlocked
            return
        }
        isExecutingUndoRedo = true
        defer {
            isExecutingUndoRedo = false
            refreshPublishedState()
        }

        do {
            _ = try await manager(for: targetContext).undo()
            await syncPinnedArtifactsAndEnforceBudget()
            schedulePersist()
        } catch let err as UndoRedoError {
            lastError = err
            schedulePersist()
        } catch {
            lastError = .executionFailed(operationTitle: undoTitle ?? "Operation", underlying: error.localizedDescription)
        }
    }

    func redo(in context: OperationContext? = nil) async {
        guard let targetContext = context ?? activeContext else { return }
        guard !isExecutingUndoRedo else {
            lastError = .reentrantExecutionBlocked
            return
        }
        isExecutingUndoRedo = true
        defer {
            isExecutingUndoRedo = false
            refreshPublishedState()
        }

        do {
            _ = try await manager(for: targetContext).redo()
            await syncPinnedArtifactsAndEnforceBudget()
            schedulePersist()
        } catch let err as UndoRedoError {
            lastError = err
            schedulePersist()
        } catch {
            lastError = .executionFailed(operationTitle: redoTitle ?? "Operation", underlying: error.localizedDescription)
        }
    }

    func validateJump(to entryID: UUID?, in context: OperationContext) -> JumpValidationResult {
        manager(for: context).validateJump(to: entryID)
    }

    func jumpTo(entryID: UUID?, in context: OperationContext) async {
        guard !isExecutingUndoRedo else {
            lastError = .reentrantExecutionBlocked
            return
        }
        isExecutingUndoRedo = true
        defer {
            isExecutingUndoRedo = false
            refreshPublishedState()
        }

        do {
            try await manager(for: context).jumpTo(entryID: entryID)
            await syncPinnedArtifactsAndEnforceBudget()
            schedulePersist()
        } catch let err as UndoRedoError {
            lastError = err
            schedulePersist()
        } catch {
            lastError = .executionFailed(operationTitle: "Jump to State", underlying: error.localizedDescription)
        }
    }

    // MARK: - Editing History Queries & Maintenance

    func canUndo(in context: OperationContext) -> Bool {
        managers[context]?.canUndo ?? false
    }

    func canRedo(in context: OperationContext) -> Bool {
        managers[context]?.canRedo ?? false
    }

    func undoTitle(in context: OperationContext) -> String? {
        managers[context]?.undoTitle
    }

    func redoTitle(in context: OperationContext) -> String? {
        managers[context]?.redoTitle
    }

    func redoCount(in context: OperationContext) -> Int {
        managers[context]?.redoStack.count ?? 0
    }

    func totalRedoCountAllContexts() -> Int {
        managers.values.reduce(0) { $0 + $1.redoStack.count }
    }

    func activeTimeline(for context: OperationContext) -> [UndoHistoryEntry] {
        managers[context]?.activeTimelineEntries ?? []
    }

    func undoEntries(for context: OperationContext) -> [UndoHistoryEntry] {
        managers[context]?.undoStack.map(\.entry) ?? []
    }

    func redoEntries(for context: OperationContext) -> [UndoHistoryEntry] {
        managers[context]?.redoStack.reversed().map(\.entry) ?? []
    }

    func archivedTimeline(for context: OperationContext) -> [UndoHistoryEntry] {
        managers[context]?.archivedEntries ?? []
    }

    func currentAppliedEntryID(for context: OperationContext) -> UUID? {
        managers[context]?.currentAppliedEntryID
    }

    /// Chronological union across all contexts (newest first) for the unified Editing History UI.
    func allChronologicalEntries(includeArchived: Bool = true) -> [UndoHistoryEntry] {
        var combined: [UndoHistoryEntry] = []
        for mgr in managers.values {
            combined.append(contentsOf: mgr.activeTimelineEntries)
            if includeArchived {
                combined.append(contentsOf: mgr.archivedEntries)
            }
        }
        return combined.sorted { $0.timestamp > $1.timestamp }
    }

    func allKnownContexts() -> [OperationContext] {
        Array(managers.keys).sorted { $0.displayName < $1.displayName }
    }

    func validateStaleness(for context: OperationContext? = nil) {
        var changed = false
        if let context {
            changed = managers[context]?.refreshStaleness() ?? false
        } else {
            for mgr in managers.values {
                if mgr.refreshStaleness() { changed = true }
            }
        }
        if changed {
            refreshPublishedState()
            schedulePersist()
        }
    }

    func clearHistory(for context: OperationContext? = nil, includeArchived: Bool = true) async {
        if let context {
            await managers[context]?.clearAll(includeArchived: includeArchived)
        } else {
            for mgr in managers.values {
                await mgr.clearAll(includeArchived: includeArchived)
            }
        }
        await syncPinnedArtifactsAndEnforceBudget()
        refreshPublishedState()
        flushPersistence()
    }

    /// Removes only unpinned recovery artifacts (orphaned or archived), never touching active undo/redo artifacts.
    func pruneUnusedRecoveryArtifacts() async {
        var pinned = Set<UUID>()
        for mgr in managers.values {
            pinned.formUnion(mgr.allPinnedArtifactIDs)
        }
        await artifactManager.syncPinnedArtifacts(pinned)
        await artifactManager.removeAllUnpinned()
        refreshPublishedState()
    }

    func currentRecoveryUsageBytes() async -> Int64 {
        await artifactManager.totalDiskUsageBytes()
    }

    /// Applies updated `editingHistoryMaxEntries` and `recoveryArtifactStorageLimitBytes` policies immediately.
    func enforcePolicies() async {
        let newMax = max(1, maxUndoStepsProvider())
        for mgr in managers.values {
            await mgr.updateMaxUndoCapacity(newMax)
        }
        await syncPinnedArtifactsAndEnforceBudget()
        refreshPublishedState()
        schedulePersist()
    }

    /// Synchronously writes `journal.json` (called on `applicationWillTerminate` and tests).
    func flushPersistence() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistJournalNow()
    }

    // MARK: - Private Internals

    private enum RehydrationOutcome {
        case active(UndoRedoManager.ActiveSlot)
        case archived(UndoHistoryEntry)
    }

    private func rehydrateSlot(_ entry: UndoHistoryEntry, targetState: UndoEntryState) async -> RehydrationOutcome {
        // 1. Session-only operations never survive restart
        guard entry.survivesRestart else {
            var expired = entry
            expired.state = .archived
            expired.isReversible = false
            expired.archivedAt = Date()
            expired.archiveReason = .sessionEnded
            expired.irreversibilityReason = "Session-only operation; cannot be reversed after relaunch."
            return .archived(expired)
        }

        // 2. Verify all required recovery artifacts still exist on disk
        for artifactID in entry.referencedArtifactIDs {
            let exists = await artifactManager.hasArtifact(id: artifactID)
            if !exists {
                var stale = entry
                stale.state = .stale
                stale.isReversible = false
                stale.archivedAt = Date()
                stale.archiveReason = .fileInvalidated
                stale.irreversibilityReason = "Required recovery data is no longer available."
                return .archived(stale)
            }
        }

        // 3. Verify disk file snapshots when entry is currently applied
        if targetState == .applied {
            for ref in entry.fileReferences {
                let status = ref.validateMatchesDisk()
                if !status.isValid {
                    var stale = entry
                    stale.state = .stale
                    stale.isReversible = false
                    stale.archivedAt = Date()
                    stale.archiveReason = .fileInvalidated
                    stale.irreversibilityReason = status.failureReason
                    return .archived(stale)
                }
            }
        }

        // 4. Rehydrate live command (compound or module-specific)
        guard let descriptor = entry.persistenceDescriptor,
              let command = await rehydrateCommand(from: entry, descriptor: descriptor) else {
            var unlinked = entry
            unlinked.state = .archived
            unlinked.isReversible = false
            unlinked.archivedAt = Date()
            unlinked.archiveReason = .fileInvalidated
            unlinked.irreversibilityReason = "Command handler unavailable after relaunch."
            return .archived(unlinked)
        }

        var restoredEntry = entry
        restoredEntry.state = targetState
        return .active(UndoRedoManager.ActiveSlot(entry: restoredEntry, command: command))
    }

    private func rehydrateCommand(
        from entry: UndoHistoryEntry,
        descriptor: UndoCommandPersistenceDescriptor
    ) async -> (any UndoableCommand)? {
        if descriptor.commandKind == CompoundUndoCommand.commandKind {
            guard let payload = try? JSONDecoder().decode(CompoundUndoCommand.CompoundPayload.self, from: descriptor.payloadData),
                  payload.children.count == payload.childEntries.count else {
                return nil
            }
            var children: [any UndoableCommand] = []
            for (childDesc, meta) in zip(payload.children, payload.childEntries) {
                let syntheticEntry = UndoHistoryEntry(
                    id: meta.id,
                    operationType: meta.operationType,
                    title: meta.title,
                    timestamp: meta.timestamp,
                    context: entry.context,
                    affectedURLs: meta.affectedURLs,
                    isReversible: entry.isReversible,
                    survivesRestart: true,
                    branchID: entry.branchID,
                    fileReferences: childDesc.fileSnapshots,
                    referencedArtifactIDs: childDesc.referencedArtifactIDs,
                    persistenceDescriptor: childDesc
                )
                guard let childCmd = await rehydrateCommand(from: syntheticEntry, descriptor: childDesc) else {
                    return nil
                }
                children.append(childCmd)
            }
            return CompoundUndoCommand(
                id: entry.id,
                title: entry.title,
                operationType: entry.operationType,
                timestamp: entry.timestamp,
                context: entry.context,
                transactionGroupID: entry.transactionGroupID,
                commands: children
            )
        }

        guard let rehydrator = rehydratorsByKind[descriptor.commandKind] else {
            return nil
        }
        return try? await rehydrator.rehydrateCommand(from: entry, descriptor: descriptor, artifactManager: artifactManager)
    }

    private func manager(for context: OperationContext) -> UndoRedoManager {
        if let existing = managers[context] {
            return existing
        }
        let maxSteps = max(1, maxUndoStepsProvider())
        let mgr = UndoRedoManager(context: context, maxUndoCapacity: maxSteps)
        managers[context] = mgr
        return mgr
    }

    private func recomputeActiveContext() {
        let resolved = OperationContext.resolve(
            tab: currentTab,
            isAudioEditorFocused: isAudioEditorFocused,
            focusedAudioEditorProjectID: focusedAudioEditorProjectID,
            overrideContext: focusedContextOverride
        )
        if activeContext != resolved {
            activeContext = resolved
        }
        refreshPublishedState()
    }

    private func refreshPublishedState() {
        if let ctx = activeContext, let mgr = managers[ctx] {
            canUndo = mgr.canUndo
            canRedo = mgr.canRedo
            undoTitle = mgr.undoTitle
            redoTitle = mgr.redoTitle
        } else {
            canUndo = false
            canRedo = false
            undoTitle = nil
            redoTitle = nil
        }
        timelineRevision &+= 1
    }

    private func syncPinnedArtifactsAndEnforceBudget() async {
        var pinned = Set<UUID>()
        for mgr in managers.values {
            pinned.formUnion(mgr.allPinnedArtifactIDs)
        }
        await artifactManager.syncPinnedArtifacts(pinned)

        guard let budgetBytes = storageBudgetBytesProvider() else {
            return
        }

        var currentUsage = await artifactManager.evictUnpinned(downTo: budgetBytes)
        // If pinned active artifacts still exceed budget, evict oldest active commands across contexts
        while currentUsage > budgetBytes {
            let oldestContext = managers.values
                .compactMap { mgr -> (OperationContext, Date)? in
                    guard let date = mgr.undoStack.first?.entry.timestamp ?? mgr.redoStack.first?.entry.timestamp else {
                        return nil
                    }
                    return (mgr.context, date)
                }
                .min { $0.1 < $1.1 }?.0

            guard let ctx = oldestContext,
                  let mgr = managers[ctx],
                  await mgr.evictOldestActiveEntryIfPossible() else {
                break
            }

            var updatedPinned = Set<UUID>()
            for m in managers.values { updatedPinned.formUnion(m.allPinnedArtifactIDs) }
            await artifactManager.syncPinnedArtifacts(updatedPinned)
            currentUsage = await artifactManager.evictUnpinned(downTo: budgetBytes)
        }
    }

    private func schedulePersist() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.persistJournalNow()
        }
    }

    private func persistJournalNow() {
        var contextMap: [String: ContextJournalSnapshot] = [:]
        for (ctx, mgr) in managers {
            let snap = mgr.makeJournalSnapshot()
            if !snap.undoEntries.isEmpty || !snap.redoEntries.isEmpty || !snap.archivedEntries.isEmpty {
                contextMap[ctx.storageKey] = snap
            }
        }
        let journal = UndoHistoryJournal(contexts: contextMap)
        do {
            try FileManager.default.createDirectory(at: journalDirectoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(journal)
            try data.write(to: journalFileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist UndoHistory journal: \(error.localizedDescription, privacy: .public)")
        }
    }
}

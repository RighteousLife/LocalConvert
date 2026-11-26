import Testing
import Foundation
import AppKit
import SwiftUI
@testable import LocalConvert

// MARK: - Test Doubles

@MainActor
private final class CounterBox {
    var value: Int
    var log: [String] = []
    var releaseCount: Int = 0

    init(value: Int = 0) {
        self.value = value
    }
}

@MainActor
private final class MockDeltaCommand: UndoableCommand {
    let id: UUID
    let operationType: UndoOperationType
    let title: String
    let timestamp: Date
    let context: OperationContext
    let affectedURLs: [URL]
    let isReversible: Bool
    let irreversibilityReason: String?
    let survivesRestart: Bool
    let transactionGroupID: UUID?
    let referencedArtifactIDs: [UUID]

    private let box: CounterBox
    private let fromValue: Int
    private let toValue: Int
    private let allowCoalesce: Bool

    init(
        id: UUID = UUID(),
        operationType: UndoOperationType = .custom,
        title: String,
        timestamp: Date = Date(),
        context: OperationContext = .convert,
        affectedURLs: [URL] = [],
        isReversible: Bool = true,
        irreversibilityReason: String? = nil,
        survivesRestart: Bool = false,
        transactionGroupID: UUID? = nil,
        referencedArtifactIDs: [UUID] = [],
        box: CounterBox,
        fromValue: Int,
        toValue: Int,
        allowCoalesce: Bool = false
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
        self.referencedArtifactIDs = referencedArtifactIDs
        self.box = box
        self.fromValue = fromValue
        self.toValue = toValue
        self.allowCoalesce = allowCoalesce
    }

    func undo() async throws {
        box.value = fromValue
        box.log.append("undo:\(title)")
    }

    func redo() async throws {
        box.value = toValue
        box.log.append("redo:\(title)")
    }

    func releaseRecoveryArtifacts() async {
        box.releaseCount += 1
    }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard allowCoalesce,
              let other = newer as? MockDeltaCommand,
              other.allowCoalesce,
              let gid = transactionGroupID,
              let otherGid = other.transactionGroupID else {
            return false
        }
        return gid == otherGid
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? MockDeltaCommand else { return nil }
        return MockDeltaCommand(
            id: id,
            operationType: operationType,
            title: other.title,
            timestamp: other.timestamp,
            context: context,
            affectedURLs: affectedURLs,
            isReversible: isReversible,
            irreversibilityReason: irreversibilityReason,
            survivesRestart: survivesRestart,
            transactionGroupID: transactionGroupID,
            referencedArtifactIDs: referencedArtifactIDs,
            box: box,
            fromValue: fromValue,
            toValue: other.toValue,
            allowCoalesce: allowCoalesce
        )
    }
}

@MainActor
private final class MockPersistentFileCommand: UndoableCommand {
    struct Payload: Codable, Sendable {
        let targetPath: String
        let backupArtifactID: UUID
    }

    static let kind = "test.persistentFile"

    let id: UUID
    let operationType: UndoOperationType = .metadataSaveToDisk
    let title: String
    let timestamp: Date
    let context: OperationContext
    let affectedURLs: [URL]
    let isReversible: Bool = true
    let survivesRestart: Bool = true
    let transactionGroupID: UUID? = nil

    private let targetURL: URL
    private let backupArtifactID: UUID
    private let artifactManager: RecoveryArtifactManager
    private let snapshots: [FileIdentitySnapshot]

    var referencedArtifactIDs: [UUID] { [backupArtifactID] }

    var persistenceDescriptor: UndoCommandPersistenceDescriptor? {
        let payload = Payload(targetPath: targetURL.standardizedFileURL.path, backupArtifactID: backupArtifactID)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return UndoCommandPersistenceDescriptor(
            commandKind: Self.kind,
            schemaVersion: 1,
            payloadData: data,
            referencedArtifactIDs: [backupArtifactID],
            fileSnapshots: snapshots
        )
    }

    init(
        id: UUID = UUID(),
        title: String,
        timestamp: Date = Date(),
        context: OperationContext = .metadata,
        targetURL: URL,
        backupArtifactID: UUID,
        artifactManager: RecoveryArtifactManager,
        snapshots: [FileIdentitySnapshot]
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.context = context
        self.targetURL = targetURL
        self.affectedURLs = [targetURL]
        self.backupArtifactID = backupArtifactID
        self.artifactManager = artifactManager
        self.snapshots = snapshots
    }

    func undo() async throws {
        try await artifactManager.restoreFile(
            artifactID: backupArtifactID,
            to: targetURL,
            allowOverwrite: true
        )
    }

    func redo() async throws {
        // Not exercised in restart-undo test
    }

    func releaseRecoveryArtifacts() async {
        await artifactManager.releaseArtifact(id: backupArtifactID)
    }
}

@MainActor
private final class MockPersistentRehydrator: UndoCommandRehydrating {
    let supportedCommandKinds: Set<String> = [MockPersistentFileCommand.kind]

    func rehydrateCommand(
        from entry: UndoHistoryEntry,
        descriptor: UndoCommandPersistenceDescriptor,
        artifactManager: RecoveryArtifactManager
    ) async throws -> (any UndoableCommand)? {
        let payload = try JSONDecoder().decode(MockPersistentFileCommand.Payload.self, from: descriptor.payloadData)
        return MockPersistentFileCommand(
            id: entry.id,
            title: entry.title,
            timestamp: entry.timestamp,
            context: entry.context,
            targetURL: URL(fileURLWithPath: payload.targetPath),
            backupArtifactID: payload.backupArtifactID,
            artifactManager: artifactManager,
            snapshots: descriptor.fileSnapshots
        )
    }
}

// MARK: - Test Suite

@Suite("Global Undo/Redo & Editing History", .serialized)
struct GlobalUndoRedoTests {

    private func makeIsolatedSandbox() throws -> (root: URL, journalDir: URL, artifactsDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalUndoRedoTests-\(UUID().uuidString)", isDirectory: true)
        let journalDir = root.appendingPathComponent("ApplicationSupport/UndoHistory", isDirectory: true)
        let artifactsDir = root.appendingPathComponent("ApplicationSupport/RecoveryArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        return (root, journalDir, artifactsDir)
    }

    // MARK: - 1. Basic Stack & Dynamic Labels

    @Test("Basic undo/redo stack updates state and dynamic menu labels")
    @MainActor
    func testBasicStackAndDynamicLabels() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        #expect(!coordinator.canUndo)
        #expect(!coordinator.canRedo)
        #expect(coordinator.undoMenuLabel == "Undo")
        #expect(coordinator.redoMenuLabel == "Redo")

        let box = CounterBox(value: 0)
        box.value = 10
        await coordinator.record(MockDeltaCommand(title: "Set Gain +10", context: .convert, box: box, fromValue: 0, toValue: 10))

        #expect(coordinator.canUndo)
        #expect(!coordinator.canRedo)
        #expect(coordinator.undoTitle == "Set Gain +10")
        #expect(coordinator.undoMenuLabel == "Undo Set Gain +10")
        #expect(coordinator.redoMenuLabel == "Redo")

        await coordinator.undo()
        #expect(box.value == 0)
        #expect(!coordinator.canUndo)
        #expect(coordinator.canRedo)
        #expect(coordinator.redoTitle == "Set Gain +10")
        #expect(coordinator.redoMenuLabel == "Redo Set Gain +10")

        await coordinator.redo()
        #expect(box.value == 10)
        #expect(coordinator.canUndo)
        #expect(!coordinator.canRedo)
    }

    // MARK: - 2. Branching & Archived History

    @Test("Branching after undo archives undone operations and does not replay them")
    @MainActor
    func testBranchingArchivesUndoneFutureWithoutSilentReplay() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 1
        await coordinator.record(MockDeltaCommand(title: "Step A", context: .convert, box: box, fromValue: 0, toValue: 1))
        box.value = 2
        await coordinator.record(MockDeltaCommand(title: "Step B", context: .convert, box: box, fromValue: 1, toValue: 2))
        box.value = 3
        await coordinator.record(MockDeltaCommand(title: "Step C", context: .convert, box: box, fromValue: 2, toValue: 3))

        await coordinator.undo() // Undo C -> value 2
        await coordinator.undo() // Undo B -> value 1
        #expect(box.value == 1)
        #expect(coordinator.redoCount(in: .convert) == 2)

        // Perform new edit D -> branches off, archiving B and C
        box.value = 42
        await coordinator.record(MockDeltaCommand(title: "Step D", context: .convert, box: box, fromValue: 1, toValue: 42))

        #expect(!coordinator.canRedo)
        #expect(coordinator.redoCount(in: .convert) == 0)
        #expect(coordinator.undoTitle == "Step D")

        let activeTitles = coordinator.activeTimeline(for: .convert).map(\.title)
        #expect(activeTitles == ["Step A", "Step D"])

        let archived = coordinator.archivedTimeline(for: .convert)
        #expect(archived.count == 2)
        #expect(archived.map(\.title).contains("Step B"))
        #expect(archived.map(\.title).contains("Step C"))
        #expect(archived.allSatisfy { $0.archiveReason == .branchedNewOperation })

        // Redo must remain disabled and never replay B or C
        await coordinator.redo()
        #expect(box.value == 42)
    }

    // MARK: - 3. Transaction Grouping & Coalescing

    @Test("Transactions and continuous coalescing collapse rapid edits into single undoable entries")
    @MainActor
    func testTransactionGroupingAndCoalescing() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 100 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        // A) Transaction grouping (multiple discrete steps -> 1 CompoundUndoCommand)
        let box = CounterBox(value: 0)
        let txID = coordinator.beginTransaction(title: "Batch Adjust", context: .imageToolbox)
        box.value = 5
        await coordinator.record(MockDeltaCommand(title: "Brightness", context: .imageToolbox, transactionGroupID: txID, box: box, fromValue: 0, toValue: 5))
        box.value = 12
        await coordinator.record(MockDeltaCommand(title: "Contrast", context: .imageToolbox, transactionGroupID: txID, box: box, fromValue: 5, toValue: 12))
        await coordinator.endTransaction(id: txID, context: .imageToolbox, commit: true)

        #expect(coordinator.activeTimeline(for: .imageToolbox).count == 1)
        #expect(coordinator.undoTitle(in: .imageToolbox) == "Batch Adjust")

        await coordinator.undo(in: .imageToolbox)
        #expect(box.value == 0)
        await coordinator.redo(in: .imageToolbox)
        #expect(box.value == 12)

        // B) Continuous slider coalescing (50 rapid mutations sharing groupID -> 1 entry)
        let sliderGroupID = UUID()
        for step in 1...50 {
            let prev = box.value
            box.value = 12 + step
            await coordinator.record(
                MockDeltaCommand(
                    title: "Slider \(step)",
                    context: .imageToolbox,
                    transactionGroupID: sliderGroupID,
                    box: box,
                    fromValue: prev,
                    toValue: 12 + step,
                    allowCoalesce: true
                )
            )
        }

        #expect(coordinator.activeTimeline(for: .imageToolbox).count == 2)
        await coordinator.undo(in: .imageToolbox)
        #expect(box.value == 12)
        await coordinator.redo(in: .imageToolbox)
        #expect(box.value == 62)
    }

    // MARK: - 4. Per-Context Isolation & .settings Exclusion

    @Test("Per-context stacks stay isolated and .settings context disables global undo")
    @MainActor
    func testPerContextIsolationAndSettingsExclusion() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let convertBox = CounterBox(value: 1)
        let imageBox = CounterBox(value: 100)

        convertBox.value = 2
        await coordinator.record(MockDeltaCommand(title: "Add File", context: .convert, box: convertBox, fromValue: 1, toValue: 2))
        imageBox.value = 200
        await coordinator.record(MockDeltaCommand(title: "Crop Image", context: .imageToolbox, box: imageBox, fromValue: 100, toValue: 200))

        // Active context is .convert -> undo only affects convertBox
        await coordinator.undo()
        #expect(convertBox.value == 1)
        #expect(imageBox.value == 200)

        // Verify .settings resolves to nil context and disables global undo
        let settingsCtx = OperationContext.resolve(tab: .settings, isAudioEditorFocused: false, focusedAudioEditorProjectID: nil)
        #expect(settingsCtx == nil)
        coordinator.setFocusedContextOverride(nil)
        let appState = AppState()
        coordinator.bind(to: appState)
        appState.selectedTab = .settings
        #expect(coordinator.activeContext == nil)
        #expect(!coordinator.canUndo)
    }

    // MARK: - 5. Safe Jump-to-State & Irreversible Audit Entries

    @Test("Jump-to-state executes reversible steps in order and rejects blocked jumps safely")
    @MainActor
    func testSafeJumpToStateAndIrreversibleRejection() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let id4 = UUID()

        box.value = 1
        await coordinator.record(MockDeltaCommand(id: id1, title: "Op 1", context: .convert, box: box, fromValue: 0, toValue: 1))
        box.value = 2
        await coordinator.record(MockDeltaCommand(id: id2, title: "Op 2", context: .convert, box: box, fromValue: 1, toValue: 2))
        box.value = 3
        await coordinator.record(MockDeltaCommand(id: id3, title: "Op 3", context: .convert, box: box, fromValue: 2, toValue: 3))
        box.value = 4
        await coordinator.record(MockDeltaCommand(id: id4, title: "Op 4", context: .convert, box: box, fromValue: 3, toValue: 4))

        // Jump back 3 steps to Op 1
        await coordinator.jumpTo(entryID: id1, in: .convert)
        #expect(box.value == 1)
        #expect(box.log == ["undo:Op 4", "undo:Op 3", "undo:Op 2"])

        // Jump forward to Op 3
        await coordinator.jumpTo(entryID: id3, in: .convert)
        #expect(box.value == 3)

        // Irreversible audit entry goes to archivedEntries without blocking prior reversible entries
        let auditID = UUID()
        await coordinator.record(
            IrreversibleAuditCommand(
                id: auditID,
                operationType: .externalExport,
                title: "Overwrite External File",
                context: .convert,
                affectedURLs: [sandbox.root.appendingPathComponent("ext.wav")],
                reason: "Overwrote user-selected destination outside managed folder."
            )
        )
        let archivedJump = coordinator.validateJump(to: auditID, in: .convert)
        #expect(!archivedJump.isSafe)
        await coordinator.jumpTo(entryID: auditID, in: .convert)
        #expect(box.value == 3)
        #expect(coordinator.lastError != nil)

        // Stale entry on undoStack blocks jump back to earlier states cleanly without partial execution
        let trackedFile = sandbox.root.appendingPathComponent("tracked.bin")
        try Data("v1".utf8).write(to: trackedFile)
        let snapshot = FileIdentitySnapshot.capture(url: trackedFile, expectedToExist: true, includeContentHash: true)
        let staleFileID = UUID()
        box.value = 5
        await coordinator.record(
            MockDeltaCommand(
                id: staleFileID,
                title: "Tracked File Edit",
                context: .convert,
                affectedURLs: [trackedFile],
                box: box,
                fromValue: 3,
                toValue: 5
            )
        )
        _ = snapshot
        // Delete tracked file externally -> validateStaleness marks top undo entry stale
        try FileManager.default.removeItem(at: trackedFile)
        coordinator.validateStaleness(for: .convert)
        let blockedByStale = coordinator.validateJump(to: id1, in: .convert)
        #expect(!blockedByStale.isSafe)
        await coordinator.jumpTo(entryID: id1, in: .convert)
        #expect(box.value == 5)
    }

    // MARK: - 6. Persistence & Corrupted Journal Recovery

    @Test("Persistent entries rehydrate across relaunch while session-only expire and corrupted journals back up")
    @MainActor
    func testPersistenceRehydrationAndCorruptedJournalRecovery() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let targetFile = sandbox.root.appendingPathComponent("notes.txt")
        try "original".write(to: targetFile, atomically: true, encoding: .utf8)

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let staged = try await artifacts.stageFileByCopying(from: targetFile)
        try "modified".write(to: targetFile, atomically: true, encoding: .utf8)
        let afterSnapshot = FileIdentitySnapshot.capture(url: targetFile, expectedToExist: true, includeContentHash: true)

        let coordinator1 = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 1
        await coordinator1.record(MockDeltaCommand(title: "Session UI Edit", context: .metadata, survivesRestart: false, box: box, fromValue: 0, toValue: 1))
        await coordinator1.record(
            MockPersistentFileCommand(
                title: "Save Metadata",
                context: .metadata,
                targetURL: targetFile,
                backupArtifactID: staged.id,
                artifactManager: artifacts,
                snapshots: [afterSnapshot]
            )
        )
        coordinator1.flushPersistence()
        #expect(FileManager.default.fileExists(atPath: coordinator1.journalFileURL.path))

        // Relaunch with fresh coordinator + rehydrator
        let artifacts2 = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator2 = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts2,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )
        coordinator2.registerRehydrator(MockPersistentRehydrator())
        await coordinator2.restorePersistedHistory()

        #expect(coordinator2.canUndo(in: .metadata))
        #expect(coordinator2.undoTitle(in: .metadata) == "Save Metadata")
        let archived = coordinator2.archivedTimeline(for: .metadata)
        #expect(archived.contains(where: { $0.title == "Session UI Edit" && $0.archiveReason == .sessionEnded }))

        await coordinator2.undo(in: .metadata)
        let restoredText = try String(contentsOf: targetFile, encoding: .utf8)
        #expect(restoredText == "original")

        // Corrupt journal.json -> verify backup created and safe startup
        try "{ invalid json".write(to: coordinator2.journalFileURL, atomically: true, encoding: .utf8)
        let coordinator3 = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts2,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )
        await coordinator3.restorePersistedHistory()
        let dirContents = try FileManager.default.contentsOfDirectory(at: sandbox.journalDir, includingPropertiesForKeys: nil)
        #expect(dirContents.contains(where: { $0.lastPathComponent.hasPrefix("journal.corrupted.") }))
    }

    // MARK: - 7. Temp Cleanup Immunity

    @Test("UndoHistory and RecoveryArtifacts remain untouched by temporary file cleanup routines")
    @MainActor
    func testTempCleanupImmunity() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let tempDir = sandbox.root.appendingPathComponent("TemporaryDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let tempTrash1 = tempDir.appendingPathComponent("LocalConvert-stale.tmp")
        let tempTrash2 = tempDir.appendingPathComponent("LocalConvertAudio_stale.caf")
        try Data("temp1".utf8).write(to: tempTrash1)
        try Data("temp2".utf8).write(to: tempTrash2)

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let staged = try await artifacts.stageData(Data("recovery-blob".utf8), filenameHint: "backup.bin")
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )
        let box = CounterBox(value: 0)
        await coordinator.record(
            MockDeltaCommand(
                title: "Protected Op",
                context: .convert,
                referencedArtifactIDs: [staged.id],
                box: box,
                fromValue: 0,
                toValue: 1
            )
        )
        coordinator.flushPersistence()

        // Run both real cleanup routines against tempDir
        OutputManager.cleanupTemporaryFiles(in: tempDir)
        ConversionManager.cleanStaleTemporaryFiles(in: tempDir, olderThan: 0)

        #expect(!FileManager.default.fileExists(atPath: tempTrash1.path))
        #expect(!FileManager.default.fileExists(atPath: tempTrash2.path))
        #expect(FileManager.default.fileExists(atPath: coordinator.journalFileURL.path))
        #expect(await artifacts.hasArtifact(id: staged.id))
    }

    // MARK: - 8. RecoveryArtifactManager Deduplication & Pinning

    @Test("RecoveryArtifactManager deduplicates identical blobs and protects pinned active artifacts from eviction")
    @MainActor
    func testArtifactDeduplicationAndPinnedProtection() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let samePayload = Data(repeating: 0xAB, count: 2048)

        let a1 = try await artifacts.stageData(samePayload, filenameHint: "one.bin")
        let a2 = try await artifacts.stageData(samePayload, filenameHint: "two.bin")
        #expect(a1.contentSHA256 == a2.contentSHA256)
        #expect(await artifacts.uniqueBlobCount() == 1)

        // Stage distinct unpinned blob and distinct pinned blob
        let unpinnedPayload = Data(repeating: 0xCD, count: 1024)
        let pinnedPayload = Data(repeating: 0xEF, count: 1024)
        let unpinned = try await artifacts.stageData(unpinnedPayload, filenameHint: "old-unpinned.bin")
        let pinned = try await artifacts.stageData(pinnedPayload, filenameHint: "active-pinned.bin")

        await artifacts.syncPinnedArtifacts([pinned.id])
        await artifacts.evictUnpinned(downTo: 1024)

        #expect(!(await artifacts.hasArtifact(id: unpinned.id)))
        #expect(await artifacts.hasArtifact(id: pinned.id))
    }

    // MARK: - 9. File-Identity, Collision-Safe Restore & Source-Overwrite Guard

    @Test("File-identity check detects external edits and restoreFile refuses collisions or source overwrites")
    @MainActor
    func testFileIdentityCollisionAndSourceOverwriteGuards() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let sourceURL = sandbox.root.appendingPathComponent("source.wav")
        let outputURL = sandbox.root.appendingPathComponent("output.wav")
        try Data("source-audio".utf8).write(to: sourceURL)
        try Data("original-output".utf8).write(to: outputURL)

        let snapshot = FileIdentitySnapshot.capture(url: outputURL, expectedToExist: true, includeContentHash: true)
        #expect(snapshot.validateMatchesDisk().isValid)

        // External modification breaks identity validation
        try Data("externally-tampered-audio".utf8).write(to: outputURL)
        let statusAfterEdit = snapshot.validateMatchesDisk()
        #expect(!statusAfterEdit.isValid)

        // Stage artifact and verify restore guards
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let staged = try await artifacts.stageData(Data("restored-data".utf8), filenameHint: "output.wav")

        // 1) Refuses overwriting protected source URL even if allowOverwrite is true
        do {
            _ = try await artifacts.restoreFile(
                artifactID: staged.id,
                to: sourceURL,
                protectedSourceURLs: [sourceURL],
                allowOverwrite: true
            )
            Issue.record("Expected sourceOverwriteForbidden error")
        } catch let error as RecoveryArtifactError {
            #expect(error == .sourceOverwriteForbidden(sourceURL.standardizedFileURL))
        }

        // 2) Refuses overwriting an occupied destination when allowOverwrite == false
        do {
            _ = try await artifacts.restoreFile(
                artifactID: staged.id,
                to: outputURL,
                protectedSourceURLs: [sourceURL],
                allowOverwrite: false
            )
            Issue.record("Expected destinationOccupied error")
        } catch let error as RecoveryArtifactError {
            #expect(error == .destinationOccupied(outputURL.standardizedFileURL))
        }
        #expect(try Data(contentsOf: outputURL) == Data("externally-tampered-audio".utf8))
    }

    // MARK: - 10. First-Responder Text-Edit Isolation (5 scenarios)

    @Test("TextField active undo delegates exclusively to field editor without touching coordinator")
    @MainActor
    func testTextFieldActiveUndoIsolation() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 99
        await coordinator.record(MockDeltaCommand(title: "Background Op", context: .convert, box: box, fromValue: 0, toValue: 99))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        textView.isEditable = true
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)

        let menuController = UndoMenuController(coordinator: coordinator, windowProvider: { window })
        textView.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        menuController.refreshNow()

        #expect(menuController.isTextInputActive)
        #expect(menuController.canUndo)
        #expect(menuController.undoTitle.contains("Undo"))

        let didUndo = await menuController.performUndoAsync()
        #expect(didUndo)
        #expect(textView.string == "")
        #expect(box.value == 99) // Coordinator untouched!
        #expect(coordinator.canUndo)
    }

    @Test("TextField with empty undo stack blocks Cmd+Z fallback to coordinator")
    @MainActor
    func testEmptyTextFieldNeverFallsBackToCoordinator() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 55
        await coordinator.record(MockDeltaCommand(title: "Global Edit", context: .convert, box: box, fromValue: 0, toValue: 55))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        textView.isEditable = true
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)

        let menuController = UndoMenuController(coordinator: coordinator, windowProvider: { window })
        menuController.refreshNow()

        #expect(menuController.isTextInputActive)
        #expect(!menuController.canUndo)

        let didUndo = await menuController.performUndoAsync()
        #expect(!didUndo)
        #expect(box.value == 55) // Coordinator MUST NOT undo
        #expect(coordinator.canUndo)
    }

    @Test("SecureField focus isolates undo from global coordinator")
    @MainActor
    func testSecureFieldIsolation() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 77
        await coordinator.record(MockDeltaCommand(title: "Global Edit", context: .convert, box: box, fromValue: 0, toValue: 77))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let secureField = NSSecureTextField(frame: NSRect(x: 20, y: 60, width: 240, height: 24))
        window.contentView = secureField
        window.makeFirstResponder(secureField)

        let menuController = UndoMenuController(coordinator: coordinator, windowProvider: { window })
        menuController.refreshNow()

        #expect(menuController.isTextInputActive)
        let didUndo = await menuController.performUndoAsync()
        #expect(!didUndo)
        #expect(box.value == 77)
    }

    @Test("Read-only text selection delegates to coordinator")
    @MainActor
    func testReadOnlyTextSelectionDelegatesToCoordinator() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 33
        await coordinator.record(MockDeltaCommand(title: "Global Edit", context: .convert, box: box, fromValue: 0, toValue: 33))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let readOnlyTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        readOnlyTextView.isEditable = false
        readOnlyTextView.isSelectable = true
        readOnlyTextView.string = "Read-only license text"
        window.contentView = readOnlyTextView
        window.makeFirstResponder(readOnlyTextView)

        let menuController = UndoMenuController(coordinator: coordinator, windowProvider: { window })
        menuController.refreshNow()

        #expect(!menuController.isTextInputActive)
        #expect(menuController.canUndo)
        #expect(menuController.undoTitle == "Undo Global Edit")

        let didUndo = await menuController.performUndoAsync()
        #expect(didUndo)
        #expect(box.value == 0)
    }

    @Test("Active window switch cleanly updates UndoMenuController target")
    @MainActor
    func testPopoverOrSheetWindowFocusSwitch() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 11
        await coordinator.record(MockDeltaCommand(title: "Main Window Edit", context: .convert, box: box, fromValue: 0, toValue: 11))

        let mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        let popoverWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        let popoverTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        popoverTextView.isEditable = true
        popoverTextView.allowsUndo = true
        popoverWindow.contentView = popoverTextView
        popoverWindow.makeFirstResponder(popoverTextView)

        @MainActor
        final class WindowHolder {
            var current: NSWindow
            init(_ window: NSWindow) { self.current = window }
        }

        let windowHolder = WindowHolder(mainWindow)
        let menuController = UndoMenuController(coordinator: coordinator, windowProvider: { windowHolder.current })
        menuController.refreshNow()
        #expect(!menuController.isTextInputActive)
        #expect(menuController.undoTitle == "Undo Main Window Edit")

        // Switch active window to popover/sheet window
        windowHolder.current = popoverWindow
        popoverTextView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        menuController.refreshNow()

        #expect(menuController.isTextInputActive)
        let didUndo = await menuController.performUndoAsync()
        #expect(didUndo)
        #expect(popoverTextView.string == "")
        #expect(box.value == 11)
    }

    // MARK: - 11. Existing HistoryManager Preservation

    @Test("UndoRedoCoordinator never alters or clears ConversionHistoryItem records in HistoryManager")
    @MainActor
    func testExistingHistoryManagerUntouched() async throws {
        let sandbox = try makeIsolatedSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let history = HistoryManager.shared
        let initialIDs = history.items.map(\.id)
        let initialFilenames = history.items.map(\.inputFilename)

        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 50 },
            storageBudgetBytesProvider: { 10_000_000 }
        )

        let box = CounterBox(value: 0)
        box.value = 5
        await coordinator.record(MockDeltaCommand(title: "Edit", context: .convert, box: box, fromValue: 0, toValue: 5))
        await coordinator.undo()
        await coordinator.redo()
        await coordinator.clearHistory()

        #expect(history.items.map(\.id) == initialIDs)
        #expect(history.items.map(\.inputFilename) == initialFilenames)
    }

    // MARK: - 12. Settings Bounds & Reset

    @Test("AppSettings clamps editing history limits and resets them cleanly")
    @MainActor
    func testSettingsBoundsAndReset() {
        let settings = AppSettings.shared
        defer { settings.resetToDefaults() }

        settings.editingHistoryMaxEntries = 0
        #expect(settings.editingHistoryMaxEntries == 10)
        settings.editingHistoryMaxEntries = 99_999
        #expect(settings.editingHistoryMaxEntries == 1000)

        settings.recoveryArtifactStorageLimitMB = 1
        #expect(settings.recoveryArtifactStorageLimitMB == 64)
        #expect(settings.recoveryArtifactStorageLimitBytes == Int64(64) * 1_048_576)

        settings.recoveryArtifactStorageLimitMB = 100_000
        #expect(settings.recoveryArtifactStorageLimitMB == 8192)
        #expect(settings.recoveryArtifactStorageLimitBytes == Int64(8192) * 1_048_576)

        settings.resetToDefaults()
        #expect(settings.editingHistoryMaxEntries == 100)
        #expect(settings.recoveryArtifactStorageLimitMB == 512)
        #expect(settings.recoveryArtifactStorageLimitBytes == Int64(512) * 1_048_576)

        let shortcutActions = KeyboardShortcutDescriptor.defaultShortcuts.map(\.action)
        #expect(shortcutActions.contains("Undo"))
        #expect(shortcutActions.contains("Redo"))
    }
}

import Foundation
import SwiftUI

// MARK: - Metadata Undo Command

@MainActor
final class MetadataSnapshotUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType
    let title: String
    let timestamp = Date()
    let context: OperationContext = .metadata
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID?

    private let before: MetadataDocument
    private let after: MetadataDocument
    private let applyDocument: @MainActor (MetadataDocument) -> Void

    init(
        operationType: UndoOperationType,
        title: String,
        before: MetadataDocument,
        after: MetadataDocument,
        transactionGroupID: UUID? = nil,
        applyDocument: @escaping @MainActor (MetadataDocument) -> Void
    ) {
        self.operationType = operationType
        self.title = title
        self.before = before
        self.after = after
        self.transactionGroupID = transactionGroupID
        self.affectedURLs = after.fileURL.map { [$0] } ?? []
        self.applyDocument = applyDocument
    }

    func undo() async throws { applyDocument(before) }
    func redo() async throws { applyDocument(after) }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? MetadataSnapshotUndoCommand,
              other.transactionGroupID == gid,
              other.affectedURLs == affectedURLs else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? MetadataSnapshotUndoCommand else { return nil }
        return MetadataSnapshotUndoCommand(
            operationType: other.operationType,
            title: other.title,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyDocument: self.applyDocument
        )
    }
}

// MARK: - Preset Undo Command

@MainActor
final class PresetStoreUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType
    let title: String
    let timestamp = Date()
    let context: OperationContext = .presets
    let affectedURLs: [URL] = []
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID? = nil

    private let beforePresets: [SavedPreset]
    private let afterPresets: [SavedPreset]
    private let applyPresets: @MainActor ([SavedPreset]) -> Void

    init(
        operationType: UndoOperationType,
        title: String,
        beforePresets: [SavedPreset],
        afterPresets: [SavedPreset],
        applyPresets: @escaping @MainActor ([SavedPreset]) -> Void
    ) {
        self.operationType = operationType
        self.title = title
        self.beforePresets = beforePresets
        self.afterPresets = afterPresets
        self.applyPresets = applyPresets
    }

    func undo() async throws { applyPresets(beforePresets) }
    func redo() async throws { applyPresets(afterPresets) }
}

// MARK: - Dropped Files / Convert Queue Undo Command

@MainActor
final class DroppedFilesUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType
    let title: String
    let timestamp = Date()
    let context: OperationContext = .convert
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID? = nil

    private let beforeFiles: [DroppedFile]
    private let afterFiles: [DroppedFile]
    private let applyFiles: @MainActor ([DroppedFile]) -> Void

    init(
        operationType: UndoOperationType,
        title: String,
        beforeFiles: [DroppedFile],
        afterFiles: [DroppedFile],
        applyFiles: @escaping @MainActor ([DroppedFile]) -> Void
    ) {
        self.operationType = operationType
        self.title = title
        self.beforeFiles = beforeFiles
        self.afterFiles = afterFiles
        self.affectedURLs = afterFiles.map(\.url)
        self.applyFiles = applyFiles
    }

    func undo() async throws { applyFiles(beforeFiles) }
    func redo() async throws { applyFiles(afterFiles) }

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [] }
}

// MARK: - App-Managed Output Creation Undo Command (stages output safely; never touches sources)

@MainActor
final class OutputCreationUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType = .outputFileCreation
    let title: String
    let timestamp = Date()
    let context: OperationContext
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID? = nil

    private let outputURLs: [URL]
    private let protectedSourceURLs: [URL]
    private let artifactManager: RecoveryArtifactManager
    private var stagedByURL: [URL: UUID] = [:]

    var referencedArtifactIDs: [UUID] { Array(stagedByURL.values) }

    init(
        title: String,
        context: OperationContext,
        outputURLs: [URL],
        protectedSourceURLs: [URL],
        artifactManager: RecoveryArtifactManager = .shared
    ) {
        self.title = title
        self.context = context
        self.protectedSourceURLs = protectedSourceURLs
        let protectedResolved = Set(protectedSourceURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        var seen = Set<URL>()
        var sanitizedOutputs: [URL] = []
        sanitizedOutputs.reserveCapacity(outputURLs.count)
        for url in outputURLs {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !protectedResolved.contains(resolved) else { continue }
            if seen.insert(resolved).inserted {
                sanitizedOutputs.append(url)
            }
        }
        self.outputURLs = sanitizedOutputs
        self.affectedURLs = sanitizedOutputs
        self.artifactManager = artifactManager
    }

    func undo() async throws {
        let protectedResolved = Set(protectedSourceURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        for url in outputURLs {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !protectedResolved.contains(resolved) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let staged = try await artifactManager.stageFileByMoving(from: url)
            stagedByURL[url] = staged.id
        }
    }

    func redo() async throws {
        for url in outputURLs {
            guard let artifactID = stagedByURL[url] else { continue }
            _ = try await artifactManager.restoreFile(
                artifactID: artifactID,
                to: url,
                protectedSourceURLs: protectedSourceURLs,
                allowOverwrite: false
            )
        }
        stagedByURL.removeAll()
    }

    func releaseRecoveryArtifacts() async {
        stagedByURL.removeAll()
    }
}

// MARK: - Disk-Level Metadata Write Undo Command (In-Place Save & Save Copy)

@MainActor
final class MetadataFileWriteUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType = .metadataSaveToDisk
    let title: String
    let timestamp = Date()
    let context: OperationContext
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID? = nil

    private let destinationURL: URL
    private let protectedSourceURLs: [URL]
    private let previousArtifactID: UUID?
    private var redoArtifactID: UUID?
    private var expectedCurrentIdentity: FileIdentitySnapshot
    private let artifactManager: RecoveryArtifactManager
    private let onDidMutateDisk: (@MainActor (URL, Bool) async -> Void)?

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [expectedCurrentIdentity] }

    var referencedArtifactIDs: [UUID] {
        [previousArtifactID, redoArtifactID].compactMap { $0 }
    }

    init(
        title: String,
        context: OperationContext = .metadata,
        destinationURL: URL,
        protectedSourceURLs: [URL] = [],
        previousArtifactID: UUID?,
        artifactManager: RecoveryArtifactManager = .shared,
        onDidMutateDisk: (@MainActor (URL, Bool) async -> Void)? = nil
    ) {
        self.title = title
        self.context = context
        self.destinationURL = destinationURL
        self.protectedSourceURLs = protectedSourceURLs
        self.affectedURLs = [destinationURL]
        self.previousArtifactID = previousArtifactID
        self.artifactManager = artifactManager
        self.onDidMutateDisk = onDidMutateDisk
        self.expectedCurrentIdentity = FileIdentitySnapshot.capture(
            url: destinationURL,
            expectedToExist: true,
            includeContentHash: true
        )
    }

    func undo() async throws {
        guard expectedCurrentIdentity.validateMatchesDisk() == .valid else {
            throw UndoRedoError.staleEntry(
                entryTitle: title,
                reason: "Saved metadata file was modified or removed externally (\(destinationURL.lastPathComponent))."
            )
        }
        let stagedCurrent = try await artifactManager.stageFileByMoving(from: destinationURL)
        redoArtifactID = stagedCurrent.id

        if let prevID = previousArtifactID {
            _ = try await artifactManager.restoreFile(
                artifactID: prevID,
                to: destinationURL,
                protectedSourceURLs: [],
                allowOverwrite: true
            )
            expectedCurrentIdentity = FileIdentitySnapshot.capture(
                url: destinationURL,
                expectedToExist: true,
                includeContentHash: true
            )
            await onDidMutateDisk?(destinationURL, true)
        } else {
            expectedCurrentIdentity = FileIdentitySnapshot.capture(
                url: destinationURL,
                expectedToExist: false,
                includeContentHash: false
            )
            await onDidMutateDisk?(destinationURL, false)
        }
    }

    func redo() async throws {
        guard let redoID = redoArtifactID else {
            throw UndoRedoError.staleEntry(entryTitle: title, reason: "Recovery data for redo is missing.")
        }
        guard expectedCurrentIdentity.validateMatchesDisk() == .valid else {
            throw UndoRedoError.staleEntry(
                entryTitle: title,
                reason: "Target metadata path changed externally before redo (\(destinationURL.lastPathComponent))."
            )
        }
        _ = try await artifactManager.restoreFile(
            artifactID: redoID,
            to: destinationURL,
            protectedSourceURLs: previousArtifactID == nil ? protectedSourceURLs : [],
            allowOverwrite: previousArtifactID != nil
        )
        expectedCurrentIdentity = FileIdentitySnapshot.capture(
            url: destinationURL,
            expectedToExist: true,
            includeContentHash: true
        )
        await onDidMutateDisk?(destinationURL, true)
    }

    func releaseRecoveryArtifacts() async {
        redoArtifactID = nil
    }
}

// MARK: - Safe Batch Rename Undo Command (verifies file identity & collisions)

@MainActor
final class BatchRenameUndoCommand: UndoableCommand {
    struct MoveEntry: Sendable {
        let from: URL
        let to: URL
        var identityAfterMove: FileIdentitySnapshot
    }

    let id = UUID()
    let operationType: UndoOperationType = .fileRename
    let title: String
    let timestamp = Date()
    let context: OperationContext
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID? = nil

    private var entries: [MoveEntry]
    private let onURLsMoved: (@MainActor ([(from: URL, to: URL)]) -> Void)?

    var fileIdentitySnapshots: [FileIdentitySnapshot] {
        entries.flatMap { entry in
            [
                FileIdentitySnapshot.capture(url: entry.to, expectedToExist: true),
                FileIdentitySnapshot.capture(url: entry.from, expectedToExist: false)
            ]
        }
    }

    init(
        title: String = "Batch Rename",
        context: OperationContext = .fileOperations,
        manifest: ImageBatchRenameUndoManifest,
        onURLsMoved: (@MainActor ([(from: URL, to: URL)]) -> Void)? = nil
    ) {
        self.title = title
        self.context = context
        self.onURLsMoved = onURLsMoved
        self.entries = manifest.appliedMoves.map { move in
            MoveEntry(
                from: move.from,
                to: move.to,
                identityAfterMove: FileIdentitySnapshot.capture(url: move.to, expectedToExist: true, includeContentHash: false)
            )
        }
        self.affectedURLs = manifest.appliedMoves.flatMap { [$0.from, $0.to] }
    }

    func undo() async throws {
        let fm = FileManager.default
        // Pre-validate all moves before touching disk
        for entry in entries.reversed() {
            let status = entry.identityAfterMove.validateMatchesDisk()
            guard status == .valid else {
                throw UndoRedoError.staleEntry(entryTitle: title, reason: "Renamed file was modified or moved externally (\(entry.to.lastPathComponent)).")
            }
            guard !fm.fileExists(atPath: entry.from.path) else {
                throw UndoRedoError.staleEntry(entryTitle: title, reason: "Original filename is already occupied (\(entry.from.lastPathComponent)).")
            }
        }
        var undone: [(from: URL, to: URL)] = []
        do {
            for idx in entries.indices.reversed() {
                let e = entries[idx]
                try fm.moveItem(at: e.to, to: e.from)
                undone.append((from: e.to, to: e.from))
                entries[idx].identityAfterMove = FileIdentitySnapshot.capture(url: e.from, expectedToExist: true)
            }
        } catch {
            for r in undone.reversed() { try? fm.moveItem(at: r.to, to: r.from) }
            throw UndoRedoError.executionFailed(operationTitle: title, underlying: error.localizedDescription)
        }
        onURLsMoved?(undone)
    }

    func redo() async throws {
        let fm = FileManager.default
        for entry in entries {
            let status = entry.identityAfterMove.validateMatchesDisk()
            guard status == .valid else {
                throw UndoRedoError.staleEntry(entryTitle: title, reason: "Source file was modified or moved externally (\(entry.from.lastPathComponent)).")
            }
            guard !fm.fileExists(atPath: entry.to.path) else {
                throw UndoRedoError.staleEntry(entryTitle: title, reason: "Target filename is already occupied (\(entry.to.lastPathComponent)).")
            }
        }
        var redone: [(from: URL, to: URL)] = []
        do {
            for idx in entries.indices {
                let e = entries[idx]
                try fm.moveItem(at: e.from, to: e.to)
                redone.append((from: e.from, to: e.to))
                entries[idx].identityAfterMove = FileIdentitySnapshot.capture(url: e.to, expectedToExist: true)
            }
        } catch {
            for r in redone.reversed() { try? fm.moveItem(at: r.to, to: r.from) }
            throw UndoRedoError.executionFailed(operationTitle: title, underlying: error.localizedDescription)
        }
        onURLsMoved?(redone)
    }
}

// MARK: - Irreversible Audit Entry Command (Archived cleanly without blocking reversible undo stack)

@MainActor
final class IrreversibleAuditUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType
    let title: String
    let timestamp = Date()
    let context: OperationContext
    let affectedURLs: [URL]
    let isReversible = false
    let survivesRestart = false
    let transactionGroupID: UUID? = nil
    let irreversibilityReason: String?

    init(
        operationType: UndoOperationType,
        title: String,
        context: OperationContext,
        affectedURLs: [URL],
        irreversibilityReason: String
    ) {
        self.operationType = operationType
        self.title = title
        self.context = context
        self.affectedURLs = affectedURLs.map(\.standardizedFileURL)
        self.irreversibilityReason = irreversibilityReason
    }

    func undo() async throws {
        throw UndoRedoError.operationIrreversible(
            reason: irreversibilityReason ?? "This operation cannot be undone automatically."
        )
    }

    func redo() async throws {
        throw UndoRedoError.operationIrreversible(
            reason: irreversibilityReason ?? "This operation cannot be redone automatically."
        )
    }
}

// MARK: - Audio Toolbox Per-File State & Undo Commands

struct AudioToolboxFileState: Codable, Sendable, Equatable {
    var targetFormat: FileFormat
    var config: AudioToolboxConfig
    var preserveMetadata: Bool
    var trimStart: Double
    var trimEnd: Double
    var hasInitializedTrimBounds: Bool

    init(
        targetFormat: FileFormat = .mp3,
        config: AudioToolboxConfig = AudioToolboxConfig(),
        preserveMetadata: Bool = true,
        trimStart: Double = 0,
        trimEnd: Double = 0,
        hasInitializedTrimBounds: Bool = false
    ) {
        self.targetFormat = targetFormat
        self.config = config
        self.preserveMetadata = preserveMetadata
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.hasInitializedTrimBounds = hasInitializedTrimBounds
    }

    /// Returns a sanitized copy suitable for cross-session persistence when `rememberLastUsedOptions` is enabled.
    /// Strips track-specific trim bounds and segments while keeping codec, format, metadata, and effect settings.
    func sanitizedForRemembering() -> AudioToolboxFileState {
        var sanitizedConfig = config
        sanitizedConfig.operation = .convert
        sanitizedConfig.trimStartSeconds = nil
        sanitizedConfig.trimEndSeconds = nil
        sanitizedConfig.segments = []
        return AudioToolboxFileState(
            targetFormat: targetFormat,
            config: sanitizedConfig,
            preserveMetadata: preserveMetadata,
            trimStart: 0,
            trimEnd: 0,
            hasInitializedTrimBounds: false
        )
    }
}

@MainActor
final class AudioToolboxConfigUndoCommand: UndoableCommand {
    struct Payload: Codable, Sendable {
        let filePath: String?
        let before: AudioToolboxFileState
        let after: AudioToolboxFileState
    }

    static let commandKind = "audioToolbox.stateMutation"

    let id: UUID
    let operationType: UndoOperationType
    let title: String
    let timestamp: Date
    let context: OperationContext = .audioToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = true
    let transactionGroupID: UUID?

    private let fileURL: URL?
    private let before: AudioToolboxFileState
    private let after: AudioToolboxFileState
    private let applyState: @MainActor (URL?, AudioToolboxFileState) -> Void

    init(
        id: UUID = UUID(),
        operationType: UndoOperationType,
        title: String,
        timestamp: Date = Date(),
        fileURL: URL?,
        before: AudioToolboxFileState,
        after: AudioToolboxFileState,
        transactionGroupID: UUID? = nil,
        applyState: @escaping @MainActor (URL?, AudioToolboxFileState) -> Void
    ) {
        self.id = id
        self.operationType = operationType
        self.title = title
        self.timestamp = timestamp
        self.fileURL = fileURL?.standardizedFileURL
        self.affectedURLs = fileURL.map { [$0.standardizedFileURL] } ?? []
        self.before = before
        self.after = after
        self.transactionGroupID = transactionGroupID
        self.applyState = applyState
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [] }

    var persistenceDescriptor: UndoCommandPersistenceDescriptor? {
        guard let data = try? JSONEncoder().encode(
            Payload(filePath: fileURL?.path, before: before, after: after)
        ) else { return nil }
        return UndoCommandPersistenceDescriptor(
            commandKind: Self.commandKind,
            schemaVersion: 1,
            payloadData: data
        )
    }

    func undo() async throws {
        applyState(fileURL, before)
    }

    func redo() async throws {
        applyState(fileURL, after)
    }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? AudioToolboxConfigUndoCommand,
              other.transactionGroupID == gid,
              other.fileURL == fileURL else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? AudioToolboxConfigUndoCommand else { return nil }
        return AudioToolboxConfigUndoCommand(
            id: self.id,
            operationType: other.operationType,
            title: other.title,
            timestamp: other.timestamp,
            fileURL: self.fileURL,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyState: self.applyState
        )
    }
}

@MainActor
final class AudioToolboxUndoRehydrator: UndoCommandRehydrating {
    let supportedCommandKinds: Set<String> = [AudioToolboxConfigUndoCommand.commandKind]
    private let applyState: @MainActor (URL?, AudioToolboxFileState) -> Void

    init(applyState: @escaping @MainActor (URL?, AudioToolboxFileState) -> Void) {
        self.applyState = applyState
    }

    func rehydrateCommand(
        from entry: UndoHistoryEntry,
        descriptor: UndoCommandPersistenceDescriptor,
        artifactManager: RecoveryArtifactManager
    ) async throws -> (any UndoableCommand)? {
        let payload = try JSONDecoder().decode(AudioToolboxConfigUndoCommand.Payload.self, from: descriptor.payloadData)
        let url = payload.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        return AudioToolboxConfigUndoCommand(
            id: entry.id,
            operationType: entry.operationType,
            title: entry.title,
            timestamp: entry.timestamp,
            fileURL: url,
            before: payload.before,
            after: payload.after,
            transactionGroupID: entry.transactionGroupID,
            applyState: applyState
        )
    }
}

@MainActor
final class AudioToolboxStore: ObservableObject {
    @Published var selectedSection: AudioToolboxSection = .convert
    @Published var selectedFileIds: Set<UUID> = []
    @Published var orderedMergeIDs: [UUID] = []
    @Published private(set) var statesByURL: [URL: AudioToolboxFileState] = [:]
    @Published private var fallbackState: AudioToolboxFileState

    private let undoCoordinator: UndoRedoCoordinator
    private var pendingUndoChain: Task<Void, Never>?
    private var rapidGroupID: UUID?
    private var rapidGroupKey: String?
    private var rapidResetTask: Task<Void, Never>?

    init(undoCoordinator: UndoRedoCoordinator = .shared) {
        self.undoCoordinator = undoCoordinator
        self.fallbackState = Self.makeDefaultState()
        let rehydrator = AudioToolboxUndoRehydrator { [weak self] url, restored in
            self?.applyRestoredState(restored, for: url)
        }
        undoCoordinator.registerRehydrator(rehydrator)
    }

    private static func key(_ url: URL?) -> URL? {
        url?.standardizedFileURL
    }

    static func makeDefaultState() -> AudioToolboxFileState {
        let settings = AppSettings.shared
        if settings.rememberLastUsedOptions,
           !settings.rememberedAudioToolboxStateJSON.isEmpty,
           let data = settings.rememberedAudioToolboxStateJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AudioToolboxFileState.self, from: data) {
            return decoded.sanitizedForRemembering()
        }
        return AudioToolboxFileState(
            targetFormat: .mp3,
            config: AudioToolboxConfig(),
            preserveMetadata: settings.preserveMetadataByDefault,
            trimStart: 0,
            trimEnd: 0,
            hasInitializedTrimBounds: false
        )
    }

    func state(for url: URL?) -> AudioToolboxFileState {
        guard let k = Self.key(url) else { return fallbackState }
        return statesByURL[k] ?? Self.makeDefaultState()
    }

    func targetFormat(for url: URL?) -> FileFormat {
        state(for: url).targetFormat
    }

    func config(for url: URL?) -> AudioToolboxConfig {
        state(for: url).config
    }

    func preserveMetadata(for url: URL?) -> Bool {
        state(for: url).preserveMetadata
    }

    func trimStart(for url: URL?) -> Double {
        state(for: url).trimStart
    }

    func trimEnd(for url: URL?) -> Double {
        state(for: url).trimEnd
    }

    /// Initializes default trim bounds `[0, duration]` once when media info loads, without overwriting user edits or recording Undo.
    func hydrateTrimBoundsIfNeeded(for url: URL?, duration: Double) {
        guard duration > 0 else { return }
        let k = Self.key(url)
        var current = state(for: k)
        guard !current.hasInitializedTrimBounds else { return }
        current.trimStart = 0
        current.trimEnd = duration
        current.hasInitializedTrimBounds = true
        if let k {
            statesByURL[k] = current
        } else {
            fallbackState = current
        }
    }

    func updateState(
        for url: URL?,
        explicitType: UndoOperationType? = nil,
        explicitTitle: String? = nil,
        transactionGroupID: UUID? = nil,
        recordUndo: Bool = true,
        _ mutate: (inout AudioToolboxFileState) -> Void
    ) {
        let k = Self.key(url)
        let before = state(for: k)
        var next = before
        mutate(&next)
        guard next != before else { return }

        if let k {
            statesByURL[k] = next
        } else {
            fallbackState = next
        }

        persistRememberedDefaultsIfEnabled(from: next)

        guard recordUndo else { return }

        let classified = Self.classifyChange(from: before, to: next)
        let opType = explicitType ?? classified.type
        let title = explicitTitle ?? classified.title

        let gid: UUID
        if let provided = transactionGroupID {
            gid = provided
        } else {
            let keyStr = "\(k?.path ?? "default")|\(opType.rawValue)|\(title)"
            if rapidGroupKey != keyStr || rapidGroupID == nil {
                rapidGroupKey = keyStr
                rapidGroupID = UUID()
            }
            gid = rapidGroupID!
            rapidResetTask?.cancel()
            rapidResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                self?.rapidGroupKey = nil
                self?.rapidGroupID = nil
            }
        }

        let cmd = AudioToolboxConfigUndoCommand(
            operationType: opType,
            title: title,
            fileURL: k,
            before: before,
            after: next,
            transactionGroupID: gid,
            applyState: { [weak self] u, restored in
                self?.applyRestoredState(restored, for: u)
            }
        )
        enqueueUndoRecord(cmd)
    }

    func setTargetFormat(_ format: FileFormat, for url: URL?, recordUndo: Bool = true) {
        updateState(
            for: url,
            explicitType: .outputFormatChange,
            explicitTitle: "Audio Format -> \(format.shortExtensionLabel)",
            transactionGroupID: UUID(),
            recordUndo: recordUndo
        ) { state in
            state.targetFormat = format
        }
    }

    func setPreserveMetadata(_ preserve: Bool, for url: URL?, recordUndo: Bool = true) {
        updateState(
            for: url,
            explicitType: .audioToolboxConfig,
            explicitTitle: preserve ? "Enable Preserve Audio Metadata" : "Disable Preserve Audio Metadata",
            transactionGroupID: UUID(),
            recordUndo: recordUndo
        ) { state in
            state.preserveMetadata = preserve
        }
    }

    func setTrimBounds(start: Double, end: Double, for url: URL?, recordUndo: Bool = true) {
        updateState(
            for: url,
            explicitType: .audioToolboxSegmentEdit,
            explicitTitle: "Audio Trim Bounds",
            recordUndo: recordUndo
        ) { state in
            state.trimStart = start
            state.trimEnd = end
            state.hasInitializedTrimBounds = true
        }
    }

    func updateConfig(
        for url: URL?,
        explicitType: UndoOperationType? = nil,
        explicitTitle: String? = nil,
        transactionGroupID: UUID? = nil,
        recordUndo: Bool = true,
        _ mutate: (inout AudioToolboxConfig) -> Void
    ) {
        updateState(
            for: url,
            explicitType: explicitType,
            explicitTitle: explicitTitle,
            transactionGroupID: transactionGroupID,
            recordUndo: recordUndo
        ) { state in
            mutate(&state.config)
        }
    }

    func targetFormatBinding(for url: URL?) -> Binding<FileFormat> {
        let k = Self.key(url)
        return Binding(
            get: { self.targetFormat(for: k) },
            set: { newFormat in self.setTargetFormat(newFormat, for: k, recordUndo: true) }
        )
    }

    func configBinding(for url: URL?) -> Binding<AudioToolboxConfig> {
        let k = Self.key(url)
        return Binding(
            get: { self.config(for: k) },
            set: { newConfig in
                self.updateState(for: k) { $0.config = newConfig }
            }
        )
    }

    func preserveMetadataBinding(for url: URL?) -> Binding<Bool> {
        let k = Self.key(url)
        return Binding(
            get: { self.preserveMetadata(for: k) },
            set: { newVal in self.setPreserveMetadata(newVal, for: k, recordUndo: true) }
        )
    }

    func trimStartBinding(for url: URL?) -> Binding<Double> {
        let k = Self.key(url)
        return Binding(
            get: { self.trimStart(for: k) },
            set: { newStart in
                self.updateState(
                    for: k,
                    explicitType: .audioToolboxSegmentEdit,
                    explicitTitle: "Audio Trim Start"
                ) { state in
                    state.trimStart = newStart
                    state.hasInitializedTrimBounds = true
                }
            }
        )
    }

    func trimEndBinding(for url: URL?) -> Binding<Double> {
        let k = Self.key(url)
        return Binding(
            get: { self.trimEnd(for: k) },
            set: { newEnd in
                self.updateState(
                    for: k,
                    explicitType: .audioToolboxSegmentEdit,
                    explicitTitle: "Audio Trim End"
                ) { state in
                    state.trimEnd = newEnd
                    state.hasInitializedTrimBounds = true
                }
            }
        )
    }

    func migrateURLs(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        var moveMap: [URL: URL] = [:]
        for move in moves {
            moveMap[move.from.standardizedFileURL] = move.to.standardizedFileURL
        }
        guard !moveMap.isEmpty else { return }
        let oldStates = statesByURL
        var updatedStates = oldStates
        for (fromKey, _) in moveMap {
            updatedStates.removeValue(forKey: fromKey)
        }
        for (fromKey, toKey) in moveMap {
            if let existing = oldStates[fromKey] {
                updatedStates[toKey] = existing
            }
        }
        statesByURL = updatedStates
    }

    func flushPendingUndoRecords() async {
        await pendingUndoChain?.value
    }

    private func applyRestoredState(_ restored: AudioToolboxFileState, for url: URL?) {
        if let k = Self.key(url) {
            statesByURL[k] = restored
        } else {
            fallbackState = restored
        }
        persistRememberedDefaultsIfEnabled(from: restored)
    }

    private func persistRememberedDefaultsIfEnabled(from state: AudioToolboxFileState) {
        let settings = AppSettings.shared
        guard settings.rememberLastUsedOptions else { return }
        let sanitized = state.sanitizedForRemembering()
        if let encoded = try? JSONEncoder().encode(sanitized),
           let json = String(data: encoded, encoding: .utf8) {
            settings.rememberedAudioToolboxStateJSON = json
        }
    }

    private func enqueueUndoRecord(_ cmd: any UndoableCommand) {
        let prev = pendingUndoChain
        let coordinator = undoCoordinator
        pendingUndoChain = Task { @MainActor in
            _ = await prev?.value
            await coordinator.record(cmd)
        }
    }

    static func classifyChange(
        from before: AudioToolboxFileState,
        to after: AudioToolboxFileState
    ) -> (type: UndoOperationType, title: String) {
        if before.targetFormat != after.targetFormat {
            return (.outputFormatChange, "Audio Format -> \(after.targetFormat.shortExtensionLabel)")
        }
        if before.preserveMetadata != after.preserveMetadata {
            return (.audioToolboxConfig, after.preserveMetadata ? "Enable Preserve Audio Metadata" : "Disable Preserve Audio Metadata")
        }
        if before.trimStart != after.trimStart || before.trimEnd != after.trimEnd {
            return (.audioToolboxSegmentEdit, "Audio Trim Bounds")
        }
        let b = before.config
        let a = after.config
        if b.segments != a.segments {
            return (.audioToolboxSegmentEdit, "Audio Segments")
        }
        if b.removeSilence != a.removeSilence
            || b.silenceThresholdDB != a.silenceThresholdDB
            || b.silenceMinDurationSeconds != a.silenceMinDurationSeconds
            || b.silenceTrimScope != a.silenceTrimScope {
            return (.audioToolboxConfig, "Silence Detection Settings")
        }
        if b.codec != a.codec
            || b.bitrateMode != a.bitrateMode
            || b.bitrateKbps != a.bitrateKbps
            || b.vbrQuality != a.vbrQuality
            || b.sampleRateHz != a.sampleRateHz
            || b.bitDepth != a.bitDepth
            || b.channelMode != a.channelMode
            || b.preferStreamCopy != a.preferStreamCopy {
            return (.audioToolboxConfig, "Audio Codec Settings")
        }
        if b.eqBands != a.eqBands || b.highPassHz != a.highPassHz || b.lowPassHz != a.lowPassHz {
            return (.audioToolboxConfig, "Audio Equalizer")
        }
        if b.volumeGainDB != a.volumeGainDB
            || b.fadeInSeconds != a.fadeInSeconds
            || b.fadeOutSeconds != a.fadeOutSeconds
            || b.speedMultiplier != a.speedMultiplier
            || b.pitchSemitones != a.pitchSemitones
            || b.reverseAudio != a.reverseAudio {
            return (.audioToolboxConfig, "Audio Gain & Timing")
        }
        if b.normalizationMode != a.normalizationMode
            || b.targetLUFS != a.targetLUFS
            || b.targetTruePeakDB != a.targetTruePeakDB
            || b.peakNormalizeTargetDB != a.peakNormalizeTargetDB
            || b.compressorEnabled != a.compressorEnabled
            || b.limiterEnabled != a.limiterEnabled
            || b.noiseReduction != a.noiseReduction
            || b.declickEnabled != a.declickEnabled {
            return (.audioToolboxConfig, "Audio Dynamics & Loudness")
        }
        return (.audioToolboxConfig, "Audio Toolbox Settings")
    }
}

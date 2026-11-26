import Foundation

// MARK: - Audio Editor Undo Command (Value-based lightweight project diff)

@MainActor
final class AudioProjectMutationCommand: UndoableCommand {
    struct Payload: Codable, Sendable {
        var before: AudioEditorProject
        var after: AudioEditorProject
    }

    static let commandKind = "audioEditor.projectMutation"

    let id: UUID
    let operationType: UndoOperationType
    let title: String
    let timestamp: Date
    let context: OperationContext
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = true
    let transactionGroupID: UUID?

    private let before: AudioEditorProject
    private var after: AudioEditorProject
    private let applyProject: @MainActor (AudioEditorProject) -> Void

    init(
        id: UUID = UUID(),
        operationType: UndoOperationType,
        title: String,
        timestamp: Date = Date(),
        projectID: UUID,
        before: AudioEditorProject,
        after: AudioEditorProject,
        transactionGroupID: UUID? = nil,
        applyProject: @escaping @MainActor (AudioEditorProject) -> Void
    ) {
        self.id = id
        self.operationType = operationType
        self.title = title
        self.timestamp = timestamp
        self.context = .audioEditor(projectID: projectID)
        self.before = before
        self.after = after
        self.transactionGroupID = transactionGroupID
        self.applyProject = applyProject
        self.affectedURLs = after.mediaAssets.map(\.url)
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [] }

    var persistenceDescriptor: UndoCommandPersistenceDescriptor? {
        guard let data = try? JSONEncoder().encode(Payload(before: before, after: after)) else { return nil }
        return UndoCommandPersistenceDescriptor(
            commandKind: Self.commandKind,
            schemaVersion: 1,
            payloadData: data
        )
    }

    func undo() async throws {
        applyProject(before)
    }

    func redo() async throws {
        applyProject(after)
    }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? AudioProjectMutationCommand,
              other.transactionGroupID == gid,
              other.context == context else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? AudioProjectMutationCommand else { return nil }
        return AudioProjectMutationCommand(
            id: self.id,
            operationType: other.operationType,
            title: other.title,
            timestamp: other.timestamp,
            projectID: before.id,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyProject: self.applyProject
        )
    }
}

// MARK: - Rehydrator for Restart Persistence

@MainActor
final class AudioEditorUndoRehydrator: UndoCommandRehydrating {
    let supportedCommandKinds: Set<String> = [AudioProjectMutationCommand.commandKind]
    private let applyProject: @MainActor (AudioEditorProject) -> Void

    init(applyProject: @escaping @MainActor (AudioEditorProject) -> Void) {
        self.applyProject = applyProject
    }

    func rehydrateCommand(
        from entry: UndoHistoryEntry,
        descriptor: UndoCommandPersistenceDescriptor,
        artifactManager: RecoveryArtifactManager
    ) async throws -> (any UndoableCommand)? {
        let payload = try JSONDecoder().decode(AudioProjectMutationCommand.Payload.self, from: descriptor.payloadData)
        return AudioProjectMutationCommand(
            id: entry.id,
            operationType: entry.operationType,
            title: entry.title,
            timestamp: entry.timestamp,
            projectID: payload.after.id,
            before: payload.before,
            after: payload.after,
            transactionGroupID: entry.transactionGroupID,
            applyProject: applyProject
        )
    }
}

import Foundation

// MARK: - PDF Draft Models

struct PDFFormDraftSnapshot: Codable, Sendable, Equatable {
    var fields: [PDFFormFieldItem] = []
    var flattenFields: Bool = false
}

struct PDFRedactionDraft: Codable, Sendable, Equatable {
    var searchTerms: [String] = []
    var manualRegions: [PDFRedactionRegion] = []
    var wholePageRanges: String = ""
    var removeMetadata: Bool = true
    var cleanAnnotations: Bool = true
    var preserveSearchability: Bool = true
    var overlayTag: String = "REDACTED"

    func toRedactionOptions(password: String?) -> PDFRedactionOptions {
        var opts = PDFRedactionOptions()
        opts.searchTerms = searchTerms
        opts.regions = manualRegions
        opts.wholePageRanges = wholePageRanges
        opts.removeMetadata = removeMetadata
        opts.cleanAnnotationsInRegions = cleanAnnotations
        opts.preserveUnrelatedTextSearchability = preserveSearchability
        opts.overlayTag = overlayTag
        opts.password = password?.isEmpty == false ? password : nil
        return opts
    }
}

// MARK: - PDF Form Draft Undo Command (Coalesces typing, isolated per PDF)

@MainActor
final class PDFFormDraftUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType = .pdfFormDraftEdit
    let title: String
    let timestamp: Date
    let context: OperationContext = .pdfToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID?

    private let fileURL: URL
    private let before: PDFFormDraftSnapshot
    private var after: PDFFormDraftSnapshot
    private let applyDraft: @MainActor (URL, PDFFormDraftSnapshot) -> Void

    init(
        title: String,
        timestamp: Date = Date(),
        fileURL: URL,
        before: PDFFormDraftSnapshot,
        after: PDFFormDraftSnapshot,
        transactionGroupID: UUID? = nil,
        applyDraft: @escaping @MainActor (URL, PDFFormDraftSnapshot) -> Void
    ) {
        self.title = title
        self.timestamp = timestamp
        let std = fileURL.standardizedFileURL
        self.fileURL = std
        self.affectedURLs = [std]
        self.before = before
        self.after = after
        self.transactionGroupID = transactionGroupID
        self.applyDraft = applyDraft
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [] }

    func undo() async throws { applyDraft(fileURL, before) }
    func redo() async throws { applyDraft(fileURL, after) }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? PDFFormDraftUndoCommand,
              other.transactionGroupID == gid,
              other.fileURL == fileURL else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? PDFFormDraftUndoCommand else { return nil }
        return PDFFormDraftUndoCommand(
            title: other.title,
            timestamp: other.timestamp,
            fileURL: self.fileURL,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyDraft: self.applyDraft
        )
    }
}

// MARK: - PDF Annotation Draft Undo Command (Session-only to protect private document notes)

@MainActor
final class PDFAnnotationDraftUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType = .pdfAnnotationEdit
    let title: String
    let timestamp: Date
    let context: OperationContext = .pdfToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID?

    private let fileURL: URL
    private let before: PDFAnnotationWorkspaceDraft
    private var after: PDFAnnotationWorkspaceDraft
    private let applyDraft: @MainActor (URL, PDFAnnotationWorkspaceDraft) -> Void

    init(
        title: String,
        timestamp: Date = Date(),
        fileURL: URL,
        before: PDFAnnotationWorkspaceDraft,
        after: PDFAnnotationWorkspaceDraft,
        transactionGroupID: UUID? = nil,
        applyDraft: @escaping @MainActor (URL, PDFAnnotationWorkspaceDraft) -> Void
    ) {
        self.title = title
        self.timestamp = timestamp
        let std = fileURL.standardizedFileURL
        self.fileURL = std
        self.affectedURLs = [std]
        self.before = before
        self.after = after
        self.transactionGroupID = transactionGroupID
        self.applyDraft = applyDraft
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [] }

    func undo() async throws { applyDraft(fileURL, before) }
    func redo() async throws { applyDraft(fileURL, after) }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? PDFAnnotationDraftUndoCommand,
              other.transactionGroupID == gid,
              other.fileURL == fileURL else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? PDFAnnotationDraftUndoCommand else { return nil }
        return PDFAnnotationDraftUndoCommand(
            title: other.title,
            timestamp: other.timestamp,
            fileURL: self.fileURL,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyDraft: self.applyDraft
        )
    }
}

// MARK: - PDF Redaction Draft Undo Command (Session-only so sensitive search terms never persist to disk)

@MainActor
final class PDFRedactionDraftUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType = .pdfRedactionEdit
    let title: String
    let timestamp = Date()
    let context: OperationContext = .pdfToolbox
    let affectedURLs: [URL]
    let isReversible = true
    /// Sensitive PII redaction search terms/regions remain strictly session-only in RAM (not written to journal.json).
    let survivesRestart = false
    let transactionGroupID: UUID?

    private let fileURL: URL
    private let before: PDFRedactionDraft
    private var after: PDFRedactionDraft
    private let applyDraft: @MainActor (URL, PDFRedactionDraft) -> Void

    init(
        title: String,
        fileURL: URL,
        before: PDFRedactionDraft,
        after: PDFRedactionDraft,
        transactionGroupID: UUID? = nil,
        applyDraft: @escaping @MainActor (URL, PDFRedactionDraft) -> Void
    ) {
        self.title = title
        let std = fileURL.standardizedFileURL
        self.fileURL = std
        self.affectedURLs = [std]
        self.before = before
        self.after = after
        self.transactionGroupID = transactionGroupID
        self.applyDraft = applyDraft
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [] }

    func undo() async throws { applyDraft(fileURL, before) }
    func redo() async throws { applyDraft(fileURL, after) }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? PDFRedactionDraftUndoCommand,
              other.transactionGroupID == gid,
              other.fileURL == fileURL else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? PDFRedactionDraftUndoCommand else { return nil }
        return PDFRedactionDraftUndoCommand(
            title: other.title,
            fileURL: self.fileURL,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyDraft: self.applyDraft
        )
    }
}

// MARK: - PDF Page Workspace Draft Undo Command (Restart-survivable, stale-guarded)

@MainActor
final class PDFPageDraftUndoCommand: UndoableCommand {
    struct Payload: Codable, Sendable {
        let filePath: String
        let before: PDFPageWorkspaceDraft
        let after: PDFPageWorkspaceDraft
    }

    static let commandKind = "pdfToolbox.pageWorkspaceMutation"

    let id: UUID
    let operationType: UndoOperationType = .pdfPageEdit
    let title: String
    let timestamp: Date
    let context: OperationContext = .pdfToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = true
    let transactionGroupID: UUID?

    private let fileURL: URL
    private let before: PDFPageWorkspaceDraft
    private var after: PDFPageWorkspaceDraft
    private let applyDraft: @MainActor (URL, PDFPageWorkspaceDraft) -> Void

    init(
        id: UUID = UUID(),
        title: String,
        timestamp: Date = Date(),
        fileURL: URL,
        before: PDFPageWorkspaceDraft,
        after: PDFPageWorkspaceDraft,
        transactionGroupID: UUID? = nil,
        applyDraft: @escaping @MainActor (URL, PDFPageWorkspaceDraft) -> Void
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        let std = fileURL.standardizedFileURL
        self.fileURL = std
        self.affectedURLs = [std]
        self.before = before
        self.after = after
        self.transactionGroupID = transactionGroupID
        self.applyDraft = applyDraft
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] {
        [before.sourceIdentity, after.sourceIdentity].compactMap { $0 }
    }

    var persistenceDescriptor: UndoCommandPersistenceDescriptor? {
        guard let data = try? JSONEncoder().encode(
            Payload(filePath: fileURL.path, before: before, after: after)
        ) else { return nil }
        return UndoCommandPersistenceDescriptor(
            commandKind: Self.commandKind,
            schemaVersion: 1,
            payloadData: data,
            referencedArtifactIDs: [],
            fileSnapshots: fileIdentitySnapshots
        )
    }

    func undo() async throws {
        applyDraft(fileURL, before)
    }

    func redo() async throws {
        applyDraft(fileURL, after)
    }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? PDFPageDraftUndoCommand,
              other.transactionGroupID == gid,
              other.fileURL == fileURL else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? PDFPageDraftUndoCommand else { return nil }
        return PDFPageDraftUndoCommand(
            id: self.id,
            title: other.title,
            timestamp: other.timestamp,
            fileURL: self.fileURL,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyDraft: self.applyDraft
        )
    }
}

// MARK: - PDF Operation Config Undo Command (Compression / OCR Settings — Restart-survivable, Password-free)

@MainActor
final class PDFOperationConfigUndoCommand: UndoableCommand {
    struct Payload: Codable, Sendable {
        let scopeKey: String
        let affectedPaths: [String]
        let snapshots: [FileIdentitySnapshot]
        let compressionBefore: PDFCompressionOptions?
        let compressionAfter: PDFCompressionOptions?
        let ocrBefore: PDFOCROptions?
        let ocrAfter: PDFOCROptions?
    }

    static let commandKind = "pdfToolbox.operationConfig"

    let id: UUID
    let operationType: UndoOperationType = .pdfOperationConfig
    let title: String
    let timestamp: Date
    let context: OperationContext = .pdfToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = true
    let transactionGroupID: UUID?

    private let payload: Payload
    private let applyConfig: @MainActor (Payload, _ isUndo: Bool) -> Void

    init(
        id: UUID = UUID(),
        title: String,
        timestamp: Date = Date(),
        payload: Payload,
        transactionGroupID: UUID? = nil,
        applyConfig: @escaping @MainActor (Payload, _ isUndo: Bool) -> Void
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.payload = Self.scrubPasswords(payload)
        self.affectedURLs = payload.affectedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        self.transactionGroupID = transactionGroupID
        self.applyConfig = applyConfig
    }

    private static func scrubPasswords(_ raw: Payload) -> Payload {
        var cBefore = raw.compressionBefore
        cBefore?.password = nil
        var cAfter = raw.compressionAfter
        cAfter?.password = nil
        var oBefore = raw.ocrBefore
        oBefore?.password = nil
        var oAfter = raw.ocrAfter
        oAfter?.password = nil
        return Payload(
            scopeKey: raw.scopeKey,
            affectedPaths: raw.affectedPaths,
            snapshots: raw.snapshots,
            compressionBefore: cBefore,
            compressionAfter: cAfter,
            ocrBefore: oBefore,
            ocrAfter: oAfter
        )
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] {
        payload.snapshots
    }

    var persistenceDescriptor: UndoCommandPersistenceDescriptor? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return UndoCommandPersistenceDescriptor(
            commandKind: Self.commandKind,
            schemaVersion: 1,
            payloadData: data,
            referencedArtifactIDs: [],
            fileSnapshots: payload.snapshots
        )
    }

    func undo() async throws {
        applyConfig(payload, true)
    }

    func redo() async throws {
        applyConfig(payload, false)
    }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? PDFOperationConfigUndoCommand,
              other.transactionGroupID == gid,
              other.payload.scopeKey == payload.scopeKey else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? PDFOperationConfigUndoCommand else { return nil }
        let merged = Payload(
            scopeKey: payload.scopeKey,
            affectedPaths: other.payload.affectedPaths,
            snapshots: payload.snapshots,
            compressionBefore: payload.compressionBefore,
            compressionAfter: other.payload.compressionAfter,
            ocrBefore: payload.ocrBefore,
            ocrAfter: other.payload.ocrAfter
        )
        return PDFOperationConfigUndoCommand(
            id: self.id,
            title: other.title,
            timestamp: other.timestamp,
            payload: merged,
            transactionGroupID: self.transactionGroupID,
            applyConfig: self.applyConfig
        )
    }
}

@MainActor
final class PDFToolboxUndoRehydrator: UndoCommandRehydrating {
    let supportedCommandKinds: Set<String> = [
        PDFPageDraftUndoCommand.commandKind,
        PDFOperationConfigUndoCommand.commandKind
    ]
    private let applyPageDraft: @MainActor (URL, PDFPageWorkspaceDraft) -> Void
    private let applyOperationConfig: @MainActor (PDFOperationConfigUndoCommand.Payload, Bool) -> Void

    init(
        applyPageDraft: @escaping @MainActor (URL, PDFPageWorkspaceDraft) -> Void,
        applyOperationConfig: @escaping @MainActor (PDFOperationConfigUndoCommand.Payload, Bool) -> Void
    ) {
        self.applyPageDraft = applyPageDraft
        self.applyOperationConfig = applyOperationConfig
    }

    func rehydrateCommand(
        from entry: UndoHistoryEntry,
        descriptor: UndoCommandPersistenceDescriptor,
        artifactManager: RecoveryArtifactManager
    ) async throws -> (any UndoableCommand)? {
        switch descriptor.commandKind {
        case PDFPageDraftUndoCommand.commandKind:
            let payload = try JSONDecoder().decode(PDFPageDraftUndoCommand.Payload.self, from: descriptor.payloadData)
            let url = URL(fileURLWithPath: payload.filePath).standardizedFileURL
            return PDFPageDraftUndoCommand(
                id: entry.id,
                title: entry.title,
                timestamp: entry.timestamp,
                fileURL: url,
                before: payload.before,
                after: payload.after,
                transactionGroupID: entry.transactionGroupID,
                applyDraft: applyPageDraft
            )
        case PDFOperationConfigUndoCommand.commandKind:
            let payload = try JSONDecoder().decode(PDFOperationConfigUndoCommand.Payload.self, from: descriptor.payloadData)
            return PDFOperationConfigUndoCommand(
                id: entry.id,
                title: entry.title,
                timestamp: entry.timestamp,
                payload: payload,
                transactionGroupID: entry.transactionGroupID,
                applyConfig: applyOperationConfig
            )
        default:
            return nil
        }
    }
}

// MARK: - Long-Lived Per-File PDF Toolbox Store

@MainActor
final class PDFToolboxStore: ObservableObject {
    @Published private(set) var pageWorkspacesByURL: [URL: PDFPageWorkspaceDraft] = [:]
    @Published private(set) var annotationDraftsByURL: [URL: PDFAnnotationWorkspaceDraft] = [:]
    @Published private(set) var formDraftsByURL: [URL: PDFFormDraftSnapshot] = [:]
    @Published private(set) var redactionDraftsByURL: [URL: PDFRedactionDraft] = [:]
    @Published private(set) var compressionConfigsByKey: [String: PDFCompressionOptions] = [:]
    @Published private(set) var ocrConfigsByKey: [String: PDFOCROptions] = [:]

    private let undoCoordinator: UndoRedoCoordinator
    private var pendingUndoChain: Task<Void, Never>?

    private var activeFormTypingKey: String?
    private var activeFormTypingGroupID: UUID?
    private var formTypingResetTask: Task<Void, Never>?

    private var activeAnnotCoalesceKey: String?
    private var activeAnnotGroupID: UUID?
    private var annotResetTask: Task<Void, Never>?

    private var activeConfigCoalesceKey: String?
    private var activeConfigGroupID: UUID?
    private var configResetTask: Task<Void, Never>?

    init(undoCoordinator: UndoRedoCoordinator = .shared) {
        self.undoCoordinator = undoCoordinator
        let rehydrator = PDFToolboxUndoRehydrator(
            applyPageDraft: { [weak self] url, restored in
                self?.pageWorkspacesByURL[url.standardizedFileURL] = restored
            },
            applyOperationConfig: { [weak self] payload, isUndo in
                guard let self else { return }
                let comp = isUndo ? payload.compressionBefore : payload.compressionAfter
                let ocr = isUndo ? payload.ocrBefore : payload.ocrAfter
                if let comp {
                    self.compressionConfigsByKey[payload.scopeKey] = comp
                }
                if let ocr {
                    self.ocrConfigsByKey[payload.scopeKey] = ocr
                }
            }
        )
        undoCoordinator.registerRehydrator(rehydrator)
    }

    static func configKey(for files: [URL]) -> String {
        if files.count == 1 {
            return files[0].standardizedFileURL.path
        }
        return "__batch__"
    }

    func compressionConfig(for key: String) -> PDFCompressionOptions {
        compressionConfigsByKey[key] ?? .forProfile(.balanced)
    }

    func ocrConfig(for key: String) -> PDFOCROptions {
        ocrConfigsByKey[key] ?? .default
    }

    func updateCompressionConfig(
        for key: String,
        affectedURLs: [URL],
        title: String,
        coalesceKey: String? = nil,
        _ mutate: (inout PDFCompressionOptions) -> Void
    ) {
        var before = compressionConfig(for: key)
        before.password = nil
        var next = before
        mutate(&next)
        next.password = nil
        guard next != before else { return }
        compressionConfigsByKey[key] = next

        let gid = resolveConfigGroupID(key: "comp|\(key)", coalesceKey: coalesceKey)
        let stdURLs = affectedURLs.map(\.standardizedFileURL)
        let snaps = stdURLs.compactMap { FileIdentitySnapshot.capture(url: $0) }
        let payload = PDFOperationConfigUndoCommand.Payload(
            scopeKey: key,
            affectedPaths: stdURLs.map(\.path),
            snapshots: snaps,
            compressionBefore: before,
            compressionAfter: next,
            ocrBefore: nil,
            ocrAfter: nil
        )
        let cmd = PDFOperationConfigUndoCommand(title: title, payload: payload, transactionGroupID: gid) { [weak self] p, isUndo in
            let restored = isUndo ? p.compressionBefore : p.compressionAfter
            if let restored {
                self?.compressionConfigsByKey[p.scopeKey] = restored
            }
        }
        enqueueUndo(cmd)
    }

    func updateOCRConfig(
        for key: String,
        affectedURLs: [URL],
        title: String,
        coalesceKey: String? = nil,
        _ mutate: (inout PDFOCROptions) -> Void
    ) {
        var before = ocrConfig(for: key)
        before.password = nil
        var next = before
        mutate(&next)
        next.password = nil
        guard next != before else { return }
        ocrConfigsByKey[key] = next

        let gid = resolveConfigGroupID(key: "ocr|\(key)", coalesceKey: coalesceKey)
        let stdURLs = affectedURLs.map(\.standardizedFileURL)
        let snaps = stdURLs.compactMap { FileIdentitySnapshot.capture(url: $0) }
        let payload = PDFOperationConfigUndoCommand.Payload(
            scopeKey: key,
            affectedPaths: stdURLs.map(\.path),
            snapshots: snaps,
            compressionBefore: nil,
            compressionAfter: nil,
            ocrBefore: before,
            ocrAfter: next
        )
        let cmd = PDFOperationConfigUndoCommand(title: title, payload: payload, transactionGroupID: gid) { [weak self] p, isUndo in
            let restored = isUndo ? p.ocrBefore : p.ocrAfter
            if let restored {
                self?.ocrConfigsByKey[p.scopeKey] = restored
            }
        }
        enqueueUndo(cmd)
    }

    private func resolveConfigGroupID(key: String, coalesceKey: String?) -> UUID? {
        guard let coalesceKey else {
            configResetTask?.cancel()
            activeConfigCoalesceKey = nil
            activeConfigGroupID = nil
            return nil
        }
        let fullKey = "\(key)|\(coalesceKey)"
        if activeConfigCoalesceKey != fullKey || activeConfigGroupID == nil {
            activeConfigCoalesceKey = fullKey
            activeConfigGroupID = UUID()
        }
        let gid = activeConfigGroupID
        configResetTask?.cancel()
        configResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            self?.activeConfigCoalesceKey = nil
            self?.activeConfigGroupID = nil
        }
        return gid
    }

    // MARK: - Annotation Drafts

    func annotationDraft(for url: URL) -> PDFAnnotationWorkspaceDraft {
        annotationDraftsByURL[url.standardizedFileURL] ?? PDFAnnotationWorkspaceDraft()
    }

    /// Silent initial load of existing PDF markup annotations (does NOT push an Undo entry).
    func hydrateAnnotations(_ records: [PDFDraftAnnotationRecord], for url: URL) {
        let k = url.standardizedFileURL
        if annotationDraftsByURL[k] == nil {
            annotationDraftsByURL[k] = PDFAnnotationWorkspaceDraft(records: records, flattenOnSave: false)
        }
    }

    func updateAnnotationDraft(
        for url: URL,
        title: String,
        coalesceKey: String? = nil,
        _ mutate: (inout PDFAnnotationWorkspaceDraft) -> Void
    ) {
        let k = url.standardizedFileURL
        let before = annotationDraft(for: k)
        var next = before
        mutate(&next)
        guard next != before else { return }
        annotationDraftsByURL[k] = next

        var gid: UUID? = nil
        if let coalesceKey {
            let fullKey = "\(k.path)|\(coalesceKey)"
            if activeAnnotCoalesceKey != fullKey || activeAnnotGroupID == nil {
                activeAnnotCoalesceKey = fullKey
                activeAnnotGroupID = UUID()
            }
            gid = activeAnnotGroupID
            annotResetTask?.cancel()
            annotResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                self?.activeAnnotCoalesceKey = nil
                self?.activeAnnotGroupID = nil
            }
        } else {
            annotResetTask?.cancel()
            activeAnnotCoalesceKey = nil
            activeAnnotGroupID = nil
        }

        let cmd = PDFAnnotationDraftUndoCommand(
            title: title,
            fileURL: k,
            before: before,
            after: next,
            transactionGroupID: gid,
            applyDraft: { [weak self] u, restored in
                self?.annotationDraftsByURL[u.standardizedFileURL] = restored
            }
        )
        enqueueUndo(cmd)
    }

    // MARK: - Page Workspace Drafts

    func pageWorkspaceDraft(for url: URL) -> PDFPageWorkspaceDraft {
        pageWorkspacesByURL[url.standardizedFileURL] ?? PDFPageWorkspaceDraft(primaryURL: url.standardizedFileURL, pages: [], sourceIdentity: nil)
    }

    /// Silent initial scan hydration (does NOT push an undo step). Re-hydrates automatically if underlying disk file changed.
    func hydratePageWorkspace(for url: URL, pageCount: Int) {
        let k = url.standardizedFileURL
        let currentDisk = FileIdentitySnapshot.capture(url: k, expectedToExist: true, includeContentHash: false)
        if let existing = pageWorkspacesByURL[k],
           !existing.pages.isEmpty,
           existing.sourceIdentity?.validateMatchesDisk().isValid != false {
            return
        }
        let descriptors = (0..<max(0, pageCount)).map {
            PDFPageDescriptor(sourceURL: k, sourcePageIndex: $0)
        }
        pageWorkspacesByURL[k] = PDFPageWorkspaceDraft(primaryURL: k, pages: descriptors, sourceIdentity: currentDisk)
    }

    func updatePageWorkspace(
        for url: URL,
        title: String,
        transactionGroupID: UUID? = nil,
        _ mutate: (inout PDFPageWorkspaceDraft) -> Void
    ) {
        let k = url.standardizedFileURL
        let before = pageWorkspaceDraft(for: k)
        var next = before
        mutate(&next)
        guard next != before else { return }
        pageWorkspacesByURL[k] = next

        let cmd = PDFPageDraftUndoCommand(
            title: title,
            fileURL: k,
            before: before,
            after: next,
            transactionGroupID: transactionGroupID,
            applyDraft: { [weak self] u, restored in
                self?.pageWorkspacesByURL[u.standardizedFileURL] = restored
            }
        )
        enqueueUndo(cmd)
    }

    // MARK: - Form Drafts

    func formDraft(for url: URL) -> PDFFormDraftSnapshot {
        formDraftsByURL[url.standardizedFileURL] ?? PDFFormDraftSnapshot()
    }

    /// Silent initial scan hydration (does NOT create an undo step).
    func hydrateScannedFormFields(_ fields: [PDFFormFieldItem], for url: URL) {
        let k = url.standardizedFileURL
        if formDraftsByURL[k] == nil || formDraftsByURL[k]?.fields.isEmpty == true {
            var snap = formDraftsByURL[k] ?? PDFFormDraftSnapshot()
            snap.fields = fields
            formDraftsByURL[k] = snap
        }
    }

    func updateFormDraft(
        for url: URL,
        title: String,
        coalesceKey: String? = nil,
        _ mutate: (inout PDFFormDraftSnapshot) -> Void
    ) {
        let k = url.standardizedFileURL
        let before = formDraft(for: k)
        var next = before
        mutate(&next)
        guard next != before else { return }
        formDraftsByURL[k] = next

        var gid: UUID? = nil
        if let coalesceKey {
            let fullKey = "\(k.path)|\(coalesceKey)"
            if activeFormTypingKey != fullKey || activeFormTypingGroupID == nil {
                activeFormTypingKey = fullKey
                activeFormTypingGroupID = UUID()
            }
            gid = activeFormTypingGroupID
            formTypingResetTask?.cancel()
            formTypingResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                self?.activeFormTypingKey = nil
                self?.activeFormTypingGroupID = nil
            }
        } else {
            formTypingResetTask?.cancel()
            activeFormTypingKey = nil
            activeFormTypingGroupID = nil
        }

        let cmd = PDFFormDraftUndoCommand(
            title: title,
            fileURL: k,
            before: before,
            after: next,
            transactionGroupID: gid,
            applyDraft: { [weak self] u, restored in
                self?.formDraftsByURL[u.standardizedFileURL] = restored
            }
        )
        enqueueUndo(cmd)
    }

    // MARK: - Redaction Drafts

    func redactionDraft(for url: URL) -> PDFRedactionDraft {
        redactionDraftsByURL[url.standardizedFileURL] ?? PDFRedactionDraft()
    }

    func updateRedactionDraft(
        for url: URL,
        title: String,
        transactionGroupID: UUID? = nil,
        _ mutate: (inout PDFRedactionDraft) -> Void
    ) {
        let k = url.standardizedFileURL
        let before = redactionDraft(for: k)
        var next = before
        mutate(&next)
        guard next != before else { return }
        redactionDraftsByURL[k] = next

        let cmd = PDFRedactionDraftUndoCommand(
            title: title,
            fileURL: k,
            before: before,
            after: next,
            transactionGroupID: transactionGroupID,
            applyDraft: { [weak self] u, restored in
                self?.redactionDraftsByURL[u.standardizedFileURL] = restored
            }
        )
        enqueueUndo(cmd)
    }

    func flushPendingUndoRecords() async {
        await pendingUndoChain?.value
    }

    private func enqueueUndo(_ cmd: any UndoableCommand) {
        let prev = pendingUndoChain
        let coordinator = undoCoordinator
        pendingUndoChain = Task { @MainActor in
            _ = await prev?.value
            await coordinator.record(cmd)
        }
    }
}

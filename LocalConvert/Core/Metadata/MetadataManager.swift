import Foundation
import SwiftUI
import os.log

@MainActor
final class MetadataManager: ObservableObject {
    
    static let shared = MetadataManager()
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "MetadataManager")
    private let registry = MetadataRegistry.shared
    
    @Published private(set) var activeURL: URL?
    @Published var document: MetadataDocument?
    @Published private(set) var originalDocument: MetadataDocument?
    @Published private(set) var capabilities: MetadataCapabilities?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isSaving: Bool = false
    @Published private(set) var lastSavedCopyURL: URL?
    @Published var errorMessage: String?
    @Published var showSuccessToast: Bool = false

    private var activeFieldEditID: String?
    private var activeFieldGroupID: UUID?
    private var fieldCoalesceResetTask: Task<Void, Never>?
    private var pendingUndoChain: Task<Void, Never>?
    private let undoCoordinator: UndoRedoCoordinator
    private let artifactManager: RecoveryArtifactManager
    private let historyManager: HistoryManager

    init(
        undoCoordinator: UndoRedoCoordinator = .shared,
        artifactManager: RecoveryArtifactManager = .shared,
        historyManager: HistoryManager = .shared
    ) {
        self.undoCoordinator = undoCoordinator
        self.artifactManager = artifactManager
        self.historyManager = historyManager
    }

    /// Waits for any pending asynchronous undo-record tasks to complete.
    func flushPendingUndoRecords() async {
        await pendingUndoChain?.value
    }
    
    var isDirty: Bool {
        guard let doc = document, let orig = originalDocument else { return false }
        return doc != orig
    }
    
    // MARK: - Load
    
    func load(url: URL) async {
        activeURL = url
        isLoading = true
        errorMessage = nil
        showSuccessToast = false
        
        guard let format = FileDetector.detectFormat(url: url) else {
            isLoading = false
            errorMessage = "Could not detect file format."
            StructuredDiagnostics.record(
                category: .metadata,
                severity: .validation,
                stage: "load",
                filename: url.lastPathComponent,
                message: "Could not detect file format"
            )
            return
        }
        
        let caps = registry.capabilities(for: format)
        capabilities = caps
        
        guard let provider = registry.provider(for: format) else {
            isLoading = false
            errorMessage = "No metadata provider available for \(format.displayName)."
            StructuredDiagnostics.record(
                category: .metadata,
                severity: .validation,
                stage: "load",
                filename: url.lastPathComponent,
                message: "No metadata provider registered for \(format.fileExtension)"
            )
            return
        }
        
        do {
            let doc = try await provider.readMetadata(from: url)
            self.document = doc
            self.originalDocument = doc
            self.isLoading = false
            logger.info("Loaded metadata for \(url.lastPathComponent, privacy: .public)")
        } catch {
            self.isLoading = false
            self.errorMessage = error.localizedDescription
            logger.error("Failed to load metadata: \(error.localizedDescription, privacy: .public)")
            StructuredDiagnostics.record(
                category: .metadata,
                severity: .internalError,
                stage: "load",
                filename: url.lastPathComponent,
                message: error.localizedDescription
            )
        }
    }
    
    // MARK: - Update
    
    func updateField(id: String, value: MetadataValue?) {
        guard let before = document else { return }
        var doc = before
        doc.setValue(value, for: id)
        self.document = doc
        if activeFieldEditID != id || activeFieldGroupID == nil {
            activeFieldEditID = id
            activeFieldGroupID = UUID()
        }
        let groupID = activeFieldGroupID
        fieldCoalesceResetTask?.cancel()
        fieldCoalesceResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.activeFieldEditID = nil
            self?.activeFieldGroupID = nil
        }
        recordMetadataUndo(
            type: .metadataDraftEdit,
            title: "Edit Metadata Field",
            before: before,
            after: doc,
            transactionGroupID: groupID
        )
    }
    
    func updateArtwork(data: Data?, mimeType: String = "image/jpeg") {
        guard let before = document else { return }
        var doc = before
        if let data = data {
            do {
                let (normalized, ext) = try AudioMetadataProvider.validateAndNormalizeArtwork(data)
                let resolvedMime = (ext == "png") ? "image/png" : mimeType
                doc.artwork = MetadataArtwork(data: normalized, mimeType: resolvedMime)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } else {
            doc.artwork = nil
            errorMessage = nil
        }
        self.document = doc
        recordMetadataUndo(type: .metadataDraftEdit, title: "Update Artwork", before: before, after: doc)
    }
    
    func removeGPS() {
        guard let before = document else { return }
        var doc = before
        doc.gps = nil
        self.document = doc
        recordMetadataUndo(type: .metadataDraftEdit, title: "Remove GPS Metadata", before: before, after: doc)
    }
    
    func removeAllMetadata() {
        guard let before = document, let url = activeURL, let format = FileDetector.detectFormat(url: url) else { return }
        var cleanDoc = MetadataDocument(format: format, fileURL: url)
        cleanDoc.technical = document?.technical ?? [:]
        cleanDoc.isStrippedAll = true
        self.document = cleanDoc
        recordMetadataUndo(type: .metadataDraftEdit, title: "Remove All Metadata", before: before, after: cleanDoc)
    }
    
    func revert() {
        guard let before = document, let orig = originalDocument else { return }
        self.document = orig
        recordMetadataUndo(type: .metadataDraftEdit, title: "Revert Metadata", before: before, after: orig)
    }

    private func recordMetadataUndo(
        type: UndoOperationType,
        title: String,
        before: MetadataDocument,
        after: MetadataDocument,
        transactionGroupID: UUID? = nil
    ) {
        if transactionGroupID == nil {
            fieldCoalesceResetTask?.cancel()
            activeFieldEditID = nil
            activeFieldGroupID = nil
        }
        guard before != after else { return }
        let coordinator = undoCoordinator
        let cmd = MetadataSnapshotUndoCommand(
            operationType: type,
            title: title,
            before: before,
            after: after,
            transactionGroupID: transactionGroupID,
            applyDocument: { [weak self] restored in
                self?.document = restored
            }
        )
        let previous = pendingUndoChain
        pendingUndoChain = Task {
            await previous?.value
            await coordinator.record(cmd)
        }
    }

    // MARK: - Save (In-Place & Collision-Safe Copy)

    /// Computes a collision-safe sibling copy URL (`<name>_tagged.<ext>`, `<name>_tagged_2.<ext>`, ...) without reserving it.
    func suggestedSaveCopyURL(for sourceOverride: URL? = nil) -> URL? {
        guard let sourceURL = sourceOverride ?? activeURL else { return nil }
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        guard let reserved = try? ConversionManager.reserveUniqueOutputURL(
            directory: directory,
            baseName: "\(baseName)_tagged",
            extension: ext,
            sourceURL: sourceURL,
            policy: .createUnique
        ) else {
            return directory.appendingPathComponent("\(baseName)_tagged.\(ext)")
        }
        ConversionManager.releaseReservedOutputURL(reserved)
        return reserved
    }

    func save(context: OperationContext = .metadata) async -> Bool {
        await saveInPlace(context: context)
    }

    func saveInPlace(context: OperationContext = .metadata) async -> Bool {
        guard let url = activeURL, let doc = document else { return false }
        guard let format = FileDetector.detectFormat(url: url), let provider = registry.provider(for: format) else {
            errorMessage = "No metadata provider for \(url.pathExtension)."
            return false
        }

        await flushPendingUndoRecords()
        isSaving = true
        errorMessage = nil
        let startTime = CFAbsoluteTimeGetCurrent()
        var stagedOriginalID: UUID?

        do {
            let stagedOriginal = try await artifactManager.stageFileByCopying(from: url)
            stagedOriginalID = stagedOriginal.id
            let writeResult = try await provider.writeMetadata(doc, to: url)
            let writtenURL = writeResult.outputURL
            self.originalDocument = doc
            self.isSaving = false
            self.showSuccessToast = true

            let cmd = MetadataFileWriteUndoCommand(
                title: "Save Metadata (\(writtenURL.lastPathComponent))",
                context: context,
                destinationURL: writtenURL,
                protectedSourceURLs: [],
                previousArtifactID: stagedOriginal.id,
                artifactManager: artifactManager,
                onDidMutateDisk: { [weak self] mutatedURL, existsOnDisk in
                    guard let self, existsOnDisk else { return }
                    guard let active = self.activeURL,
                          active.standardizedFileURL.resolvingSymlinksInPath() == mutatedURL.standardizedFileURL.resolvingSymlinksInPath() else {
                        return
                    }
                    await self.reloadActiveFromDiskPreservingErrorState()
                }
            )
            await undoCoordinator.record(cmd)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let size = (try? FileManager.default.attributesOfItem(atPath: writtenURL.path)[.size] as? NSNumber)?.int64Value

            let historyItem = ConversionHistoryItem(
                id: UUID(),
                inputFilename: url.lastPathComponent,
                inputFormatName: format.displayName,
                outputFilename: writtenURL.lastPathComponent,
                outputFormatName: "Metadata Updated",
                date: Date(),
                status: .completed,
                inputSizeBytes: size,
                outputSizeBytes: size,
                presetName: "Metadata Edit",
                outputURLPath: writtenURL.path,
                duration: duration,
                source: .manual
            )
            historyManager.addEntry(historyItem)

            logger.info("Saved metadata in-place to \(writtenURL.lastPathComponent, privacy: .public)")
            return true
        } catch {
            if let stagedOriginalID {
                await artifactManager.releaseArtifact(id: stagedOriginalID)
            }
            self.isSaving = false
            self.errorMessage = error.localizedDescription
            logger.error("Failed to save metadata in-place: \(error.localizedDescription, privacy: .public)")
            StructuredDiagnostics.record(
                category: .metadata,
                severity: .internalError,
                stage: "saveInPlace",
                filename: url.lastPathComponent,
                message: error.localizedDescription
            )
            return false
        }
    }

    /// Writes modified metadata to a distinct destination file without modifying `activeURL`.
    /// When `destinationURL` is `nil`, automatically reserves a collision-safe `<name>_tagged.<ext>` sibling path.
    @discardableResult
    func saveCopy(to destinationURL: URL? = nil, context: OperationContext = .metadata) async -> URL? {
        guard let sourceURL = activeURL, let doc = document else { return nil }
        guard let format = FileDetector.detectFormat(url: sourceURL), let provider = registry.provider(for: format) else {
            errorMessage = "No metadata provider for \(sourceURL.pathExtension)."
            return nil
        }

        let sourceResolved = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let ext = sourceURL.pathExtension.isEmpty ? format.fileExtension : sourceURL.pathExtension
        let targetURL: URL
        let didReserveTarget: Bool

        if let explicitURL = destinationURL {
            if explicitURL.standardizedFileURL.resolvingSymlinksInPath() == sourceResolved {
                errorMessage = "Save Copy destination must be distinct from the original source file."
                return nil
            }
            targetURL = explicitURL
            didReserveTarget = false
        } else {
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            guard let reserved = try? ConversionManager.reserveUniqueOutputURL(
                directory: sourceURL.deletingLastPathComponent(),
                baseName: "\(baseName)_tagged",
                extension: ext,
                sourceURL: sourceURL,
                policy: .createUnique
            ) else {
                errorMessage = "Failed to reserve a collision-safe metadata copy path."
                return nil
            }
            targetURL = reserved
            didReserveTarget = true
        }

        defer {
            if didReserveTarget {
                ConversionManager.releaseReservedOutputURL(targetURL)
            }
        }

        await flushPendingUndoRecords()
        isSaving = true
        errorMessage = nil
        let startTime = CFAbsoluteTimeGetCurrent()
        let fm = FileManager.default
        let targetDirectory = targetURL.deletingLastPathComponent()
        let tempCopyURL = targetDirectory.appendingPathComponent(".localconvert_metacopy_\(UUID().uuidString).\(ext)")
        var previousArtifactID: UUID?

        do {
            try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: targetURL.path) {
                let stagedExisting = try await artifactManager.stageFileByCopying(from: targetURL)
                previousArtifactID = stagedExisting.id
            }

            try fm.copyItem(at: sourceURL, to: tempCopyURL)
            var copyDoc = doc
            copyDoc.fileURL = tempCopyURL
            let writeResult = try await provider.writeMetadata(copyDoc, to: tempCopyURL)
            let writtenTempURL = writeResult.outputURL

            if fm.fileExists(atPath: targetURL.path) {
                _ = try fm.replaceItemAt(targetURL, withItemAt: writtenTempURL)
            } else {
                try fm.moveItem(at: writtenTempURL, to: targetURL)
            }
            if fm.fileExists(atPath: tempCopyURL.path) {
                try? fm.removeItem(at: tempCopyURL)
            }

            self.lastSavedCopyURL = targetURL
            self.isSaving = false
            self.showSuccessToast = true

            let cmd = MetadataFileWriteUndoCommand(
                title: "Save Metadata Copy (\(targetURL.lastPathComponent))",
                context: context,
                destinationURL: targetURL,
                protectedSourceURLs: [sourceURL],
                previousArtifactID: previousArtifactID,
                artifactManager: artifactManager,
                onDidMutateDisk: { [weak self] mutatedURL, existsOnDisk in
                    guard let self else { return }
                    if existsOnDisk {
                        self.lastSavedCopyURL = mutatedURL
                    } else if self.lastSavedCopyURL?.standardizedFileURL.resolvingSymlinksInPath() == mutatedURL.standardizedFileURL.resolvingSymlinksInPath() {
                        self.lastSavedCopyURL = nil
                    }
                    if existsOnDisk,
                       let active = self.activeURL,
                       active.standardizedFileURL.resolvingSymlinksInPath() == mutatedURL.standardizedFileURL.resolvingSymlinksInPath() {
                        await self.reloadActiveFromDiskPreservingErrorState()
                    }
                }
            )
            await undoCoordinator.record(cmd)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let inputSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value
            let outputSize = (try? fm.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.int64Value

            let historyItem = ConversionHistoryItem(
                id: UUID(),
                inputFilename: sourceURL.lastPathComponent,
                inputFormatName: format.displayName,
                outputFilename: targetURL.lastPathComponent,
                outputFormatName: "Metadata Copy",
                date: Date(),
                status: .completed,
                inputSizeBytes: inputSize,
                outputSizeBytes: outputSize,
                presetName: "Metadata Save Copy",
                outputURLPath: targetURL.path,
                duration: duration,
                source: .manual
            )
            historyManager.addEntry(historyItem)

            logger.info("Saved metadata copy to \(targetURL.lastPathComponent, privacy: .public)")
            return targetURL
        } catch {
            if fm.fileExists(atPath: tempCopyURL.path) {
                try? fm.removeItem(at: tempCopyURL)
            }
            if let previousArtifactID {
                await artifactManager.releaseArtifact(id: previousArtifactID)
            }
            self.isSaving = false
            self.errorMessage = error.localizedDescription
            logger.error("Failed to save metadata copy: \(error.localizedDescription, privacy: .public)")
            StructuredDiagnostics.record(
                category: .metadata,
                severity: .internalError,
                stage: "saveCopy",
                filename: sourceURL.lastPathComponent,
                message: error.localizedDescription
            )
            return nil
        }
    }

    private func reloadActiveFromDiskPreservingErrorState() async {
        guard let url = activeURL,
              let format = FileDetector.detectFormat(url: url),
              let provider = registry.provider(for: format),
              let refreshed = try? await provider.readMetadata(from: url) else {
            return
        }
        self.document = refreshed
        self.originalDocument = refreshed
    }
}

import Foundation
import SwiftUI

// MARK: - Image Config Undo Command (Per-file isolated, restart-survivable, coalesced)

@MainActor
final class ImageConfigUndoCommand: UndoableCommand {
    struct Payload: Codable, Sendable {
        let filePath: String?
        let before: ImageToolboxConfig
        let after: ImageToolboxConfig
    }

    static let commandKind = "imageToolbox.configMutation"

    let id: UUID
    let operationType: UndoOperationType
    let title: String
    let timestamp: Date
    let context: OperationContext = .imageToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = true
    let transactionGroupID: UUID?

    private let fileURL: URL?
    private let before: ImageToolboxConfig
    private var after: ImageToolboxConfig
    private let applyConfig: @MainActor (URL?, ImageToolboxConfig) -> Void

    init(
        id: UUID = UUID(),
        operationType: UndoOperationType,
        title: String,
        timestamp: Date = Date(),
        fileURL: URL?,
        before: ImageToolboxConfig,
        after: ImageToolboxConfig,
        transactionGroupID: UUID? = nil,
        applyConfig: @escaping @MainActor (URL?, ImageToolboxConfig) -> Void
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
        self.applyConfig = applyConfig
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
        applyConfig(fileURL, before)
    }

    func redo() async throws {
        applyConfig(fileURL, after)
    }

    func canCoalesce(with newer: any UndoableCommand) -> Bool {
        guard let gid = transactionGroupID,
              let other = newer as? ImageConfigUndoCommand,
              other.transactionGroupID == gid,
              other.fileURL == fileURL else {
            return false
        }
        return true
    }

    func coalesced(with newer: any UndoableCommand) -> (any UndoableCommand)? {
        guard let other = newer as? ImageConfigUndoCommand else { return nil }
        return ImageConfigUndoCommand(
            id: self.id,
            operationType: other.operationType,
            title: other.title,
            timestamp: other.timestamp,
            fileURL: self.fileURL,
            before: self.before,
            after: other.after,
            transactionGroupID: self.transactionGroupID,
            applyConfig: self.applyConfig
        )
    }
}

@MainActor
final class ImageTargetFormatUndoCommand: UndoableCommand {
    struct Payload: Codable, Sendable {
        let filePath: String?
        let beforeFormat: FileFormat
        let afterFormat: FileFormat
    }

    static let commandKind = "imageToolbox.targetFormatMutation"

    let id: UUID
    let operationType: UndoOperationType = .outputFormatChange
    let title: String
    let timestamp: Date
    let context: OperationContext = .imageToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = true
    let transactionGroupID: UUID?

    private let fileURL: URL?
    private let beforeFormat: FileFormat
    private let afterFormat: FileFormat
    private let applyFormat: @MainActor (URL?, FileFormat) -> Void

    init(
        id: UUID = UUID(),
        title: String,
        timestamp: Date = Date(),
        fileURL: URL?,
        beforeFormat: FileFormat,
        afterFormat: FileFormat,
        transactionGroupID: UUID? = nil,
        applyFormat: @escaping @MainActor (URL?, FileFormat) -> Void
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.fileURL = fileURL?.standardizedFileURL
        self.affectedURLs = fileURL.map { [$0.standardizedFileURL] } ?? []
        self.beforeFormat = beforeFormat
        self.afterFormat = afterFormat
        self.transactionGroupID = transactionGroupID
        self.applyFormat = applyFormat
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] { [] }

    var persistenceDescriptor: UndoCommandPersistenceDescriptor? {
        guard let data = try? JSONEncoder().encode(
            Payload(filePath: fileURL?.path, beforeFormat: beforeFormat, afterFormat: afterFormat)
        ) else { return nil }
        return UndoCommandPersistenceDescriptor(
            commandKind: Self.commandKind,
            schemaVersion: 1,
            payloadData: data
        )
    }

    func undo() async throws {
        applyFormat(fileURL, beforeFormat)
    }

    func redo() async throws {
        applyFormat(fileURL, afterFormat)
    }
}

@MainActor
final class ImageToolboxUndoRehydrator: UndoCommandRehydrating {
    let supportedCommandKinds: Set<String> = [
        ImageConfigUndoCommand.commandKind,
        ImageTargetFormatUndoCommand.commandKind
    ]
    private let applyConfig: @MainActor (URL?, ImageToolboxConfig) -> Void
    private let applyFormat: (@MainActor (URL?, FileFormat) -> Void)?

    init(
        applyConfig: @escaping @MainActor (URL?, ImageToolboxConfig) -> Void,
        applyFormat: (@MainActor (URL?, FileFormat) -> Void)? = nil
    ) {
        self.applyConfig = applyConfig
        self.applyFormat = applyFormat
    }

    func rehydrateCommand(
        from entry: UndoHistoryEntry,
        descriptor: UndoCommandPersistenceDescriptor,
        artifactManager: RecoveryArtifactManager
    ) async throws -> (any UndoableCommand)? {
        if descriptor.commandKind == ImageTargetFormatUndoCommand.commandKind {
            let payload = try JSONDecoder().decode(ImageTargetFormatUndoCommand.Payload.self, from: descriptor.payloadData)
            let url = payload.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let formatHandler = applyFormat ?? { _, _ in }
            return ImageTargetFormatUndoCommand(
                id: entry.id,
                title: entry.title,
                timestamp: entry.timestamp,
                fileURL: url,
                beforeFormat: payload.beforeFormat,
                afterFormat: payload.afterFormat,
                transactionGroupID: entry.transactionGroupID,
                applyFormat: formatHandler
            )
        }
        let payload = try JSONDecoder().decode(ImageConfigUndoCommand.Payload.self, from: descriptor.payloadData)
        let url = payload.filePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        return ImageConfigUndoCommand(
            id: entry.id,
            operationType: entry.operationType,
            title: entry.title,
            timestamp: entry.timestamp,
            fileURL: url,
            before: payload.before,
            after: payload.after,
            transactionGroupID: entry.transactionGroupID,
            applyConfig: applyConfig
        )
    }
}

// MARK: - Image Metadata / File Write Undo Command (Safe Artifact Backup & Identity Check)

@MainActor
final class ImageFileWriteUndoCommand: UndoableCommand {
    let id = UUID()
    let operationType: UndoOperationType = .imageInPlaceMetadataSave
    let title: String
    let timestamp = Date()
    let context: OperationContext = .imageToolbox
    let affectedURLs: [URL]
    let isReversible = true
    let survivesRestart = false
    let transactionGroupID: UUID? = nil

    private let destinationURL: URL
    private let protectedSourceURLs: [URL]
    private let artifactManager: RecoveryArtifactManager
    private let previousArtifactID: UUID?
    private var currentArtifactID: UUID?
    private var expectedIdentityOnDisk: FileIdentitySnapshot

    var referencedArtifactIDs: [UUID] {
        [previousArtifactID, currentArtifactID].compactMap { $0 }
    }

    var fileIdentitySnapshots: [FileIdentitySnapshot] {
        [expectedIdentityOnDisk]
    }

    init(
        title: String,
        destinationURL: URL,
        protectedSourceURLs: [URL] = [],
        previousArtifactID: UUID?,
        artifactManager: RecoveryArtifactManager = .shared
    ) {
        let std = destinationURL.standardizedFileURL
        self.title = title
        self.destinationURL = std
        self.protectedSourceURLs = protectedSourceURLs
        self.affectedURLs = [std]
        self.previousArtifactID = previousArtifactID
        self.artifactManager = artifactManager
        self.expectedIdentityOnDisk = FileIdentitySnapshot.capture(url: std, expectedToExist: true, includeContentHash: true)
    }

    func undo() async throws {
        guard expectedIdentityOnDisk.validateMatchesDisk().isValid else {
            throw UndoRedoError.staleEntry(
                entryTitle: title,
                reason: "Image file was modified externally since '\(title)' (\(destinationURL.lastPathComponent))."
            )
        }
        // Stage current written bytes for Redo before restoring or removing
        let stagedCurrent = try await artifactManager.stageFileByCopying(from: destinationURL)
        currentArtifactID = stagedCurrent.id

        if let prevID = previousArtifactID {
            _ = try await artifactManager.restoreFile(
                artifactID: prevID,
                to: destinationURL,
                protectedSourceURLs: protectedSourceURLs,
                allowOverwrite: true
            )
            expectedIdentityOnDisk = FileIdentitySnapshot.capture(url: destinationURL, expectedToExist: true, includeContentHash: true)
        } else {
            // File did not exist previously: remove created copy cleanly (never removes protected sources)
            let resolvedDest = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
            let isProtected = protectedSourceURLs.contains { $0.standardizedFileURL.resolvingSymlinksInPath() == resolvedDest }
            guard !isProtected else {
                throw UndoRedoError.operationIrreversible(reason: "Protected source file cannot be removed.")
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            expectedIdentityOnDisk = FileIdentitySnapshot.capture(url: destinationURL, expectedToExist: false)
        }
    }

    func redo() async throws {
        guard let curID = currentArtifactID else {
            throw UndoRedoError.staleEntry(entryTitle: title, reason: "Recovery data for redo is missing.")
        }
        guard expectedIdentityOnDisk.validateMatchesDisk().isValid else {
            throw UndoRedoError.staleEntry(
                entryTitle: title,
                reason: "Target file changed externally before redo (\(destinationURL.lastPathComponent))."
            )
        }
        _ = try await artifactManager.restoreFile(
            artifactID: curID,
            to: destinationURL,
            protectedSourceURLs: protectedSourceURLs,
            allowOverwrite: true
        )
        expectedIdentityOnDisk = FileIdentitySnapshot.capture(url: destinationURL, expectedToExist: true, includeContentHash: true)
    }

    func releaseRecoveryArtifacts() async {
        currentArtifactID = nil
    }
}

// MARK: - Long-Lived Per-File Image Toolbox Store

@MainActor
final class ImageToolboxStore: ObservableObject {
    @Published private(set) var configsByURL: [URL: ImageToolboxConfig] = [:]
    @Published private(set) var targetFormatByURL: [URL: FileFormat] = [:]
    @Published private var fallbackConfig = ImageToolboxConfig()
    @Published private var fallbackTargetFormat: FileFormat = .jxl

    private let undoCoordinator: UndoRedoCoordinator
    private var pendingUndoChain: Task<Void, Never>?

    // Continuous gesture / rapid slider coalescing
    private var activeContinuousGroupID: UUID?
    private var activeContinuousURL: URL?
    private var continuousSnapshotBefore: ImageToolboxConfig?

    private var rapidGroupID: UUID?
    private var rapidGroupKey: String?
    private var rapidResetTask: Task<Void, Never>?

    init(undoCoordinator: UndoRedoCoordinator = .shared) {
        self.undoCoordinator = undoCoordinator
        let rehydrator = ImageToolboxUndoRehydrator(
            applyConfig: { [weak self] url, restored in
                self?.applyRestoredConfig(restored, for: url)
            },
            applyFormat: { [weak self] url, restoredFormat in
                self?.applyRestoredTargetFormat(restoredFormat, for: url)
            }
        )
        undoCoordinator.registerRehydrator(rehydrator)
    }

    private static func key(_ url: URL?) -> URL? {
        url?.standardizedFileURL
    }

    static func defaultTargetFormat(for url: URL?) -> FileFormat {
        guard let url else { return .jxl }
        if FileDetector.detectFormat(url: url) == .jxl {
            return .png
        }
        return .jxl
    }

    func config(for url: URL?) -> ImageToolboxConfig {
        guard let k = Self.key(url) else { return fallbackConfig }
        return configsByURL[k] ?? ImageToolboxConfig()
    }

    func targetFormat(for url: URL?, fallback: FileFormat? = nil) -> FileFormat {
        guard let k = Self.key(url) else { return fallback ?? fallbackTargetFormat }
        return targetFormatByURL[k] ?? fallback ?? Self.defaultTargetFormat(for: k)
    }

    func setTargetFormat(_ format: FileFormat, for url: URL?, recordUndo: Bool = true) {
        let k = Self.key(url)
        let before = targetFormat(for: k)
        guard before != format else { return }

        if let k {
            targetFormatByURL[k] = format
        } else {
            fallbackTargetFormat = format
        }

        guard recordUndo else { return }
        let fileLabel = k?.lastPathComponent
        let title = fileLabel.map { "Output Format -> \(format.shortExtensionLabel) (\($0))" }
            ?? "Output Format -> \(format.shortExtensionLabel)"
        let cmd = ImageTargetFormatUndoCommand(
            title: title,
            fileURL: k,
            beforeFormat: before,
            afterFormat: format,
            applyFormat: { [weak self] u, restored in
                self?.applyRestoredTargetFormat(restored, for: u)
            }
        )
        enqueueUndoRecord(cmd)
    }

    func targetFormatBinding(for url: URL?, fallback: FileFormat? = nil) -> Binding<FileFormat> {
        let k = Self.key(url)
        return Binding(
            get: { self.targetFormat(for: k, fallback: fallback) },
            set: { newFormat in
                self.setTargetFormat(newFormat, for: k, recordUndo: true)
            }
        )
    }

    /// Migrates per-file configuration and target format entries when files are renamed, undone, or redone.
    func migrateURLs(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        var moveMap: [URL: URL] = [:]
        for move in moves {
            moveMap[move.from.standardizedFileURL] = move.to.standardizedFileURL
        }
        guard !moveMap.isEmpty else { return }

        let oldConfigs = configsByURL
        var updatedConfigs = oldConfigs
        for (fromKey, _) in moveMap {
            updatedConfigs.removeValue(forKey: fromKey)
        }
        for (fromKey, toKey) in moveMap {
            if let existing = oldConfigs[fromKey] {
                updatedConfigs[toKey] = existing
            }
        }
        configsByURL = updatedConfigs

        let oldFormats = targetFormatByURL
        var updatedFormats = oldFormats
        for (fromKey, _) in moveMap {
            updatedFormats.removeValue(forKey: fromKey)
        }
        for (fromKey, toKey) in moveMap {
            if let existing = oldFormats[fromKey] {
                updatedFormats[toKey] = existing
            }
        }
        targetFormatByURL = updatedFormats

        if let activeURL = activeContinuousURL, let movedActive = moveMap[activeURL] {
            activeContinuousURL = movedActive
        }
    }

    /// Silent metadata hydration when opening/loading an image; never pushes an Undo step.
    func hydrateMetadataDefaults(for url: URL, payload: ImageMetadataEditPayload) {
        let k = url.standardizedFileURL
        var cur = configsByURL[k] ?? ImageToolboxConfig()
        guard cur.metadataEdit.policy == .preserveAll, cur.metadataEdit != payload else { return }
        cur.metadataEdit = payload
        configsByURL[k] = cur
    }

    // MARK: - Continuous Gesture Support (Explicit or Auto-Coalesced)

    func beginContinuousEdit(for url: URL?) {
        let k = Self.key(url)
        if activeContinuousGroupID != nil && activeContinuousURL != k {
            endContinuousEdit(for: activeContinuousURL)
        }
        if activeContinuousGroupID == nil {
            activeContinuousGroupID = UUID()
            activeContinuousURL = k
            continuousSnapshotBefore = config(for: k)
        }
    }

    func endContinuousEdit(for url: URL?, explicitType: UndoOperationType? = nil, explicitTitle: String? = nil) {
        let k = Self.key(url)
        guard let gid = activeContinuousGroupID,
              activeContinuousURL == k,
              let before = continuousSnapshotBefore else {
            activeContinuousGroupID = nil
            activeContinuousURL = nil
            continuousSnapshotBefore = nil
            return
        }
        let after = config(for: k)
        activeContinuousGroupID = nil
        activeContinuousURL = nil
        continuousSnapshotBefore = nil
        guard before != after else { return }
        let classified = Self.classifyChange(from: before, to: after)
        let cmd = ImageConfigUndoCommand(
            operationType: explicitType ?? classified.type,
            title: explicitTitle ?? classified.title,
            fileURL: k,
            before: before,
            after: after,
            transactionGroupID: gid,
            applyConfig: { [weak self] u, cfg in self?.applyRestoredConfig(cfg, for: u) }
        )
        enqueueUndoRecord(cmd)
    }

    func updateConfig(
        for url: URL?,
        explicitType: UndoOperationType? = nil,
        explicitTitle: String? = nil,
        transactionGroupID: UUID? = nil,
        _ mutate: (inout ImageToolboxConfig) -> Void
    ) {
        let k = Self.key(url)
        let before = config(for: k)
        var next = before
        mutate(&next)
        guard next != before else { return }

        if let k {
            configsByURL[k] = next
        } else {
            fallbackConfig = next
        }

        // If inside an explicit continuous drag gesture, defer recording until endContinuousEdit()
        if activeContinuousGroupID != nil && activeContinuousURL == k {
            return
        }

        let classified = Self.classifyChange(from: before, to: next)
        let opType = explicitType ?? classified.type
        let title = explicitTitle ?? classified.title

        let gid: UUID
        if let provided = transactionGroupID {
            gid = provided
        } else {
            // Auto-coalesce rapid continuous slider drags (e.g. quality, sharpen, corner radius, opacity)
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

        let cmd = ImageConfigUndoCommand(
            operationType: opType,
            title: title,
            fileURL: k,
            before: before,
            after: next,
            transactionGroupID: gid,
            applyConfig: { [weak self] u, cfg in self?.applyRestoredConfig(cfg, for: u) }
        )
        enqueueUndoRecord(cmd)
    }

    func binding(for url: URL?) -> Binding<ImageToolboxConfig> {
        let k = Self.key(url)
        return Binding(
            get: { self.config(for: k) },
            set: { newValue in
                self.updateConfig(for: k) { $0 = newValue }
            }
        )
    }

    func resetConfig(for url: URL?) {
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Image Pipeline") {
            $0 = ImageToolboxConfig()
        }
    }

    // MARK: - Ordered Effect Stack Helpers

    func addEffect(_ kind: ImageEffectKind, for url: URL?) {
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Add Effect: \(kind.rawValue)") { cfg in
            cfg.effectStack.append(ImageEffectSlot.makeDefault(kind: kind))
        }
    }

    func removeEffect(id: UUID, for url: URL?) {
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Remove Effect") { cfg in
            cfg.effectStack.removeAll { $0.id == id }
        }
    }

    func moveEffect(id: UUID, offset: Int, for url: URL?) {
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reorder Effects") { cfg in
            guard let idx = cfg.effectStack.firstIndex(where: { $0.id == id }) else { return }
            let dest = idx + offset
            guard cfg.effectStack.indices.contains(dest) else { return }
            cfg.effectStack.swapAt(idx, dest)
        }
    }

    func toggleEffect(id: UUID, for url: URL?) {
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Toggle Effect") { cfg in
            guard let idx = cfg.effectStack.firstIndex(where: { $0.id == id }) else { return }
            cfg.effectStack[idx].isEnabled.toggle()
        }
    }

    func resetEffect(id: UUID, for url: URL?) {
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Effect") { cfg in
            guard let idx = cfg.effectStack.firstIndex(where: { $0.id == id }) else { return }
            cfg.effectStack[idx].resetParameters()
        }
    }

    func resetAllEffects(for url: URL?) {
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Effects Stack") { cfg in
            cfg.effectStack.removeAll()
        }
    }

    // MARK: - Look Preset Application (Single & Multi-Image Batch)

    @discardableResult
    func applyPreset(_ preset: SavedPreset, to url: URL?, lookOnly: Bool? = nil) -> Bool {
        let validation = ImagePresetCatalog.validatePreset(preset)
        guard validation.isValid else { return false }
        var didApply = false
        updateConfig(for: url, explicitType: .presetApply, explicitTitle: "Apply Preset: \(preset.name)") { cfg in
            didApply = ImagePresetCatalog.apply(preset: preset, lookOnly: lookOnly, to: &cfg)
        }
        return didApply
    }

    func applyPresetBatch(
        _ preset: SavedPreset,
        to urls: [URL],
        lookOnly: Bool? = nil
    ) async -> ImageBatchPresetReport {
        let validation = ImagePresetCatalog.validatePreset(preset)
        guard validation.isValid else {
            let fails = urls.map {
                ImageBatchPresetOutcome(url: $0, succeeded: false, message: validation.reason ?? "Invalid preset")
            }
            return ImageBatchPresetReport(presetName: preset.name, outcomes: fails, wasCancelled: false)
        }

        let batchGroupID = UUID()
        var outcomes: [ImageBatchPresetOutcome] = []
        var cancelled = false

        for u in urls {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let fmt = FileDetector.detectFormat(url: u)
            guard fmt?.category == .image else {
                outcomes.append(ImageBatchPresetOutcome(url: u, succeeded: false, message: "Not a supported image file."))
                continue
            }
            var ok = false
            updateConfig(
                for: u,
                explicitType: .presetApply,
                explicitTitle: "Apply Preset: \(preset.name)",
                transactionGroupID: batchGroupID
            ) { cfg in
                ok = ImagePresetCatalog.apply(preset: preset, lookOnly: lookOnly, to: &cfg)
            }
            outcomes.append(
                ImageBatchPresetOutcome(
                    url: u,
                    succeeded: ok,
                    message: ok ? "Applied '\(preset.name)'." : "Failed to decode preset parameters."
                )
            )
            await Task.yield()
        }

        return ImageBatchPresetReport(presetName: preset.name, outcomes: outcomes, wasCancelled: cancelled)
    }

    /// Directly assigns a loaded project configuration (e.g. from `.lcimg`) under Undo/Redo.
    func applyLoadedConfig(_ loadedConfig: ImageToolboxConfig, for url: URL, title: String = "Open Image Project") {
        if activeContinuousGroupID != nil {
            endContinuousEdit(for: activeContinuousURL)
        }
        updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: title) { cfg in
            cfg = loadedConfig
        }
    }

    func recordFileWriteCommand(_ cmd: ImageFileWriteUndoCommand) {
        let prev = pendingUndoChain
        let coordinator = undoCoordinator
        pendingUndoChain = Task { @MainActor in
            _ = await prev?.value
            await coordinator.record(cmd)
        }
    }

    func flushPendingUndoRecords() async {
        await pendingUndoChain?.value
    }

    private func applyRestoredConfig(_ restored: ImageToolboxConfig, for url: URL?) {
        if let k = Self.key(url) {
            configsByURL[k] = restored
        } else {
            fallbackConfig = restored
        }
    }

    private func applyRestoredTargetFormat(_ restored: FileFormat, for url: URL?) {
        if let k = Self.key(url) {
            targetFormatByURL[k] = restored
        } else {
            fallbackTargetFormat = restored
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

    static func classifyChange(from before: ImageToolboxConfig, to after: ImageToolboxConfig) -> (type: UndoOperationType, title: String) {
        if before.cropTransform.rotationDegrees != after.cropTransform.rotationDegrees
            || before.cropTransform.flipHorizontal != after.cropTransform.flipHorizontal
            || before.cropTransform.flipVertical != after.cropTransform.flipVertical {
            return (.imageRotateFlip, "Image Rotate / Flip")
        }
        if before.cropTransform.straightenDegrees != after.cropTransform.straightenDegrees
            || before.cropTransform.autoCropOnStraighten != after.cropTransform.autoCropOnStraighten {
            return (.imageCrop, "Straighten Image")
        }
        if before.cropTransform != after.cropTransform {
            if before.cropTransform.shape != after.cropTransform.shape
                || before.cropTransform.roundedCornerRadiusPercent != after.cropTransform.roundedCornerRadiusPercent
                || before.cropTransform.polygonSides != after.cropTransform.polygonSides
                || before.cropTransform.polygonVertices != after.cropTransform.polygonVertices {
                return (.imageCrop, "Shape Crop")
            }
            return (.imageCrop, "Image Crop")
        }
        if before.perspective != after.perspective {
            return (.imageCrop, "Perspective Crop")
        }
        if before.resizeStrategy != after.resizeStrategy
            || before.resizeWidth != after.resizeWidth
            || before.resizeHeight != after.resizeHeight
            || before.resizePercentage != after.resizePercentage
            || before.preserveAspectRatio != after.preserveAspectRatio
            || before.resamplingMethod != after.resamplingMethod
            || before.multiSizePresets != after.multiSizePresets
            || before.exportMultipleSizes != after.exportMultipleSizes {
            return (.imageResize, "Image Resize")
        }
        if before.postResizeSharpen != after.postResizeSharpen {
            return (.imageConfigEdit, "Image Sharpening")
        }
        if before.quality != after.quality || before.compressionProfile != after.compressionProfile {
            return (.imageConfigEdit, "Image Quality")
        }
        if before.watermark != after.watermark {
            return (.imageConfigEdit, "Image Watermark")
        }
        if before.upscale != after.upscale {
            return (.imageResize, "Image Upscale")
        }
        if before.canvasExtension != after.canvasExtension || before.borderFrame != after.borderFrame || before.dpiConfig != after.dpiConfig {
            return (.imageResize, "Canvas & Print Size")
        }
        if before.colorTarget != after.colorTarget {
            return (.imageConfigEdit, "Color Profile")
        }
        if before.colorAdjustments != after.colorAdjustments {
            return (.imageConfigEdit, "Color & Light Adjustments")
        }
        if before.effectStack != after.effectStack {
            return (.imageConfigEdit, "Effects Stack")
        }
        if before.rawDevelop != after.rawDevelop {
            return (.imageConfigEdit, "Camera RAW Develop")
        }
        if before.backgroundRemoval != after.backgroundRemoval {
            return (.imageConfigEdit, "Background Removal")
        }
        if before.metadataEdit != after.metadataEdit {
            return (.imageConfigEdit, "Image Metadata Draft")
        }
        return (.imageConfigEdit, "Image Adjustments")
    }
}

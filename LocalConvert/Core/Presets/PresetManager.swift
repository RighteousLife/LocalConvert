import Foundation
import SwiftUI
import os.log

// MARK: - Preset Manager

@MainActor
final class PresetManager: ObservableObject {
    
    static let shared = PresetManager()
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "PresetManager")
    
    let store: PresetStore
    let validator: PresetValidator
    let executor: PresetExecutor
    private let undoCoordinator: UndoRedoCoordinator
    private var pendingUndoChain: Task<Void, Never>?
    
    @Published var selectedPresetId: UUID?
    
    var presets: [SavedPreset] {
        store.userPresets
    }
    
    init(store: PresetStore = PresetStore(), undoCoordinator: UndoRedoCoordinator = .shared) {
        self.store = store
        self.validator = PresetValidator()
        self.executor = PresetExecutor()
        self.undoCoordinator = undoCoordinator
        self.selectedPresetId = store.userPresets.first?.id
    }
    
    // MARK: - Preset Operations
    
    func save(preset: SavedPreset) {
        let before = store.userPresets
        store.save(preset)
        selectedPresetId = preset.id
        objectWillChange.send()
        recordPresetUndo(type: .presetSave, title: "Save Preset \"\(preset.name)\"", before: before, after: store.userPresets)
    }
    
    func delete(id: UUID) {
        let before = store.userPresets
        store.delete(id: id)
        if selectedPresetId == id {
            selectedPresetId = store.userPresets.first?.id
        }
        objectWillChange.send()
        recordPresetUndo(type: .presetDelete, title: "Delete Preset", before: before, after: store.userPresets)
    }

    @discardableResult
    func rename(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let existing = store.get(id: id),
              !existing.isBuiltIn else {
            return false
        }
        let before = store.userPresets
        var updated = existing
        updated.name = trimmed
        store.save(updated)
        objectWillChange.send()
        recordPresetUndo(type: .presetSave, title: "Rename Preset \"\(trimmed)\"", before: before, after: store.userPresets)
        return true
    }
    
    func duplicate(id: UUID) -> SavedPreset? {
        let before = store.userPresets
        let duplicated = store.duplicate(id: id)
        if let dup = duplicated {
            selectedPresetId = dup.id
            recordPresetUndo(type: .presetDuplicate, title: "Duplicate Preset", before: before, after: store.userPresets)
        }
        objectWillChange.send()
        return duplicated
    }

    private func recordPresetUndo(
        type: UndoOperationType,
        title: String,
        before: [SavedPreset],
        after: [SavedPreset]
    ) {
        guard before != after else { return }
        let cmd = PresetStoreUndoCommand(
            operationType: type,
            title: title,
            beforePresets: before,
            afterPresets: after,
            applyPresets: { [weak self] restored in
                guard let self else { return }
                self.store.replaceAll(restored)
                if let currentSelected = self.selectedPresetId,
                   !restored.contains(where: { $0.id == currentSelected }) {
                    self.selectedPresetId = restored.first?.id
                } else if self.selectedPresetId == nil {
                    self.selectedPresetId = restored.first?.id
                }
                self.objectWillChange.send()
            }
        )
        let prev = pendingUndoChain
        let coordinator = undoCoordinator
        pendingUndoChain = Task { @MainActor in
            _ = await prev?.value
            await coordinator.record(cmd)
        }
    }
    
    func resetToDefaults() {
        let before = store.userPresets
        store.resetToDefaults()
        selectedPresetId = store.userPresets.first?.id
        objectWillChange.send()
        recordPresetUndo(type: .presetReset, title: "Reset Presets to Defaults", before: before, after: store.userPresets)
    }

    func flushPendingUndoRecords() async {
        await pendingUndoChain?.value
    }
    
    // MARK: - Queue Application
    
    /// Applies the preset to all compatible dropped files in AppState
    @discardableResult
    func apply(preset: SavedPreset, to appState: AppState) -> PresetBatchValidationResult {
        let urls = appState.droppedFiles.map { $0.url }
        let validation = validator.validateBatch(preset: preset, urls: urls)
        
        for fileIndex in appState.droppedFiles.indices {
            let fileURL = appState.droppedFiles[fileIndex].url
            if validation.compatibleURLs.contains(fileURL) {
                appState.droppedFiles[fileIndex].selectedOutputFormat = preset.targetFormat
                var opts = preset.options
                opts.overwriteExisting = opts.overwriteExisting || appState.droppedFiles[fileIndex].options.overwriteExisting
                opts.customOptions["preset_name"] = preset.name
                switch preset.outputNamingPolicy {
                case .addSuffix(let suffix):
                    opts.customOptions["output_suffix"] = suffix
                case .addPrefix(let prefix):
                    opts.customOptions["output_prefix"] = prefix
                case .standard:
                    break
                }
                appState.droppedFiles[fileIndex].options = opts
            }
        }
        
        logger.info("Applied preset '\(preset.name, privacy: .public)' to \(validation.compatibleURLs.count, privacy: .public) of \(appState.droppedFiles.count, privacy: .public) files in queue")
        return validation
    }
    
    /// Executes the preset directly on the files in AppState
    func execute(preset: SavedPreset, on appState: AppState) -> PresetExecutionReport {
        let urls = appState.droppedFiles.map { $0.url }
        appState.isConverting = true
        
        let report = executor.execute(
            preset: preset,
            inputURLs: urls,
            conversionManager: appState.conversionManager,
            conversionQueue: appState.conversionQueue,
            destinationOverride: nil,
            defaultOutputLocation: appState.outputLocation,
            customOutputDirectory: appState.customOutputDirectory
        )
        
        if report.enqueuedJobs.isEmpty {
            appState.isConverting = false
        }
        
        return report
    }
}

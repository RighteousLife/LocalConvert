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
    
    @Published var selectedPresetId: UUID?
    
    var presets: [SavedPreset] {
        store.userPresets
    }
    
    init(store: PresetStore = PresetStore()) {
        self.store = store
        self.validator = PresetValidator()
        self.executor = PresetExecutor()
        self.selectedPresetId = store.userPresets.first?.id
    }
    
    // MARK: - Preset Operations
    
    func save(preset: SavedPreset) {
        store.save(preset)
        selectedPresetId = preset.id
        objectWillChange.send()
    }
    
    func delete(id: UUID) {
        store.delete(id: id)
        if selectedPresetId == id {
            selectedPresetId = store.userPresets.first?.id
        }
        objectWillChange.send()
    }
    
    func duplicate(id: UUID) -> SavedPreset? {
        let duplicated = store.duplicate(id: id)
        if let dup = duplicated {
            selectedPresetId = dup.id
        }
        objectWillChange.send()
        return duplicated
    }
    
    func resetToDefaults() {
        store.resetToDefaults()
        selectedPresetId = store.userPresets.first?.id
        objectWillChange.send()
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
                opts.customOptions["preset_name"] = preset.name
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
        
        return report
    }
}

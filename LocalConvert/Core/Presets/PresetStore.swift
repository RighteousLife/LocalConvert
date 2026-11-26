import Foundation
import os.log

// MARK: - Preset Store

@MainActor
final class PresetStore: ObservableObject {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "PresetStore")
    
    @Published private(set) var userPresets: [SavedPreset] = []
    @Published private(set) var lastPersistenceError: String?
    
    let fileURL: URL
    
    init(fileURL: URL? = nil) {
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            let resolvedURL = AppStoragePaths.presetsFileURL
            try? FileManager.default.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.fileURL = resolvedURL
        }
        
        load()
    }

    func clearPersistenceError() {
        lastPersistenceError = nil
    }
    
    // MARK: - CRUD Operations
    
    func getAll() -> [SavedPreset] {
        userPresets
    }
    
    func get(id: UUID) -> SavedPreset? {
        userPresets.first { $0.id == id }
    }
    
    func save(_ preset: SavedPreset) {
        var mutablePreset = preset
        mutablePreset.modifiedAt = Date()
        
        if let index = userPresets.firstIndex(where: { $0.id == preset.id }) {
            userPresets[index] = mutablePreset
            logger.info("Updated preset '\(mutablePreset.name, privacy: .public)' (ID: \(mutablePreset.id, privacy: .public))")
        } else {
            userPresets.append(mutablePreset)
            logger.info("Created preset '\(mutablePreset.name, privacy: .public)' (ID: \(mutablePreset.id, privacy: .public))")
        }
        
        persist()
    }
    
    func delete(id: UUID) {
        if let index = userPresets.firstIndex(where: { $0.id == id }) {
            guard !userPresets[index].isBuiltIn else {
                logger.warning("Cannot delete built-in preset '\(self.userPresets[index].name, privacy: .public)'")
                return
            }
            let removed = userPresets.remove(at: index)
            logger.info("Deleted preset '\(removed.name, privacy: .public)' (ID: \(id, privacy: .public))")
            persist()
        }
    }
    
    func duplicate(id: UUID) -> SavedPreset? {
        guard let original = get(id: id) else { return nil }
        
        var duplicatePreset = original
        duplicatePreset.id = UUID()
        duplicatePreset.name = "\(original.name) (Copy)"
        duplicatePreset.isBuiltIn = false
        duplicatePreset.createdAt = Date()
        duplicatePreset.modifiedAt = Date()
        
        userPresets.append(duplicatePreset)
        logger.info("Duplicated preset '\(original.name, privacy: .public)' -> '\(duplicatePreset.name, privacy: .public)'")
        persist()
        return duplicatePreset
    }
    
    func resetToDefaults() {
        userPresets = SavedPreset.defaultTemplates
        logger.info("Reset user presets to default factory templates (\(self.userPresets.count, privacy: .public) presets)")
        persist()
    }

    func replaceAll(_ presets: [SavedPreset]) {
        userPresets = presets
        logger.info("Restored preset collection (\(self.userPresets.count, privacy: .public) presets)")
        persist()
    }
    
    // MARK: - Persistence
    
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // First run: populate with default templates
            userPresets = SavedPreset.defaultTemplates
            persist()
            return
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            userPresets = try decoder.decode([SavedPreset].self, from: data)
            lastPersistenceError = nil
            logger.info("Loaded \(self.userPresets.count, privacy: .public) saved presets from \(self.fileURL.lastPathComponent, privacy: .private)")
        } catch {
            let sanitizedError = ErrorDetailsFormatter.sanitize(error.localizedDescription)
            logger.error("Failed to decode presets from \(self.fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private). Falling back to safe recovery.")
            
            // Backup corrupted file
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent("presets.corrupted.\(timestamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            
            // Fallback safely to defaults without crashing
            userPresets = SavedPreset.defaultTemplates
            let persisted = persist()
            if persisted {
                lastPersistenceError = "Failed to load saved presets; corrupt file backed up as '\(backupURL.lastPathComponent)'."
            }
            StructuredDiagnostics.record(
                category: .fileAccess,
                severity: .internalError,
                stage: "loadPresets",
                filename: fileURL.lastPathComponent,
                message: "Failed to load presets (backed up to \(backupURL.lastPathComponent)): \(sanitizedError)"
            )
        }
    }
    
    @discardableResult
    func persist() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(userPresets)
            
            // Ensure directory exists
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            try data.write(to: fileURL, options: .atomic)
            lastPersistenceError = nil
            logger.debug("Persisted \(self.userPresets.count, privacy: .public) presets to \(self.fileURL.lastPathComponent, privacy: .private)")
            return true
        } catch {
            let sanitizedError = ErrorDetailsFormatter.sanitize(error.localizedDescription)
            logger.error("Failed to persist presets to \(self.fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            lastPersistenceError = "Failed to save presets: \(sanitizedError)"
            StructuredDiagnostics.record(
                category: .fileAccess,
                severity: .internalError,
                stage: "persistPresets",
                filename: fileURL.lastPathComponent,
                message: "Failed to persist presets: \(sanitizedError)"
            )
            return false
        }
    }
}

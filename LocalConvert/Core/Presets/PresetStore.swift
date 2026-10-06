import Foundation
import os.log

// MARK: - Preset Store

@MainActor
final class PresetStore: ObservableObject {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "PresetStore")
    
    @Published private(set) var userPresets: [SavedPreset] = []
    
    let fileURL: URL
    
    init(fileURL: URL? = nil) {
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "com.localconvert.app"
            let dir = appSupport.appendingPathComponent(bundleID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("presets.json")
        }
        
        load()
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
            logger.info("Loaded \(self.userPresets.count, privacy: .public) saved presets from \(self.fileURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Failed to decode presets from \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to safe recovery.")
            
            // Backup corrupted file
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent("presets.corrupted.\(timestamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            
            // Fallback safely to defaults without crashing
            userPresets = SavedPreset.defaultTemplates
            persist()
        }
    }
    
    func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(userPresets)
            
            // Ensure directory exists
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            try data.write(to: fileURL, options: .atomic)
            logger.debug("Persisted \(self.userPresets.count, privacy: .public) presets to \(self.fileURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Failed to persist presets to \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

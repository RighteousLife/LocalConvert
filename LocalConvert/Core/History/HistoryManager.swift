import Foundation
import os.log
import Combine

@MainActor
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    
    @Published private(set) var items: [ConversionHistoryItem] = []
    
    private let maxEntries = 500
    private let logger = Logger(subsystem: "com.localconvert.app", category: "HistoryManager")
    
    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.localconvert.app"
        let dir = appSupport.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    
    private init() {
        loadHistory()
    }
    
    // MARK: - Actions
    
    func addEntry(_ item: ConversionHistoryItem) {
        items.insert(item, at: 0)
        
        if items.count > maxEntries {
            items.removeLast(items.count - maxEntries)
        }
        
        saveHistory()
    }
    
    func clearHistory() {
        items.removeAll()
        saveHistory()
    }
    
    func clearCompleted() {
        items.removeAll { $0.status == .completed }
        saveHistory()
    }
    
    func clearFailed() {
        items.removeAll { $0.status == .failed || $0.status == .cancelled }
        saveHistory()
    }
    
    // MARK: - Persistence
    
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            items = try decoder.decode([ConversionHistoryItem].self, from: data)
            logger.info("Loaded \(self.items.count) history items")
        } catch {
            logger.error("Failed to load history: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}

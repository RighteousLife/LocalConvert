import Foundation
import os.log
import Combine

@MainActor
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    static var isRunningUnderXCTest: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func productionStoreFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.localconvert.app"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private static func defaultStoreFileURL() -> URL {
        AppStoragePaths.historyFileURL
    }

    @Published private(set) var items: [ConversionHistoryItem] = []
    @Published private(set) var lastPersistenceError: String?

    private let maxEntries = 500
    private let logger = Logger(subsystem: "com.localconvert.app", category: "HistoryManager")

    let fileURL: URL

    init(fileURL: URL? = nil) {
        let resolvedURL = (fileURL ?? Self.defaultStoreFileURL()).standardizedFileURL
        let parentDir = resolvedURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        self.fileURL = resolvedURL
        loadHistory()
        applyAutoRemovePolicy()
    }

    func clearPersistenceError() {
        lastPersistenceError = nil
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

    func applyAutoRemovePolicy() {
        guard let days = AppSettings.shared.historyAutoRemove.days else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let originalCount = items.count
        items.removeAll { $0.date < cutoff }
        if items.count != originalCount {
            saveHistory()
        }
    }
    
    // MARK: - Persistence
    
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            items = try decoder.decode([ConversionHistoryItem].self, from: data)
            lastPersistenceError = nil
            logger.info("Loaded \(self.items.count) history items")
        } catch {
            items = []
            logger.error("Failed to load history from \(self.fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            let quarantinedURL = quarantineCorruptHistoryFile()
            let sanitizedError = ErrorDetailsFormatter.sanitize(error.localizedDescription)
            if let quarantinedURL {
                lastPersistenceError = "Failed to load conversion history; corrupt file was quarantined as '\(quarantinedURL.lastPathComponent)'."
                StructuredDiagnostics.record(
                    category: .fileAccess,
                    severity: .internalError,
                    stage: "loadHistory",
                    filename: fileURL.lastPathComponent,
                    message: "Corrupt history quarantined to \(quarantinedURL.lastPathComponent): \(sanitizedError)"
                )
            } else {
                lastPersistenceError = "Failed to load conversion history: \(sanitizedError)"
                StructuredDiagnostics.record(
                    category: .fileAccess,
                    severity: .internalError,
                    stage: "loadHistory",
                    filename: fileURL.lastPathComponent,
                    message: "Failed to load history and quarantine corrupt file: \(sanitizedError)"
                )
            }
        }
    }

    private func quarantineCorruptHistoryFile() -> URL? {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        var candidate = dir.appendingPathComponent("\(stem).corrupted.\(timestamp).\(ext)")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem).corrupted.\(timestamp)-\(suffix).\(ext)")
            suffix += 1
        }

        do {
            try fm.moveItem(at: fileURL, to: candidate)
            return candidate
        } catch {
            do {
                try fm.copyItem(at: fileURL, to: candidate)
                return candidate
            } catch {
                logger.error("Failed to quarantine corrupt history file at \(self.fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }
    }
    
    @discardableResult
    private func saveHistory() -> Bool {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(items)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastPersistenceError = nil
            return true
        } catch {
            let sanitizedError = ErrorDetailsFormatter.sanitize(error.localizedDescription)
            logger.error("Failed to save history to \(self.fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            lastPersistenceError = "Failed to save conversion history: \(sanitizedError)"
            StructuredDiagnostics.record(
                category: .fileAccess,
                severity: .internalError,
                stage: "saveHistory",
                filename: fileURL.lastPathComponent,
                message: "Failed to persist history: \(sanitizedError)"
            )
            return false
        }
    }
}

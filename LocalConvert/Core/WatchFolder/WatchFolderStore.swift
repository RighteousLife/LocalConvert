import Foundation
import os.log

// MARK: - Watch Folder Persisted Snapshot

struct WatchFolderPersistedSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var rules: [WatchFolderRule] = []
    var processedFingerprintsByRule: [UUID: [String: WatchFolderFileFingerprint]] = [:]
    var recentRecords: [WatchFolderFileRecord] = []
}

// MARK: - Security-Scoped Bookmark Helper

enum WatchFolderBookmarkManager: Sendable {
    static func createBookmark(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let scopedURL = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (scopedURL, isStale)
        }
        isStale = false
        if let plainURL = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (plainURL, isStale)
        }
        return nil
    }
}

// MARK: - Watch Folder Store

@MainActor
final class WatchFolderStore: ObservableObject {

    static let maxFingerprintsPerRule = 500
    static let maxRetainedRecords = 200

    private let logger = Logger(subsystem: "com.localconvert.app", category: "WatchFolderStore")
    let fileURL: URL

    @Published private(set) var snapshot = WatchFolderPersistedSnapshot()

    init(fileURL: URL? = nil) {
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            let resolvedURL = AppStoragePaths.watchFoldersFileURL
            try? FileManager.default.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.fileURL = resolvedURL
        }
        load()
    }

    func update(_ mutate: (inout WatchFolderPersistedSnapshot) -> Void) {
        mutate(&snapshot)
        enforceBounds()
        persist()
    }

    /// Transitions stale `.pending`, `.stabilizing`, `.queued`, or `.processing` records loaded from disk after an unclean shutdown
    /// into `.failed` so they are never silently lost or auto-submitted ambiguously.
    @discardableResult
    func reconcileStaleInProgressRecords() -> Int {
        var reconciledCount = 0
        for idx in snapshot.recentRecords.indices {
            let state = snapshot.recentRecords[idx].state
            if state == .pending || state == .stabilizing || state == .queued || state == .processing {
                snapshot.recentRecords[idx].state = .failed
                snapshot.recentRecords[idx].reason = "Interrupted during previous app session before completion. Click Retry to reprocess."
                snapshot.recentRecords[idx].updatedAt = Date()
                reconciledCount += 1
            }
        }
        if reconciledCount > 0 {
            persist()
            logger.info("Reconciled \(reconciledCount, privacy: .public) interrupted Watch Folder record(s) from previous session")
        }
        return reconciledCount
    }

    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            snapshot = WatchFolderPersistedSnapshot()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(WatchFolderPersistedSnapshot.self, from: data)
            enforceBounds()
            logger.info("Loaded \(self.snapshot.rules.count, privacy: .public) Watch Folder rule(s)")
        } catch {
            logger.error("Failed to decode watch_folders.json: \(error.localizedDescription, privacy: .public). Backing up corrupt file.")
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent("watch_folders.corrupted.\(timestamp).json")
            try? fm.copyItem(at: fileURL, to: backupURL)
            snapshot = WatchFolderPersistedSnapshot()
            persist()
        }
    }

    func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist watch_folders.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enforceBounds() {
        if snapshot.recentRecords.count > Self.maxRetainedRecords {
            snapshot.recentRecords = Array(snapshot.recentRecords.prefix(Self.maxRetainedRecords))
        }
        let validRuleIDs = Set(snapshot.rules.map(\.id))
        for key in snapshot.processedFingerprintsByRule.keys where !validRuleIDs.contains(key) {
            snapshot.processedFingerprintsByRule.removeValue(forKey: key)
        }
        for ruleID in validRuleIDs {
            if var map = snapshot.processedFingerprintsByRule[ruleID], map.count > Self.maxFingerprintsPerRule {
                let sortedKeys = map.sorted { $0.value.modificationTimeInterval > $1.value.modificationTimeInterval }
                map = Dictionary(uniqueKeysWithValues: sortedKeys.prefix(Self.maxFingerprintsPerRule).map { ($0.key, $0.value) })
                snapshot.processedFingerprintsByRule[ruleID] = map
            }
        }
    }
}

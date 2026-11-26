import Foundation
import Darwin
import os

// MARK: - Persisted Queue Snapshot Models

struct PersistedQueueEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let inputURLPaths: [String]
    let inputFormat: FileFormat
    let outputFormat: FileFormat
    let outputDirectoryPath: String
    let options: ConversionOptions
    let createdAt: Date
    let batchID: UUID?
    let presetName: String?
    let source: ConversionSource
    let watchFolderRuleID: UUID?
    let watchFolderRuleName: String?

    init(
        id: UUID = UUID(),
        inputURLPaths: [String],
        inputFormat: FileFormat,
        outputFormat: FileFormat,
        outputDirectoryPath: String,
        options: ConversionOptions = .default,
        createdAt: Date = Date(),
        batchID: UUID? = nil,
        presetName: String? = nil,
        source: ConversionSource = .manual,
        watchFolderRuleID: UUID? = nil,
        watchFolderRuleName: String? = nil
    ) {
        self.id = id
        self.inputURLPaths = inputURLPaths
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.outputDirectoryPath = outputDirectoryPath
        self.options = options
        self.createdAt = createdAt
        self.batchID = batchID
        self.presetName = presetName
        self.source = source
        self.watchFolderRuleID = watchFolderRuleID
        self.watchFolderRuleName = watchFolderRuleName
    }

    init?(job: ConversionJob) {
        let standardizedPaths = job.inputURLs
            .map { $0.standardizedFileURL.path }
            .filter { !$0.isEmpty }
        guard !standardizedPaths.isEmpty else { return nil }

        self.init(
            id: job.id,
            inputURLPaths: standardizedPaths,
            inputFormat: job.inputFormat,
            outputFormat: job.outputFormat,
            outputDirectoryPath: job.outputDirectory.standardizedFileURL.path,
            options: job.options,
            createdAt: job.createdAt,
            batchID: job.batchID,
            presetName: job.presetName,
            source: job.source,
            watchFolderRuleID: job.watchFolderRuleID,
            watchFolderRuleName: job.watchFolderRuleName
        )
    }

    var inputURLs: [URL] {
        inputURLPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    var outputDirectoryURL: URL {
        URL(fileURLWithPath: outputDirectoryPath, isDirectory: true).standardizedFileURL
    }

    var canonicalSignature: String {
        let normalizedInputs = inputURLPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            .joined(separator: "\u{1F}")
        let normalizedOutDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let optionsKey: String
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(options),
           let json = String(data: data, encoding: .utf8) {
            optionsKey = json
        } else {
            optionsKey = String(describing: options)
        }

        return [
            normalizedInputs,
            inputFormat.rawValue,
            outputFormat.rawValue,
            normalizedOutDir,
            optionsKey
        ].joined(separator: "|")
    }

    func makeConversionJob(validatedInputURLs: [URL]? = nil) -> ConversionJob {
        ConversionJob(
            id: id,
            inputURLs: validatedInputURLs ?? inputURLs,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            outputDirectory: outputDirectoryURL,
            options: options,
            createdAt: createdAt,
            batchID: batchID,
            presetName: presetName,
            source: source,
            watchFolderRuleID: watchFolderRuleID,
            watchFolderRuleName: watchFolderRuleName
        )
    }
}

struct PersistedQueueSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var entries: [PersistedQueueEntry]

    init(
        schemaVersion: Int = PersistedQueueSnapshot.currentSchemaVersion,
        updatedAt: Date = Date(),
        entries: [PersistedQueueEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

// MARK: - Persistent Queue Store

/// Atomically persists unfinished conversion queue entries so interrupted batches can be recovered on relaunch.
final class PersistentQueueStore: Sendable {

    struct LoadResult: Sendable {
        let recoveredJobs: [ConversionJob]
        let droppedMissingOrInvalidCount: Int
        let droppedDuplicateCount: Int
        let wasCorrupted: Bool
    }

    static let defaultFilename = "pending_queue.json"

    static var defaultFileURL: URL {
        AppStoragePaths.applicationSupportDirectory
            .appendingPathComponent(defaultFilename, isDirectory: false)
    }

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "PersistentQueueStore")
    private let lock = OSAllocatedUnfairLock()
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = (fileURL ?? Self.defaultFileURL).standardizedFileURL
    }

    init(directoryURL: URL, filename: String = PersistentQueueStore.defaultFilename) {
        self.fileURL = directoryURL
            .appendingPathComponent(filename, isDirectory: false)
            .standardizedFileURL
    }

    // MARK: - Save & Clear

    @discardableResult
    func save(jobs: [ConversionJob]) -> Bool {
        let entries = jobs.compactMap(PersistedQueueEntry.init(job:))
        return save(entries: entries)
    }

    @discardableResult
    func save(entries: [PersistedQueueEntry]) -> Bool {
        lock.withLock {
            if entries.isEmpty {
                return clearLocked()
            }

            let fm = FileManager.default
            let parentDir = fileURL.deletingLastPathComponent()
            let tempURL = parentDir.appendingPathComponent(
                ".\(fileURL.lastPathComponent).tmp.\(UUID().uuidString)",
                isDirectory: false
            )

            defer {
                if fm.fileExists(atPath: tempURL.path) {
                    try? fm.removeItem(at: tempURL)
                }
            }

            do {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                let snapshot = PersistedQueueSnapshot(
                    schemaVersion: PersistedQueueSnapshot.currentSchemaVersion,
                    updatedAt: Date(),
                    entries: entries
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: tempURL, options: .atomic)

                if fm.fileExists(atPath: fileURL.path) {
                    _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
                } else {
                    try fm.moveItem(at: tempURL, to: fileURL)
                }
                return true
            } catch {
                Self.logger.error("Failed to save pending queue snapshot: \(error.localizedDescription, privacy: .private)")
                return false
            }
        }
    }

    @discardableResult
    func clear() -> Bool {
        lock.withLock {
            clearLocked()
        }
    }

    // MARK: - Load & Validate

    func load() -> LoadResult {
        lock.withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: fileURL.path) else {
                return LoadResult(
                    recoveredJobs: [],
                    droppedMissingOrInvalidCount: 0,
                    droppedDuplicateCount: 0,
                    wasCorrupted: false
                )
            }

            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                Self.logger.warning("Failed to read pending queue snapshot; quarantining: \(error.localizedDescription, privacy: .private)")
                quarantineCorruptFileLocked()
                return LoadResult(
                    recoveredJobs: [],
                    droppedMissingOrInvalidCount: 0,
                    droppedDuplicateCount: 0,
                    wasCorrupted: true
                )
            }

            guard !data.isEmpty else {
                Self.logger.warning("Pending queue snapshot is empty; quarantining")
                quarantineCorruptFileLocked()
                return LoadResult(
                    recoveredJobs: [],
                    droppedMissingOrInvalidCount: 0,
                    droppedDuplicateCount: 0,
                    wasCorrupted: true
                )
            }

            let snapshot: PersistedQueueSnapshot
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                snapshot = try decoder.decode(PersistedQueueSnapshot.self, from: data)
            } catch {
                Self.logger.warning("Failed to decode pending queue snapshot; quarantining: \(error.localizedDescription, privacy: .private)")
                quarantineCorruptFileLocked()
                return LoadResult(
                    recoveredJobs: [],
                    droppedMissingOrInvalidCount: 0,
                    droppedDuplicateCount: 0,
                    wasCorrupted: true
                )
            }

            guard snapshot.schemaVersion > 0,
                  snapshot.schemaVersion <= PersistedQueueSnapshot.currentSchemaVersion else {
                Self.logger.warning("Unsupported pending queue schema version \(snapshot.schemaVersion, privacy: .public); quarantining")
                quarantineCorruptFileLocked()
                return LoadResult(
                    recoveredJobs: [],
                    droppedMissingOrInvalidCount: 0,
                    droppedDuplicateCount: 0,
                    wasCorrupted: true
                )
            }

            var seenIDs = Set<UUID>()
            var seenSignatures = Set<String>()
            var recoveredJobs: [ConversionJob] = []
            var droppedMissingOrInvalidCount = 0
            var droppedDuplicateCount = 0

            for entry in snapshot.entries {
                guard seenIDs.insert(entry.id).inserted else {
                    droppedDuplicateCount += 1
                    continue
                }

                guard !entry.inputURLPaths.isEmpty else {
                    droppedMissingOrInvalidCount += 1
                    continue
                }

                var validatedURLs: [URL] = []
                validatedURLs.reserveCapacity(entry.inputURLPaths.count)
                var allInputsValid = true

                for rawPath in entry.inputURLPaths {
                    guard !rawPath.isEmpty else {
                        allInputsValid = false
                        break
                    }
                    let candidateURL = URL(fileURLWithPath: rawPath).standardizedFileURL
                    guard Self.isValidRecoverableSourceFile(candidateURL) else {
                        allInputsValid = false
                        break
                    }
                    validatedURLs.append(candidateURL)
                }

                guard allInputsValid, !validatedURLs.isEmpty else {
                    droppedMissingOrInvalidCount += 1
                    continue
                }

                guard seenSignatures.insert(entry.canonicalSignature).inserted else {
                    droppedDuplicateCount += 1
                    continue
                }

                recoveredJobs.append(entry.makeConversionJob(validatedInputURLs: validatedURLs))
            }

            return LoadResult(
                recoveredJobs: recoveredJobs,
                droppedMissingOrInvalidCount: droppedMissingOrInvalidCount,
                droppedDuplicateCount: droppedDuplicateCount,
                wasCorrupted: false
            )
        }
    }

    static func isValidRecoverableSourceFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }

        switch FinderHandoffHandler.validateInputFileURL(url) {
        case .success:
            return true
        case .failure(.folderRejected(let path)):
            let folderURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var dirStat = Darwin.stat()
            let isRealDirectory = Darwin.lstat(folderURL.path, &dirStat) == 0 && (dirStat.st_mode & S_IFMT) == S_IFDIR
            guard isRealDirectory,
                  hasNoSymlinkAncestors(for: folderURL.path),
                  FileDetector.isIWorkPackageBundle(url: folderURL),
                  FileManager.default.isReadableFile(atPath: folderURL.path),
                  Darwin.access(folderURL.path, R_OK) == 0 else {
                return false
            }
            return true
        case .failure:
            return false
        }
    }

    // MARK: - Private Helpers

    private func clearLocked() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return true }
        do {
            try fm.removeItem(at: fileURL)
            return true
        } catch {
            Self.logger.warning("Failed to clear pending queue snapshot: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func quarantineCorruptFileLocked() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }

        let parentDir = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        var candidate = parentDir.appendingPathComponent(
            "\(baseName).corrupted.\(timestamp)\(suffix)",
            isDirectory: false
        )
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = parentDir.appendingPathComponent(
                "\(baseName).corrupted.\(timestamp)-\(counter)\(suffix)",
                isDirectory: false
            )
            counter += 1
        }

        do {
            try fm.moveItem(at: fileURL, to: candidate)
        } catch {
            Self.logger.warning("Failed to quarantine corrupt queue snapshot; removing: \(error.localizedDescription, privacy: .private)")
            try? fm.removeItem(at: fileURL)
        }
    }

    private static func hasNoSymlinkAncestors(for standardizedPath: String) -> Bool {
        let components = standardizedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return true }

        var currentPrefix = ""
        for index in 0..<(components.count - 1) {
            currentPrefix += "/" + components[index]
            var compStat = Darwin.stat()
            guard Darwin.lstat(currentPrefix, &compStat) == 0 else {
                return false
            }
            if (compStat.st_mode & S_IFMT) == S_IFLNK {
                if index == 0, isGenuineMacOSRootSymlink(path: currentPrefix, statInfo: compStat) {
                    continue
                }
                return false
            }
        }
        return true
    }

    private static func isGenuineMacOSRootSymlink(path: String, statInfo: Darwin.stat) -> Bool {
        guard statInfo.st_uid == 0 else { return false }
        let expectedTarget: String
        switch path {
        case "/var":
            expectedTarget = "private/var"
        case "/tmp":
            expectedTarget = "private/tmp"
        case "/etc":
            expectedTarget = "private/etc"
        default:
            return false
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = Darwin.readlink(path, &buffer, buffer.count - 1)
        guard length > 0 else { return false }
        buffer[length] = 0
        let target = buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) }
        }
        return target == expectedTarget
    }
}

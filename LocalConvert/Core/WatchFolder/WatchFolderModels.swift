import Foundation

// MARK: - Watch Folder Output Destination

enum WatchFolderOutputDestination: Codable, Sendable, Equatable, Hashable {
    case subfolder(name: String)
    case customDirectory(path: String, bookmarkData: Data?)
    case presetDefault

    static let defaultSubfolder = WatchFolderOutputDestination.subfolder(name: "Converted")

    var displayName: String {
        switch self {
        case .subfolder(let name):
            return "Subfolder '\(name)'"
        case .customDirectory(let path, _):
            return URL(fileURLWithPath: path).lastPathComponent
        case .presetDefault:
            return "Preset / App Default"
        }
    }

    func resolvedDirectory(
        for inputDirectory: URL,
        preset: SavedPreset?,
        defaultOutputLocation: OutputLocation,
        customAppOutputDirectory: URL?
    ) -> URL {
        switch self {
        case .subfolder(let rawName):
            let sanitized = Self.sanitizeSubfolderName(rawName)
            return inputDirectory.appendingPathComponent(sanitized, isDirectory: true).standardizedFileURL

        case .customDirectory(let rawPath, _):
            return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL

        case .presetDefault:
            if let preset {
                switch preset.outputDestinationPolicy {
                case .customDirectory(let path):
                    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                case .sameAsInput:
                    return inputDirectory.standardizedFileURL
                case .defaultLocation:
                    break
                }
            }
            let sampleFile = inputDirectory.appendingPathComponent("sample.tmp")
            return OutputManager.resolveOutputDirectory(
                for: sampleFile,
                preference: defaultOutputLocation,
                customDirectory: customAppOutputDirectory
            ).standardizedFileURL
        }
    }

    static func sanitizeSubfolderName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "")
        return trimmed.isEmpty ? "Converted" : trimmed
    }
}

// MARK: - Watch Folder Monitoring Status

enum WatchFolderMonitoringStatus: Codable, Sendable, Equatable, Hashable {
    case disabled
    case active
    case paused
    case error(String)

    var displayLabel: String {
        switch self {
        case .disabled: return "Disabled"
        case .active: return "Monitoring Active"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }

    var shortBadgeText: String {
        switch self {
        case .disabled: return "Disabled"
        case .active: return "Active"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

// MARK: - File State Machine

enum WatchFolderFileState: String, Codable, Sendable, CaseIterable, Hashable {
    case pending = "Pending"
    case stabilizing = "Waiting for Stability"
    case queued = "Queued"
    case processing = "Processing"
    case completed = "Completed"
    case failed = "Failed"
    case ignored = "Ignored"

    func canTransition(to next: WatchFolderFileState) -> Bool {
        if self == next { return true }
        switch self {
        case .pending:
            return [.stabilizing, .ignored, .failed].contains(next)
        case .stabilizing:
            return [.queued, .ignored, .failed].contains(next)
        case .queued:
            return [.processing, .completed, .failed, .ignored].contains(next)
        case .processing:
            return [.completed, .failed].contains(next)
        case .completed:
            return [.pending, .ignored].contains(next)
        case .failed:
            return [.pending, .stabilizing, .ignored].contains(next)
        case .ignored:
            return [.pending].contains(next)
        }
    }
}

// MARK: - Stable File Fingerprint & Activity Record

struct WatchFolderFileFingerprint: Codable, Sendable, Equatable, Hashable {
    let standardizedPath: String
    let resourceIdentifierBase64: String?
    let fileSize: Int64
    let modificationTimeInterval: TimeInterval

    static func capture(for url: URL) -> WatchFolderFileFingerprint? {
        let std = url.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ]
        guard let values = try? std.resourceValues(forKeys: keys),
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            return nil
        }

        let size = Int64(values.fileSize ?? 0)
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0

        let resourceIDBase64: String?
        if let nsObj = values.fileResourceIdentifier {
            resourceIDBase64 = (try? NSKeyedArchiver.archivedData(withRootObject: nsObj, requiringSecureCoding: false))?.base64EncodedString()
        } else {
            resourceIDBase64 = nil
        }

        return WatchFolderFileFingerprint(
            standardizedPath: std.path,
            resourceIdentifierBase64: resourceIDBase64,
            fileSize: size,
            modificationTimeInterval: mtime
        )
    }

    func matchesContent(of other: WatchFolderFileFingerprint) -> Bool {
        guard fileSize == other.fileSize,
              abs(modificationTimeInterval - other.modificationTimeInterval) < 0.001 else {
            return false
        }
        if let a = resourceIdentifierBase64, let b = other.resourceIdentifierBase64 {
            return a == b
        }
        return true
    }
}

struct WatchFolderFileRecord: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let ruleID: UUID
    var filePath: String
    var fileName: String
    var state: WatchFolderFileState
    var fingerprint: WatchFolderFileFingerprint?
    var jobID: UUID?
    var outputPaths: [String]
    var reason: String?
    var updatedAt: Date
    var retryCount: Int

    init(
        id: UUID = UUID(),
        ruleID: UUID,
        filePath: String,
        fileName: String,
        state: WatchFolderFileState = .pending,
        fingerprint: WatchFolderFileFingerprint? = nil,
        jobID: UUID? = nil,
        outputPaths: [String] = [],
        reason: String? = nil,
        updatedAt: Date = Date(),
        retryCount: Int = 0
    ) {
        self.id = id
        self.ruleID = ruleID
        self.filePath = filePath
        self.fileName = fileName
        self.state = state
        self.fingerprint = fingerprint
        self.jobID = jobID
        self.outputPaths = outputPaths
        self.reason = reason
        self.updatedAt = updatedAt
        self.retryCount = retryCount
    }

    var canRetry: Bool {
        state == .failed || state == .ignored
    }
}

// MARK: - Watch Folder Configuration Rule

struct WatchFolderRule: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    var inputDirectoryPath: String
    var inputBookmarkData: Data?
    var presetID: UUID
    var isEnabled: Bool
    var isPaused: Bool
    var includeSubdirectories: Bool
    var outputDestination: WatchFolderOutputDestination
    var collisionPolicy: ExistingFileHandling
    var settleDelaySeconds: TimeInterval
    var maxStabilityWaitSeconds: TimeInterval
    var createdAt: Date
    var modifiedAt: Date
    var lastExecutionAt: Date?
    var lastStatus: WatchFolderMonitoringStatus
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        name: String,
        inputDirectoryPath: String,
        inputBookmarkData: Data? = nil,
        presetID: UUID,
        isEnabled: Bool = true,
        isPaused: Bool = false,
        includeSubdirectories: Bool = false,
        outputDestination: WatchFolderOutputDestination = .defaultSubfolder,
        collisionPolicy: ExistingFileHandling = .createUnique,
        settleDelaySeconds: TimeInterval = 1.5,
        maxStabilityWaitSeconds: TimeInterval = 30.0,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        lastExecutionAt: Date? = nil,
        lastStatus: WatchFolderMonitoringStatus = .disabled,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.inputDirectoryPath = inputDirectoryPath
        self.inputBookmarkData = inputBookmarkData
        self.presetID = presetID
        self.isEnabled = isEnabled
        self.isPaused = isPaused
        self.includeSubdirectories = includeSubdirectories
        self.outputDestination = outputDestination
        self.collisionPolicy = collisionPolicy
        self.settleDelaySeconds = min(max(settleDelaySeconds, 0.05), 30.0)
        self.maxStabilityWaitSeconds = min(max(maxStabilityWaitSeconds, 0.2), 300.0)
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastExecutionAt = lastExecutionAt
        self.lastStatus = lastStatus
        self.lastErrorMessage = lastErrorMessage
    }

    var inputDirectoryURL: URL {
        URL(fileURLWithPath: inputDirectoryPath, isDirectory: true).standardizedFileURL
    }
}

// MARK: - Path Safety & Loop Exclusion Helpers

enum WatchFolderPathSafety: Sendable {
    static let excludedTempExtensions: Set<String> = [
        "tmp", "temp", "part", "crdownload", "download", "partial",
        "filepart", "opdownload", "swp", "swo", "lock", "lck"
    ]

    static func canonicalPath(for url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.count > 1 && resolved.hasSuffix("/") {
            return String(resolved.dropLast())
        }
        return resolved
    }

    static func isPath(_ child: String, equalToOrInside parent: String) -> Bool {
        if child == parent { return true }
        let prefix = parent == "/" ? "/" : parent + "/"
        return child.hasPrefix(prefix)
    }

    static func isTemporaryOrHiddenFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.isEmpty || name.hasPrefix(".") || name.hasPrefix("~$") || name.hasPrefix(".~") {
            return true
        }
        if name.hasPrefix("LocalConvert-") || name.hasPrefix("LocalConvertAudio_") || name.hasPrefix(".localconvert_") {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if excludedTempExtensions.contains(ext) {
            return true
        }
        let ignoredComponents: Set<String> = [".TemporaryItems", "TemporaryItems", ".Trashes", ".fseventsd", "__MACOSX"]
        if url.pathComponents.contains(where: { ignoredComponents.contains($0) }) {
            return true
        }
        return false
    }

    /// Resolves a bookmark or direct URL and returns canonical directory path if accessible.
    static func isExistingReadableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return false
        }
        return true
    }
}

// MARK: - Watch Folder Validation

struct WatchFolderValidationResult: Sendable, Equatable {
    let isValid: Bool
    let errorMessage: String?
    let warningMessage: String?
}

enum WatchFolderValidator: Sendable {
    static func validate(
        rule: WatchFolderRule,
        existingRules: [WatchFolderRule],
        availablePresets: [SavedPreset],
        defaultOutputLocation: OutputLocation = .sameFolder,
        customAppOutputDirectory: URL? = nil
    ) -> WatchFolderValidationResult {
        let trimmedName = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return WatchFolderValidationResult(
                isValid: false,
                errorMessage: "Enter a name for this Watch Folder.",
                warningMessage: nil
            )
        }

        let inputURL = rule.inputDirectoryURL
        var isDir: ObjCBool = false
        guard !rule.inputDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir),
              isDir.boolValue else {
            return WatchFolderValidationResult(
                isValid: false,
                errorMessage: "Watched folder does not exist or its volume is unavailable.",
                warningMessage: nil
            )
        }

        guard FileManager.default.isReadableFile(atPath: inputURL.path) else {
            return WatchFolderValidationResult(
                isValid: false,
                errorMessage: "LocalConvert does not have read permission for the selected watched folder.",
                warningMessage: nil
            )
        }

        guard let preset = availablePresets.first(where: { $0.id == rule.presetID }) else {
            return WatchFolderValidationResult(
                isValid: false,
                errorMessage: "Selected preset no longer exists. Choose a valid saved preset.",
                warningMessage: nil
            )
        }

        let inCanonical = WatchFolderPathSafety.canonicalPath(for: inputURL)

        // Check duplicate or overlapping Watch Folder rules
        for other in existingRules where other.id != rule.id {
            let otherCanonical = WatchFolderPathSafety.canonicalPath(for: other.inputDirectoryURL)
            if otherCanonical == inCanonical {
                return WatchFolderValidationResult(
                    isValid: false,
                    errorMessage: "A Watch Folder rule for '\(inputURL.lastPathComponent)' already exists ('\(other.name)').",
                    warningMessage: nil
                )
            }
            if rule.isEnabled && other.isEnabled {
                if other.includeSubdirectories && WatchFolderPathSafety.isPath(inCanonical, equalToOrInside: otherCanonical) {
                    return WatchFolderValidationResult(
                        isValid: false,
                        errorMessage: "Folder overlaps with recursive Watch Folder '\(other.name)'.",
                        warningMessage: nil
                    )
                }
                if rule.includeSubdirectories && WatchFolderPathSafety.isPath(otherCanonical, equalToOrInside: inCanonical) {
                    return WatchFolderValidationResult(
                        isValid: false,
                        errorMessage: "Recursive watch would overlap with existing Watch Folder '\(other.name)'.",
                        warningMessage: nil
                    )
                }
            }
        }

        // Loop prevention checks against resolved output directory
        let resolvedOutputDir = rule.outputDestination.resolvedDirectory(
            for: inputURL,
            preset: preset,
            defaultOutputLocation: defaultOutputLocation,
            customAppOutputDirectory: customAppOutputDirectory
        )
        let outCanonical = WatchFolderPathSafety.canonicalPath(for: resolvedOutputDir)

        if outCanonical == inCanonical {
            return WatchFolderValidationResult(
                isValid: false,
                errorMessage: "Output folder cannot be the same as the watched input folder. Choose a dedicated subfolder (e.g. 'Converted') or another folder to prevent infinite conversion loops.",
                warningMessage: nil
            )
        }

        if WatchFolderPathSafety.isPath(inCanonical, equalToOrInside: outCanonical) {
            return WatchFolderValidationResult(
                isValid: false,
                errorMessage: "Watched folder cannot be nested inside its own output folder.",
                warningMessage: nil
            )
        }

        var warning: String? = nil
        if case .customDirectory(let customPath, _) = rule.outputDestination {
            var outIsDir: ObjCBool = false
            let customURL = URL(fileURLWithPath: customPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: customURL.path, isDirectory: &outIsDir) && !outIsDir.boolValue {
                return WatchFolderValidationResult(
                    isValid: false,
                    errorMessage: "Selected output path points to a file instead of a folder.",
                    warningMessage: nil
                )
            }
        }

        if WatchFolderPathSafety.isPath(outCanonical, equalToOrInside: inCanonical) {
            warning = "Converted files in '\(resolvedOutputDir.lastPathComponent)' are automatically excluded from watching to prevent loops."
        }

        return WatchFolderValidationResult(
            isValid: true,
            errorMessage: nil,
            warningMessage: warning
        )
    }
}

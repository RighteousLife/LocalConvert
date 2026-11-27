import Foundation
import os.log

// MARK: - Diagnostic Bundle Exporter

enum DiagnosticBundleExportError: Error, LocalizedError, Equatable, Sendable {
    case archiveToolUnavailable
    case archiveCreationFailed(String)
    case emptyArchiveProduced

    var errorDescription: String? {
        switch self {
        case .archiveToolUnavailable:
            return String(localized: "macOS archive utility (/usr/bin/bsdtar) is unavailable.")
        case .archiveCreationFailed(let detail):
            return String(localized: "Failed to package diagnostic bundle: \(detail)")
        case .emptyArchiveProduced:
            return String(localized: "Diagnostic bundle archive was empty.")
        }
    }
}

struct DiagnosticBundleExportResult: Equatable, Sendable {
    let outputURL: URL
    let includedFiles: [String]
    let fileSizeBytes: Int64
    let createdAt: Date
}

/// Exports a redacted `.zip` diagnostic bundle containing sanitized system/app info,
/// structured diagnostic events, and local logs with `/Users/<username>` masked to `/Users/<redacted>`.
struct DiagnosticBundleExporter: Sendable {

    private static let bsdtarPath = "/usr/bin/bsdtar"
    private static let maxLogReadBytes = 2 * 1024 * 1024
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "DiagnosticBundleExporter")

    let logsDirectoryOverride: URL?
    let stagingParentDirectory: URL
    let currentUsernameOverride: String?

    init(
        logsDirectoryOverride: URL? = nil,
        stagingParentDirectory: URL = FileManager.default.temporaryDirectory,
        currentUsernameOverride: String? = nil
    ) {
        self.logsDirectoryOverride = logsDirectoryOverride
        self.stagingParentDirectory = stagingParentDirectory
        self.currentUsernameOverride = currentUsernameOverride
    }

    static func defaultExportFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "LocalConvert-Diagnostics-\(formatter.string(from: date)).zip"
    }

    /// Redacts `/Users/<username>` paths to `/Users/<redacted>`, along with secrets, tokens, and GPS coordinates.
    static func redact(_ text: String, username: String? = nil) -> String {
        var result = text

        // 1. Replace any /Users/<name> segment (preserving trailing path components) with /Users/<redacted>
        let pathPatterns: [(String, String)] = [
            ("/Users/[^/\\s:'\"\\),;]+", "/Users/<redacted>"),
            ("Bearer\\s+[A-Za-z0-9\\-._~+/]+=*", "Bearer [REDACTED]"),
            ("password=[^\\s&]+", "password=[REDACTED]"),
            ("pwd=[^\\s&]+", "pwd=[REDACTED]"),
            ("secret=[^\\s&]+", "secret=[REDACTED]"),
            ("token=[^\\s&]+", "token=[REDACTED]"),
            ("key=[^\\s&]+", "key=[REDACTED]"),
            ("(?:latitude|longitude|lat|lon)\\s*[:=]\\s*[-+]?\\d+(?:\\.\\d+)?", "[GPS_REDACTED]"),
            ("\\b\\d{1,3}\\.\\d{3,}°\\s*[NSEW]\\b", "[GPS_REDACTED]")
        ]

        for (pattern, template) in pathPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(location: 0, length: result.utf16.count),
                    withTemplate: template
                )
            }
        }

        // 2. Also explicitly mask the active macOS short username if embedded in `/Users/<name>`
        let activeUsername = (username ?? NSUserName()).trimmingCharacters(in: .whitespacesAndNewlines)
        if !activeUsername.isEmpty, activeUsername.count >= 2 {
            result = result.replacingOccurrences(
                of: "/Users/\(activeUsername)",
                with: "/Users/<redacted>",
                options: .caseInsensitive
            )
        }

        return result
    }

    @discardableResult
    func exportBundle(
        to destinationURL: URL,
        policy: ExistingFileHandling = .createUnique,
        additionalLogContents: String? = nil
    ) throws -> DiagnosticBundleExportResult {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.bsdtarPath) else {
            throw DiagnosticBundleExportError.archiveToolUnavailable
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try OutputReservationCoordinator.validateWritableDirectory(parentDir)

        let now = Date()
        let stagingRoot = stagingParentDirectory.appendingPathComponent(
            "LocalConvert-DiagStage-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundleFolderName = "LocalConvert-Diagnostics"
        let payloadDir = stagingRoot.appendingPathComponent(bundleFolderName, isDirectory: true)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingRoot)
        }

        var includedFiles: [String] = []

        // 1. Sanitized System & App Summary
        let summaryURL = payloadDir.appendingPathComponent("system-summary.txt")
        let summaryText = Self.redact(buildSystemSummary(date: now), username: currentUsernameOverride)
        try summaryText.write(to: summaryURL, atomically: true, encoding: .utf8)
        includedFiles.append("system-summary.txt")

        // 2. Sanitized Settings Snapshot
        let settingsURL = payloadDir.appendingPathComponent("settings-summary.txt")
        let settingsText = Self.redact(buildSettingsSummary(), username: currentUsernameOverride)
        try settingsText.write(to: settingsURL, atomically: true, encoding: .utf8)
        includedFiles.append("settings-summary.txt")

        // 3. Structured Diagnostic Events
        let structuredSummary = StructuredDiagnostics.exportSanitizedSummary(limit: 200)
        let eventsText = structuredSummary.isEmpty
            ? "No in-memory structured diagnostic events recorded in this session.\n"
            : Self.redact(structuredSummary, username: currentUsernameOverride) + "\n"
        let eventsURL = payloadDir.appendingPathComponent("structured-events.log")
        try eventsText.write(to: eventsURL, atomically: true, encoding: .utf8)
        includedFiles.append("structured-events.log")

        // 4. Local Diagnostic Log Files (redacted)
        let logsDir = logsDirectoryOverride ?? AppStoragePaths.logsDirectory
        if let entries = try? fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            let logFiles = entries
                .filter { ["log", "txt"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for logFile in logFiles {
                let isRegular = (try? logFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }
                if let rawContent = readBoundedUTF8(from: logFile, maxBytes: Self.maxLogReadBytes) {
                    let safeName = "logs-\(logFile.lastPathComponent)"
                    let redacted = Self.redact(rawContent, username: currentUsernameOverride)
                    try redacted.write(to: payloadDir.appendingPathComponent(safeName), atomically: true, encoding: .utf8)
                    includedFiles.append(safeName)
                }
            }
        }

        if let additionalLogContents, !additionalLogContents.isEmpty {
            let safeExtra = Self.redact(additionalLogContents, username: currentUsernameOverride)
            try safeExtra.write(to: payloadDir.appendingPathComponent("additional-notes.log"), atomically: true, encoding: .utf8)
            includedFiles.append("additional-notes.log")
        }

        // 5. Build .zip in hidden sibling temp file and atomically publish via OutputReservationCoordinator
        let tempZipURL = parentDir.appendingPathComponent(".LocalConvert-diag-\(UUID().uuidString).zip")
        defer {
            try? fm.removeItem(at: tempZipURL)
        }

        try createZipArchive(fromFolderNamed: bundleFolderName, inDirectory: stagingRoot, outputZipURL: tempZipURL)

        let finalURL: URL
        if policy == .createUnique {
            let baseName = FileFormat.baseNameByStrippingExtension(from: destinationURL)
            let reserved = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: parentDir,
                baseName: baseName.isEmpty ? "LocalConvert-Diagnostics" : baseName,
                extension: "zip",
                policy: .createUnique
            )
            defer { OutputReservationCoordinator.releaseReservedOutputURL(reserved) }
            finalURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempZipURL,
                to: reserved,
                policy: .createUnique
            )
        } else {
            finalURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempZipURL,
                to: destinationURL,
                policy: policy
            )
        }

        let sizeBytes = (try? fm.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard sizeBytes > 0 else {
            throw DiagnosticBundleExportError.emptyArchiveProduced
        }

        Self.logger.info("Exported redacted diagnostic bundle (\(includedFiles.count) files, \(sizeBytes) bytes)")
        return DiagnosticBundleExportResult(
            outputURL: finalURL,
            includedFiles: includedFiles,
            fileSizeBytes: sizeBytes,
            createdAt: now
        )
    }

    private func readBoundedUTF8(from url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > Int64(maxBytes) {
            let offset = UInt64(fileSize - Int64(maxBytes))
            try? handle.seek(toOffset: offset)
        }
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        if fileSize > Int64(maxBytes) {
            return "[Truncated to last \(maxBytes) bytes]\n" + text
        }
        return text
    }

    private func buildSystemSummary(date: Date) -> String {
        let info = Bundle.main.infoDictionary
        let appName = (info?["CFBundleName"] as? String) ?? "LocalConvert"
        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? "com.localconvert.app"
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "2.0.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "2"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let logsPath = (logsDirectoryOverride ?? AppStoragePaths.logsDirectory).path
        let supportPath = AppStoragePaths.applicationSupportDirectory.path

        let formatter = ISO8601DateFormatter()
        return """
        LocalConvert Redacted Diagnostic Bundle
        GeneratedAt: \(formatter.string(from: date))
        App: \(appName) (\(bundleID))
        Version: \(version) (Build \(build))
        Architecture: arm64
        macOS: \(osVersion)
        VerboseLoggingEnabled: \(DiagnosticLogManager.isVerboseLoggingEnabled())
        LogsDirectory: \(logsPath)
        ApplicationSupportDirectory: \(supportPath)
        """
    }

    private func buildSettingsSummary() -> String {
        let defaults = AppStoragePaths.userDefaults
        let appearance = defaults.string(forKey: "settings.appearanceMode") ?? "System"
        let outputLoc = defaults.string(forKey: "settings.defaultOutputLocation") ?? "Same Folder"
        let customDir = defaults.string(forKey: "settings.customOutputDirectoryPath") ?? ""
        let collision = defaults.string(forKey: "settings.existingFileHandling") ?? "Create Unique"
        let concurrency = defaults.string(forKey: "settings.concurrentConversions") ?? "Automatic"
        let verbose = defaults.bool(forKey: "settings.verboseLogging")
        return """
        AppearanceMode: \(appearance)
        DefaultOutputLocation: \(outputLoc)
        CustomOutputDirectory: \(customDir.isEmpty ? "(none)" : customDir)
        ExistingFileHandling: \(collision)
        ConcurrentConversions: \(concurrency)
        VerboseLogging: \(verbose)
        """
    }

    private func createZipArchive(fromFolderNamed folderName: String, inDirectory baseDir: URL, outputZipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.bsdtarPath)
        process.arguments = ["--format=zip", "-cf", outputZipURL.path, "-C", baseDir.path, "--", folderName]
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw DiagnosticBundleExportError.archiveCreationFailed(error.localizedDescription)
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        final class LockedDataBox: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            private let maxBytes: Int

            init(maxBytes: Int) {
                self.maxBytes = maxBytes
            }

            func appendCapped(_ chunk: Data) {
                lock.lock()
                if data.count < maxBytes {
                    let remaining = maxBytes - data.count
                    data.append(chunk.prefix(remaining))
                }
                lock.unlock()
            }

            func snapshot() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }

        let maxCaptureBytes = 256 * 1024
        let stderrBox = LockedDataBox(maxBytes: maxCaptureBytes)
        let stdoutReadHandle = stdoutPipe.fileHandleForReading
        let stderrReadHandle = stderrPipe.fileHandleForReading
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()

        group.enter()
        queue.async {
            defer { group.leave() }
            while let chunk = try? stdoutReadHandle.read(upToCount: 65_536), !chunk.isEmpty {
                // Drain stdout completely to prevent pipe deadlock
            }
        }

        group.enter()
        queue.async {
            defer { group.leave() }
            while let chunk = try? stderrReadHandle.read(upToCount: 65_536), !chunk.isEmpty {
                stderrBox.appendCapped(chunk)
            }
        }

        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrBox.snapshot()
            let trimmed = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errText = trimmed.isEmpty ? "exit \(process.terminationStatus)" : trimmed
            throw DiagnosticBundleExportError.archiveCreationFailed(errText)
        }
    }
}

// MARK: - Opt-In Update Check Service

protocol UpdateCheckTransport: Sendable {
    func fetchLatestReleaseData(from url: URL) async throws -> (Data, URLResponse)
}

struct URLSessionUpdateCheckTransport: UpdateCheckTransport, Sendable {
    init() {}

    func fetchLatestReleaseData(from url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LocalConvert", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request)
    }
}

enum UpdateCheckError: Error, LocalizedError, Equatable, Sendable {
    case httpStatusError(Int)
    case invalidReleasePayload(String)
    case insecureReleaseURL(String)

    var errorDescription: String? {
        switch self {
        case .httpStatusError(let status):
            return String(localized: "Update server returned HTTP status \(status).")
        case .invalidReleasePayload(let detail):
            return String(localized: "Could not parse release information: \(detail)")
        case .insecureReleaseURL(let urlString):
            return String(localized: "Rejected non-HTTPS release URL: \(urlString)")
        }
    }
}

struct GitHubReleasePayload: Codable, Equatable, Sendable {
    let tagName: String
    let name: String?
    let htmlURL: String
    let publishedAt: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case body
    }
}

struct UpdateCheckResult: Equatable, Sendable {
    let currentVersion: String
    let latestVersion: String
    let isUpdateAvailable: Bool
    let releaseURL: URL?
    let releaseNotesSummary: String?
    let checkedAt: Date
}

struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init?(parsing raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        // Strip build metadata (+...)
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }

        let prereleaseSplit = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let corePart = String(prereleaseSplit[0])
        let prePart = prereleaseSplit.count > 1 && !prereleaseSplit[1].isEmpty ? String(prereleaseSplit[1]) : nil

        let components = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var nums: [Int] = []
        for comp in components {
            guard let val = Int(comp), val >= 0 else { return nil }
            nums.append(val)
        }

        self.major = nums[0]
        self.minor = nums.count > 1 ? nums[1] : 0
        self.patch = nums.count > 2 ? nums[2] : 0
        self.prerelease = prePart
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A normal version has higher precedence than a pre-release version (1.0.0 > 1.0.0-beta.1)
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (let lPre?, let rPre?):
            return lPre.compare(rPre, options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    var normalizedString: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }
}

/// Opt-in update checker that NEVER performs automatic background network calls.
/// Queries GitHub releases only when `checkForUpdates()` is explicitly invoked by the user.
@MainActor
final class UpdateCheckService: ObservableObject {

    static let shared = UpdateCheckService()
    static let defaultReleasesEndpoint = URL(string: "https://api.github.com/repos/RighteousLife/LocalConvert/releases/latest")!

    @Published private(set) var isChecking: Bool = false
    @Published private(set) var lastResult: UpdateCheckResult? = nil
    @Published private(set) var lastError: String? = nil

    private let transport: any UpdateCheckTransport
    private let endpointURL: URL
    private let currentVersionProvider: @Sendable () -> String

    init(
        transport: any UpdateCheckTransport = URLSessionUpdateCheckTransport(),
        endpointURL: URL = UpdateCheckService.defaultReleasesEndpoint,
        currentVersionProvider: @escaping @Sendable () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        }
    ) {
        self.transport = transport
        self.endpointURL = endpointURL
        self.currentVersionProvider = currentVersionProvider
    }

    nonisolated static func isVersion(_ candidateRaw: String, newerThan currentRaw: String) -> Bool {
        guard let candidate = SemanticVersion(parsing: candidateRaw),
              let current = SemanticVersion(parsing: currentRaw) else {
            return false
        }
        return current < candidate
    }

    nonisolated static func normalizedVersionString(_ raw: String) -> String {
        SemanticVersion(parsing: raw)?.normalizedString ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func checkForUpdates() async throws -> UpdateCheckResult {
        isChecking = true
        lastError = nil
        defer { isChecking = false }

        do {
            let (data, response) = try await transport.fetchLatestReleaseData(from: endpointURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateCheckError.httpStatusError(http.statusCode)
            }

            let payload: GitHubReleasePayload
            do {
                payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            } catch {
                throw UpdateCheckError.invalidReleasePayload(error.localizedDescription)
            }

            guard let releaseURL = URL(string: payload.htmlURL),
                  releaseURL.scheme?.lowercased() == "https" else {
                throw UpdateCheckError.insecureReleaseURL(payload.htmlURL)
            }

            let rawCurrent = currentVersionProvider()
            let normalizedCurrent = Self.normalizedVersionString(rawCurrent)
            let normalizedLatest = Self.normalizedVersionString(payload.tagName)
            let updateAvailable = Self.isVersion(payload.tagName, newerThan: rawCurrent)

            let summary = payload.body?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: true)
                .prefix(3)
                .map(String.init)
                .joined(separator: "\n")

            let result = UpdateCheckResult(
                currentVersion: normalizedCurrent,
                latestVersion: normalizedLatest,
                isUpdateAvailable: updateAvailable,
                releaseURL: releaseURL,
                releaseNotesSummary: summary?.isEmpty == true ? nil : summary,
                checkedAt: Date()
            )
            lastResult = result
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}

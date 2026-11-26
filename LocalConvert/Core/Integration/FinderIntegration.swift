import Foundation
import AppKit
import Darwin
import os.log

// MARK: - Validation & Result Types

struct FinderValidationResult: Equatable, Sendable {
    var validURLs: [URL]
    var rejectedFolders: [URL]
    var inaccessibleURLs: [URL]
    var unsupportedURLs: [URL]
    
    init(
        validURLs: [URL] = [],
        rejectedFolders: [URL] = [],
        inaccessibleURLs: [URL] = [],
        unsupportedURLs: [URL] = []
    ) {
        self.validURLs = validURLs
        self.rejectedFolders = rejectedFolders
        self.inaccessibleURLs = inaccessibleURLs
        self.unsupportedURLs = unsupportedURLs
    }
}

enum FinderHandoffError: Error, LocalizedError, Equatable, Sendable {
    case invalidScheme(String)
    case malformedURL(String)
    case unsupportedAction(String)
    case emptyInput
    case pathTraversalRejected(String)
    case symlinkRejected(String)
    case notRegularFile(String)
    case fileNotReadable(String)
    case fileNotFound(String)
    case folderRejected(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidScheme(let s):
            return "Invalid URL scheme '\(s)'. Expected 'localconvert'."
        case .malformedURL(let u):
            return "Malformed URL: \(u)"
        case .unsupportedAction(let a):
            return "Unsupported action '\(a)'. Supported actions are 'open' and 'convert'."
        case .emptyInput:
            return "No files specified in conversion request."
        case .pathTraversalRejected(let path):
            return "Path traversal is not allowed: \(path)"
        case .symlinkRejected(let path):
            return "Symbolic links are not allowed in URL requests: \(path)"
        case .notRegularFile(let path):
            return "Target is not a regular file: \(path)"
        case .fileNotReadable(let path):
            return "File is not readable: \(path)"
        case .fileNotFound(let path):
            return "File not found or inaccessible: \(path)"
        case .folderRejected(let path):
            return "Folder input is not supported: \(path)"
        }
    }
}

enum SchemeURLAction: String, Equatable, Sendable {
    case open
    case convert
}

struct RejectedSchemePath: Equatable, Sendable {
    let rawInput: String
    let error: FinderHandoffError

    var displayName: String {
        let candidate = URL(fileURLWithPath: rawInput).lastPathComponent
        return candidate.isEmpty ? rawInput : candidate
    }
}

struct SchemeURLValidationBatch: Equatable, Sendable {
    let action: SchemeURLAction
    let validURLs: [URL]
    let rejectedEntries: [RejectedSchemePath]
}

struct PendingURLConversionRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL
    let stagedURLs: [URL]
    let rejectedEntries: [RejectedSchemePath]

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        stagedURLs: [URL],
        rejectedEntries: [RejectedSchemePath] = []
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.stagedURLs = stagedURLs
        self.rejectedEntries = rejectedEntries
    }

    var resolvedFilenames: [String] {
        stagedURLs.map { $0.lastPathComponent }
    }

    var resolvedFilePaths: [String] {
        stagedURLs.map { $0.path }
    }
}

// MARK: - Finder Handoff Handler

final class FinderHandoffHandler: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "FinderIntegration")
    
    /// Validates, checks permissions, and categorizes input URLs
    static func validateAndSanitize(
        urls: [URL],
        registry: ConversionRegistry = ConversionRegistry.shared,
        fileDetector: FileDetector = FileDetector()
    ) -> FinderValidationResult {
        var result = FinderValidationResult()
        let fileManager = FileManager.default
        
        for rawURL in urls {
            // Standardize and resolve symlinks
            let resolvedURL = rawURL.resolvingSymlinksInPath().standardizedFileURL
            
            // Check existence and directory status
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDir) else {
                logger.warning("Inaccessible or missing item: \(resolvedURL.path, privacy: .private)")
                result.inaccessibleURLs.append(resolvedURL)
                continue
            }
            
            if isDir.boolValue {
                logger.warning("Rejected folder from selection: \(resolvedURL.lastPathComponent, privacy: .private)")
                result.rejectedFolders.append(resolvedURL)
                continue
            }
            
            // Check readability
            guard fileManager.isReadableFile(atPath: resolvedURL.path) else {
                logger.warning("Unreadable file: \(resolvedURL.path, privacy: .private)")
                result.inaccessibleURLs.append(resolvedURL)
                continue
            }
            
            // Check format support
            let detection = fileDetector.detect(url: resolvedURL)
            if let format = detection.bestFormat {
                let availableTargets = registry.supportedOutputFormats(for: format)
                if availableTargets.isEmpty {
                    logger.info("Unsupported format for conversion: \(format.rawValue, privacy: .public)")
                    result.unsupportedURLs.append(resolvedURL)
                } else {
                    result.validURLs.append(resolvedURL)
                }
            } else {
                logger.info("Unknown format for item: \(resolvedURL.lastPathComponent, privacy: .private)")
                result.unsupportedURLs.append(resolvedURL)
            }
        }
        
        return result
    }
    
    /// Parses custom scheme URLs, e.g. localconvert://open?file=/path/to/file or localconvert://convert?files=p1,p2.
    /// Rejects any invalid scheme, unsupported action, traversal, symlink, directory, non-regular file, or unreadable path.
    static func parseSchemeURL(_ url: URL) -> Result<[URL], FinderHandoffError> {
        switch parseAndValidateSchemeURL(url, allowPartialSuccess: false) {
        case .success(let batch):
            return .success(batch.validURLs)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Parses and security-validates custom scheme URLs with mixed-batch support.
    /// Valid regular readable non-symlink files are returned in `validURLs`, while invalid entries are collected in `rejectedEntries`.
    /// Fails only when the URL itself is invalid/empty or when zero valid files remain.
    static func parseAndValidateSchemeURL(
        _ url: URL,
        allowPartialSuccess: Bool = true
    ) -> Result<SchemeURLValidationBatch, FinderHandoffError> {
        guard let scheme = url.scheme?.lowercased(), scheme == "localconvert" else {
            return .failure(.invalidScheme(url.scheme ?? ""))
        }

        if url.absoluteString.lowercased().contains("%00") || url.absoluteString.contains("\0") {
            return .failure(.malformedURL("URL contains null byte"))
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformedURL(url.absoluteString))
        }

        if components.user != nil || components.password != nil || components.port != nil || components.fragment != nil {
            return .failure(.malformedURL(url.absoluteString))
        }

        let rawAction = (components.host ?? "").lowercased()
        let action: SchemeURLAction
        switch rawAction {
        case "convert":
            action = .convert
        case "open", "":
            action = .open
        default:
            return .failure(.unsupportedAction(rawAction))
        }

        var candidatePaths: [String] = []
        var preParseRejected: [RejectedSchemePath] = []

        if let queryItems = components.queryItems {
            for item in queryItems {
                let key = item.name.lowercased()
                switch key {
                case "file", "path", "url":
                    guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                        preParseRejected.append(RejectedSchemePath(rawInput: item.name, error: .emptyInput))
                        continue
                    }
                    candidatePaths.append(value)
                case "files", "paths":
                    guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                        preParseRejected.append(RejectedSchemePath(rawInput: item.name, error: .emptyInput))
                        continue
                    }
                    let split = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    for segment in split {
                        if segment.isEmpty {
                            preParseRejected.append(RejectedSchemePath(rawInput: "(empty)", error: .malformedURL("Empty path entry in '\(item.name)'")))
                        } else {
                            candidatePaths.append(segment)
                        }
                    }
                default:
                    break
                }
            }
        }

        // Also support path-based payload: localconvert:///Users/...
        if candidatePaths.isEmpty, !components.path.isEmpty, components.path != "/" {
            candidatePaths.append(components.path)
        }

        guard !candidatePaths.isEmpty else {
            return .failure(.emptyInput)
        }

        var validURLs: [URL] = []
        var seenStandardizedPaths = Set<String>()
        var rejectedEntries: [RejectedSchemePath] = preParseRejected

        for rawPath in candidatePaths {
            switch validateSchemeFilePath(rawPath) {
            case .success(let validatedURL):
                let dedupKey = validatedURL.standardizedFileURL.path
                if seenStandardizedPaths.insert(dedupKey).inserted {
                    validURLs.append(validatedURL)
                }
            case .failure(let error):
                logger.warning("Rejected URL scheme path '\(rawPath, privacy: .private)': \(error.localizedDescription, privacy: .private)")
                if !allowPartialSuccess {
                    return .failure(error)
                }
                rejectedEntries.append(RejectedSchemePath(rawInput: rawPath, error: error))
            }
        }

        if !allowPartialSuccess, let firstPreParse = preParseRejected.first {
            return .failure(firstPreParse.error)
        }

        guard !validURLs.isEmpty else {
            return .failure(rejectedEntries.first?.error ?? .emptyInput)
        }

        return .success(
            SchemeURLValidationBatch(
                action: action,
                validURLs: validURLs,
                rejectedEntries: rejectedEntries
            )
        )
    }

    /// Validates a single file path received from a custom URL scheme without following symlinks.
    static func validateSchemeFilePath(_ rawPath: String) -> Result<URL, FinderHandoffError> {
        guard !rawPath.isEmpty else {
            return .failure(.emptyInput)
        }
        if rawPath.contains("\0") || rawPath.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x0A || $0.value == 0x0D }) {
            return .failure(.malformedURL("Path contains invalid control characters"))
        }

        let candidatePath: String
        if rawPath.lowercased().hasPrefix("file://") {
            let afterScheme = String(rawPath.dropFirst("file://".count))
            if afterScheme.split(separator: "/").contains("..") {
                return .failure(.pathTraversalRejected(rawPath))
            }
            if let decodedURL = URL(string: rawPath), decodedURL.isFileURL {
                if let host = decodedURL.host, !host.isEmpty, host.lowercased() != "localhost" {
                    return .failure(.malformedURL(rawPath))
                }
                candidatePath = decodedURL.path
            } else if afterScheme.hasPrefix("/") {
                candidatePath = afterScheme.removingPercentEncoding ?? afterScheme
            } else if afterScheme.lowercased().hasPrefix("localhost/") {
                let trimmed = String(afterScheme.dropFirst("localhost".count))
                candidatePath = trimmed.removingPercentEncoding ?? trimmed
            } else {
                return .failure(.malformedURL(rawPath))
            }
        } else {
            candidatePath = rawPath
        }

        if candidatePath.contains("\0") {
            return .failure(.malformedURL("Path contains null byte"))
        }

        guard candidatePath.hasPrefix("/") else {
            return .failure(.malformedURL(rawPath))
        }

        let rawComponents = candidatePath.split(separator: "/", omittingEmptySubsequences: true)
        if rawComponents.contains("..") {
            return .failure(.pathTraversalRejected(candidatePath))
        }

        let fileURL = URL(fileURLWithPath: candidatePath).standardizedFileURL
        let filePath = fileURL.path

        var targetStat = Darwin.stat()
        if Darwin.lstat(filePath, &targetStat) != 0 {
            let err = errno
            if err == EACCES || err == EPERM {
                return .failure(.fileNotReadable(filePath))
            }
            return .failure(.fileNotFound(filePath))
        }

        let targetType = targetStat.st_mode & S_IFMT
        if targetType == S_IFLNK {
            return .failure(.symlinkRejected(filePath))
        }

        // Check every ancestor component for symlinks (allowing only genuine macOS root symlinks /var, /tmp, /etc).
        if let ancestorError = validateAncestorComponentsHaveNoSymlinks(for: filePath) {
            return .failure(ancestorError)
        }

        let resourceValues = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        if resourceValues?.isSymbolicLink == true {
            return .failure(.symlinkRejected(filePath))
        }

        if targetType == S_IFDIR || resourceValues?.isDirectory == true {
            return .failure(.folderRejected(filePath))
        }

        guard targetType == S_IFREG, resourceValues?.isRegularFile == true else {
            return .failure(.notRegularFile(filePath))
        }

        guard FileManager.default.isReadableFile(atPath: filePath),
              Darwin.access(filePath, R_OK) == 0 else {
            return .failure(.fileNotReadable(filePath))
        }

        return .success(fileURL)
    }

    private static func validateAncestorComponentsHaveNoSymlinks(for standardizedPath: String) -> FinderHandoffError? {
        let components = standardizedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return nil }

        var currentPrefix = ""
        for index in 0..<(components.count - 1) {
            currentPrefix += "/" + components[index]
            var compStat = Darwin.stat()
            if Darwin.lstat(currentPrefix, &compStat) != 0 {
                let err = errno
                if err == EACCES || err == EPERM {
                    return .fileNotReadable(standardizedPath)
                }
                return .fileNotFound(standardizedPath)
            }
            if (compStat.st_mode & S_IFMT) == S_IFLNK {
                if index == 0, isGenuineMacOSRootSymlink(path: currentPrefix, statInfo: compStat) {
                    continue
                }
                return .symlinkRejected(standardizedPath)
            }
        }
        return nil
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
        return readlinkTarget(at: path) == expectedTarget
    }

    private static func readlinkTarget(at path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = Darwin.readlink(path, &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        buffer[length] = 0
        return buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) }
        }
    }
    
    /// Reads file URLs from NSPasteboard (used by macOS Services)
    static func extractPasteboardURLs(_ pboard: NSPasteboard) -> [URL] {
        guard let classes = [NSURL.self] as? [AnyClass] else { return [] }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        
        if let urls = pboard.readObjects(forClasses: classes, options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        
        // Fallback to property list
        if let plist = pboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            return plist.map { URL(fileURLWithPath: $0) }
        }
        
        return []
    }
}

// MARK: - macOS Services Provider

@MainActor
@objc final class ServicesProvider: NSObject {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ServicesProvider")
    
    var onFilesReceived: (@MainActor ([URL]) -> Void)?
    var onFilesReceivedWithAction: (@MainActor ([URL], String) -> Void)?
    
    override init() {
        super.init()
    }
    
    @objc func handleServicesConvert(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "convert")
    }
    
    @objc func handleConvertPDF(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "pdf")
    }
    
    @objc func handleConvertWebP(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "webp")
    }
    
    @objc func handleConvertMP4(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "mp4")
    }
    
    @objc func handleExtractAudio(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "extract_audio")
    }
    
    @objc func handleMergePDFs(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "merge_pdfs")
    }
    
    @objc func handleExtractPDF(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "extract_pdf")
    }
    
    @objc func handleCompressPDF(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        processService(pboard, action: "compress_pdf")
    }
    
    private func processService(_ pboard: NSPasteboard, action: String) {
        logger.info("Service invoked for action: \(action, privacy: .public)")
        let urls = FinderHandoffHandler.extractPasteboardURLs(pboard)
        guard !urls.isEmpty else {
            logger.warning("No URLs extracted from Service pasteboard")
            return
        }
        
        NSApp.activate(ignoringOtherApps: true)
        if let callbackWithAction = self.onFilesReceivedWithAction {
            callbackWithAction(urls, action)
        } else if let callback = self.onFilesReceived {
            callback(urls) // Fallback for old behavior
        } else {
            AppState.shared?.handleQuickAction(urls: urls, action: action)
        }
    }
}

// MARK: - URL Scheme Staging & Explicit Confirmation Coordinator

@MainActor
final class URLSchemeHandoffCoordinator: ObservableObject {

    static let shared = URLSchemeHandoffCoordinator()

    private let logger = Logger(subsystem: "com.localconvert.app", category: "URLSchemeHandoffCoordinator")

    @Published private(set) var pendingConversionRequest: PendingURLConversionRequest?
    @Published var isConfirmationPresented: Bool = false {
        didSet {
            if !isConfirmationPresented, pendingConversionRequest != nil {
                // Alert dismissed without explicit confirmation — discard staged files completely.
                pendingConversionRequest = nil
            }
        }
    }
    @Published private(set) var lastRejectedEntries: [RejectedSchemePath] = []

    init() {}

    func handleIncomingURL(_ url: URL, appState: AppState) {
        switch FinderHandoffHandler.parseAndValidateSchemeURL(url, allowPartialSuccess: true) {
        case .success(let batch):
            lastRejectedEntries = batch.rejectedEntries
            switch batch.action {
            case .open:
                appState.addFiles(urls: batch.validURLs)
                if !batch.rejectedEntries.isEmpty {
                    let count = batch.rejectedEntries.count
                    let summary = batch.rejectedEntries.map { "\($0.displayName): \($0.error.localizedDescription)" }.joined(separator: "\n")
                    appState.showError(
                        title: "Some URL Paths Were Rejected",
                        message: "\(count) invalid or unsafe path\(count == 1 ? "" : "s") skipped.",
                        details: summary
                    )
                }
            case .convert:
                stageConversionRequest(sourceURL: url, validURLs: batch.validURLs, rejectedEntries: batch.rejectedEntries)
            }
        case .failure(let error):
            lastRejectedEntries = [RejectedSchemePath(rawInput: url.absoluteString, error: error)]
            logger.warning("Rejected URL scheme request: \(error.localizedDescription, privacy: .private)")
            appState.showError(
                title: "URL Request Rejected",
                message: error.localizedDescription
            )
        }
    }

    private func stageConversionRequest(
        sourceURL: URL,
        validURLs: [URL],
        rejectedEntries: [RejectedSchemePath]
    ) {
        guard !validURLs.isEmpty else { return }

        if let existing = pendingConversionRequest {
            var mergedURLs = existing.stagedURLs
            var seen = Set(mergedURLs.map { $0.standardizedFileURL.path })
            for candidate in validURLs {
                if seen.insert(candidate.standardizedFileURL.path).inserted {
                    mergedURLs.append(candidate)
                }
            }
            let mergedRejected = existing.rejectedEntries + rejectedEntries
            pendingConversionRequest = PendingURLConversionRequest(
                id: existing.id,
                sourceURL: sourceURL,
                stagedURLs: mergedURLs,
                rejectedEntries: mergedRejected
            )
        } else {
            pendingConversionRequest = PendingURLConversionRequest(
                sourceURL: sourceURL,
                stagedURLs: validURLs,
                rejectedEntries: rejectedEntries
            )
        }
        isConfirmationPresented = true
    }

    @discardableResult
    func confirmPendingConversion(appState: AppState) -> Bool {
        guard let request = pendingConversionRequest else {
            isConfirmationPresented = false
            return false
        }
        pendingConversionRequest = nil
        isConfirmationPresented = false
        appState.addFiles(urls: request.stagedURLs)
        appState.convertAll()
        return true
    }

    func cancelPendingConversion() {
        pendingConversionRequest = nil
        isConfirmationPresented = false
    }

    static func confirmationMessage(for request: PendingURLConversionRequest) -> String {
        let filenames = request.resolvedFilenames
        let maxListed = 10
        let listed = filenames.prefix(maxListed).map { "• \($0)" }.joined(separator: "\n")
        let overflow = filenames.count > maxListed ? "\n…and \(filenames.count - maxListed) more" : ""
        let fileWord = filenames.count == 1 ? "file" : "files"
        var body = "Start converting \(filenames.count) \(fileWord) requested via URL?\n\n\(listed)\(overflow)"
        if !request.rejectedEntries.isEmpty {
            let skippedCount = request.rejectedEntries.count
            let skippedWord = skippedCount == 1 ? "path was" : "paths were"
            body += "\n\n\(skippedCount) invalid or unsafe \(skippedWord) skipped."
        }
        return body
    }
}

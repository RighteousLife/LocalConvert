import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin
import os

// MARK: - Validation & Safe Routing Models

enum QuickActionValidationError: Error, Equatable, Sendable {
    case nonFileURL
    case malformedURL
    case pathTraversalRejected
    case symlinkRejected
    case folderRejected
    case notRegularFile
    case fileNotReadable
    case fileNotFound
}

struct QuickActionValidationBatch: Equatable, Sendable {
    let validURLs: [URL]
    let rejectedInputs: [String]
}

// MARK: - Pure Testable Quick Action URL Router

enum QuickActionURLRouter: Sendable {

    static let hostBundleIdentifier = "com.localconvert.app"

    static func coerceFileURL(from item: (any NSSecureCoding)?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let nsURL = item as? NSURL {
            return nsURL as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let path = item as? String, path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Validates a single local file URL using the same strict `LC-002` security checks as `FinderHandoffHandler`:
    /// rejects non-file URLs, null bytes, control characters, path traversal (`..`), symlinks (target or non-system ancestors),
    /// directories, non-regular files (FIFOs/sockets/devices), missing files, and unreadable files.
    static func validateInputFileURL(_ url: URL) -> Result<URL, QuickActionValidationError> {
        guard url.isFileURL else {
            return .failure(.nonFileURL)
        }

        let abs = url.absoluteString
        if abs.lowercased().contains("%00") || abs.contains("\0") {
            return .failure(.malformedURL)
        }
        if abs.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x0A || $0.value == 0x0D }) {
            return .failure(.malformedURL)
        }
        if let decoded = abs.removingPercentEncoding,
           decoded.split(separator: "/").contains("..") {
            return .failure(.pathTraversalRejected)
        }

        let nsURL = url as NSURL
        let pathURL = nsURL.isFileReferenceURL() ? (nsURL.filePathURL ?? url) : url
        let rawPath = pathURL.path

        if rawPath.isEmpty || !rawPath.hasPrefix("/") {
            return .failure(.malformedURL)
        }
        if rawPath.contains("\0") || rawPath.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x0A || $0.value == 0x0D }) {
            return .failure(.malformedURL)
        }
        if rawPath.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
            return .failure(.pathTraversalRejected)
        }

        let standardizedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        let standardizedPath = standardizedURL.path

        var targetStat = Darwin.stat()
        if Darwin.lstat(standardizedPath, &targetStat) != 0 {
            let err = errno
            if err == EACCES || err == EPERM {
                return .failure(.fileNotReadable)
            }
            return .failure(.fileNotFound)
        }

        let targetType = targetStat.st_mode & S_IFMT
        if targetType == S_IFLNK {
            return .failure(.symlinkRejected)
        }

        if let ancestorError = validateAncestorsHaveNoSymlinks(for: standardizedPath) {
            return .failure(ancestorError)
        }

        let values = try? standardizedURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        if values?.isSymbolicLink == true {
            return .failure(.symlinkRejected)
        }
        if targetType == S_IFDIR || values?.isDirectory == true {
            return .failure(.folderRejected)
        }
        guard targetType == S_IFREG, values?.isRegularFile == true else {
            return .failure(.notRegularFile)
        }
        guard FileManager.default.isReadableFile(atPath: standardizedPath),
              Darwin.access(standardizedPath, R_OK) == 0 else {
            return .failure(.fileNotReadable)
        }

        return .success(standardizedURL)
    }

    static func validateInputFileURLs(_ urls: [URL]) -> QuickActionValidationBatch {
        var validURLs: [URL] = []
        var rejectedInputs: [String] = []
        var seenPaths = Set<String>()

        for url in urls {
            switch validateInputFileURL(url) {
            case .success(let safeURL):
                if seenPaths.insert(safeURL.standardizedFileURL.path).inserted {
                    validURLs.append(safeURL)
                }
            case .failure:
                let label = url.path.isEmpty ? url.absoluteString : url.path
                rejectedInputs.append(label)
            }
        }

        return QuickActionValidationBatch(validURLs: validURLs, rejectedInputs: rejectedInputs)
    }

    /// Builds a `localconvert://open?...` URL that preserves `LC-002` security (stages/opens without auto-converting).
    /// Returns `nil` if no valid local regular files remain after filtering.
    static func makeSafeOpenSchemeURL(for urls: [URL]) -> URL? {
        let batch = validateInputFileURLs(urls)
        guard !batch.validURLs.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "localconvert"
        components.host = "open"
        components.queryItems = batch.validURLs.map { URLQueryItem(name: "file", value: $0.path) }
        return components.url
    }

    static func hostApplicationURL(
        extensionBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL? {
        if extensionBundleURL.pathExtension.lowercased() == "appex" {
            // <App>.app/Contents/PlugIns/<Extension>.appex -> <App>.app
            let candidate = extensionBundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if candidate.pathExtension.lowercased() == "app",
               fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostBundleIdentifier)
    }

    private static func validateAncestorsHaveNoSymlinks(for standardizedPath: String) -> QuickActionValidationError? {
        let components = standardizedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return nil }

        var prefix = ""
        for index in 0..<(components.count - 1) {
            prefix += "/" + components[index]
            var st = Darwin.stat()
            if Darwin.lstat(prefix, &st) != 0 {
                let err = errno
                if err == EACCES || err == EPERM {
                    return .fileNotReadable
                }
                return .fileNotFound
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                if index == 0, isGenuineMacOSRootSymlink(path: prefix, statInfo: st) {
                    continue
                }
                return .symlinkRejected
            }
        }
        return nil
    }

    private static func isGenuineMacOSRootSymlink(path: String, statInfo: Darwin.stat) -> Bool {
        guard statInfo.st_uid == 0 else { return false }
        let expected: String
        switch path {
        case "/var": expected = "private/var"
        case "/tmp": expected = "private/tmp"
        case "/etc": expected = "private/etc"
        default: return false
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = Darwin.readlink(path, &buffer, buffer.count - 1)
        guard length > 0 else { return false }
        buffer[length] = 0
        let target = buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) }
        }
        return target == expected
    }
}

// MARK: - Action Extension Entry Point

final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {

    private let logger = Logger(subsystem: "com.localconvert.app.quickactions", category: "ActionRequestHandler")

    func beginRequest(with context: NSExtensionContext) {
        let items = (context.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        let collected = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let group = DispatchGroup()

        for provider in providers {
            let typeIdentifier: String?
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                typeIdentifier = UTType.fileURL.identifier
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                typeIdentifier = UTType.url.identifier
            } else {
                typeIdentifier = nil
            }
            guard let typeIdentifier else { continue }

            group.enter()
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = QuickActionURLRouter.coerceFileURL(from: item) {
                    collected.withLock { $0.append(url) }
                }
                group.leave()
            }
        }

        let waitResult = group.wait(timeout: .now() + 5.0)
        if waitResult == .timedOut {
            logger.warning("Timed out waiting for Finder Quick Action attachment items")
        }

        let candidateURLs = collected.withLock { $0 }
        let batch = QuickActionURLRouter.validateInputFileURLs(candidateURLs)
        if !batch.rejectedInputs.isEmpty {
            logger.warning("Filtered \(batch.rejectedInputs.count, privacy: .public) unsafe or unsupported Quick Action URL(s)")
        }

        if !batch.validURLs.isEmpty {
            routeToHostApplication(validURLs: batch.validURLs)
        }

        context.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func routeToHostApplication(validURLs: [URL]) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        if let appURL = QuickActionURLRouter.hostApplicationURL() {
            NSWorkspace.shared.open(validURLs, withApplicationAt: appURL, configuration: config) { [logger] _, error in
                if let error {
                    logger.error("Failed to open files in LocalConvert.app: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        if let schemeURL = QuickActionURLRouter.makeSafeOpenSchemeURL(for: validURLs) {
            NSWorkspace.shared.open(schemeURL)
        }
    }
}

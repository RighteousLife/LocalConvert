import Foundation
import AppKit
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

enum FinderHandoffError: Error, LocalizedError, Equatable {
    case invalidScheme(String)
    case malformedURL(String)
    case unsupportedAction(String)
    case emptyInput
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
        case .fileNotFound(let path):
            return "File not found or inaccessible: \(path)"
        case .folderRejected(let path):
            return "Folder input is not supported: \(path)"
        }
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
                logger.warning("Inaccessible or missing item: \(resolvedURL.path, privacy: .public)")
                result.inaccessibleURLs.append(resolvedURL)
                continue
            }
            
            if isDir.boolValue {
                logger.warning("Rejected folder from selection: \(resolvedURL.lastPathComponent, privacy: .public)")
                result.rejectedFolders.append(resolvedURL)
                continue
            }
            
            // Check readability
            guard fileManager.isReadableFile(atPath: resolvedURL.path) else {
                logger.warning("Unreadable file: \(resolvedURL.path, privacy: .public)")
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
                logger.info("Unknown format for item: \(resolvedURL.lastPathComponent, privacy: .public)")
                result.unsupportedURLs.append(resolvedURL)
            }
        }
        
        return result
    }
    
    /// Parses custom scheme URLs, e.g. localconvert://open?file=/path/to/file or localconvert://convert?files=p1,p2
    static func parseSchemeURL(_ url: URL) -> Result<[URL], FinderHandoffError> {
        guard let scheme = url.scheme?.lowercased(), scheme == "localconvert" else {
            return .failure(.invalidScheme(url.scheme ?? ""))
        }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformedURL(url.absoluteString))
        }
        
        let action = (components.host ?? "").lowercased()
        guard action == "open" || action == "convert" || action.isEmpty else {
            return .failure(.unsupportedAction(action))
        }
        
        var filePaths: [String] = []
        
        if let queryItems = components.queryItems {
            for item in queryItems {
                guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    continue
                }
                
                switch item.name.lowercased() {
                case "file", "path", "url":
                    filePaths.append(value)
                case "files", "paths":
                    let split = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    filePaths.append(contentsOf: split.filter { !$0.isEmpty })
                default:
                    break
                }
            }
        }
        
        // Also support path-based payload: localconvert:///Users/...
        if filePaths.isEmpty, !components.path.isEmpty, components.path != "/" {
            filePaths.append(components.path)
        }
        
        guard !filePaths.isEmpty else {
            return .failure(.emptyInput)
        }
        
        var resolvedURLs: [URL] = []
        let fileManager = FileManager.default
        
        for pathString in filePaths {
            let fileURL: URL
            if pathString.hasPrefix("file://") {
                guard let decodedURL = URL(string: pathString) else {
                    return .failure(.malformedURL(pathString))
                }
                fileURL = decodedURL.standardizedFileURL
            } else {
                fileURL = URL(fileURLWithPath: pathString).standardizedFileURL
            }
            
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
                return .failure(.fileNotFound(fileURL.path))
            }
            
            if isDir.boolValue {
                return .failure(.folderRejected(fileURL.path))
            }
            
            resolvedURLs.append(fileURL)
        }
        
        return .success(resolvedURLs)
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

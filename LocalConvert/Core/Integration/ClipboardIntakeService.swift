import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - Clipboard Intake Types

enum ClipboardIntakeSourceKind: String, Sendable, Equatable {
    case fileURLs
    case image
    case json
    case xml
    case plainText
}

enum ClipboardTextFormat: String, Sendable, Equatable {
    case json
    case xml
    case plainText

    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .xml: return "xml"
        case .plainText: return "txt"
        }
    }

    var filenamePrefix: String {
        switch self {
        case .json: return "Clipboard-JSON"
        case .xml: return "Clipboard-XML"
        case .plainText: return "Clipboard-Text"
        }
    }

    var sourceKind: ClipboardIntakeSourceKind {
        switch self {
        case .json: return .json
        case .xml: return .xml
        case .plainText: return .plainText
        }
    }
}

struct ClipboardIntakeResult: Sendable, Equatable {
    let stagedURLs: [URL]
    let sourceKind: ClipboardIntakeSourceKind
    let rejectedEntries: [RejectedSchemePath]
    let createdTempFiles: [URL]

    init(
        stagedURLs: [URL],
        sourceKind: ClipboardIntakeSourceKind,
        rejectedEntries: [RejectedSchemePath] = [],
        createdTempFiles: [URL] = []
    ) {
        self.stagedURLs = stagedURLs
        self.sourceKind = sourceKind
        self.rejectedEntries = rejectedEntries
        self.createdTempFiles = createdTempFiles
    }
}

enum ClipboardIntakeError: Error, LocalizedError, Equatable, Sendable {
    case emptyPasteboard
    case unsupportedPasteboardContent
    case invalidImageData
    case invalidTextEncoding
    case payloadTooLarge(Int64)
    case allFileURLsRejected([RejectedSchemePath])
    case stagingFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPasteboard:
            return String(localized: "The clipboard is empty.")
        case .unsupportedPasteboardContent:
            return String(localized: "The clipboard does not contain supported files, images, or text.")
        case .invalidImageData:
            return String(localized: "The image data on the clipboard could not be decoded.")
        case .invalidTextEncoding:
            return String(localized: "The text on the clipboard could not be encoded as UTF-8.")
        case .payloadTooLarge(let bytes):
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return String(localized: "The clipboard payload (\(formatted)) exceeds the maximum supported size.")
        case .allFileURLsRejected(let entries):
            if let first = entries.first {
                return first.error.localizedDescription
            }
            return String(localized: "All copied file paths were rejected by safety validation.")
        case .stagingFailed(let message):
            return String(localized: "Could not stage clipboard content: \(message)")
        }
    }
}

// MARK: - Clipboard Intake Service

enum ClipboardIntakeService: Sendable {

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "ClipboardIntake")

    /// Maximum text payload staged from clipboard (100 MB, aligned with TextConversionEngine).
    static let maxTextPayloadBytes: Int = Int(AppleDataFormatConverter.maxInputFileBytes)

    /// Maximum image payload staged from clipboard (200 MB).
    static let maxImagePayloadBytes: Int = 200 * 1024 * 1024

    static var defaultStagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-ClipboardIntake", isDirectory: true)
    }

    private enum ClipboardRawPayload: Sendable {
        case fileURLs([URL])
        case pngData(Data, fallbackTIFF: Data?)
        case tiffData(Data)
        case cgImage(CGImage)
        case invalidImage
        case text(String)
        case unsupported
        case empty
    }

    // MARK: - Public API

    /// Extracts supported content from `pasteboard` (file URLs, PNG/TIFF/NSImage, or JSON/XML/plain text),
    /// validates or stages it safely into `stagingDirectory`, and returns staged local file URLs.
    @MainActor
    static func intake(
        from pasteboard: NSPasteboard = .general,
        stagingDirectory: URL? = nil
    ) async throws -> ClipboardIntakeResult {
        let payload = extractPayload(from: pasteboard)
        let targetDirectory = (stagingDirectory ?? defaultStagingDirectory).standardizedFileURL
        return try await stagePayload(payload, stagingDirectory: targetDirectory)
    }

    /// Convenience coordinator helper that intakes clipboard content, adds it to `AppState`,
    /// and navigates to the Convert tab.
    @MainActor
    @discardableResult
    static func pasteToConvert(
        into appState: AppState,
        from pasteboard: NSPasteboard = .general,
        stagingDirectory: URL? = nil
    ) async -> ClipboardIntakeResult? {
        guard !appState.isConverting else { return nil }

        do {
            let result = try await intake(from: pasteboard, stagingDirectory: stagingDirectory)
            guard !result.stagedURLs.isEmpty else { return nil }

            // Re-check conversion state after async staging before mutating queue state.
            guard !appState.isConverting else {
                cleanupStagedFiles(result.createdTempFiles)
                return nil
            }

            appState.addFiles(urls: result.stagedURLs)
            appState.selectedTab = .convert
            _ = AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .convert, appState: appState)
            return result
        } catch {
            let title: String
            switch error {
            case ClipboardIntakeError.emptyPasteboard, ClipboardIntakeError.unsupportedPasteboardContent:
                title = String(localized: "Nothing to Paste")
            default:
                title = String(localized: "Clipboard Paste Failed")
            }
            logger.info("Clipboard paste failed: \(error.localizedDescription, privacy: .public)")
            appState.showError(title: title, message: error.localizedDescription)
            return nil
        }
    }

    /// Classifies raw clipboard text into `.json`, `.xml`, or `.plainText`.
    /// Returns `nil` for empty or whitespace/BOM-only strings.
    nonisolated static func classifyText(_ rawText: String) -> ClipboardTextFormat? {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        let trimmed = rawText.trimmingCharacters(in: trimSet)
        guard !trimmed.isEmpty else { return nil }

        if isValidJSONObjectOrArray(trimmed) {
            return .json
        }
        if isValidXMLOrDeclaration(trimmed) {
            return .xml
        }
        return .plainText
    }

    // MARK: - Pasteboard Extraction (@MainActor)

    @MainActor
    private static func extractPayload(from pasteboard: NSPasteboard) -> ClipboardRawPayload {
        let types = pasteboard.types ?? []
        if types.isEmpty {
            return .empty
        }

        // 1. Copied file URLs take highest priority (Finder puts filename string & icon TIFF alongside URLs).
        let fileURLs = FinderHandoffHandler.extractPasteboardURLs(pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        // 2. Image / screenshot data (PNG -> TIFF -> NSImage).
        let hasExplicitImageType = types.contains(.png) || types.contains(.tiff)
        let pngData = pasteboard.data(forType: .png)
        let tiffData = pasteboard.data(forType: .tiff)

        if let pngData, !pngData.isEmpty {
            return .pngData(pngData, fallbackTIFF: tiffData)
        }
        if let tiffData, !tiffData.isEmpty {
            return .tiffData(tiffData)
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return .cgImage(cgImage)
            }
            if let repData = image.tiffRepresentation, !repData.isEmpty {
                return .tiffData(repData)
            }
            return .invalidImage
        }
        if hasExplicitImageType {
            return .invalidImage
        }

        // 3. Raw text / JSON / XML.
        if let string = pasteboard.string(forType: .string) {
            return .text(string)
        }
        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String],
           let firstString = strings.first {
            return .text(firstString)
        }

        return .unsupported
    }

    // MARK: - Off-MainActor Validation & Atomic Staging

    private nonisolated static func stagePayload(
        _ payload: ClipboardRawPayload,
        stagingDirectory: URL
    ) async throws -> ClipboardIntakeResult {
        switch payload {
        case .empty:
            throw ClipboardIntakeError.emptyPasteboard

        case .unsupported:
            throw ClipboardIntakeError.unsupportedPasteboardContent

        case .invalidImage:
            throw ClipboardIntakeError.invalidImageData

        case .fileURLs(let rawURLs):
            let validation = FinderHandoffHandler.validateInputFileURLs(rawURLs)
            guard !validation.validURLs.isEmpty else {
                throw ClipboardIntakeError.allFileURLsRejected(validation.rejectedEntries)
            }
            return ClipboardIntakeResult(
                stagedURLs: validation.validURLs,
                sourceKind: .fileURLs,
                rejectedEntries: validation.rejectedEntries,
                createdTempFiles: []
            )

        case .pngData(let pngData, let fallbackTIFF):
            guard pngData.count <= maxImagePayloadBytes else {
                throw ClipboardIntakeError.payloadTooLarge(Int64(pngData.count))
            }
            if let validPNG = validatePNGData(pngData) {
                let stagedURL = try writeStagedData(
                    validPNG,
                    prefix: "Clipboard-Image",
                    fileExtension: "png",
                    in: stagingDirectory
                )
                return ClipboardIntakeResult(
                    stagedURLs: [stagedURL],
                    sourceKind: .image,
                    createdTempFiles: [stagedURL]
                )
            }
            if let fallbackTIFF, !fallbackTIFF.isEmpty {
                guard fallbackTIFF.count <= maxImagePayloadBytes else {
                    throw ClipboardIntakeError.payloadTooLarge(Int64(fallbackTIFF.count))
                }
                if let convertedPNG = encodeImageDataToPNG(fallbackTIFF) {
                    let stagedURL = try writeStagedData(
                        convertedPNG,
                        prefix: "Clipboard-Image",
                        fileExtension: "png",
                        in: stagingDirectory
                    )
                    return ClipboardIntakeResult(
                        stagedURLs: [stagedURL],
                        sourceKind: .image,
                        createdTempFiles: [stagedURL]
                    )
                }
            }
            throw ClipboardIntakeError.invalidImageData

        case .tiffData(let tiffData):
            guard tiffData.count <= maxImagePayloadBytes else {
                throw ClipboardIntakeError.payloadTooLarge(Int64(tiffData.count))
            }
            guard let convertedPNG = encodeImageDataToPNG(tiffData) else {
                throw ClipboardIntakeError.invalidImageData
            }
            let stagedURL = try writeStagedData(
                convertedPNG,
                prefix: "Clipboard-Image",
                fileExtension: "png",
                in: stagingDirectory
            )
            return ClipboardIntakeResult(
                stagedURLs: [stagedURL],
                sourceKind: .image,
                createdTempFiles: [stagedURL]
            )

        case .cgImage(let cgImage):
            guard let convertedPNG = encodeCGImageToPNG(cgImage) else {
                throw ClipboardIntakeError.invalidImageData
            }
            let stagedURL = try writeStagedData(
                convertedPNG,
                prefix: "Clipboard-Image",
                fileExtension: "png",
                in: stagingDirectory
            )
            return ClipboardIntakeResult(
                stagedURLs: [stagedURL],
                sourceKind: .image,
                createdTempFiles: [stagedURL]
            )

        case .text(let rawText):
            let byteCount = rawText.utf8.count
            guard byteCount <= maxTextPayloadBytes else {
                throw ClipboardIntakeError.payloadTooLarge(Int64(byteCount))
            }
            guard let format = classifyText(rawText) else {
                throw ClipboardIntakeError.emptyPasteboard
            }
            guard let textData = rawText.data(using: .utf8) else {
                throw ClipboardIntakeError.invalidTextEncoding
            }
            let stagedURL = try writeStagedData(
                textData,
                prefix: format.filenamePrefix,
                fileExtension: format.fileExtension,
                in: stagingDirectory
            )
            return ClipboardIntakeResult(
                stagedURLs: [stagedURL],
                sourceKind: format.sourceKind,
                createdTempFiles: [stagedURL]
            )
        }
    }

    // MARK: - Classification Helpers

    private nonisolated static func isValidJSONObjectOrArray(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            return false
        }
        guard let data = trimmed.data(using: .utf8) else {
            return false
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return parsed is [String: Any] || parsed is [Any]
    }

    private nonisolated static func isValidXMLOrDeclaration(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("<") else {
            return false
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<?xml") {
            let afterPrefix = lower.dropFirst("<?xml".count)
            let hasSeparator = afterPrefix.first.map { $0.isWhitespace || $0 == "?" } ?? false
            if hasSeparator, lower.contains("?>") {
                return true
            }
        }
        guard let data = trimmed.data(using: .utf8) else {
            return false
        }
        let delegate = SafeXMLValidationDelegate(maxDepth: AppleDataFormatConverter.maxXMLNestingDepth)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        return parser.parse() && !delegate.exceededMaxDepth && delegate.elementCount > 0
    }

    // MARK: - Image Encoding Helpers

    private nonisolated static func validatePNGData(_ data: Data) -> Data? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) as String?,
              sourceType == UTType.png.identifier,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return nil
        }
        return data
    }

    private nonisolated static func encodeImageDataToPNG(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let png = encodeCGImageToPNG(cgImage) {
            return png
        }
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]),
           !png.isEmpty {
            return png
        }
        return nil
    }

    private nonisolated static func encodeCGImageToPNG(_ cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest), mutableData.length > 0 else {
            return nil
        }
        return mutableData as Data
    }

    // MARK: - Atomic Staging

    private nonisolated static func writeStagedData(
        _ data: Data,
        prefix: String,
        fileExtension: String,
        in directory: URL
    ) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ClipboardIntakeError.stagingFailed(error.localizedDescription)
        }

        let stamp = timestampToken()
        var candidateURL: URL?
        for _ in 0..<8 {
            let suffix = String(UUID().uuidString.prefix(8))
            let filename = "\(prefix)-\(stamp)-\(suffix).\(fileExtension)"
            let candidate = directory.appendingPathComponent(filename, isDirectory: false)
            if !fm.fileExists(atPath: candidate.path) {
                candidateURL = candidate
                break
            }
        }
        guard let destinationURL = candidateURL else {
            throw ClipboardIntakeError.stagingFailed("Unable to reserve unique filename.")
        }

        do {
            try data.write(to: destinationURL, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            return destinationURL.standardizedFileURL
        } catch {
            try? fm.removeItem(at: destinationURL)
            throw ClipboardIntakeError.stagingFailed(error.localizedDescription)
        }
    }

    private nonisolated static func timestampToken() -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1,
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0
        )
    }

    private nonisolated static func cleanupStagedFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Safe XML Validation Delegate

private final class SafeXMLValidationDelegate: NSObject, XMLParserDelegate {
    private let maxDepth: Int
    private var currentDepth: Int = 0
    private(set) var elementCount: Int = 0
    private(set) var exceededMaxDepth: Bool = false

    init(maxDepth: Int) {
        self.maxDepth = maxDepth
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentDepth += 1
        elementCount += 1
        if currentDepth > maxDepth {
            exceededMaxDepth = true
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        currentDepth = max(0, currentDepth - 1)
    }
}

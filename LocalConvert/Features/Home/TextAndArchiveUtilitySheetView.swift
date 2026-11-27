import SwiftUI
import AppKit
import CoreText
import CoreGraphics
import PDFKit
import UniformTypeIdentifiers
import WebKit
import Darwin

// MARK: - Locked Cross-Worker Controller & Mode Contract

enum TextAndArchiveUtilityMode: String, CaseIterable, Identifiable, Sendable {
    case archive
    case textTools
    case urlToPDF

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .archive:
            return String(localized: "Archive & ZIP")
        case .textTools:
            return String(localized: "Text Tools")
        case .urlToPDF:
            return String(localized: "URL to PDF")
        }
    }

    var systemImage: String {
        switch self {
        case .archive:
            return "archivebox"
        case .textTools:
            return "curlybraces"
        case .urlToPDF:
            return "globe"
        }
    }
}

@MainActor
final class TextAndArchiveUtilityController: ObservableObject {
    static let shared = TextAndArchiveUtilityController()

    @Published var isPresented: Bool = false
    @Published var selectedMode: TextAndArchiveUtilityMode = .archive
    @Published var selectedArchiveURL: URL?

    init(
        isPresented: Bool = false,
        selectedMode: TextAndArchiveUtilityMode = .archive,
        selectedArchiveURL: URL? = nil
    ) {
        self.isPresented = isPresented
        self.selectedMode = selectedMode
        self.selectedArchiveURL = selectedArchiveURL
    }

    func open(mode: TextAndArchiveUtilityMode = .archive, archiveURL: URL? = nil) {
        self.selectedMode = mode
        if let archiveURL {
            self.selectedArchiveURL = archiveURL
        }
        self.isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}

// MARK: - Pure Testable Quick Text Tools Engine (Offline)

enum QuickTextToolsEngine: Sendable {

    enum TextToolKind: String, CaseIterable, Identifiable, Sendable {
        case markdown
        case json
        case base64

        var id: String { rawValue }

        var displayTitle: String {
            switch self {
            case .markdown: return String(localized: "Markdown")
            case .json: return String(localized: "JSON")
            case .base64: return String(localized: "Base64")
            }
        }
    }

    // MARK: JSON Pretty-Print & Minify

    static func formatJSON(_ input: String, prettyPrinted: Bool) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConversionError.invalidInput("Enter JSON text to format.")
        }
        guard let inputData = trimmed.data(using: .utf8) else {
            throw ConversionError.invalidInput("JSON input could not be encoded as UTF-8.")
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: inputData, options: [])
        } catch {
            throw ConversionError.invalidInput("Invalid JSON: \(error.localizedDescription)")
        }

        var writeOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if prettyPrinted {
            writeOptions.insert(.prettyPrinted)
        }

        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            throw ConversionError.invalidInput("JSON root must be an object or array.")
        }

        let outputData = try JSONSerialization.data(withJSONObject: jsonObject, options: writeOptions)
        guard let outputString = String(data: outputData, encoding: .utf8) else {
            throw ConversionError.engineExecutionFailed("Failed to encode formatted JSON as UTF-8.", underlyingError: nil)
        }
        return outputString
    }

    // MARK: Base64 Encode & Decode

    static func encodeBase64(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    static func decodeBase64(_ input: String) throws -> String {
        let cleaned = input
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !cleaned.isEmpty else {
            throw ConversionError.invalidInput("Enter Base64 text to decode.")
        }
        guard let decodedData = Data(base64Encoded: cleaned, options: []) else {
            throw ConversionError.invalidInput("Invalid Base64 string.")
        }
        guard let decodedText = String(data: decodedData, encoding: .utf8) else {
            throw ConversionError.invalidInput("Decoded Base64 bytes are not valid UTF-8 text.")
        }
        return decodedText
    }

    // MARK: Markdown → Styled HTML

    static func markdownToStyledHTML(_ markdown: String, title: String = "Document") -> String {
        let escapedTitle = escapeHTML(title)
        let bodyHTML = renderMarkdownBlocksToHTML(markdown)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            line-height: 1.6;
            color: #1d1f23;
            background: #ffffff;
            max-width: 780px;
            margin: 32px auto;
            padding: 0 24px;
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            line-height: 1.25;
            margin-top: 1.3em;
            margin-bottom: 0.45em;
            color: #111317;
        }
        h1 { font-size: 1.9em; border-bottom: 1px solid #e3e6ec; padding-bottom: 0.25em; }
        h2 { font-size: 1.45em; }
        h3 { font-size: 1.2em; }
        p { margin: 0.65em 0; }
        code {
            font-family: "SF Mono", Menlo, Monaco, monospace;
            font-size: 0.9em;
            background: #f3f5f8;
            padding: 0.15em 0.38em;
            border-radius: 4px;
        }
        pre {
            background: #f3f5f8;
            border: 1px solid #dfe3ea;
            border-radius: 8px;
            padding: 12px 14px;
            overflow-x: auto;
        }
        pre code {
            background: transparent;
            padding: 0;
        }
        blockquote {
            margin: 0.8em 0;
            padding: 0.2em 0 0.2em 14px;
            border-left: 3px solid #3b82f6;
            color: #4b5563;
            background: #f8fafc;
        }
        ul, ol { margin: 0.6em 0; padding-left: 1.6em; }
        li { margin: 0.25em 0; }
        hr { border: none; border-top: 1px solid #dfe3ea; margin: 1.4em 0; }
        a { color: #2563eb; text-decoration: none; }
        a:hover { text-decoration: underline; }
        </style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }

    // MARK: Markdown → Pure Offline Vector PDF

    static func renderMarkdownToPDFData(_ markdown: String, title: String = "Document") throws -> Data {
        let attributed = buildAttributedString(fromMarkdown: markdown, title: title)
        let mutableData = NSMutableData()
        var pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter

        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
            throw ConversionError.engineExecutionFailed("Unable to initialize PDF graphics context.", underlyingError: nil)
        }

        let margin: CGFloat = 48
        let contentRect = CGRect(
            x: margin,
            y: margin,
            width: pageRect.width - margin * 2,
            height: pageRect.height - margin * 2
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var currentLocation = 0
        let totalLength = attributed.length

        repeat {
            pdfContext.beginPDFPage(nil)
            pdfContext.setFillColor(NSColor.white.cgColor)
            pdfContext.fill(pageRect)
            pdfContext.textMatrix = .identity

            let framePath = CGMutablePath()
            framePath.addRect(contentRect)
            let range = CFRange(location: currentLocation, length: 0)
            let frame = CTFramesetterCreateFrame(framesetter, range, framePath, nil)
            CTFrameDraw(frame, pdfContext)

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            pdfContext.endPDFPage()

            if visibleRange.length <= 0 {
                break
            }
            currentLocation += visibleRange.length
        } while currentLocation < totalLength

        pdfContext.closePDF()
        let resultData = mutableData as Data
        guard !resultData.isEmpty else {
            throw ConversionError.engineExecutionFailed("Markdown PDF rendering produced empty output.", underlyingError: nil)
        }
        return resultData
    }

    static func saveOutputData(
        _ data: Data,
        to directory: URL,
        baseName: String,
        extension ext: String,
        policy: ExistingFileHandling = .createUnique
    ) throws -> URL {
        try OutputReservationCoordinator.validateWritableDirectory(directory)
        let tempURL = directory.appendingPathComponent(".LocalConvert-text-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try data.write(to: tempURL, options: .atomic)
        let reserved = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: directory,
            baseName: baseName,
            extension: ext,
            policy: policy
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(reserved) }

        return try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempURL,
            to: reserved,
            policy: policy
        )
    }

    // MARK: Markdown Parser Helpers

    private enum MarkdownListKind {
        case unordered
        case ordered
    }

    private static func renderMarkdownBlocksToHTML(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var htmlParts: [String] = []
        var inCodeBlock = false
        var codeFenceLang = ""
        var codeLines: [String] = []
        var activeList: MarkdownListKind?
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: " ")
            htmlParts.append("<p>\(renderInlineMarkdownToHTML(joined))</p>")
            paragraphBuffer.removeAll()
        }

        func closeList() {
            if let list = activeList {
                htmlParts.append(list == .unordered ? "</ul>" : "</ol>")
                activeList = nil
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                closeList()
                if !inCodeBlock {
                    inCodeBlock = true
                    codeFenceLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLines.removeAll()
                } else {
                    let classAttr = codeFenceLang.isEmpty ? "" : " class=\"language-\(escapeHTML(codeFenceLang))\""
                    htmlParts.append("<pre><code\(classAttr)>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>")
                    inCodeBlock = false
                    codeFenceLang = ""
                    codeLines.removeAll()
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                closeList()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                closeList()
                htmlParts.append("<hr>")
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                closeList()
                htmlParts.append("<h\(heading.level)>\(renderInlineMarkdownToHTML(heading.text))</h\(heading.level)>")
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeList()
                let quoteText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                htmlParts.append("<blockquote><p>\(renderInlineMarkdownToHTML(quoteText))</p></blockquote>")
                continue
            }

            if let unorderedItem = parseUnorderedListItem(trimmed) {
                flushParagraph()
                if activeList != .unordered {
                    closeList()
                    htmlParts.append("<ul>")
                    activeList = .unordered
                }
                htmlParts.append("<li>\(renderInlineMarkdownToHTML(unorderedItem))</li>")
                continue
            }

            if let orderedItem = parseOrderedListItem(trimmed) {
                flushParagraph()
                if activeList != .ordered {
                    closeList()
                    htmlParts.append("<ol>")
                    activeList = .ordered
                }
                htmlParts.append("<li>\(renderInlineMarkdownToHTML(orderedItem))</li>")
                continue
            }

            closeList()
            paragraphBuffer.append(trimmed)
        }

        if inCodeBlock {
            htmlParts.append("<pre><code>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        closeList()

        return htmlParts.joined(separator: "\n")
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var hashes = 0
        for ch in line {
            if ch == "#" {
                hashes += 1
            } else {
                break
            }
        }
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func parseUnorderedListItem(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func parseOrderedListItem(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let numberPart = line[..<dotIndex]
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private static func renderInlineMarkdownToHTML(_ text: String) -> String {
        var result = ""
        var idx = text.startIndex

        while idx < text.endIndex {
            // Inline code `...`
            if text[idx] == "`" {
                let afterTick = text.index(after: idx)
                if let closing = text[afterTick...].firstIndex(of: "`") {
                    let codeText = String(text[afterTick..<closing])
                    result.append("<code>\(escapeHTML(codeText))</code>")
                    idx = text.index(after: closing)
                    continue
                }
            }

            // Link [label](url)
            if text[idx] == "[" {
                if let parsed = parseMarkdownLink(in: text, from: idx) {
                    if let safeHref = sanitizeMarkdownLinkHref(parsed.url) {
                        result.append("<a href=\"\(escapeHTML(safeHref))\">\(escapeHTML(parsed.label))</a>")
                    } else {
                        result.append(escapeHTML(parsed.label))
                    }
                    idx = parsed.nextIndex
                    continue
                }
            }

            // Bold **...** or __...__
            if text[idx...].hasPrefix("**") || text[idx...].hasPrefix("__") {
                let delimiter = String(text[idx..<text.index(idx, offsetBy: 2)])
                let startContent = text.index(idx, offsetBy: 2)
                if let closingRange = text.range(of: delimiter, range: startContent..<text.endIndex) {
                    let inner = String(text[startContent..<closingRange.lowerBound])
                    result.append("<strong>\(renderInlineMarkdownToHTML(inner))</strong>")
                    idx = closingRange.upperBound
                    continue
                }
            }

            // Italic *...* or _..._
            if text[idx] == "*" || text[idx] == "_" {
                let marker = text[idx]
                let startContent = text.index(after: idx)
                if let closing = text[startContent...].firstIndex(of: marker),
                   closing > startContent {
                    let inner = String(text[startContent..<closing])
                    result.append("<em>\(renderInlineMarkdownToHTML(inner))</em>")
                    idx = text.index(after: closing)
                    continue
                }
            }

            result.append(escapeHTML(String(text[idx])))
            idx = text.index(after: idx)
        }

        return result
    }

    private static func parseMarkdownLink(in text: String, from start: String.Index) -> (label: String, url: String, nextIndex: String.Index)? {
        let labelStart = text.index(after: start)
        guard let closeBracket = text[labelStart...].firstIndex(of: "]") else { return nil }
        let openParen = text.index(after: closeBracket)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }
        let urlStart = text.index(after: openParen)
        guard let closeParen = text[urlStart...].firstIndex(of: ")") else { return nil }
        let label = String(text[labelStart..<closeBracket])
        let url = String(text[urlStart..<closeParen]).trimmingCharacters(in: .whitespaces)
        return (label, url, text.index(after: closeParen))
    }

    private static func sanitizeMarkdownLinkHref(_ rawURL: String) -> String? {
        guard let parsed = URL(string: rawURL) else { return nil }
        if let scheme = parsed.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" || scheme == "mailto" else {
                return nil
            }
            return rawURL
        }
        return rawURL.hasPrefix("#") || rawURL.hasPrefix("/") ? rawURL : nil
    }

    private static func escapeHTML(_ raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.count)
        for ch in raw {
            switch ch {
            case "&": escaped.append("&amp;")
            case "<": escaped.append("&lt;")
            case ">": escaped.append("&gt;")
            case "\"": escaped.append("&quot;")
            case "'": escaped.append("&#39;")
            default: escaped.append(ch)
            }
        }
        return escaped
    }

    private static func buildAttributedString(fromMarkdown markdown: String, title: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 11.5)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let bodyColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
        let mutedColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)

        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBuffer: [String] = []

        func appendParagraph(_ text: String, font: NSFont, color: NSColor, spacingAfter: CGFloat = 6, indent: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = spacingAfter
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
            result.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inCodeBlock {
                    inCodeBlock = true
                    codeBuffer.removeAll()
                } else {
                    appendParagraph(codeBuffer.joined(separator: "\n"), font: codeFont, color: bodyColor, spacingAfter: 8, indent: 12)
                    inCodeBlock = false
                    codeBuffer.removeAll()
                }
                continue
            }
            if inCodeBlock {
                codeBuffer.append(line)
                continue
            }
            if trimmed.isEmpty {
                continue
            }
            if let heading = parseHeading(trimmed) {
                let size = max(12.5, 22.0 - CGFloat(heading.level - 1) * 2.0)
                let font = NSFont.systemFont(ofSize: size, weight: .semibold)
                appendParagraph(stripInlineMarkers(heading.text), font: font, color: bodyColor, spacingAfter: 8)
                continue
            }
            if trimmed.hasPrefix(">") {
                let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                appendParagraph(stripInlineMarkers(quote), font: bodyFont, color: mutedColor, spacingAfter: 6, indent: 16)
                continue
            }
            if let item = parseUnorderedListItem(trimmed) {
                appendParagraph("•  " + stripInlineMarkers(item), font: bodyFont, color: bodyColor, spacingAfter: 4, indent: 14)
                continue
            }
            if let item = parseOrderedListItem(trimmed) {
                let prefix = trimmed.split(separator: ".", maxSplits: 1).first.map { "\($0). " } ?? "1. "
                appendParagraph(prefix + stripInlineMarkers(item), font: bodyFont, color: bodyColor, spacingAfter: 4, indent: 14)
                continue
            }
            appendParagraph(stripInlineMarkers(trimmed), font: bodyFont, color: bodyColor, spacingAfter: 6)
        }

        if result.length == 0 {
            appendParagraph(title, font: bodyFont, color: bodyColor)
        }
        return result
    }

    private static func stripInlineMarkers(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        // Simplify [label](url) -> label
        while let openB = cleaned.firstIndex(of: "["),
              let closeB = cleaned[openB...].firstIndex(of: "]") {
            let afterB = cleaned.index(after: closeB)
            guard afterB < cleaned.endIndex, cleaned[afterB] == "(",
                  let closeP = cleaned[afterB...].firstIndex(of: ")") else {
                break
            }
            let label = String(cleaned[cleaned.index(after: openB)..<closeB])
            cleaned.replaceSubrange(openB...closeP, with: label)
        }
        return cleaned
    }
}

// MARK: - URL-to-PDF Validation, Protocol & Coordinator (LC-002 Safe)

enum URLToPDFValidationError: LocalizedError, Equatable, Sendable {
    case emptyURL
    case invalidURL
    case unsupportedScheme(String)
    case missingHost
    case localFileNotFound(URL)
    case symlinkNotAllowed(URL)
    case userConfirmationRequired
    case loadTimedOut(TimeInterval)
    case webContentProcessTerminated

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return String(localized: "Enter a local file:// or web http(s):// URL.")
        case .invalidURL:
            return String(localized: "The provided URL is malformed.")
        case .unsupportedScheme(let scheme):
            return String(localized: "Unsupported URL scheme \"\(scheme)\". Only file://, https://, and http:// are allowed.")
        case .missingHost:
            return String(localized: "Web URLs must include a valid host name.")
        case .localFileNotFound(let url):
            return String(localized: "Local file could not be found: \(url.lastPathComponent)")
        case .symlinkNotAllowed(let url):
            return String(localized: "Symbolic links are not allowed for local URL-to-PDF rendering: \(url.lastPathComponent)")
        case .userConfirmationRequired:
            return String(localized: "Network URLs require explicit user confirmation before loading.")
        case .loadTimedOut(let seconds):
            return String(localized: "Page loading timed out after \(Int(seconds.rounded())) seconds.")
        case .webContentProcessTerminated:
            return String(localized: "Web content process terminated unexpectedly while loading the page.")
        }
    }
}

struct URLToPDFRenderRequest: Sendable, Equatable {
    let url: URL
    let userInitiated: Bool
}

protocol URLToPDFRendering: Sendable {
    func renderPDFData(for request: URLToPDFRenderRequest) async throws -> Data
}

enum URLToPDFValidator: Sendable {

    static func validateAndNormalize(_ rawInput: String, userInitiated: Bool) throws -> URLToPDFRenderRequest {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw URLToPDFValidationError.emptyURL
        }
        guard !trimmed.contains("\0") else {
            throw URLToPDFValidationError.invalidURL
        }
        guard let url = URL(string: trimmed), let rawScheme = url.scheme else {
            throw URLToPDFValidationError.invalidURL
        }

        let scheme = rawScheme.lowercased()
        switch scheme {
        case "file":
            if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
                throw URLToPDFValidationError.invalidURL
            }
            if url.path.components(separatedBy: "/").contains("..") {
                throw URLToPDFValidationError.invalidURL
            }
            let standardizedURL = url.standardizedFileURL
            let stdPath = standardizedURL.path
            try validateNoUserSymlinks(at: stdPath, originalURL: url)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: stdPath, isDirectory: &isDir), !isDir.boolValue else {
                throw URLToPDFValidationError.localFileNotFound(url)
            }
            return URLToPDFRenderRequest(url: standardizedURL, userInitiated: userInitiated)

        case "https", "http":
            guard let host = url.host, !host.isEmpty else {
                throw URLToPDFValidationError.missingHost
            }
            guard userInitiated else {
                throw URLToPDFValidationError.userConfirmationRequired
            }
            return URLToPDFRenderRequest(url: url, userInitiated: true)

        default:
            throw URLToPDFValidationError.unsupportedScheme(scheme)
        }
    }

    private static func validateNoUserSymlinks(at standardizedPath: String, originalURL: URL) throws {
        var targetStat = Darwin.stat()
        guard Darwin.lstat(standardizedPath, &targetStat) == 0 else {
            throw URLToPDFValidationError.localFileNotFound(originalURL)
        }
        let targetType = targetStat.st_mode & S_IFMT
        if targetType == S_IFLNK {
            throw URLToPDFValidationError.symlinkNotAllowed(originalURL)
        }
        guard targetType == S_IFREG else {
            throw URLToPDFValidationError.localFileNotFound(originalURL)
        }

        // Validate every ancestor component for symlinks (allowing only genuine macOS root symlinks /var, /tmp, /etc).
        let components = standardizedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1 else { return }

        var currentPrefix = ""
        for index in 0..<(components.count - 1) {
            currentPrefix += "/" + components[index]
            var compStat = Darwin.stat()
            guard Darwin.lstat(currentPrefix, &compStat) == 0 else {
                throw URLToPDFValidationError.localFileNotFound(originalURL)
            }
            if (compStat.st_mode & S_IFMT) == S_IFLNK {
                if index == 0, isGenuineMacOSRootSymlink(path: currentPrefix, statInfo: compStat) {
                    continue
                }
                throw URLToPDFValidationError.symlinkNotAllowed(originalURL)
            }
        }
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

struct LiveWebKitURLToPDFRenderer: URLToPDFRendering {
    let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 20.0) {
        self.timeoutSeconds = timeoutSeconds
    }

    func renderPDFData(for request: URLToPDFRenderRequest) async throws -> Data {
        try await Self.renderOnMainActor(request: request, timeoutSeconds: timeoutSeconds)
    }

    @MainActor
    private static func renderOnMainActor(request: URLToPDFRenderRequest, timeoutSeconds: TimeInterval) async throws -> Data {
        let session = WebKitPDFRenderSession(timeoutSeconds: timeoutSeconds)
        return try await session.render(request: request)
    }
}

@MainActor
final class WebKitPDFRenderSession: NSObject, WKNavigationDelegate {
    private let timeoutSeconds: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var webView: WKWebView?
    private(set) var resumeCountForTesting: Int = 0

    init(timeoutSeconds: TimeInterval = 20.0) {
        self.timeoutSeconds = timeoutSeconds
        super.init()
    }

    func render(request: URLToPDFRenderRequest) async throws -> Data {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        defer {
            timeoutTask?.cancel()
            timeoutTask = nil
            wv.stopLoading()
            wv.navigationDelegate = nil
            self.webView = nil
        }

        try await waitForNavigation {
            if request.url.isFileURL {
                wv.loadFileURL(request.url, allowingReadAccessTo: request.url)
            } else {
                guard request.userInitiated else {
                    self.finishNavigation(.failure(URLToPDFValidationError.userConfirmationRequired))
                    return
                }
                wv.load(URLRequest(url: request.url))
            }
        }

        try Task.checkCancellation()

        let pdfConfig = WKPDFConfiguration()
        return try await withCheckedThrowingContinuation { cont in
            wv.createPDF(configuration: pdfConfig) { result in
                cont.resume(with: result)
            }
        }
    }

    func waitForNavigation(startLoad: @MainActor () -> Void) async throws {
        defer {
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                if Task.isCancelled {
                    self.finishNavigation(.failure(CancellationError()))
                    return
                }
                self.startTimeoutTask()
                startLoad()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelNavigation()
            }
        }
    }

    func finishNavigation(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let cont = continuation else { return }
        continuation = nil
        resumeCountForTesting += 1
        cont.resume(with: result)
    }

    private func startTimeoutTask() {
        timeoutTask?.cancel()
        let timeout = timeoutSeconds
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, timeout)))
            guard !Task.isCancelled, let self else { return }
            self.finishNavigation(.failure(URLToPDFValidationError.loadTimedOut(timeout)))
        }
    }

    private func cancelNavigation() {
        webView?.stopLoading()
        finishNavigation(.failure(CancellationError()))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(URLToPDFValidationError.webContentProcessTerminated))
    }
}

enum URLToPDFExportCoordinator: Sendable {

    @discardableResult
    static func exportPDF(
        from rawURLString: String,
        userInitiated: Bool,
        outputDirectory: URL,
        suggestedBaseName: String? = nil,
        policy: ExistingFileHandling = .createUnique,
        renderer: any URLToPDFRendering = LiveWebKitURLToPDFRenderer()
    ) async throws -> URL {
        let request = try URLToPDFValidator.validateAndNormalize(rawURLString, userInitiated: userInitiated)
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        let pdfData = try await renderer.renderPDFData(for: request)
        guard pdfData.starts(with: Data("%PDF-".utf8)) else {
            throw ConversionError.engineExecutionFailed(
                "URL renderer did not produce valid PDF data.",
                underlyingError: nil
            )
        }

        let baseName: String = {
            if let suggestedBaseName, !suggestedBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return suggestedBaseName
            }
            if request.url.isFileURL {
                let stem = FileFormat.baseNameByStrippingExtension(from: request.url)
                return stem.isEmpty ? "WebPage" : stem
            }
            return request.url.host?.replacingOccurrences(of: ":", with: "_") ?? "WebPage"
        }()

        return try QuickTextToolsEngine.saveOutputData(
            pdfData,
            to: outputDirectory,
            baseName: baseName,
            extension: "pdf",
            policy: policy
        )
    }
}

// MARK: - Multi-Mode Utility Sheet View (Fits 820x580 LC-019)

struct TextAndArchiveUtilitySheetView: View {
    @ObservedObject var controller: TextAndArchiveUtilityController

    enum ArchiveSubMode: String, CaseIterable, Identifiable {
        case inspect
        case createEncryptedZIP

        var id: String { rawValue }
        var title: String {
            switch self {
            case .inspect: return String(localized: "Inspect & Extract")
            case .createEncryptedZIP: return String(localized: "Encrypted ZIP")
            }
        }
    }

    // Archive Inspector State
    @State private var archiveSubMode: ArchiveSubMode = .inspect
    @State private var archiveURL: URL? = nil
    @State private var inspectionResult: ArchiveInspectionResult? = nil
    @State private var archiveSearchText: String = ""
    @State private var selectedEntryPath: String? = nil
    @State private var extractPassword: String = ""
    @State private var isLoadingArchive: Bool = false

    // Encrypted ZIP Maker State
    @State private var zipInputURLs: [URL] = []
    @State private var zipArchiveName: String = "SecureArchive"
    @State private var zipPassword: String = ""
    @State private var zipConfirmPassword: String = ""
    @State private var showZipPassword: Bool = false
    @State private var isCreatingZip: Bool = false

    // Text Tools State
    @State private var selectedTextTool: QuickTextToolsEngine.TextToolKind = .markdown
    @State private var markdownInput: String = "# LocalConvert Notes\n\n- **100% Offline** processing\n- Clean HTML & PDF export\n\n`hello@local`"
    @State private var jsonInput: String = "{\n  \"app\": \"LocalConvert\",\n  \"offline\": true\n}"
    @State private var jsonOutput: String = ""
    @State private var base64Input: String = "LocalConvert offline text tool"
    @State private var base64Output: String = ""

    // URL to PDF State
    @State private var urlInputString: String = "file://"
    @State private var isConvertingURL: Bool = false

    // Feedback State
    @State private var statusBanner: String? = nil
    @State private var lastSavedURL: URL? = nil
    @State private var errorMessage: String? = nil

    init(controller: TextAndArchiveUtilityController = .shared) {
        self.controller = controller
    }

    private var filteredEntries: [ArchiveEntry] {
        guard let entries = inspectionResult?.entries else { return [] }
        let q = archiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.path.localizedCaseInsensitiveContains(q) }
    }

    private var selectedArchiveEntry: ArchiveEntry? {
        guard let selectedEntryPath else { return nil }
        return inspectionResult?.entries.first(where: { $0.path == selectedEntryPath })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            AppDivider()

            Group {
                switch controller.selectedMode {
                case .archive:
                    archiveTabContent
                case .textTools:
                    textToolsTabContent
                case .urlToPDF:
                    urlToPDFTabContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                AppInfoBanner(
                    style: .error,
                    message: errorMessage,
                    onDismiss: { self.errorMessage = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.sm)
            } else if let statusBanner {
                AppInfoBanner(
                    style: .success,
                    message: statusBanner,
                    actionTitle: lastSavedURL != nil ? String(localized: "Reveal") : nil,
                    onAction: lastSavedURL.map { url in
                        { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    },
                    onDismiss: {
                        self.statusBanner = nil
                        self.lastSavedURL = nil
                    }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.sm)
            }

            AppDivider()
            footerBar
        }
        .frame(minWidth: 660, idealWidth: 760, maxWidth: 800, minHeight: 460, idealHeight: 520, maxHeight: 560)
        .appWorkspaceSurface()
        .task(id: controller.selectedArchiveURL) {
            if let incoming = controller.selectedArchiveURL, incoming != archiveURL {
                archiveURL = incoming
                archiveSubMode = .inspect
                await loadArchive(incoming)
            }
        }
        .onExitCommand {
            controller.dismiss()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("textArchiveUtility.sheet")
    }

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Colors.accentTint)
                    .frame(width: 30, height: 30)
                Image(systemName: controller.selectedMode.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Archive & Text Utilities")
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)
                Text("Inspect archives, create encrypted ZIPs, format text, or export URLs to PDF")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Picker("Mode", selection: $controller.selectedMode) {
                ForEach(TextAndArchiveUtilityMode.allCases) { mode in
                    Text(mode.displayTitle).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 290)
            .accessibilityIdentifier("textArchiveUtility.modePicker")

            Button("Done") {
                controller.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("textArchiveUtility.doneButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var footerBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Label("100% On-Device", systemImage: "lock.shield")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if controller.selectedMode == .archive && archiveSubMode == .inspect,
               let result = inspectionResult {
                Text("\(result.entries.count) items · \(ByteCountFormatter.string(fromByteCount: result.totalUncompressedBytes, countStyle: .file))")
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - Tab 1: Archive Inspector & Encrypted ZIP

    private var archiveTabContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Picker("Archive Action", selection: $archiveSubMode) {
                    ForEach(ArchiveSubMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Spacer(minLength: 0)

                if archiveSubMode == .inspect {
                    Button {
                        pickArchiveFile()
                    } label: {
                        Label("Choose Archive...", systemImage: "doc.zipper")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        pickZipSourceItems()
                    } label: {
                        Label("Add Files...", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !zipInputURLs.isEmpty {
                        Button("Clear") {
                            zipInputURLs.removeAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if archiveSubMode == .inspect {
                archiveInspectorPane
            } else {
                encryptedZipMakerPane
            }
        }
        .padding(AppTheme.Spacing.lg)
    }

    private var archiveInspectorPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(archiveURL?.lastPathComponent ?? String(localized: "No archive selected"))
                    .font(AppTheme.Typography.cardTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if inspectionResult?.hasEncryptedEntries == true {
                    AppStatusBadge(text: String(localized: "Encrypted"), tint: AppTheme.Colors.warning, style: .rounded)
                }

                Spacer(minLength: 0)

                TextField("Filter entries...", text: $archiveSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
            }

            if isLoadingArchive {
                AppLoadingStateView(message: String(localized: "Inspecting archive entries..."))
            } else if let result = inspectionResult {
                if result.entries.isEmpty {
                    AppEmptyStateView(
                        icon: "archivebox",
                        title: String(localized: "Empty Archive"),
                        subtitle: String(localized: "This archive does not contain any inspectable entries.")
                    )
                } else {
                    List(filteredEntries, selection: $selectedEntryPath) { entry in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                                .foregroundStyle(entry.isDirectory ? AppTheme.Colors.accent : .secondary)
                                .frame(width: 18)

                            Text(entry.path)
                                .font(AppTheme.Typography.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: AppTheme.Spacing.sm)

                            if entry.isEncrypted {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.warning)
                            }

                            Text(entry.formattedSize)
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(entry.path)
                    }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )

                    HStack(spacing: AppTheme.Spacing.sm) {
                        if result.hasEncryptedEntries {
                            SecureField("Archive password", text: $extractPassword)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }

                        Spacer(minLength: 0)

                        Button {
                            Task { await extractSelectedEntry() }
                        } label: {
                            Label("Extract Selected File...", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedArchiveEntry == nil || selectedArchiveEntry?.isDirectory == true)
                    }
                }
            } else {
                AppEmptyStateView(
                    icon: "doc.zipper",
                    title: String(localized: "Inspect Archive Contents"),
                    subtitle: String(localized: "Select a .zip, .tar, or .tgz archive to browse entries and extract single files safely."),
                    primaryButtonTitle: String(localized: "Choose Archive..."),
                    primaryButtonIcon: "folder",
                    onPrimaryAction: pickArchiveFile
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var encryptedZipMakerPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: String(localized: "Files to Encrypt"), icon: "doc.on.doc") {
                if zipInputURLs.isEmpty {
                    HStack {
                        Text("No files selected yet.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Files...") {
                            pickZipSourceItems()
                        }
                        .controlSize(.small)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            ForEach(zipInputURLs, id: \.self) { url in
                                HStack {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text(url.lastPathComponent)
                                        .font(AppTheme.Typography.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        zipInputURLs.removeAll { $0 == url }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }

            AppCard(title: String(localized: "Archive Protection"), icon: "lock.shield") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Archive Name")
                            .font(AppTheme.Typography.caption)
                            .frame(width: 110, alignment: .leading)
                        TextField("SecureArchive", text: $zipArchiveName)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Password")
                            .font(AppTheme.Typography.caption)
                            .frame(width: 110, alignment: .leading)
                        if showZipPassword {
                            TextField("Password", text: $zipPassword)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Password", text: $zipPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            showZipPassword.toggle()
                        } label: {
                            Image(systemName: showZipPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Confirm Password")
                            .font(AppTheme.Typography.caption)
                            .frame(width: 110, alignment: .leading)
                        if showZipPassword {
                            TextField("Confirm Password", text: $zipConfirmPassword)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Confirm Password", text: $zipConfirmPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    Task { await createEncryptedZipAction() }
                } label: {
                    if isCreatingZip {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Create Encrypted ZIP...", systemImage: "lock.doc")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(zipInputURLs.isEmpty || zipPassword.isEmpty || isCreatingZip)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Tab 2: Quick Text Tools

    private var textToolsTabContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Picker("Text Tool", selection: $selectedTextTool) {
                    ForEach(QuickTextToolsEngine.TextToolKind.allCases) { kind in
                        Text(kind.displayTitle).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Spacer()
            }

            switch selectedTextTool {
            case .markdown:
                markdownToolPane
            case .json:
                jsonToolPane
            case .base64:
                base64ToolPane
            }
        }
        .padding(AppTheme.Spacing.lg)
    }

    private var markdownToolPane: some View {
        let htmlPreview = QuickTextToolsEngine.markdownToStyledHTML(markdownInput)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Markdown Input")
                        .font(AppTheme.Typography.cardTitle)
                    TextEditor(text: $markdownInput)
                        .font(.system(.caption, design: .monospaced))
                        .padding(AppTheme.Spacing.xs)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Styled HTML Output")
                        .font(AppTheme.Typography.cardTitle)
                    ScrollView {
                        Text(htmlPreview)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppTheme.Spacing.sm)
                    }
                    .background(AppTheme.Colors.elevatedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Spacer()
                Button("Copy HTML") {
                    copyStringToPasteboard(htmlPreview)
                    statusBanner = String(localized: "Styled HTML copied to clipboard.")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Save HTML...") {
                    saveMarkdownHTML(htmlPreview)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Save PDF...") {
                    saveMarkdownPDF()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var jsonToolPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("JSON Input")
                        .font(AppTheme.Typography.cardTitle)
                    TextEditor(text: $jsonInput)
                        .font(.system(.caption, design: .monospaced))
                        .padding(AppTheme.Spacing.xs)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Formatted Output")
                        .font(AppTheme.Typography.cardTitle)
                    TextEditor(text: .constant(jsonOutput))
                        .font(.system(.caption, design: .monospaced))
                        .padding(AppTheme.Spacing.xs)
                        .background(AppTheme.Colors.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                        )
                }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Pretty-Print") {
                    runJSONFormat(pretty: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Minify") {
                    runJSONFormat(pretty: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Copy Output") {
                    copyStringToPasteboard(jsonOutput)
                    statusBanner = String(localized: "JSON output copied to clipboard.")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(jsonOutput.isEmpty)
            }
        }
    }

    private var base64ToolPane: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Input")
                        .font(AppTheme.Typography.cardTitle)
                    TextEditor(text: $base64Input)
                        .font(.system(.caption, design: .monospaced))
                        .padding(AppTheme.Spacing.xs)
                        .background(AppTheme.Colors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Output")
                        .font(AppTheme.Typography.cardTitle)
                    TextEditor(text: .constant(base64Output))
                        .font(.system(.caption, design: .monospaced))
                        .padding(AppTheme.Spacing.xs)
                        .background(AppTheme.Colors.elevatedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                        )
                }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Encode UTF-8") {
                    errorMessage = nil
                    base64Output = QuickTextToolsEngine.encodeBase64(base64Input)
                    statusBanner = String(localized: "Encoded text to Base64.")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Decode Base64") {
                    errorMessage = nil
                    do {
                        base64Output = try QuickTextToolsEngine.decodeBase64(base64Input)
                        statusBanner = String(localized: "Decoded Base64 to UTF-8 text.")
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Copy Output") {
                    copyStringToPasteboard(base64Output)
                    statusBanner = String(localized: "Base64 result copied to clipboard.")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(base64Output.isEmpty)
            }
        }
    }

    // MARK: - Tab 3: URL to PDF

    private var urlToPDFTabContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            AppCard(title: String(localized: "Convert Local HTML or Web Page to PDF"), icon: "globe") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Enter a local file:// HTML path or a web https:// URL. Network requests only happen when you click Convert.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: AppTheme.Spacing.sm) {
                        TextField("https://example.com or file:///path/to/page.html", text: $urlInputString)
                            .textFieldStyle(.roundedBorder)

                        Button("Choose HTML...") {
                            pickLocalHTMLFile()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    HStack {
                        Spacer()
                        Button {
                            Task { await convertURLToPDFAction() }
                        } label: {
                            if isConvertingURL {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Convert URL to PDF...", systemImage: "doc.richtext")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(urlInputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConvertingURL)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.lg)
    }

    // MARK: - Actions

    private func pickArchiveFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .zip,
            UTType(filenameExtension: "tar") ?? .data,
            UTType(filenameExtension: "tgz") ?? .gzip,
            .gzip
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveURL = url
        controller.selectedArchiveURL = url
        Task { await loadArchive(url) }
    }

    private func loadArchive(_ url: URL) async {
        errorMessage = nil
        statusBanner = nil
        lastSavedURL = nil
        isLoadingArchive = true
        defer { isLoadingArchive = false }

        do {
            let result = try await ArchiveInspectorEngine.listEntries(in: url)
            inspectionResult = result
            selectedEntryPath = result.regularFileEntries.first?.path ?? result.entries.first?.path
        } catch {
            inspectionResult = nil
            selectedEntryPath = nil
            errorMessage = error.localizedDescription
        }
    }

    private func extractSelectedEntry() async {
        guard let archiveURL, let entry = selectedArchiveEntry else { return }
        errorMessage = nil
        statusBanner = nil
        lastSavedURL = nil

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = archiveURL.deletingLastPathComponent()
        panel.prompt = String(localized: "Extract Here")
        guard panel.runModal() == .OK, let destDir = panel.url else { return }

        do {
            let extracted = try await ArchiveInspectorEngine.extractEntry(
                entry.path,
                from: archiveURL,
                to: destDir,
                password: extractPassword.isEmpty ? nil : extractPassword
            )
            lastSavedURL = extracted
            statusBanner = String(localized: "Extracted \"\(extracted.lastPathComponent)\".")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickZipSourceItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !zipInputURLs.contains(url) {
            zipInputURLs.append(url)
        }
    }

    private func createEncryptedZipAction() async {
        errorMessage = nil
        statusBanner = nil
        lastSavedURL = nil

        guard zipPassword == zipConfirmPassword else {
            errorMessage = String(localized: "Passwords do not match.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Save Here")
        guard panel.runModal() == .OK, let destDir = panel.url else { return }

        isCreatingZip = true
        defer { isCreatingZip = false }

        do {
            let outputURL = try await ArchiveInspectorEngine.createEncryptedZip(
                inputs: zipInputURLs,
                outputDirectory: destDir,
                archiveBaseName: zipArchiveName,
                password: zipPassword
            )
            lastSavedURL = outputURL
            statusBanner = String(localized: "Created encrypted ZIP \"\(outputURL.lastPathComponent)\".")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runJSONFormat(pretty: Bool) {
        errorMessage = nil
        statusBanner = nil
        lastSavedURL = nil
        do {
            jsonOutput = try QuickTextToolsEngine.formatJSON(jsonInput, prettyPrinted: pretty)
            statusBanner = pretty
                ? String(localized: "JSON formatted.")
                : String(localized: "JSON minified.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveMarkdownHTML(_ html: String) {
        errorMessage = nil
        statusBanner = nil
        lastSavedURL = nil
        guard let dir = pickDirectory(prompt: String(localized: "Save HTML")) else { return }
        do {
            let saved = try QuickTextToolsEngine.saveOutputData(
                Data(html.utf8),
                to: dir,
                baseName: "MarkdownNotes",
                extension: "html"
            )
            lastSavedURL = saved
            statusBanner = String(localized: "Saved HTML to \"\(saved.lastPathComponent)\".")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveMarkdownPDF() {
        errorMessage = nil
        statusBanner = nil
        lastSavedURL = nil
        guard let dir = pickDirectory(prompt: String(localized: "Save PDF")) else { return }
        do {
            let pdfData = try QuickTextToolsEngine.renderMarkdownToPDFData(markdownInput)
            let saved = try QuickTextToolsEngine.saveOutputData(
                pdfData,
                to: dir,
                baseName: "MarkdownNotes",
                extension: "pdf"
            )
            lastSavedURL = saved
            statusBanner = String(localized: "Saved PDF to \"\(saved.lastPathComponent)\".")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickLocalHTMLFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        urlInputString = url.absoluteString
    }

    private func convertURLToPDFAction() async {
        errorMessage = nil
        statusBanner = nil
        lastSavedURL = nil
        guard let dir = pickDirectory(prompt: String(localized: "Save PDF")) else { return }

        isConvertingURL = true
        defer { isConvertingURL = false }

        do {
            let saved = try await URLToPDFExportCoordinator.exportPDF(
                from: urlInputString,
                userInitiated: true,
                outputDirectory: dir
            )
            lastSavedURL = saved
            statusBanner = String(localized: "Saved PDF to \"\(saved.lastPathComponent)\".")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pickDirectory(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func copyStringToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

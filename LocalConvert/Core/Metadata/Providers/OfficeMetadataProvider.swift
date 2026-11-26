import Foundation
import os.log

final class OfficeMetadataProvider: MetadataProvider, @unchecked Sendable {
    
    let providerName = "OfficeMetadataProvider"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "OfficeMetadataProvider")
    
    var supportedFormats: Set<FileFormat> {
        [.docx, .xlsx, .pptx]
    }
    
    init() {}
    
    // MARK: - Capabilities
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        guard supportedFormats.contains(format) else {
            return .unsupported(for: format)
        }
        
        let fields: [MetadataFieldDescriptor] = [
            MetadataFieldDescriptor(id: "title", name: "Title", section: .basic, valueType: .string, placeholder: "Document Title"),
            MetadataFieldDescriptor(id: "creator", name: "Author / Creator", section: .basic, valueType: .string, placeholder: "Author Name"),
            MetadataFieldDescriptor(id: "subject", name: "Subject", section: .basic, valueType: .string, placeholder: "Subject"),
            MetadataFieldDescriptor(id: "description", name: "Description", section: .description, valueType: .string, placeholder: "Document Summary"),
            MetadataFieldDescriptor(id: "keywords", name: "Keywords", section: .basic, valueType: .string, placeholder: "Keywords / Tags"),
            MetadataFieldDescriptor(id: "lastModifiedBy", name: "Last Modified By", section: .rights, valueType: .string, placeholder: "Modifier Name"),
            MetadataFieldDescriptor(id: "category", name: "Category", section: .basic, valueType: .string, placeholder: "Document Category"),
            
            // Technical details (Read-Only)
            MetadataFieldDescriptor(id: "packageFormat", name: "Package Standard", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false)
        ]
        
        return MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: true,
            canRemoveGPS: false,
            canRemoveArtwork: false,
            canRemoveAll: true,
            writeStrategy: .openXMLCoreXML,
            fields: fields
        )
    }
    
    // MARK: - Read
    
    func readMetadata(from url: URL) async throws -> MetadataDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url)
        }
        
        let format = FileDetector.detectFormat(url: url) ?? .docx
        var doc = MetadataDocument(format: format, fileURL: url)
        doc.technical["packageFormat"] = "OpenXML Package (ECMA-376)"
        
        // Extract docProps/core.xml using unzip -p
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "docProps/core.xml"]
        
        do {
            let output = try await AsyncProcessRunner.run(process)
            if output.terminationStatus == 0,
               let xmlStr = String(data: output.stdout, encoding: .utf8) {
                parseCorePropertiesXML(xmlStr, into: &doc)
            }
        } catch {
            logger.warning("Failed to extract OpenXML core properties: \(error.localizedDescription, privacy: .public)")
        }
        
        return doc
    }
    
    func read(from url: URL, format: FileFormat) async throws -> MetadataDocument {
        try await readMetadata(from: url)
    }
    
    // MARK: - Write
    
    @discardableResult
    func write(_ metadata: MetadataDocument, to url: URL) async throws -> URL {
        let res = try await writeMetadata(metadata, to: url)
        return res.outputURL
    }
    
    func writeMetadata(
        _ metadata: MetadataDocument,
        to url: URL
    ) async throws -> MetadataWriteResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        try await SafeMetadataWriter.performSafeWrite(on: url) { tempURL in
            try await self.executeUpdate(metadata: metadata, tempURL: tempURL)
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return MetadataWriteResult(outputURL: url, duration: duration)
    }
    
    private func executeUpdate(metadata: MetadataDocument, tempURL: URL) async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-OfficeMeta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        
        let docPropsDir = workDir.appendingPathComponent("docProps")
        try FileManager.default.createDirectory(at: docPropsDir, withIntermediateDirectories: true)
        
        let stripAll = metadata.isStrippedAll || metadata.isEditableMetadataEmpty
        var zipEntries: [String] = ["docProps/core.xml"]

        // Build new docProps/core.xml
        let coreXML = generateCorePropertiesXML(metadata: metadata, stripAll: stripAll)
        let coreURL = docPropsDir.appendingPathComponent("core.xml")
        try coreXML.write(to: coreURL, atomically: true, encoding: .utf8)

        if stripAll {
            let listProc = Process()
            listProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            listProc.arguments = ["-Z1", tempURL.path]
            let listOut = try? await AsyncProcessRunner.run(listProc)
            let existingEntries = Set((listOut.flatMap { String(data: $0.stdout, encoding: .utf8) } ?? "")
                .components(separatedBy: .newlines))

            if existingEntries.contains("docProps/app.xml") {
                let cleanAppXML = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"/>
                """
                try cleanAppXML.write(to: docPropsDir.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)
                zipEntries.append("docProps/app.xml")
            }
            if existingEntries.contains("docProps/custom.xml") {
                let cleanCustomXML = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"/>
                """
                try cleanCustomXML.write(to: docPropsDir.appendingPathComponent("custom.xml"), atomically: true, encoding: .utf8)
                zipEntries.append("docProps/custom.xml")
            }
        }
        
        // Update zip archive
        let process = Process()
        process.currentDirectoryURL = workDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = [tempURL.path] + zipEntries
        
        let result = try await AsyncProcessRunner.run(process)
        guard result.terminationStatus == 0 else {
            let errStr = String(data: result.stderr, encoding: .utf8)
            throw MetadataError.writeFailure("Failed to update OpenXML zip archive", underlying: errStr)
        }
    }
    
    private func parseCorePropertiesXML(_ xml: String, into doc: inout MetadataDocument) {
        doc.common.title = extractTagContent(from: xml, tag: "dc:title")
        let creator = extractTagContent(from: xml, tag: "dc:creator")
        doc.common.creator = creator
        doc.common.artist = creator
        
        if let sub = extractTagContent(from: xml, tag: "dc:subject") {
            doc.common.subject = sub
            doc.customFields["subject"] = .string(sub)
        }
        if let desc = extractTagContent(from: xml, tag: "dc:description") {
            doc.common.description = desc
            doc.customFields["description"] = .string(desc)
        }
        if let kw = extractTagContent(from: xml, tag: "cp:keywords") {
            doc.common.keywords = kw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            doc.customFields["keywords"] = .string(kw)
        }
        if let modBy = extractTagContent(from: xml, tag: "cp:lastModifiedBy") { doc.customFields["lastModifiedBy"] = .string(modBy) }
        if let cat = extractTagContent(from: xml, tag: "cp:category") { doc.customFields["category"] = .string(cat) }
    }
    
    private func extractTagContent(from xml: String, tag: String) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escapedTag)(?:\\s[^>]*)?>([\\s\\S]*?)</\(escapedTag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        let raw = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : unescapeXML(raw)
    }
    
    private func generateCorePropertiesXML(metadata: MetadataDocument, stripAll: Bool) -> String {
        if stripAll {
            return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            </cp:coreProperties>
            """
        }

        let title = metadata.common.title ?? ""
        let creator = metadata.common.creator ?? metadata.common.artist ?? ""
        let subject = metadata.common.subject ?? metadata.customFields["subject"]?.stringValue ?? ""
        let desc = metadata.common.description ?? metadata.customFields["description"]?.stringValue ?? ""
        let keywords = metadata.common.keywords?.joined(separator: ", ") ?? metadata.customFields["keywords"]?.stringValue ?? ""
        let lastModBy = metadata.customFields["lastModifiedBy"]?.stringValue ?? ""
        let category = metadata.customFields["category"]?.stringValue ?? ""
        
        let now = ISO8601DateFormatter().string(from: Date())
        
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <dc:title>\(escapeXML(title))</dc:title>
            <dc:subject>\(escapeXML(subject))</dc:subject>
            <dc:creator>\(escapeXML(creator))</dc:creator>
            <cp:keywords>\(escapeXML(keywords))</cp:keywords>
            <dc:description>\(escapeXML(desc))</dc:description>
            <cp:lastModifiedBy>\(escapeXML(lastModBy))</cp:lastModifiedBy>
            <cp:category>\(escapeXML(category))</cp:category>
            <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
    }
    
    private func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func unescapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&lt;", with: "<")
           .replacingOccurrences(of: "&gt;", with: ">")
           .replacingOccurrences(of: "&quot;", with: "\"")
           .replacingOccurrences(of: "&apos;", with: "'")
           .replacingOccurrences(of: "&amp;", with: "&")
    }
}

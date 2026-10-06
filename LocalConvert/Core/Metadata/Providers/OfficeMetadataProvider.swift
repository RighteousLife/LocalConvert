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
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let xmlStr = String(data: data, encoding: .utf8) {
                    parseCorePropertiesXML(xmlStr, into: &doc)
                }
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
            try self.executeUpdate(metadata: metadata, tempURL: tempURL)
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return MetadataWriteResult(outputURL: url, duration: duration)
    }
    
    private func executeUpdate(metadata: MetadataDocument, tempURL: URL) throws {
        let parent = tempURL.deletingLastPathComponent()
        let workDir = parent.appendingPathComponent("office-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        
        let docPropsDir = workDir.appendingPathComponent("docProps")
        try FileManager.default.createDirectory(at: docPropsDir, withIntermediateDirectories: true)
        
        // Build new docProps/core.xml
        let coreXML = generateCorePropertiesXML(metadata: metadata)
        let coreURL = docPropsDir.appendingPathComponent("core.xml")
        try coreXML.write(to: coreURL, atomically: true, encoding: .utf8)
        
        // Update zip archive using /usr/bin/zip -u
        let process = Process()
        process.currentDirectoryURL = workDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = [tempURL.path, "docProps/core.xml"]
        
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)
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
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let startRange = xml.range(of: open),
              let endRange = xml.range(of: close, range: startRange.upperBound..<xml.endIndex) else {
            return nil
        }
        let content = xml[startRange.upperBound..<endRange.lowerBound]
        return String(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func generateCorePropertiesXML(metadata: MetadataDocument) -> String {
        let title = metadata.common.title ?? ""
        let creator = metadata.common.creator ?? metadata.common.artist ?? ""
        let subject = metadata.common.subject ?? metadata.customFields["subject"]?.stringValue ?? ""
        let desc = metadata.common.description ?? metadata.customFields["description"]?.stringValue ?? ""
        let keywords = metadata.common.keywords?.joined(separator: ", ") ?? metadata.customFields["keywords"]?.stringValue ?? ""
        let lastModBy = metadata.customFields["lastModifiedBy"]?.stringValue ?? "LocalConvert"
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
}

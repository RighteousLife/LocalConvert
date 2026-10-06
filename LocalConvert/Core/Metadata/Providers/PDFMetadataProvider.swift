import Foundation
import PDFKit
import os.log

final class PDFMetadataProvider: MetadataProvider, @unchecked Sendable {
    
    let providerName = "PDFMetadataProvider"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "PDFMetadataProvider")
    
    var supportedFormats: Set<FileFormat> {
        [.pdf]
    }
    
    init() {}
    
    // MARK: - Capabilities
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        guard format == .pdf else { return .unsupported(for: format) }
        
        let fields: [MetadataFieldDescriptor] = [
            MetadataFieldDescriptor(id: "title", name: "Title", section: .basic, valueType: .string, placeholder: "Document Title"),
            MetadataFieldDescriptor(id: "author", name: "Author", section: .basic, valueType: .string, placeholder: "Author Name"),
            MetadataFieldDescriptor(id: "subject", name: "Subject", section: .basic, valueType: .string, placeholder: "Subject / Topic"),
            MetadataFieldDescriptor(id: "keywords", name: "Keywords", section: .basic, valueType: .string, placeholder: "Comma-separated keywords"),
            MetadataFieldDescriptor(id: "creator", name: "Creator Tool", section: .rights, valueType: .string, placeholder: "Application Name"),
            MetadataFieldDescriptor(id: "producer", name: "PDF Producer", section: .rights, valueType: .string, placeholder: "PDF Producer"),
            
            // Technical metadata (Read-Only)
            MetadataFieldDescriptor(id: "pageCount", name: "Page Count", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "pageSize", name: "Page Size", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "isEncrypted", name: "Encrypted", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false)
        ]
        
        return MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: true,
            canRemoveGPS: false,
            canRemoveArtwork: false,
            canRemoveAll: true,
            writeStrategy: .pdfDocumentInPlace,
            fields: fields
        )
    }
    
    // MARK: - Read
    
    func readMetadata(from url: URL) async throws -> MetadataDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url)
        }
        
        guard let doc = PDFDocument(url: url) else {
            throw MetadataError.corruptInput("Could not open PDF document at \(url.lastPathComponent)")
        }
        
        var metaDoc = MetadataDocument(format: .pdf, fileURL: url)
        let attrs = doc.documentAttributes ?? [:]
        
        if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String { metaDoc.common.title = title }
        if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String {
            metaDoc.common.author = author
            metaDoc.common.artist = author
        }
        if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String { metaDoc.common.subject = subject }
        if let keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            metaDoc.common.keywords = keywords
            metaDoc.customFields["keywords"] = .string(keywords.joined(separator: ", "))
        } else if let kwStr = attrs[PDFDocumentAttribute.keywordsAttribute] as? String {
            metaDoc.common.keywords = kwStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            metaDoc.customFields["keywords"] = .string(kwStr)
        }
        if let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String { metaDoc.common.creator = creator }
        if let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String { metaDoc.customFields["producer"] = .string(producer) }
        if let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date {
            let f = DateFormatter()
            f.dateFormat = "yyyy"
            if let yr = Int(f.string(from: creationDate)) {
                metaDoc.common.year = yr
            }
        }
        
        // Technical Details
        metaDoc.technical["pageCount"] = "\(doc.pageCount) page(s)"
        metaDoc.technical["isEncrypted"] = doc.isEncrypted ? "Yes" : "No"
        if let firstPage = doc.page(at: 0) {
            let bounds = firstPage.bounds(for: .mediaBox)
            metaDoc.technical["pageSize"] = "\(Int(bounds.width)) × \(Int(bounds.height)) pt"
        }
        
        return metaDoc
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
            guard let doc = PDFDocument(url: tempURL) else {
                throw MetadataError.corruptInput("Failed to load PDF for writing metadata")
            }
            
            var attrs = doc.documentAttributes ?? [:]
            
            if let title = metadata.common.title {
                attrs[PDFDocumentAttribute.titleAttribute] = title
            } else {
                attrs.removeValue(forKey: PDFDocumentAttribute.titleAttribute)
            }
            
            let author = metadata.common.author ?? metadata.common.artist
            if let author = author {
                attrs[PDFDocumentAttribute.authorAttribute] = author
            } else {
                attrs.removeValue(forKey: PDFDocumentAttribute.authorAttribute)
            }
            
            if let subject = metadata.common.subject ?? metadata.customFields["subject"]?.stringValue {
                attrs[PDFDocumentAttribute.subjectAttribute] = subject
            } else {
                attrs.removeValue(forKey: PDFDocumentAttribute.subjectAttribute)
            }
            
            if let kwList = metadata.common.keywords {
                attrs[PDFDocumentAttribute.keywordsAttribute] = kwList.joined(separator: ", ")
            } else if let keywords = metadata.customFields["keywords"]?.stringValue {
                attrs[PDFDocumentAttribute.keywordsAttribute] = keywords
            } else {
                attrs.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute)
            }
            
            if let creator = metadata.common.creator ?? metadata.customFields["creator"]?.stringValue {
                attrs[PDFDocumentAttribute.creatorAttribute] = creator
            } else {
                attrs.removeValue(forKey: PDFDocumentAttribute.creatorAttribute)
            }
            
            if let producer = metadata.customFields["producer"]?.stringValue {
                attrs[PDFDocumentAttribute.producerAttribute] = producer
            } else {
                attrs.removeValue(forKey: PDFDocumentAttribute.producerAttribute)
            }
            
            attrs[PDFDocumentAttribute.modificationDateAttribute] = Date()
            doc.documentAttributes = attrs
            
            guard doc.write(to: tempURL) else {
                throw MetadataError.writeFailure("Failed to write updated PDF document")
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return MetadataWriteResult(outputURL: url, duration: duration)
    }
}

import Foundation

// MARK: - Metadata Results

struct MetadataReadResult: Sendable {
    let document: MetadataDocument
    let duration: TimeInterval
    
    init(document: MetadataDocument, duration: TimeInterval = 0) {
        self.document = document
        self.duration = duration
    }
}

struct MetadataWriteResult: Sendable {
    let outputURL: URL
    let modifiedFields: Set<String>
    let duration: TimeInterval
    
    init(outputURL: URL, modifiedFields: Set<String> = [], duration: TimeInterval = 0) {
        self.outputURL = outputURL
        self.modifiedFields = modifiedFields
        self.duration = duration
    }
}

// MARK: - Metadata Provider Protocol

protocol MetadataProvider: Sendable {
    var providerName: String { get }
    var supportedFormats: Set<FileFormat> { get }
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities
    
    func readMetadata(from url: URL) async throws -> MetadataDocument
    
    func writeMetadata(
        _ metadata: MetadataDocument,
        to url: URL
    ) async throws -> MetadataWriteResult
    
    func removeMetadata(
        fields: Set<String>?,
        removeArtwork: Bool,
        removeGPS: Bool,
        from url: URL
    ) async throws -> MetadataWriteResult
}

// Default implementations
extension MetadataProvider {
    func removeMetadata(
        fields: Set<String>?,
        removeArtwork: Bool,
        removeGPS: Bool,
        from url: URL
    ) async throws -> MetadataWriteResult {
        var doc = try await readMetadata(from: url)
        
        if let fields = fields {
            for f in fields {
                doc.setValue(nil, for: f)
            }
        }
        
        if removeArtwork {
            doc.artwork = nil
        }
        
        if removeGPS {
            doc.gps = nil
        }
        
        return try await writeMetadata(doc, to: url)
    }
}

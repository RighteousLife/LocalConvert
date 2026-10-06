import Foundation

// MARK: - Value Types

enum MetadataValueType: String, Sendable, Codable, CaseIterable {
    case string
    case integer
    case decimal
    case boolean
    case date
    case url
    case artwork
    case gps
    case duration
    case readOnlyTechnical
}

// MARK: - Section Categories

enum MetadataSection: String, Sendable, Codable, CaseIterable, Identifiable {
    case basic = "Basic Information"
    case audio = "Audio Tags"
    case video = "Video Information"
    case camera = "Camera & Capture (EXIF)"
    case description = "Description & IPTC"
    case rights = "Copyright & Rights"
    case location = "Location (GPS)"
    case technical = "Technical Information"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .basic: return "info.circle"
        case .audio: return "music.note"
        case .video: return "film"
        case .camera: return "camera"
        case .description: return "text.alignleft"
        case .rights: return "lock.shield"
        case .location: return "location"
        case .technical: return "gearshape.2"
        }
    }
}

// MARK: - Write Strategies

enum MetadataWriteStrategy: String, Sendable, Codable, CaseIterable {
    /// Modifies metadata tags in-place without re-encoding media streams
    case streamCopyInPlace = "In-Place Stream Copy"
    /// Rewrites container metadata with safe temporary file and atomic swap (no re-encoding)
    case containerRewrite = "Container Metadata Rewrite"
    /// Creates a temporary file and atomically replaces upon verification
    case imageIOInPlace = "Image I/O In-Place"
    /// PDFKit document attribute serialization
    case pdfDocumentInPlace = "PDFKit Document Rewrite"
    /// OpenXML zip archive docProps/core.xml manipulation
    case openXMLCoreXML = "OpenXML Core XML Edit"
    /// Direct in place modification
    case directInPlace = "Direct In-Place"
    /// File can only be inspected; no metadata editing supported
    case readOnly = "Read-Only"
    /// Format has no metadata representation
    case unsupported = "Unsupported"
}

// MARK: - Field Descriptor

struct MetadataFieldDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let section: MetadataSection
    let valueType: MetadataValueType
    let isWritable: Bool
    let isRemovable: Bool
    let placeholder: String?
    let fieldDescription: String?
    
    init(
        id: String,
        name: String,
        section: MetadataSection = .basic,
        valueType: MetadataValueType = .string,
        isWritable: Bool = true,
        isRemovable: Bool = true,
        placeholder: String? = nil,
        fieldDescription: String? = nil
    ) {
        self.id = id
        self.name = name
        self.section = section
        self.valueType = valueType
        self.isWritable = isWritable
        self.isRemovable = isRemovable
        self.placeholder = placeholder
        self.fieldDescription = fieldDescription
    }
}

// MARK: - Provider Capabilities

struct MetadataCapabilities: Sendable, Equatable {
    let format: FileFormat
    let canRead: Bool
    let canWrite: Bool
    let canRemoveGPS: Bool
    let canRemoveArtwork: Bool
    let canRemoveAll: Bool
    let writeStrategy: MetadataWriteStrategy
    let fields: [MetadataFieldDescriptor]
    
    init(
        format: FileFormat,
        canRead: Bool = true,
        canWrite: Bool = true,
        canRemoveGPS: Bool = false,
        canRemoveArtwork: Bool = false,
        canRemoveAll: Bool = false,
        writeStrategy: MetadataWriteStrategy = .containerRewrite,
        fields: [MetadataFieldDescriptor] = []
    ) {
        self.format = format
        self.canRead = canRead
        self.canWrite = canWrite
        self.canRemoveGPS = canRemoveGPS
        self.canRemoveArtwork = canRemoveArtwork
        self.canRemoveAll = canRemoveAll
        self.writeStrategy = writeStrategy
        self.fields = fields
    }
    
    static func unsupported(for format: FileFormat) -> MetadataCapabilities {
        MetadataCapabilities(
            format: format,
            canRead: false,
            canWrite: false,
            canRemoveGPS: false,
            canRemoveArtwork: false,
            canRemoveAll: false,
            writeStrategy: .unsupported,
            fields: []
        )
    }
    
    static func readOnly(for format: FileFormat, fields: [MetadataFieldDescriptor]) -> MetadataCapabilities {
        MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: false,
            canRemoveGPS: false,
            canRemoveArtwork: false,
            canRemoveAll: false,
            writeStrategy: .readOnly,
            fields: fields.map {
                MetadataFieldDescriptor(
                    id: $0.id,
                    name: $0.name,
                    section: $0.section,
                    valueType: $0.valueType,
                    isWritable: false,
                    isRemovable: false,
                    placeholder: $0.placeholder,
                    fieldDescription: $0.fieldDescription
                )
            }
        )
    }
    
    var writableFields: [MetadataFieldDescriptor] {
        fields.filter { $0.isWritable }
    }
    
    var fieldsBySection: [MetadataSection: [MetadataFieldDescriptor]] {
        Dictionary(grouping: fields, by: { $0.section })
    }
}

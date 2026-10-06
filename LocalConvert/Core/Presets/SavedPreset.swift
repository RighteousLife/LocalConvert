import Foundation

// MARK: - Output Destination Policy

enum OutputDestinationPolicy: Codable, Equatable, Hashable, Sendable {
    case defaultLocation
    case sameAsInput
    case customDirectory(path: String)
    
    var displayName: String {
        switch self {
        case .defaultLocation:
            return "Default Folder (Settings)"
        case .sameAsInput:
            return "Same as Original File"
        case .customDirectory(let path):
            return "Custom: \(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }
}

// MARK: - Output Naming Policy

enum OutputNamingPolicy: Codable, Equatable, Hashable, Sendable {
    case standard
    case addSuffix(suffix: String)
    case addPrefix(prefix: String)
    
    var displayName: String {
        switch self {
        case .standard:
            return "Standard (filename.ext)"
        case .addSuffix(let suffix):
            return "Add Suffix (filename\(suffix).ext)"
        case .addPrefix(let prefix):
            return "Add Prefix (\(prefix)filename.ext)"
        }
    }
    
    func apply(to baseName: String) -> String {
        switch self {
        case .standard:
            return baseName
        case .addSuffix(let suffix):
            return "\(baseName)\(suffix)"
        case .addPrefix(let prefix):
            return "\(prefix)\(baseName)"
        }
    }
}

// MARK: - Saved Preset

struct SavedPreset: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    var description: String?
    var createdAt: Date
    var modifiedAt: Date
    var targetFormat: FileFormat
    var sourceConstraint: FileFormat?
    var sourceCategoryConstraint: FormatCategory?
    var options: ConversionOptions
    var outputDestinationPolicy: OutputDestinationPolicy
    var outputNamingPolicy: OutputNamingPolicy
    var schemaVersion: Int
    var isBuiltIn: Bool
    
    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        targetFormat: FileFormat,
        sourceConstraint: FileFormat? = nil,
        sourceCategoryConstraint: FormatCategory? = nil,
        options: ConversionOptions = .default,
        outputDestinationPolicy: OutputDestinationPolicy = .defaultLocation,
        outputNamingPolicy: OutputNamingPolicy = .standard,
        schemaVersion: Int = 1,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.targetFormat = targetFormat
        self.sourceConstraint = sourceConstraint
        self.sourceCategoryConstraint = sourceCategoryConstraint
        self.options = options
        self.outputDestinationPolicy = outputDestinationPolicy
        self.outputNamingPolicy = outputNamingPolicy
        self.schemaVersion = schemaVersion
        self.isBuiltIn = isBuiltIn
    }
    
    // MARK: - Factory Templates
    
    static var defaultTemplates: [SavedPreset] {
        [
            SavedPreset(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "Web-Optimized WebP",
                description: "Converts images into lightweight WebP format (80% quality) for web and apps.",
                targetFormat: .webp,
                sourceCategoryConstraint: .image,
                options: ConversionOptions(preset: .web, preserveMetadata: false, imageQuality: 0.80),
                outputDestinationPolicy: .defaultLocation,
                outputNamingPolicy: .standard,
                isBuiltIn: true
            ),
            SavedPreset(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                name: "High-Quality JPEG",
                description: "High quality JPEG (95% quality) preserving metadata for photos and sharing.",
                targetFormat: .jpg,
                sourceCategoryConstraint: .image,
                options: ConversionOptions(preset: .maximumQuality, preserveMetadata: true, imageQuality: 0.95),
                outputDestinationPolicy: .defaultLocation,
                outputNamingPolicy: .standard,
                isBuiltIn: true
            ),
            SavedPreset(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                name: "Universal MP4 Video",
                description: "Standard H.264 video with AAC audio for universal compatibility.",
                targetFormat: .mp4,
                sourceCategoryConstraint: .video,
                options: ConversionOptions(preset: .videoMaximumCompatibility, mediaQuality: .high),
                outputDestinationPolicy: .defaultLocation,
                outputNamingPolicy: .standard,
                isBuiltIn: true
            ),
            SavedPreset(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                name: "Extract MP3 Audio",
                description: "Extracts audio track from video files as high quality 320kbps MP3.",
                targetFormat: .mp3,
                sourceCategoryConstraint: .video,
                options: ConversionOptions(preset: .audioOnly, mediaQuality: .maximum),
                outputDestinationPolicy: .defaultLocation,
                outputNamingPolicy: .addSuffix(suffix: "_audio"),
                isBuiltIn: true
            ),
            SavedPreset(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
                name: "Document to PDF",
                description: "Converts documents, presentations, and images to crisp 300 DPI PDF files.",
                targetFormat: .pdf,
                options: ConversionOptions(preset: .documentPDF, pdfDPI: 300.0),
                outputDestinationPolicy: .defaultLocation,
                outputNamingPolicy: .standard,
                isBuiltIn: true
            ),
            SavedPreset(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000006")!,
                name: "PDF to Word (DOCX)",
                description: "Converts PDF documents to editable Microsoft Word files.",
                targetFormat: .docx,
                sourceConstraint: .pdf,
                options: ConversionOptions(preset: .documentEditable, pdfOfficeMode: .editable),
                outputDestinationPolicy: .defaultLocation,
                outputNamingPolicy: .standard,
                isBuiltIn: true
            )
        ]
    }
}

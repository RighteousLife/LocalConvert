import Foundation

// MARK: - Quality Preset

enum QualityPreset: String, Sendable, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case maximum = "Maximum"
    
    var value: Double {
        switch self {
        case .low: return 0.50
        case .medium: return 0.75
        case .high: return 0.90
        case .maximum: return 1.00
        }
    }
}

// MARK: - PDF to Office Conversion Mode

enum PDFOfficeConversionMode: String, Sendable, CaseIterable {
    /// Automatically choose the best conversion approach
    case automatic = "Automatic"
    /// Attempt editable text extraction (LibreOffice writer_pdf_import)
    case editable = "Editable"
    /// Visual mode: render PDF pages as images embedded in the output
    case visual = "Visual"
}

// MARK: - Conversion Options

struct ConversionOptions: Sendable {
    var preserveMetadata: Bool
    var overwriteExisting: Bool
    var imageQuality: Double? // 0.0...1.0 for lossy formats (default 0.90)
    var pdfDPI: Double? // DPI for PDF rendering (default 150.0)
    var pdfOfficeMode: PDFOfficeConversionMode? // PDF → Office conversion mode
    var webpLossless: Bool // WebP lossless encoding (default false = lossy)
    var mediaQuality: QualityPreset? // Quality preset for audio/video (default .high)
    var customOptions: [String: String]
    
    init(
        preserveMetadata: Bool = true,
        overwriteExisting: Bool = false,
        imageQuality: Double? = 0.90,
        pdfDPI: Double? = 150.0,
        pdfOfficeMode: PDFOfficeConversionMode? = .automatic,
        webpLossless: Bool = false,
        mediaQuality: QualityPreset? = .high,
        customOptions: [String: String] = [:]
    ) {
        self.preserveMetadata = preserveMetadata
        self.overwriteExisting = overwriteExisting
        self.imageQuality = imageQuality
        self.pdfDPI = pdfDPI
        self.pdfOfficeMode = pdfOfficeMode
        self.webpLossless = webpLossless
        self.mediaQuality = mediaQuality
        self.customOptions = customOptions
    }
    
    static let `default` = ConversionOptions()
    
    /// Effective JPEG/lossy quality (defaults to 0.90 if nil)
    var effectiveImageQuality: Double {
        imageQuality ?? 0.90
    }
    
    /// Effective PDF rendering DPI (defaults to 150.0 if nil)
    var effectivePDFDPI: Double {
        pdfDPI ?? 150.0
    }
    
    /// Effective PDF to Office conversion mode (defaults to .automatic if nil)
    var effectivePDFOfficeMode: PDFOfficeConversionMode {
        pdfOfficeMode ?? .automatic
    }
    
    /// Effective media (audio/video) quality preset (defaults to .high if nil)
    var effectiveMediaQuality: QualityPreset {
        mediaQuality ?? .high
    }
}



// MARK: - Conversion Progress

struct ConversionProgress: Sendable {
    let fractionCompleted: Double? // nil = indeterminate
    let statusMessage: String
    
    static let indeterminate = ConversionProgress(fractionCompleted: nil, statusMessage: "Converting...")
    
    static func determinate(_ fraction: Double, message: String = "Converting...") -> ConversionProgress {
        ConversionProgress(fractionCompleted: min(max(fraction, 0), 1), statusMessage: message)
    }
}

// MARK: - Conversion Result

struct ConversionResult: Sendable {
    let outputURL: URL
    let additionalOutputURLs: [URL]
    let outputFormat: FileFormat
    let fileSize: Int64
    let duration: TimeInterval
    let engineName: String
    
    var allOutputURLs: [URL] {
        [outputURL] + additionalOutputURLs
    }
    
    init(
        outputURL: URL,
        additionalOutputURLs: [URL] = [],
        outputFormat: FileFormat,
        fileSize: Int64,
        duration: TimeInterval,
        engineName: String
    ) {
        self.outputURL = outputURL
        self.additionalOutputURLs = additionalOutputURLs
        self.outputFormat = outputFormat
        self.fileSize = fileSize
        self.duration = duration
        self.engineName = engineName
    }
}

// MARK: - Conversion Error

enum ConversionError: LocalizedError, Sendable {
    case unsupportedConversion(from: FileFormat, to: FileFormat)
    case inputFileNotFound(URL)
    case outputDirectoryNotWritable(URL)
    case engineNotAvailable(String)
    case engineExecutionFailed(String, underlyingError: String?)
    case cancelled
    case invalidInput(String)
    case outputFileAlreadyExists(URL)
    case insufficientDiskSpace
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedConversion(let from, let to):
            return "Converting from \(from.displayName) to \(to.displayName) is not supported."
        case .inputFileNotFound(let url):
            return "The input file could not be found at: \(url.lastPathComponent)"
        case .outputDirectoryNotWritable(let url):
            return "Cannot write to the output directory: \(url.lastPathComponent)"
        case .engineNotAvailable(let name):
            return "The conversion engine '\(name)' is not available on this system."
        case .engineExecutionFailed(let message, _):
            return "Conversion failed: \(message)"
        case .cancelled:
            return "The conversion was cancelled."
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .outputFileAlreadyExists(let url):
            return "A file already exists at: \(url.lastPathComponent)"
        case .insufficientDiskSpace:
            return "There is not enough disk space for the conversion."
        case .unknown(let message):
            return "An unexpected error occurred: \(message)"
        }
    }
    
    var userFacingMessage: String {
        errorDescription ?? "Conversion failed"
    }
    
    var technicalDetails: String? {
        switch self {
        case .engineExecutionFailed(_, let underlying):
            return underlying
        default:
            return nil
        }
    }
}

// MARK: - Option Descriptors

enum OptionKind: Sendable, Equatable {
    case qualityPreset([QualityPreset])
    case dpiPreset([Double])
    case pdfOfficeMode([PDFOfficeConversionMode])
    case toggle(title: String, defaultValue: Bool)
}

struct ConversionOptionDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let description: String
    let kind: OptionKind
}

// MARK: - Conversion Engine Protocol

protocol ConversionEngine: Sendable {
    /// Unique name for this engine
    var name: String { get }
    
    /// The set of input formats this engine can read
    var supportedInputFormats: Set<FileFormat> { get }
    
    /// The set of output formats this engine can write
    var supportedOutputFormats: Set<FileFormat> { get }
    
    /// Check if this engine can perform a specific conversion
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool
    
    /// Returns available output formats for a given input format
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat>
    
    /// Returns option descriptors applicable for a specific conversion route
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor]
    
    /// Check if the engine is available on this system
    func isAvailable() async -> Bool
    
    /// Perform the conversion
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult
}

// MARK: - Default Implementation

extension ConversionEngine {
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        supportedInputFormats.contains(input) && supportedOutputFormats.contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        return supportedOutputFormats
    }
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        []
    }
}

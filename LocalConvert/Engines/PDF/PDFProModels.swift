import Foundation
import CoreGraphics
import PDFKit

// MARK: - PDF Toolbox Navigation Sections

enum PDFToolboxSection: String, CaseIterable, Identifiable, Sendable {
    case organize
    case ocr
    case pdfa
    case redact
    case compare
    case compress
    case forms
    case inspectSecurity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .organize: return "Organize"
        case .ocr: return "OCR & Searchable PDF"
        case .pdfa: return "PDF/A & Archiving"
        case .redact: return "Redact"
        case .compare: return "Compare"
        case .compress: return "Compress"
        case .forms: return "Forms"
        case .inspectSecurity: return "Inspect & Security"
        }
    }

    var systemImage: String {
        switch self {
        case .organize: return "square.stack.3d.up"
        case .ocr: return "text.viewfinder"
        case .pdfa: return "archivebox"
        case .redact: return "eye.slash.fill"
        case .compare: return "doc.on.doc"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .forms: return "list.bullet.rectangle"
        case .inspectSecurity: return "lock.shield"
        }
    }
}

// MARK: - OCR Models

enum PDFOCRRecognitionLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case accurate
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .accurate: return "Accurate"
        case .fast: return "Fast"
        }
    }
}

struct PDFOCROptions: Codable, Equatable, Sendable {
    var languageCodes: [String] = ["en-US"]
    var automaticallyDetectsLanguage: Bool = true
    var multiColumnReadingOrder: Bool = true
    var recognitionLevel: PDFOCRRecognitionLevel = .accurate
    var usesLanguageCorrection: Bool = true
    var deskewPages: Bool = false
    var pageRanges: String = ""
    var skipExistingTextPages: Bool = true
    var hybridTextImageThreshold: Int = 24
    var renderDPI: Double = 200.0
    var exportExtractedTextSidecar: Bool = false
    var password: String? = nil

    init(
        languageCodes: [String] = ["en-US"],
        automaticallyDetectsLanguage: Bool = true,
        multiColumnReadingOrder: Bool = true,
        recognitionLevel: PDFOCRRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true,
        deskewPages: Bool = false,
        pageRanges: String = "",
        skipExistingTextPages: Bool = true,
        hybridTextImageThreshold: Int = 24,
        renderDPI: Double = 200.0,
        exportExtractedTextSidecar: Bool = false,
        password: String? = nil
    ) {
        self.languageCodes = languageCodes
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.multiColumnReadingOrder = multiColumnReadingOrder
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.deskewPages = deskewPages
        self.pageRanges = pageRanges
        self.skipExistingTextPages = skipExistingTextPages
        self.hybridTextImageThreshold = hybridTextImageThreshold
        self.renderDPI = renderDPI
        self.exportExtractedTextSidecar = exportExtractedTextSidecar
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        languageCodes = try c.decodeIfPresent([String].self, forKey: .languageCodes) ?? ["en-US"]
        automaticallyDetectsLanguage = try c.decodeIfPresent(Bool.self, forKey: .automaticallyDetectsLanguage) ?? true
        multiColumnReadingOrder = try c.decodeIfPresent(Bool.self, forKey: .multiColumnReadingOrder) ?? true
        recognitionLevel = try c.decodeIfPresent(PDFOCRRecognitionLevel.self, forKey: .recognitionLevel) ?? .accurate
        usesLanguageCorrection = try c.decodeIfPresent(Bool.self, forKey: .usesLanguageCorrection) ?? true
        deskewPages = try c.decodeIfPresent(Bool.self, forKey: .deskewPages) ?? false
        pageRanges = try c.decodeIfPresent(String.self, forKey: .pageRanges) ?? ""
        skipExistingTextPages = try c.decodeIfPresent(Bool.self, forKey: .skipExistingTextPages) ?? true
        hybridTextImageThreshold = try c.decodeIfPresent(Int.self, forKey: .hybridTextImageThreshold) ?? 24
        renderDPI = try c.decodeIfPresent(Double.self, forKey: .renderDPI) ?? 200.0
        exportExtractedTextSidecar = try c.decodeIfPresent(Bool.self, forKey: .exportExtractedTextSidecar) ?? false
        password = try c.decodeIfPresent(String.self, forKey: .password)
    }

    static let `default` = PDFOCROptions()
}

struct PDFOCRPageSummary: Identifiable, Sendable {
    let pageNumber: Int
    let didRunOCR: Bool
    let skippedReason: String?
    let recognizedCharacters: Int
    let confidenceAverage: Float

    var id: Int { pageNumber }
}

struct PDFOCRResult: Sendable {
    let outputPDFURL: URL
    let sidecarTextURL: URL?
    let extractedText: String
    let processedPages: Int
    let skippedPages: Int
    let pageSummaries: [PDFOCRPageSummary]
    let warnings: [String]
}

// MARK: - PDF/A Archival Models

enum PDFAProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case pdfa1b = "PDF/A-1b"
    case pdfa2b = "PDF/A-2b"
    case pdfa2u = "PDF/A-2u"
    case pdfa3b = "PDF/A-3b"
    case pdfa4 = "PDF/A-4"

    var id: String { rawValue }

    /// Bundled LibreOffice `draw_pdf_Export` `SelectPdfVersion` flag where supported.
    var libreOfficeVersionValue: Int? {
        switch self {
        case .pdfa1b: return 1
        case .pdfa2b: return 2
        case .pdfa2u: return nil // Explicitly unsupported for generation (LibreOffice lacks 2u; Apple CG writes 2b).
        case .pdfa3b: return 3
        case .pdfa4: return 4
        }
    }

    var isGenerationSupported: Bool {
        libreOfficeVersionValue != nil
    }

    var isoStandard: String {
        switch self {
        case .pdfa1b: return "ISO 19005-1 Level B (PDF 1.4)"
        case .pdfa2b: return "ISO 19005-2 Level B (PDF 1.7)"
        case .pdfa2u: return "ISO 19005-2 Level U (Unicode — Not Supported)"
        case .pdfa3b: return "ISO 19005-3 Level B (PDF 1.7)"
        case .pdfa4: return "ISO 19005-4 (PDF 2.0)"
        }
    }

    var limitationNote: String? {
        switch self {
        case .pdfa2u:
            return "PDF/A-2u generation is unsupported with available runtimes: LibreOffice exports PDF/A-1b, 2b, 3b, and 4, and CoreGraphics stamps conformance B (PDF/A-2b)."
        case .pdfa1b:
            return "PDF/A-1b disallows transparency and encryption; LibreOffice Draw flattens transparent graphics during archival export."
        default:
            return nil
        }
    }
}

struct PDFAValidationCheck: Identifiable, Sendable {
    let id = UUID()
    let requirement: String
    let passed: Bool
    let detail: String
    var severity: String = "Error"
    var objectPath: String? = nil
}

struct PDFAValidationReport: Sendable {
    let profile: PDFAProfile
    let detectedPart: String?
    let detectedConformance: String?
    let detectedRevision: String?
    let isCompliant: Bool
    let checks: [PDFAValidationCheck]
    let failedRequirements: [String]
    let warnings: [String]
    var validationScopeNote: String = "Structural & XMP conformance inspection only (fonts, ToUnicode CMaps, OutputIntents, transparency, encryption, scripts, and embedded files). Not a full ISO 19005 veraPDF certification."
}

// MARK: - Permanent Redaction Models

struct PDFRedactionRegion: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let pageIndex: Int // 0-based
    /// Rect in PDF page coordinates (origin at page mediaBox lower-left, in points).
    let rect: CGRect
    let label: String

    init(id: UUID = UUID(), pageIndex: Int, rect: CGRect, label: String = "Redaction Region") {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.label = label
    }
}

struct PDFRedactionOptions: Codable, Equatable, Sendable {
    var searchTerms: [String] = []
    var regions: [PDFRedactionRegion] = []
    /// 1-based page range string to redact whole pages (e.g. "2, 4-5").
    var wholePageRanges: String = ""
    var removeMetadata: Bool = true
    var scrubXMPMetadata: Bool = true
    var sanitizeOutlinesAndLinks: Bool = true
    var cleanAnnotationsInRegions: Bool = true
    var preserveUnrelatedTextSearchability: Bool = true
    var renderDPI: Double = 300.0
    var fillColorHex: String = "#000000"
    var overlayTag: String = ""
    var password: String? = nil
    var failIfVerificationFails: Bool = true
}

struct PDFRedactionVerificationReport: Sendable {
    let outputURL: URL
    let redactedPageIndices: Set<Int>
    let appliedRegionsCount: Int
    let removedAnnotationsCount: Int
    let residualMatchesFound: [String]
    let isVerifiedClean: Bool
    var scrubbedOutlineCount: Int = 0
    var scrubbedFormFieldCount: Int = 0
    var scrubbedMetadataItemsCount: Int = 0
    var verificationChecks: [String] = []
    var riskWarnings: [String] = []
    var incrementalRevisionsCount: Int = 1
    var decompressedStreamChecked: Bool = false
}

// MARK: - PDF Comparison Models

struct PDFPageComparisonDiff: Identifiable, Sendable {
    let id = UUID()
    let pageNumber: Int
    let status: PageDiffStatus
    let leftDimensions: CGSize?
    let rightDimensions: CGSize?
    let leftRotation: Int?
    let rightRotation: Int?
    let addedLines: [String]
    let removedLines: [String]
    let visualDifferenceRatio: Double? // 0.0 identical .. 1.0 completely different
    let visualDiffImageData: Data?
    let leftThumbnailData: Data?
    let rightThumbnailData: Data?
    var annotationChanges: [String] = []
    var formFieldChanges: [String] = []
    var leftImageCount: Int = 0
    var rightImageCount: Int = 0

    enum PageDiffStatus: String, Sendable {
        case identical = "Identical"
        case modifiedTextAndVisual = "Text & Visual Differences"
        case textOnlyModified = "Text Differences"
        case visualOnlyModified = "Visual Differences"
        case annotationsOrFormsChanged = "Annotations / Forms Changed"
        case added = "Added Page"
        case removed = "Removed Page"
        case layoutChanged = "Page Size / Rotation Changed"
    }
}

struct PDFComparisonReport: Sendable {
    let leftURL: URL
    let rightURL: URL
    let leftPageCount: Int
    let rightPageCount: Int
    let identicalPagesCount: Int
    let modifiedPagesCount: Int
    let addedPagesCount: Int
    let removedPagesCount: Int
    let totalAddedLines: Int
    let totalRemovedLines: Int
    let pageDiffs: [PDFPageComparisonDiff]
    let summaryText: String
    var totalAnnotationChanges: Int = 0
    var totalFormFieldChanges: Int = 0
    var totalImageChanges: Int = 0
}

// MARK: - Compression Models

enum PDFCompressionProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case maximumQuality = "Maximum Quality"
    case balanced = "Balanced"
    case smallFile = "Small File"
    case webOptimized = "Web Optimized"
    case emailAttachment = "Email Attachment"
    case custom = "Custom"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .maximumQuality:
            return "Lossless stream rewrite preserving vector text, links, forms, and outlines."
        case .balanced:
            return "Vector-preserving Quartz optimization: downsamples images to 150 DPI (80% JPEG) while keeping crisp vector text and bookmarks."
        case .smallFile:
            return "Compact 110 DPI rasterization with 60% JPEG quality."
        case .webOptimized:
            return "Structure-preserving screen image optimization (JPEG) + stripped metadata. Does not write PDF linearization hint tables."
        case .emailAttachment:
            return "Aggressive 96 DPI / 50% JPEG target for lightweight sharing."
        case .custom:
            return "Configure tier, target DPI, image codec, quality, grayscale, and metadata cleanup."
        }
    }

    var isLossy: Bool {
        self != .maximumQuality
    }
}

enum PDFImageCompressionCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpeg = "JPEG"
    case jpeg2000 = "JPEG 2000"
    case losslessFlate = "Lossless (Flate/PDFKit)"

    var id: String { rawValue }
}

enum PDFCompressionStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    case losslessCleanup = "Lossless Structure Cleanup (No Image Re-encoding)"
    case quartzOptimized = "Vector-Preserving Quartz Optimization (DPI + JPEG)"
    case structurePreserving = "Structure-Preserving (Keep Vectors, Links & Forms)"
    case rasterizePages = "Rasterize Pages (Maximum Size Reduction)"

    var id: String { rawValue }
}

struct PDFCompressionOptions: Codable, Equatable, Sendable {
    var profile: PDFCompressionProfile = .balanced
    var strategy: PDFCompressionStrategy = .quartzOptimized
    var targetDPI: Double = 150.0
    var imageQuality: Double = 0.80
    var imageCodec: PDFImageCompressionCodec = .jpeg
    var stripMetadata: Bool = false
    var grayscale: Bool = false
    var password: String? = nil

    init(
        profile: PDFCompressionProfile = .balanced,
        strategy: PDFCompressionStrategy = .quartzOptimized,
        targetDPI: Double = 150.0,
        imageQuality: Double = 0.80,
        imageCodec: PDFImageCompressionCodec = .jpeg,
        stripMetadata: Bool = false,
        grayscale: Bool = false,
        password: String? = nil
    ) {
        self.profile = profile
        self.strategy = strategy
        self.targetDPI = targetDPI
        self.imageQuality = imageQuality
        self.imageCodec = imageCodec
        self.stripMetadata = stripMetadata
        self.grayscale = grayscale
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(PDFCompressionProfile.self, forKey: .profile) ?? .balanced
        strategy = try c.decodeIfPresent(PDFCompressionStrategy.self, forKey: .strategy) ?? .quartzOptimized
        targetDPI = try c.decodeIfPresent(Double.self, forKey: .targetDPI) ?? 150.0
        imageQuality = try c.decodeIfPresent(Double.self, forKey: .imageQuality) ?? 0.80
        imageCodec = try c.decodeIfPresent(PDFImageCompressionCodec.self, forKey: .imageCodec) ?? .jpeg
        stripMetadata = try c.decodeIfPresent(Bool.self, forKey: .stripMetadata) ?? false
        grayscale = try c.decodeIfPresent(Bool.self, forKey: .grayscale) ?? false
        password = try c.decodeIfPresent(String.self, forKey: .password)
    }

    static func forProfile(_ profile: PDFCompressionProfile) -> PDFCompressionOptions {
        switch profile {
        case .maximumQuality:
            return PDFCompressionOptions(profile: .maximumQuality, strategy: .losslessCleanup, targetDPI: 300.0, imageQuality: 1.0, imageCodec: .losslessFlate, stripMetadata: false)
        case .balanced:
            return PDFCompressionOptions(profile: .balanced, strategy: .quartzOptimized, targetDPI: 150.0, imageQuality: 0.80, imageCodec: .jpeg, stripMetadata: false)
        case .smallFile:
            return PDFCompressionOptions(profile: .smallFile, strategy: .rasterizePages, targetDPI: 110.0, imageQuality: 0.60, imageCodec: .jpeg, stripMetadata: true)
        case .webOptimized:
            return PDFCompressionOptions(profile: .webOptimized, strategy: .structurePreserving, targetDPI: 144.0, imageQuality: 0.78, imageCodec: .jpeg, stripMetadata: true)
        case .emailAttachment:
            return PDFCompressionOptions(profile: .emailAttachment, strategy: .rasterizePages, targetDPI: 96.0, imageQuality: 0.50, imageCodec: .jpeg, stripMetadata: true)
        case .custom:
            return PDFCompressionOptions(profile: .custom, strategy: .quartzOptimized, targetDPI: 150.0, imageQuality: 0.75, imageCodec: .jpeg, stripMetadata: false)
        }
    }
}

struct PDFCompressionResultInfo: Sendable {
    let outputURL: URL
    let originalBytes: Int64
    let compressedBytes: Int64
    let wasLossyApplied: Bool
    let validatedReadable: Bool
    let pageCount: Int
    let tradeOffNote: String
    var preservedStructures: [String] = []
    var discardedStructures: [String] = []
    var isLinearized: Bool = false
    var linearizationNote: String? = nil
    var metadataStrippedVerified: Bool = false
    var xmpVerificationNote: String? = nil
    var preImageCount: Int = 0
    var postImageCount: Int = 0
    var fontCount: Int = 0
    var fontNote: String? = nil
    var warnings: [String] = []

    var reductionPercent: Double {
        guard originalBytes > 0 else { return 0 }
        return Double(originalBytes - compressedBytes) / Double(originalBytes) * 100.0
    }
}

// MARK: - Form Models

enum PDFFormFieldKind: String, Codable, Sendable {
    case text = "Text"
    case checkbox = "Checkbox"
    case radio = "Radio Button"
    case choice = "Dropdown / List"
    case signature = "Signature"
    case pushButton = "Button"
    case unknown = "Other"
}

struct PDFFormFieldItem: Identifiable, Codable, Equatable, Sendable {
    let id: String // "\(pageIndex)::\(index)::\(fieldName)"
    let pageIndex: Int
    let fieldName: String
    let kind: PDFFormFieldKind
    var stringValue: String
    var boolValue: Bool
    let choices: [String]
    let isReadOnly: Bool
    let bounds: CGRect
}

struct PDFFormInspection: Sendable {
    let hasAcroForm: Bool
    let hasXFA: Bool
    let xfaNote: String?
    var hasJavaScriptActions: Bool = false
    var javaScriptNote: String? = nil
    let fields: [PDFFormFieldItem]
}

// MARK: - Inspector & Security Models

struct PDFFontInfo: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let subtype: String
    let isEmbedded: Bool
    var hasToUnicode: Bool = true
    let pageNumbers: [Int]
}

enum PDFSignatureCryptoStatus: String, Sendable {
    case unsigned = "Unsigned Field"
    case validDigest = "Cryptographic Digest Verified"
    case invalidDigest = "Invalid Signature / Tampered Bytes"
    case malformedCMS = "Malformed / Unparseable CMS"
    case unsupportedSubFilter = "Unsupported SubFilter"
}

struct PDFDigitalSignatureInfo: Identifiable, Sendable {
    let id = UUID()
    let fieldName: String
    let pageNumber: Int?
    let filter: String?
    let subFilter: String?
    let signerName: String?
    let signingDateRaw: String?
    let reason: String?
    let location: String?
    let byteRange: [Int]?
    let coversEntireFile: Bool?
    let cmsCertificateCount: Int
    let certificateSubjects: [String]
    let certificateIssuers: [String]
    let cryptographicStatusNote: String
    var cmsParsed: Bool = false
    var cryptoStatus: PDFSignatureCryptoStatus = .unsigned
    var trustChainStatus: String = "Not evaluated"
    var isCertificateExpired: Bool? = nil
    var revocationStatus: String = "Not checked offline (CRL/OCSP revocation not performed)"
}

struct PDFImageAssetInfo: Identifiable, Sendable {
    let id = UUID()
    let pageNumber: Int
    let width: Int
    let height: Int
    let colorSpace: String
    let compressionFilter: String
    let hasSoftMask: Bool
}

struct PDFInspectionWarning: Identifiable, Sendable {
    let id = UUID()
    let severity: Severity
    let message: String

    enum Severity: String, Sendable {
        case info = "Info"
        case warning = "Warning"
        case critical = "Critical"
    }
}

struct PDFDocumentInspectionReport: Sendable {
    let fileURL: URL
    let fileSizeBytes: Int64
    let pdfVersion: String
    let pageCount: Int
    let pageDimensionsSummary: String
    let orientationsSummary: String
    let title: String?
    let author: String?
    let subject: String?
    let creator: String?
    let producer: String?
    let creationDate: Date?
    let modificationDate: Date?
    let hasXMPMetadata: Bool
    let xmpSummary: String?
    let claimedPDFAProfile: String?
    let fonts: [PDFFontInfo]
    let unembeddedFontsCount: Int
    let images: [PDFImageAssetInfo]
    let hasTransparency: Bool
    let colorSpaces: [String]
    let hasOutputIntent: Bool
    let annotationCount: Int
    let annotationTypes: [String]
    let hasAcroForm: Bool
    let hasXFA: Bool
    let formFieldCount: Int
    let isEncrypted: Bool
    let isLocked: Bool
    let encryptionCipherSummary: String
    let allowsPrinting: Bool
    let allowsHighQualityPrinting: Bool
    let allowsCopying: Bool
    let allowsContentAccessibility: Bool
    let allowsCommenting: Bool
    let allowsFormFieldEntry: Bool
    let allowsDocumentChanges: Bool
    let allowsDocumentAssembly: Bool
    let hasDigitalSignatures: Bool
    let signatureFieldNames: [String]
    var digitalSignatures: [PDFDigitalSignatureInfo] = []
    var isLinearized: Bool = false
    var hasToUnicodeGap: Bool = false
    var hasJavaScriptActions: Bool = false
    var hasEmbeddedFiles: Bool = false
    var embeddedFileNames: [String] = []
    var hasOptionalContentLayers: Bool = false
    var hasStructureTree: Bool = false
    var hasAssociatedFiles: Bool = false
    let warnings: [PDFInspectionWarning]
}

struct PDFSecurityOptions: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case encrypt
        case decrypt
    }

    var mode: Mode = .encrypt
    var currentPassword: String = ""
    var userPassword: String = ""
    var ownerPassword: String = ""
    var allowPrinting: Bool = true
    var allowHighQualityPrinting: Bool = true
    var allowCopying: Bool = true
    var allowAccessibility: Bool = true
    var allowCommenting: Bool = true
    var allowFormEntry: Bool = true
    var allowDocumentChanges: Bool = false
    var allowDocumentAssembly: Bool = false

    func makeCGPermissions() -> CGPDFAccessPermissions {
        var p = CGPDFAccessPermissions(rawValue: 0)
        if allowPrinting { p.insert(.allowsLowQualityPrinting) }
        if allowHighQualityPrinting { p.insert(.allowsHighQualityPrinting) }
        if allowCopying { p.insert(.allowsContentCopying) }
        if allowAccessibility { p.insert(.allowsContentAccessibility) }
        if allowCommenting { p.insert(.allowsCommenting) }
        if allowFormEntry { p.insert(.allowsFormFieldEntry) }
        if allowDocumentChanges { p.insert(.allowsDocumentChanges) }
        if allowDocumentAssembly { p.insert(.allowsDocumentAssembly) }
        return p
    }
}

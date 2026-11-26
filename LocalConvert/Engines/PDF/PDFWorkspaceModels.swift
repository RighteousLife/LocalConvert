import Foundation
import CoreGraphics

// MARK: - Phase 44 PDF Page Management Models

enum PDFPageSizePreset: Codable, Equatable, Hashable, Sendable, Identifiable {
    case original
    case a4
    case letter
    case legal
    case a3
    case custom(widthPoints: Double, heightPoints: Double)

    var id: String { displayName }

    static var standardPresets: [PDFPageSizePreset] {
        [.original, .a4, .letter, .legal, .a3]
    }

    var displayName: String {
        switch self {
        case .original: return "Original Size"
        case .a4: return "A4 (595 × 842 pt)"
        case .letter: return "US Letter (612 × 792 pt)"
        case .legal: return "US Legal (612 × 1008 pt)"
        case .a3: return "A3 (842 × 1191 pt)"
        case .custom(let w, let h): return "Custom (\(Int(w.rounded())) × \(Int(h.rounded())) pt)"
        }
    }

    /// Portrait points (width, height). Orientation matches source page unless caller preserves orientation.
    var sizeInPoints: CGSize? {
        switch self {
        case .original: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .letter: return CGSize(width: 612.0, height: 792.0)
        case .legal: return CGSize(width: 612.0, height: 1008.0)
        case .a3: return CGSize(width: 841.89, height: 1190.55)
        case .custom(let w, let h):
            return CGSize(width: max(36.0, min(14_400.0, w)), height: max(36.0, min(14_400.0, h)))
        }
    }
}

enum PDFPageResizeMode: String, CaseIterable, Codable, Equatable, Hashable, Sendable, Identifiable {
    case fitPreserveAspect = "Fit (Preserve Aspect)"
    case fillCrop = "Fill (Crop Overflow)"
    case centerUnscaled = "Center (Keep Original Scale)"

    var id: String { rawValue }
}

/// Normalized rectangle in upright displayed page space with top-left origin (`x, y, width, height` in `0...1`).
struct NormalizedPDFCropRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let fullPage = NormalizedPDFCropRect(x: 0, y: 0, width: 1, height: 1)

    init(x: Double, y: Double, width: Double, height: Double) {
        let clampedX = max(0.0, min(0.95, x))
        let clampedY = max(0.0, min(0.95, y))
        let clampedW = max(0.05, min(1.0 - clampedX, width))
        let clampedH = max(0.05, min(1.0 - clampedY, height))
        self.x = clampedX
        self.y = clampedY
        self.width = clampedW
        self.height = clampedH
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var isFullPage: Bool {
        x <= 0.001 && y <= 0.001 && width >= 0.998 && height >= 0.998
    }
}

/// Non-destructive virtual descriptor representing one page inside a PDF Page Studio draft.
struct PDFPageDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let sourcePageIndex: Int
    var rotationDeltaDegrees: Int
    var normalizedCrop: NormalizedPDFCropRect?
    var targetSizePreset: PDFPageSizePreset
    var resizeMode: PDFPageResizeMode
    var matchPageOrientation: Bool

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        sourcePageIndex: Int,
        rotationDeltaDegrees: Int = 0,
        normalizedCrop: NormalizedPDFCropRect? = nil,
        targetSizePreset: PDFPageSizePreset = .original,
        resizeMode: PDFPageResizeMode = .fitPreserveAspect,
        matchPageOrientation: Bool = true
    ) {
        self.id = id
        self.sourceURL = sourceURL.standardizedFileURL
        self.sourcePageIndex = sourcePageIndex
        self.rotationDeltaDegrees = ((rotationDeltaDegrees % 360) + 360) % 360
        self.normalizedCrop = normalizedCrop
        self.targetSizePreset = targetSizePreset
        self.resizeMode = resizeMode
        self.matchPageOrientation = matchPageOrientation
    }

    var hasTransforms: Bool {
        rotationDeltaDegrees != 0
            || (normalizedCrop != nil && normalizedCrop?.isFullPage == false)
            || targetSizePreset != .original
    }
}

struct PDFPageWorkspaceDraft: Codable, Equatable, Sendable {
    var primaryURL: URL?
    var pages: [PDFPageDescriptor] = []
    var sourceIdentity: FileIdentitySnapshot?
}

enum PDFSplitStrategy: Codable, Equatable, Sendable {
    case everyPage
    case everyNPages(Int)
    case pageRanges(String)
    case topLevelBookmarks
}

struct PDFPageOperationResult: Sendable {
    let outputURL: URL
    let additionalOutputURLs: [URL]
    let pageCount: Int
    let preservedOutlineCount: Int
    let omittedOutlineCount: Int
    let outlineLimitationNote: String?
    let warnings: [String]
}

// MARK: - Phase 44.2 PDF Annotation & Editing Models

enum PDFAnnotationTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case select = "Select"
    case highlight = "Highlight"
    case underline = "Underline"
    case strikeOut = "Strikethrough"
    case note = "Sticky Note"
    case freeText = "Text Box"
    case ink = "Freehand Ink"
    case rectangle = "Rectangle"
    case circle = "Circle"
    case line = "Line"
    case arrow = "Arrow"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        case .note: return "note.text"
        case .freeText: return "textbox"
        case .ink: return "scribble.variable"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        }
    }

    var isTextMarkup: Bool {
        self == .highlight || self == .underline || self == .strikeOut
    }
}

struct PDFAnnotationStyle: Codable, Equatable, Hashable, Sendable {
    var strokeColorHex: String = "#FFD60A"
    var fillColorHex: String? = nil
    var opacity: Double = 1.0
    var lineWidth: Double = 2.0
    var fontSize: Double = 14.0
    var fontName: String = "Helvetica Neue"
    var author: String = NSUserName()
}

struct PDFPointRecord: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ pt: CGPoint) {
        self.x = Double(pt.x)
        self.y = Double(pt.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct PDFRectRecord: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Non-destructive annotation draft record in **raw PDF page space**.
struct PDFDraftAnnotationRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    var pageIndex: Int
    var kind: PDFAnnotationTool
    var bounds: PDFRectRecord
    var quadLines: [[PDFPointRecord]]? // 4 corner points per text line in raw PDF page coords
    var inkPaths: [[PDFPointRecord]]?  // strokes in raw PDF page coords
    var lineStart: PDFPointRecord?
    var lineEnd: PDFPointRecord?
    var contents: String = ""
    var style: PDFAnnotationStyle

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        kind: PDFAnnotationTool,
        bounds: CGRect,
        quadLines: [[CGPoint]]? = nil,
        inkPaths: [[CGPoint]]? = nil,
        lineStart: CGPoint? = nil,
        lineEnd: CGPoint? = nil,
        contents: String = "",
        style: PDFAnnotationStyle = PDFAnnotationStyle()
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.kind = kind
        self.bounds = PDFRectRecord(bounds)
        self.quadLines = quadLines?.map { $0.map(PDFPointRecord.init) }
        self.inkPaths = inkPaths?.map { $0.map(PDFPointRecord.init) }
        self.lineStart = lineStart.map(PDFPointRecord.init)
        self.lineEnd = lineEnd.map(PDFPointRecord.init)
        self.contents = contents
        self.style = style
    }
}

struct PDFAnnotationWorkspaceDraft: Codable, Equatable, Sendable {
    var records: [PDFDraftAnnotationRecord] = []
    var flattenOnSave: Bool = false
}

struct PDFAnnotationSaveOptions: Codable, Equatable, Sendable {
    var records: [PDFDraftAnnotationRecord] = []
    var flattenAnnotations: Bool = false
    var password: String? = nil
}

struct PDFAnnotationSaveResult: Sendable {
    let outputURL: URL
    let savedAnnotationsCount: Int
    let flattened: Bool
    let preservedWidgetCount: Int
    let warnings: [String]
}

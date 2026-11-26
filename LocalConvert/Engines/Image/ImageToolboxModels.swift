import Foundation
import CoreGraphics

// MARK: - Toolbox Navigation Sections

enum ImageToolboxSection: String, CaseIterable, Identifiable, Sendable {
    case convert = "Convert & Codec"
    case adjustments = "Color & Light"
    case effects = "Effects & Presets"
    case rawDevelop = "RAW Develop"
    case crop = "Crop & Geometry"
    case resize = "Resize"
    case upscale = "Upscale"
    case targetSize = "Optimize File Size"
    case compression = "Compression"
    case metadata = "Metadata & Privacy"
    case watermark = "Watermark"
    case compare = "Before / After"
    case colorManagement = "Color Management"
    case backgroundRemoval = "Remove Background"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .convert: return "photo.badge.arrow.down"
        case .adjustments: return "sun.max.circle"
        case .effects: return "camera.filters"
        case .rawDevelop: return "camera.aperture"
        case .crop: return "crop.rotate"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .upscale: return "plus.viewfinder"
        case .targetSize: return "gauge.with.dots.needle.33percent"
        case .compression: return "slider.horizontal.3"
        case .metadata: return "shield.lefthalf.filled"
        case .watermark: return "textformat.abc"
        case .compare: return "rectangle.split.2x1"
        case .colorManagement: return "paintpalette"
        case .backgroundRemoval: return "person.crop.rectangle"
        }
    }

    var summary: String {
        switch self {
        case .convert:
            return "Convert between image formats including full JPEG XL lossy, lossless, 16-bit, animated, and JPEG-reconstructable workflows."
        case .adjustments:
            return "Non-destructive Exposure, Light, White Balance, Highlights/Shadows, Levels, Master & RGB Tone Curves, Color Balance, and Live Histogram."
        case .effects:
            return "Reorderable effects chain (Blur, Sharpen, Unsharp Mask, Noise Reduction, Vignette, Film Grain, Monochrome, Sepia, Looks) and Presets."
        case .rawDevelop:
            return "Native Core Image Camera RAW demosaicing controls for Exposure, White Balance, Highlight/Shadow Recovery, Boost, and Noise Reduction."
        case .resize:
            return "Resize by exact dimensions, percentage, or edge limits with live preview, aspect lock, resampling filters, and multi-size batch export."
        case .upscale:
            return "Enlarge images 2×–4× or to custom target sizes using multi-step Lanczos & detail recovery interpolation with before/after inspection."
        case .crop:
            return "Interactive crop editor with drag/corner handles, continuous straightening, auto horizon, grids, aspect ratios, geometric shapes, rotation, and mirroring."
        case .targetSize:
            return "Compress images under an exact file size budget (e.g. 100 KB, 500 KB, 1 MB) via bounded quality optimization."
        case .compression:
            return "Tune codec compression profiles, Butteraugli distance / quality, effort, bit depth, alpha preservation, and WebP/JXL lossless modes."
        case .metadata:
            return "Inspect and edit EXIF/IPTC/XMP/ICC tags or sanitize GPS, camera hardware, and author metadata (including JPEG XL containers)."
        case .watermark:
            return "Apply positioned or tiled text and logo watermarks with customizable opacity, scale, angle, font, and margins."
        case .compare:
            return "Inspect processed output against the original in split-slider or side-by-side view with zoom, pan, and codec size analytics."
        case .colorManagement:
            return "Detect embedded ICC profiles and convert non-destructively between embedded profiles, sRGB, and Display P3."
        case .backgroundRemoval:
            return "Isolate foreground subjects on-device using Apple Vision segmentation with edge refinement and transparency support."
        }
    }
}

// MARK: - Compression Profiles

enum ImageCompressionProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    case maximumQuality = "Maximum Quality"
    case balanced = "Balanced"
    case smallFile = "Small File"
    case webOptimized = "Web Optimized"
    case archiveLossless = "Archive / Lossless"
    case custom = "Custom"

    var id: String { rawValue }

    var suggestedQuality: Double {
        switch self {
        case .maximumQuality: return 0.96
        case .balanced: return 0.85
        case .smallFile: return 0.65
        case .webOptimized: return 0.78
        case .archiveLossless: return 1.0
        case .custom: return 0.85
        }
    }

    var suggestedEffort: Int {
        switch self {
        case .maximumQuality: return 8
        case .balanced: return 7
        case .smallFile: return 8
        case .webOptimized: return 7
        case .archiveLossless: return 8
        case .custom: return 7
        }
    }

    var prefersLossless: Bool {
        self == .archiveLossless
    }
}

// MARK: - Resize Pro Models

enum ImageResizeStrategy: String, CaseIterable, Codable, Sendable, Identifiable {
    case none = "Original Size"
    case exactDimensions = "Exact Dimensions"
    case percentage = "Percentage"
    case maxWidth = "Max Width"
    case maxHeight = "Max Height"
    case fitInside = "Fit Inside (Aspect)"
    case fill = "Fill (Crop to Fit)"

    var id: String { rawValue }
}

struct ImageBatchSizePreset: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var label: String
    var width: Int
    var height: Int

    static let defaults: [ImageBatchSizePreset] = [
        ImageBatchSizePreset(label: "Thumbnail 256", width: 256, height: 256),
        ImageBatchSizePreset(label: "Web 1200", width: 1200, height: 1200),
        ImageBatchSizePreset(label: "HD 1920", width: 1920, height: 1080)
    ]
}

// MARK: - Upscale Models

enum ImageUpscalePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case scale2x = "2×"
    case scale3x = "3×"
    case scale4x = "4×"
    case customScale = "Custom Scale"
    case targetDimensions = "Target Size"

    var id: String { rawValue }

    var fixedScaleFactor: Double? {
        switch self {
        case .scale2x: return 2.0
        case .scale3x: return 3.0
        case .scale4x: return 4.0
        case .customScale, .targetDimensions: return nil
        }
    }
}

enum ImageUpscaleMethod: String, CaseIterable, Codable, Sendable, Identifiable {
    case lanczosDetail = "Lanczos + Detail Recovery"
    case lanczos = "Lanczos 3 (Sharp)"
    case bicubic = "Bicubic (Smooth)"

    var id: String { rawValue }
}

struct ImageUpscaleConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var preset: ImageUpscalePreset = .scale2x
    var scaleFactor: Double = 2.0          // 1.1 ... 4.0
    var targetWidth: Int? = nil
    var targetHeight: Int? = nil
    var preserveAspectRatio: Bool = true
    var method: ImageUpscaleMethod = .lanczosDetail
    var detailEnhancement: Double = 0.35   // 0.0 ... 1.0
    var artifactReduction: Double = 0.0    // 0.0 ... 1.0

    var effectiveScaleFactor: Double {
        preset.fixedScaleFactor ?? max(1.0, min(8.0, scaleFactor))
    }
}

// MARK: - Crop & Transform Models

enum ImageAnchorPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case topLeft = "Top Left"
    case top = "Top"
    case topRight = "Top Right"
    case left = "Left"
    case center = "Center"
    case right = "Right"
    case bottomLeft = "Bottom Left"
    case bottom = "Bottom"
    case bottomRight = "Bottom Right"

    var id: String { rawValue }
}

enum ImageCropShape: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case rectangle = "Rectangle"
    case roundedRectangle = "Rounded Rectangle"
    case circle = "Circle"
    case ellipse = "Ellipse"
    case triangle = "Triangle"
    case diamond = "Diamond"
    case hexagon = "Hexagon"
    case customPolygon = "Custom Polygon"

    var id: String { rawValue }

    var isGeometricMask: Bool {
        self != .rectangle
    }

    var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "rectangle.roundedtop"
        case .circle: return "circle"
        case .ellipse: return "oval"
        case .triangle: return "triangle"
        case .diamond: return "diamond"
        case .hexagon: return "hexagon"
        case .customPolygon: return "pentagon"
        }
    }
}

enum ImageCropOverlayGrid: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case ruleOfThirds = "Rule of Thirds"
    case goldenRatio = "Golden Ratio"
    case squareGrid = "Grid"
    case none = "Off"

    var id: String { rawValue }
}

enum ImageCropRatioPreset: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case freeform = "Freeform"
    case original = "Original"
    case ratio1x1 = "1:1"
    case ratio4x3 = "4:3"
    case ratio3x4 = "3:4"
    case ratio3x2 = "3:2"
    case ratio2x3 = "2:3"
    case ratio5x4 = "5:4"
    case ratio4x5 = "4:5"
    case ratio16x9 = "16:9"
    case ratio9x16 = "9:16"
    case ratio21x9 = "21:9"
    case customRatio = "Custom"

    var id: String { rawValue }

    var fixedRatio: Double? {
        switch self {
        case .freeform, .original, .customRatio: return nil
        case .ratio1x1: return 1.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio3x4: return 3.0 / 4.0
        case .ratio3x2: return 3.0 / 2.0
        case .ratio2x3: return 2.0 / 3.0
        case .ratio5x4: return 5.0 / 4.0
        case .ratio4x5: return 4.0 / 5.0
        case .ratio16x9: return 16.0 / 9.0
        case .ratio9x16: return 9.0 / 16.0
        case .ratio21x9: return 21.0 / 9.0
        }
    }
}

struct CodableNormalizedPoint: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: Int = 0
    var x: Double   // 0.0 ... 1.0 within crop bounds
    var y: Double   // 0.0 ... 1.0 within crop bounds

    init(id: Int = 0, x: Double, y: Double) {
        self.id = id
        self.x = max(0.0, min(1.0, x))
        self.y = max(0.0, min(1.0, y))
    }

    static func regularPolygon(sides: Int, rotationDegrees: Double = 0.0) -> [CodableNormalizedPoint] {
        let count = max(3, min(12, sides))
        let rotRad = rotationDegrees * .pi / 180.0
        return (0..<count).map { idx in
            let angle = (Double(idx) / Double(count)) * (2.0 * .pi) - (.pi / 2.0) + rotRad
            let px = 0.5 + 0.48 * cos(angle)
            let py = 0.5 + 0.48 * sin(angle)
            return CodableNormalizedPoint(id: idx, x: px, y: py)
        }
    }
}

struct ImageCropAndTransformConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var cropMode: ImageCropMode = .none
    var aspectRatio: ImageCropAspectRatio = .original
    var ratioPreset: ImageCropRatioPreset? = nil
    var customAspectWidth: Double = 5.0
    var customAspectHeight: Double = 4.0
    var customWidth: Int? = nil
    var customHeight: Int? = nil
    var anchor: ImageAnchorPosition = .center
    var normalizedRect: NormalizedRect? = nil
    var rotationDegrees: Int = 0   // 0, 90, 180, 270
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var straightenDegrees: Double = 0.0   // -45.0 ... +45.0
    var autoCropOnStraighten: Bool = true

    // Interactive & geometric shape crop options
    var shape: ImageCropShape = .rectangle
    var roundedCornerRadiusPercent: Double = 18.0
    var polygonSides: Int = 5
    var polygonRotationDegrees: Double = 0.0
    var polygonVertices: [CodableNormalizedPoint]? = nil
    var shapeBackgroundFill: ImageBackgroundFillMode = .transparent
    var shapeBackgroundColor: CodableRGBAColor = .white
    var overlayGrid: ImageCropOverlayGrid = .ruleOfThirds

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        cropMode = try c.decodeIfPresent(ImageCropMode.self, forKey: .cropMode) ?? .none
        aspectRatio = try c.decodeIfPresent(ImageCropAspectRatio.self, forKey: .aspectRatio) ?? .original
        ratioPreset = try c.decodeIfPresent(ImageCropRatioPreset.self, forKey: .ratioPreset)
        customAspectWidth = try c.decodeIfPresent(Double.self, forKey: .customAspectWidth) ?? 5.0
        customAspectHeight = try c.decodeIfPresent(Double.self, forKey: .customAspectHeight) ?? 4.0
        customWidth = try c.decodeIfPresent(Int.self, forKey: .customWidth)
        customHeight = try c.decodeIfPresent(Int.self, forKey: .customHeight)
        anchor = try c.decodeIfPresent(ImageAnchorPosition.self, forKey: .anchor) ?? .center
        normalizedRect = try c.decodeIfPresent(NormalizedRect.self, forKey: .normalizedRect)
        rotationDegrees = try c.decodeIfPresent(Int.self, forKey: .rotationDegrees) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        straightenDegrees = min(45.0, max(-45.0, try c.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0.0))
        autoCropOnStraighten = try c.decodeIfPresent(Bool.self, forKey: .autoCropOnStraighten) ?? true
        shape = try c.decodeIfPresent(ImageCropShape.self, forKey: .shape) ?? .rectangle
        roundedCornerRadiusPercent = try c.decodeIfPresent(Double.self, forKey: .roundedCornerRadiusPercent) ?? 18.0
        polygonSides = try c.decodeIfPresent(Int.self, forKey: .polygonSides) ?? 5
        polygonRotationDegrees = try c.decodeIfPresent(Double.self, forKey: .polygonRotationDegrees) ?? 0.0
        polygonVertices = try c.decodeIfPresent([CodableNormalizedPoint].self, forKey: .polygonVertices)
        shapeBackgroundFill = try c.decodeIfPresent(ImageBackgroundFillMode.self, forKey: .shapeBackgroundFill) ?? .transparent
        shapeBackgroundColor = try c.decodeIfPresent(CodableRGBAColor.self, forKey: .shapeBackgroundColor) ?? .white
        overlayGrid = try c.decodeIfPresent(ImageCropOverlayGrid.self, forKey: .overlayGrid) ?? .ruleOfThirds
    }

    var effectiveRatioPreset: ImageCropRatioPreset {
        if let ratioPreset { return ratioPreset }
        switch aspectRatio {
        case .original: return .original
        case .square1x1: return .ratio1x1
        case .ratio4x3: return .ratio4x3
        case .ratio3x4: return .ratio3x4
        case .ratio3x2: return .ratio3x2
        case .ratio2x3: return .ratio2x3
        case .ratio16x9: return .ratio16x9
        case .ratio9x16: return .ratio9x16
        case .custom: return .freeform
        }
    }

    func resolvedAspectRatio(sourceWidth: Int, sourceHeight: Int) -> Double? {
        let preset = effectiveRatioPreset
        if preset == .freeform { return nil }
        if preset == .original {
            guard sourceWidth > 0, sourceHeight > 0 else { return 1.0 }
            return Double(sourceWidth) / Double(sourceHeight)
        }
        if preset == .customRatio {
            guard customAspectWidth > 0, customAspectHeight > 0 else { return nil }
            return customAspectWidth / customAspectHeight
        }
        return preset.fixedRatio
    }

    var effectivePolygonVertices: [CodableNormalizedPoint] {
        if let polygonVertices, polygonVertices.count >= 3 {
            return polygonVertices
        }
        return CodableNormalizedPoint.regularPolygon(sides: polygonSides, rotationDegrees: polygonRotationDegrees)
    }

    var isActive: Bool {
        enabled || cropMode != .none || shape.isGeometricMask || rotationDegrees % 360 != 0 || flipHorizontal || flipVertical
            || abs(straightenDegrees) > 0.01
            || (customWidth != nil && customHeight != nil)
    }
}

// MARK: - Color Management Models

enum ImageColorProfileTarget: String, CaseIterable, Codable, Sendable, Identifiable {
    case preserve = "Preserve Source Profile"
    case sRGB = "sRGB IEC61966-2.1"
    case displayP3 = "Display P3"

    var id: String { rawValue }
}

struct ImageColorProfileInfo: Sendable, Equatable {
    let profileName: String
    let colorModel: String
    let bitDepth: Int
    let hasAlpha: Bool
    let hasEmbeddedICC: Bool
    let iccSizeBytes: Int
    let isWideGamut: Bool
}

// MARK: - Watermark Models

enum ImageWatermarkKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case text = "Text"
    case image = "Logo Image"

    var id: String { rawValue }
}

struct CodableRGBAColor: Codable, Sendable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = CodableRGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = CodableRGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let transparent = CodableRGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

struct ImageWatermarkConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var kind: ImageWatermarkKind = .text
    var text: String = "© LocalConvert"
    var fontName: String = "Helvetica Neue"
    var fontSizePercent: Double = 4.5    // Relative to shortest image edge (%)
    var textColor: CodableRGBAColor = .white
    var watermarkImagePath: String? = nil
    var opacity: Double = 0.75
    var scalePercent: Double = 18.0      // Relative to base image width (%)
    var rotationDegrees: Double = 0.0
    var anchor: ImageAnchorPosition = .bottomRight
    var marginPercent: Double = 4.0
    var tiled: Bool = false
    var tileSpacingMultiplier: Double = 2.2
}

// MARK: - Background Removal Models

enum ImageBackgroundFillMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case transparent = "Transparent"
    case solidColor = "Solid Color"

    var id: String { rawValue }
}

struct ImageBackgroundRemovalConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var fillMode: ImageBackgroundFillMode = .transparent
    var solidColor: CodableRGBAColor = .white
    var edgeRefinement: Double = 1.5     // 0...8 px mask feather/refinement
}

// MARK: - Perspective Correction Models

enum ImagePerspectiveFillMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case transparent = "Transparent"
    case white = "White"
    case black = "Black"
    case custom = "Custom Color"

    var id: String { rawValue }
}

struct ImagePerspectiveConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var topLeft: CodableNormalizedPoint = CodableNormalizedPoint(id: 0, x: 0.08, y: 0.08)
    var topRight: CodableNormalizedPoint = CodableNormalizedPoint(id: 1, x: 0.92, y: 0.08)
    var bottomRight: CodableNormalizedPoint = CodableNormalizedPoint(id: 2, x: 0.92, y: 0.92)
    var bottomLeft: CodableNormalizedPoint = CodableNormalizedPoint(id: 3, x: 0.08, y: 0.92)
    var fillMode: ImagePerspectiveFillMode = .transparent
    var customColor: CodableRGBAColor = .black

    var hasNonDefaultCorners: Bool {
        abs(topLeft.x) > 0.001 || abs(topLeft.y) > 0.001
            || abs(topRight.x - 1.0) > 0.001 || abs(topRight.y) > 0.001
            || abs(bottomRight.x - 1.0) > 0.001 || abs(bottomRight.y - 1.0) > 0.001
            || abs(bottomLeft.x) > 0.001 || abs(bottomLeft.y - 1.0) > 0.001
    }

    static let fullFrame = ImagePerspectiveConfig(
        enabled: false,
        topLeft: CodableNormalizedPoint(id: 0, x: 0.0, y: 0.0),
        topRight: CodableNormalizedPoint(id: 1, x: 1.0, y: 0.0),
        bottomRight: CodableNormalizedPoint(id: 2, x: 1.0, y: 1.0),
        bottomLeft: CodableNormalizedPoint(id: 3, x: 0.0, y: 1.0)
    )
}

// MARK: - Canvas Extension & Border/Frame Models

enum ImageCanvasExtensionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case dimensions = "Target Dimensions"
    case padding = "Edge Padding (px)"

    var id: String { rawValue }
}

enum ImageCanvasFillMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case transparent = "Transparent"
    case white = "White"
    case black = "Black"
    case custom = "Custom Color"

    var id: String { rawValue }
}

struct ImageCanvasPreset: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let label: String
    let category: String
    let width: Int
    let height: Int

    static let builtInPresets: [ImageCanvasPreset] = [
        ImageCanvasPreset(id: "ig_square", label: "Instagram 1:1 (1080×1080)", category: "Social", width: 1080, height: 1080),
        ImageCanvasPreset(id: "ig_portrait", label: "Instagram 4:5 (1080×1350)", category: "Social", width: 1080, height: 1350),
        ImageCanvasPreset(id: "ig_story", label: "Story / Reels 9:16 (1080×1920)", category: "Social", width: 1080, height: 1920),
        ImageCanvasPreset(id: "wp_4k", label: "Wallpaper 4K (3840×2160)", category: "Wallpaper", width: 3840, height: 2160),
        ImageCanvasPreset(id: "print_a4", label: "Print A4 300 DPI (2480×3508)", category: "Print", width: 2480, height: 3508),
        ImageCanvasPreset(id: "print_4x6", label: "Print 4×6\" 300 DPI (1200×1800)", category: "Print", width: 1200, height: 1800)
    ]
}

struct ImageCanvasExtensionConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var mode: ImageCanvasExtensionMode = .padding
    var targetWidth: Int? = nil
    var targetHeight: Int? = nil
    var padTop: Int = 80
    var padBottom: Int = 80
    var padLeft: Int = 80
    var padRight: Int = 80
    var anchor: ImageAnchorPosition = .center
    var preserveAspectRatio: Bool = false
    var fillMode: ImageCanvasFillMode = .white
    var customColor: CodableRGBAColor = .white
}

enum ImageBorderPlacement: String, CaseIterable, Codable, Sendable, Identifiable {
    case outer = "Outer Frame"
    case inner = "Inner Inset"

    var id: String { rawValue }
}

enum ImageBorderFillStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case solidColor = "Solid Color"
    case linearGradient = "Gradient"

    var id: String { rawValue }
}

struct ImageBorderFrameConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var placement: ImageBorderPlacement = .outer
    var useIndividualEdges: Bool = false
    var uniformWidth: Int = 24
    var topWidth: Int = 24
    var rightWidth: Int = 24
    var bottomWidth: Int = 24
    var leftWidth: Int = 24
    var fillStyle: ImageBorderFillStyle = .solidColor
    var primaryColor: CodableRGBAColor = .white
    var secondaryColor: CodableRGBAColor = CodableRGBAColor(red: 0.16, green: 0.36, blue: 0.72, alpha: 1.0)
    var gradientAngleDegrees: Double = 135.0
    var cornerRadius: Double = 0.0
    var shadowEnabled: Bool = false
    var shadowRadius: Double = 14.0
    var shadowOpacity: Double = 0.35

    var effectiveInsets: (top: Int, right: Int, bottom: Int, left: Int) {
        guard enabled else { return (0, 0, 0, 0) }
        if useIndividualEdges {
            return (max(0, topWidth), max(0, rightWidth), max(0, bottomWidth), max(0, leftWidth))
        }
        let u = max(0, uniformWidth)
        return (u, u, u, u)
    }

    var shadowMarginPixels: Int {
        guard enabled && shadowEnabled && placement == .outer else { return 0 }
        return max(4, Int((shadowRadius * 1.8).rounded(.up)))
    }
}

// MARK: - DPI / PPI Config

struct ImageDPIConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = false
    var targetDPI: Double = 300.0
    var resamplePixels: Bool = false
    var sourceDPI: Double = 72.0

    static let presets: [Double] = [72, 96, 150, 300, 600]
}

// MARK: - Metadata & Privacy Models

enum ImageMetadataPrivacyPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    case preserveAll = "Preserve All"
    case stripAll = "Remove All Metadata"
    case stripGPSOnly = "Strip GPS / Location Only"
    case stripCameraInfo = "Strip Camera & EXIF Hardware"
    case stripAuthorCopyright = "Strip Author & Copyright"
    case applyEditedMetadata = "Apply Edited Metadata"

    var id: String { rawValue }
}

struct ImageMetadataEditPayload: Codable, Sendable, Equatable, Hashable {
    var policy: ImageMetadataPrivacyPolicy = .preserveAll
    var title: String? = nil
    var author: String? = nil
    var copyright: String? = nil
    var description: String? = nil
    var keywordsCSV: String? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var stripGPS: Bool = false
    var stripCamera: Bool = false
    var stripRights: Bool = false
    var stripEXIF: Bool = false
    var stripIPTC: Bool = false
    var stripXMP: Bool = false
    var stripICC: Bool = false
    var stripSoftware: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decodeIfPresent(ImageMetadataPrivacyPolicy.self, forKey: .policy) ?? .preserveAll
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        copyright = try c.decodeIfPresent(String.self, forKey: .copyright)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        keywordsCSV = try c.decodeIfPresent(String.self, forKey: .keywordsCSV)
        cameraMake = try c.decodeIfPresent(String.self, forKey: .cameraMake)
        cameraModel = try c.decodeIfPresent(String.self, forKey: .cameraModel)
        stripGPS = try c.decodeIfPresent(Bool.self, forKey: .stripGPS) ?? false
        stripCamera = try c.decodeIfPresent(Bool.self, forKey: .stripCamera) ?? false
        stripRights = try c.decodeIfPresent(Bool.self, forKey: .stripRights) ?? false
        stripEXIF = try c.decodeIfPresent(Bool.self, forKey: .stripEXIF) ?? false
        stripIPTC = try c.decodeIfPresent(Bool.self, forKey: .stripIPTC) ?? false
        stripXMP = try c.decodeIfPresent(Bool.self, forKey: .stripXMP) ?? false
        stripICC = try c.decodeIfPresent(Bool.self, forKey: .stripICC) ?? false
        stripSoftware = try c.decodeIfPresent(Bool.self, forKey: .stripSoftware) ?? false
    }
}

// MARK: - Unified Image Toolbox Config

struct ImageToolboxConfig: Codable, Sendable, Equatable, Hashable {
    // Codec & compression
    var compressionProfile: ImageCompressionProfile = .balanced
    var quality: Double = 0.85              // 0.05 ... 1.0
    var webpLossless: Bool = false
    var jxlLossless: Bool = false
    var jxlEffort: Int = 7                  // 1 ... 9
    var jxlBitDepth: Int = 8                // 8 or 16
    var jxlDistance: Double? = nil          // nil = derive from quality
    var jxlTranscodeJPEG: Bool = false
    var jxlReconstructJPEG: Bool = false
    var preserveAlpha: Bool = true
    var preserveAnimation: Bool = true

    // Resize
    var resizeStrategy: ImageResizeStrategy = .none
    var resizeWidth: Int? = nil
    var resizeHeight: Int? = nil
    var resizePercentage: Double = 100.0
    var preserveAspectRatio: Bool = true
    var resamplingMethod: ImageResamplingMethod = .lanczos
    var postResizeSharpen: Double = 0.0
    var multiSizePresets: [ImageBatchSizePreset] = []
    var exportMultipleSizes: Bool = false

    // Upscale
    var upscale: ImageUpscaleConfig = ImageUpscaleConfig()

    // Crop & transform
    var cropTransform: ImageCropAndTransformConfig = ImageCropAndTransformConfig()

    // Perspective correction
    var perspective: ImagePerspectiveConfig = ImagePerspectiveConfig()

    // Canvas extension & border
    var canvasExtension: ImageCanvasExtensionConfig = ImageCanvasExtensionConfig()
    var borderFrame: ImageBorderFrameConfig = ImageBorderFrameConfig()

    // DPI / Physical print
    var dpiConfig: ImageDPIConfig = ImageDPIConfig()

    // Target file size
    var targetFileSizeEnabled: Bool = false
    var targetFileSizeBytes: Int64 = 500_000

    // Color management
    var colorTarget: ImageColorProfileTarget = .preserve

    // Watermark
    var watermark: ImageWatermarkConfig = ImageWatermarkConfig()

    // Background removal
    var backgroundRemoval: ImageBackgroundRemovalConfig = ImageBackgroundRemovalConfig()

    // Metadata & privacy
    var metadataEdit: ImageMetadataEditPayload = ImageMetadataEditPayload()

    // Phase 46 Non-Destructive Adjustments, Ordered Effects & Camera RAW Develop
    var colorAdjustments: ImageColorAdjustmentsConfig = ImageColorAdjustmentsConfig()
    var effectStack: [ImageEffectSlot] = []
    var rawDevelop: ImageRAWDevelopConfig = ImageRAWDevelopConfig()

    var hasPixelEdits: Bool {
        cropTransform.isActive
            || perspective.enabled
            || backgroundRemoval.enabled
            || colorTarget != .preserve
            || resizeStrategy != .none
            || upscale.enabled
            || (dpiConfig.enabled && dpiConfig.resamplePixels)
            || canvasExtension.enabled
            || borderFrame.enabled
            || watermark.enabled
            || targetFileSizeEnabled
            || !preserveAlpha
            || colorAdjustments.hasActiveAdjustments
            || effectStack.contains(where: \.isEnabled)
            || rawDevelop.hasNonDefaultParameters
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compressionProfile = try c.decodeIfPresent(ImageCompressionProfile.self, forKey: .compressionProfile) ?? .balanced
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.85
        webpLossless = try c.decodeIfPresent(Bool.self, forKey: .webpLossless) ?? false
        jxlLossless = try c.decodeIfPresent(Bool.self, forKey: .jxlLossless) ?? false
        jxlEffort = try c.decodeIfPresent(Int.self, forKey: .jxlEffort) ?? 7
        jxlBitDepth = try c.decodeIfPresent(Int.self, forKey: .jxlBitDepth) ?? 8
        jxlDistance = try c.decodeIfPresent(Double.self, forKey: .jxlDistance)
        jxlTranscodeJPEG = try c.decodeIfPresent(Bool.self, forKey: .jxlTranscodeJPEG) ?? false
        jxlReconstructJPEG = try c.decodeIfPresent(Bool.self, forKey: .jxlReconstructJPEG) ?? false
        preserveAlpha = try c.decodeIfPresent(Bool.self, forKey: .preserveAlpha) ?? true
        preserveAnimation = try c.decodeIfPresent(Bool.self, forKey: .preserveAnimation) ?? true
        resizeStrategy = try c.decodeIfPresent(ImageResizeStrategy.self, forKey: .resizeStrategy) ?? .none
        resizeWidth = try c.decodeIfPresent(Int.self, forKey: .resizeWidth)
        resizeHeight = try c.decodeIfPresent(Int.self, forKey: .resizeHeight)
        resizePercentage = try c.decodeIfPresent(Double.self, forKey: .resizePercentage) ?? 100.0
        preserveAspectRatio = try c.decodeIfPresent(Bool.self, forKey: .preserveAspectRatio) ?? true
        resamplingMethod = try c.decodeIfPresent(ImageResamplingMethod.self, forKey: .resamplingMethod) ?? .lanczos
        postResizeSharpen = try c.decodeIfPresent(Double.self, forKey: .postResizeSharpen) ?? 0.0
        multiSizePresets = try c.decodeIfPresent([ImageBatchSizePreset].self, forKey: .multiSizePresets) ?? []
        exportMultipleSizes = try c.decodeIfPresent(Bool.self, forKey: .exportMultipleSizes) ?? false
        upscale = try c.decodeIfPresent(ImageUpscaleConfig.self, forKey: .upscale) ?? ImageUpscaleConfig()
        cropTransform = try c.decodeIfPresent(ImageCropAndTransformConfig.self, forKey: .cropTransform) ?? ImageCropAndTransformConfig()
        perspective = try c.decodeIfPresent(ImagePerspectiveConfig.self, forKey: .perspective) ?? ImagePerspectiveConfig()
        canvasExtension = try c.decodeIfPresent(ImageCanvasExtensionConfig.self, forKey: .canvasExtension) ?? ImageCanvasExtensionConfig()
        borderFrame = try c.decodeIfPresent(ImageBorderFrameConfig.self, forKey: .borderFrame) ?? ImageBorderFrameConfig()
        dpiConfig = try c.decodeIfPresent(ImageDPIConfig.self, forKey: .dpiConfig) ?? ImageDPIConfig()
        targetFileSizeEnabled = try c.decodeIfPresent(Bool.self, forKey: .targetFileSizeEnabled) ?? false
        targetFileSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .targetFileSizeBytes) ?? 500_000
        colorTarget = try c.decodeIfPresent(ImageColorProfileTarget.self, forKey: .colorTarget) ?? .preserve
        watermark = try c.decodeIfPresent(ImageWatermarkConfig.self, forKey: .watermark) ?? ImageWatermarkConfig()
        backgroundRemoval = try c.decodeIfPresent(ImageBackgroundRemovalConfig.self, forKey: .backgroundRemoval) ?? ImageBackgroundRemovalConfig()
        metadataEdit = try c.decodeIfPresent(ImageMetadataEditPayload.self, forKey: .metadataEdit) ?? ImageMetadataEditPayload()
        colorAdjustments = try c.decodeIfPresent(ImageColorAdjustmentsConfig.self, forKey: .colorAdjustments) ?? ImageColorAdjustmentsConfig()
        effectStack = try c.decodeIfPresent([ImageEffectSlot].self, forKey: .effectStack) ?? []
        rawDevelop = try c.decodeIfPresent(ImageRAWDevelopConfig.self, forKey: .rawDevelop) ?? ImageRAWDevelopConfig()
    }

    // MARK: Serialization to ConversionOptions

    func applying(to baseOptions: ConversionOptions, outputFormat: FileFormat) -> ConversionOptions {
        var opts = baseOptions
        opts.imageQuality = quality
        opts.webpLossless = webpLossless
        opts.preserveMetadata = (metadataEdit.policy != .stripAll)

        if targetFileSizeEnabled && targetFileSizeBytes > 0 {
            opts.imageOptimizationMode = .targetFileSize
            opts.targetFileSizeBytes = targetFileSizeBytes
            opts.targetFileSizeMB = Double(targetFileSizeBytes) / (1024.0 * 1024.0)
        } else if (outputFormat == .jxl && jxlLossless) || (outputFormat == .webp && webpLossless) || compressionProfile == .archiveLossless {
            opts.imageOptimizationMode = .lossless
            opts.targetFileSizeBytes = nil
            opts.targetFileSizeMB = nil
        } else if compressionProfile == .maximumQuality {
            opts.imageOptimizationMode = .quality
        } else {
            opts.imageOptimizationMode = .custom
        }

        // Standard resize bridging when single-output simple resize is used
        switch resizeStrategy {
        case .none:
            opts.resizeMode = .none
        case .percentage:
            opts.resizeMode = .percentage
            opts.resizePercentage = resizePercentage / 100.0
        case .maxWidth:
            opts.resizeMode = .exactWidth
            opts.resizeWidth = resizeWidth
            opts.preserveAspectRatio = true
        case .maxHeight:
            opts.resizeMode = .exactHeight
            opts.resizeHeight = resizeHeight
            opts.preserveAspectRatio = true
        case .exactDimensions, .fitInside, .fill:
            opts.resizeMode = .exactDimensions
            opts.resizeWidth = resizeWidth
            opts.resizeHeight = resizeHeight
            opts.preserveAspectRatio = preserveAspectRatio
        }

        opts.customOptions["image_toolbox"] = "true"
        opts.customOptions["image_resampling"] = resamplingMethod.rawValue
        opts.customOptions["image_sharpen"] = String(format: "%.2f", postResizeSharpen)
        opts.customOptions["jxl_lossless"] = jxlLossless ? "true" : "false"
        opts.customOptions["jxl_effort"] = String(jxlEffort)
        opts.customOptions["jxl_bit_depth"] = String(jxlBitDepth)
        if let jxlDistance {
            opts.customOptions["jxl_distance"] = String(format: "%.3f", jxlDistance)
        } else {
            opts.customOptions.removeValue(forKey: "jxl_distance")
        }
        if jxlTranscodeJPEG {
            opts.customOptions["jxl_transcode_jpeg"] = "true"
        }
        if jxlReconstructJPEG {
            opts.customOptions["jxl_reconstruct_jpeg"] = "true"
        }

        if let data = try? JSONEncoder().encode(self),
           let json = String(data: data, encoding: .utf8) {
            opts.customOptions["image_toolbox_config"] = json
        }

        return opts
    }

    static func from(options: ConversionOptions) -> ImageToolboxConfig? {
        guard let json = options.customOptions["image_toolbox_config"],
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ImageToolboxConfig.self, from: data) else {
            return nil
        }
        return decoded
    }
}

// MARK: - Processing Output Telemetry

struct ImageProcessingTelemetry: Sendable, Equatable {
    let originalBytes: Int64
    let processedBytes: Int64
    let originalWidth: Int
    let originalHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let outputFormat: FileFormat
    let targetReached: Bool
    let finalQuality: Double?
    let warnings: [String]
    let note: String?

    var sizeReductionPercent: Double {
        guard originalBytes > 0 else { return 0 }
        return (Double(originalBytes - processedBytes) / Double(originalBytes)) * 100.0
    }
}

// MARK: - Shared Dimension & Scaling Calculator

enum ImageDimensionCalculator {
    static let maxEdgePixels: Int = 16_384
    static let maxTotalPixels: Int64 = 100_000_000

    static func orientedDimensions(
        width: Int,
        height: Int,
        rotationDegrees: Int,
        straightenDegrees: Double = 0.0,
        autoCropOnStraighten: Bool = true
    ) -> (width: Int, height: Int) {
        let norm = ((rotationDegrees % 360) + 360) % 360
        let base = (norm == 90 || norm == 270) ? (width: height, height: width) : (width: width, height: height)
        guard abs(straightenDegrees) > 0.01 else { return base }
        if autoCropOnStraighten {
            return ImageCropService.inscribedDimensions(width: base.width, height: base.height, angleDegrees: straightenDegrees)
        }
        let rad = abs(straightenDegrees) * .pi / 180.0
        let bw = Double(base.width) * cos(rad) + Double(base.height) * sin(rad)
        let bh = Double(base.width) * sin(rad) + Double(base.height) * cos(rad)
        return (max(1, Int(bw.rounded())), max(1, Int(bh.rounded())))
    }

    static func croppedDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        crop: ImageCropAndTransformConfig
    ) -> (width: Int, height: Int) {
        let oriented = orientedDimensions(
            width: sourceWidth,
            height: sourceHeight,
            rotationDegrees: crop.rotationDegrees,
            straightenDegrees: crop.straightenDegrees,
            autoCropOnStraighten: crop.autoCropOnStraighten
        )
        let w = Double(max(1, oriented.width))
        let h = Double(max(1, oriented.height))

        switch crop.cropMode {
        case .none:
            return (oriented.width, oriented.height)
        case .customRect:
            if let rect = crop.normalizedRect {
                let cw = max(1, min(oriented.width, Int((rect.width * w).rounded())))
                let ch = max(1, min(oriented.height, Int((rect.height * h).rounded())))
                return (cw, ch)
            }
            if let cw = crop.customWidth, let ch = crop.customHeight, cw > 0, ch > 0 {
                return (min(oriented.width, cw), min(oriented.height, ch))
            }
            return (oriented.width, oriented.height)
        case .centerCrop:
            if let cw = crop.customWidth, let ch = crop.customHeight,
               crop.effectiveRatioPreset == .freeform || crop.effectiveRatioPreset == .customRatio,
               cw > 0, ch > 0 {
                if crop.effectiveRatioPreset == .freeform && crop.aspectRatio == .original {
                    return (min(oriented.width, cw), min(oriented.height, ch))
                }
            }
            let targetRatio = crop.resolvedAspectRatio(sourceWidth: oriented.width, sourceHeight: oriented.height) ?? (w / h)
            let curRatio = w / h
            if curRatio > targetRatio {
                return (max(1, Int((h * targetRatio).rounded())), oriented.height)
            } else {
                return (oriented.width, max(1, Int((w / max(0.001, targetRatio)).rounded())))
            }
        }
    }

    static func resizedDimensions(
        currentWidth: Int,
        currentHeight: Int,
        strategy: ImageResizeStrategy,
        width: Int?,
        height: Int?,
        percentage: Double,
        preserveAspectRatio: Bool
    ) -> (width: Int, height: Int) {
        let curW = Double(max(1, currentWidth))
        let curH = Double(max(1, currentHeight))
        let ratio = curW / curH
        let clamp: (Double) -> Int = { max(1, min(maxEdgePixels, Int($0.rounded()))) }

        switch strategy {
        case .none:
            return (currentWidth, currentHeight)
        case .percentage:
            let factor = max(0.01, percentage / 100.0)
            return (clamp(curW * factor), clamp(curH * factor))
        case .maxWidth:
            let maxW = Double(max(1, width ?? currentWidth))
            if curW <= maxW { return (currentWidth, currentHeight) }
            return (clamp(maxW), clamp(maxW / ratio))
        case .maxHeight:
            let maxH = Double(max(1, height ?? currentHeight))
            if curH <= maxH { return (currentWidth, currentHeight) }
            return (clamp(maxH * ratio), clamp(maxH))
        case .fitInside:
            let boxW = Double(max(1, width ?? currentWidth))
            let boxH = Double(max(1, height ?? currentHeight))
            let scale = min(boxW / curW, boxH / curH)
            return (clamp(curW * scale), clamp(curH * scale))
        case .fill:
            return (clamp(Double(max(1, width ?? currentWidth))), clamp(Double(max(1, height ?? currentHeight))))
        case .exactDimensions:
            let reqW = Double(max(1, width ?? currentWidth))
            let reqH = Double(max(1, height ?? currentHeight))
            if preserveAspectRatio {
                if let w = width, height == nil {
                    return (clamp(Double(max(1, w))), clamp(Double(max(1, w)) / ratio))
                } else if let h = height, width == nil {
                    return (clamp(Double(max(1, h)) * ratio), clamp(Double(max(1, h))))
                } else {
                    let scale = min(reqW / curW, reqH / curH)
                    return (clamp(curW * scale), clamp(curH * scale))
                }
            }
            return (clamp(reqW), clamp(reqH))
        }
    }

    static func upscaledDimensions(
        currentWidth: Int,
        currentHeight: Int,
        upscale: ImageUpscaleConfig
    ) -> (width: Int, height: Int, clampedByMemoryGuard: Bool) {
        guard upscale.enabled else { return (currentWidth, currentHeight, false) }
        let curW = Double(max(1, currentWidth))
        let curH = Double(max(1, currentHeight))
        let ratio = curW / curH

        var rawW: Double
        var rawH: Double
        switch upscale.preset {
        case .scale2x, .scale3x, .scale4x, .customScale:
            let factor = upscale.effectiveScaleFactor
            rawW = curW * factor
            rawH = curH * factor
        case .targetDimensions:
            let reqW = Double(max(1, upscale.targetWidth ?? Int(curW * 2.0)))
            let reqH = Double(max(1, upscale.targetHeight ?? Int(curH * 2.0)))
            if upscale.preserveAspectRatio {
                if let w = upscale.targetWidth, upscale.targetHeight == nil {
                    rawW = Double(max(1, w))
                    rawH = rawW / ratio
                } else if let h = upscale.targetHeight, upscale.targetWidth == nil {
                    rawH = Double(max(1, h))
                    rawW = rawH * ratio
                } else {
                    let scale = min(reqW / curW, reqH / curH)
                    rawW = curW * scale
                    rawH = curH * scale
                }
            } else {
                rawW = reqW
                rawH = reqH
            }
        }

        var clamped = false
        if rawW > Double(maxEdgePixels) || rawH > Double(maxEdgePixels) {
            let edgeScale = min(Double(maxEdgePixels) / rawW, Double(maxEdgePixels) / rawH)
            rawW *= edgeScale
            rawH *= edgeScale
            clamped = true
        }
        let totalPx = rawW * rawH
        if totalPx > Double(maxTotalPixels) {
            let areaScale = sqrt(Double(maxTotalPixels) / totalPx)
            rawW *= areaScale
            rawH *= areaScale
            clamped = true
        }
        return (max(1, Int(rawW.rounded())), max(1, Int(rawH.rounded())), clamped)
    }

    static func extendedCanvasDimensions(
        currentWidth: Int,
        currentHeight: Int,
        canvas: ImageCanvasExtensionConfig
    ) -> (width: Int, height: Int) {
        guard canvas.enabled else { return (currentWidth, currentHeight) }
        switch canvas.mode {
        case .padding:
            let w = currentWidth + max(0, canvas.padLeft) + max(0, canvas.padRight)
            let h = currentHeight + max(0, canvas.padTop) + max(0, canvas.padBottom)
            return (min(maxEdgePixels, max(currentWidth, w)), min(maxEdgePixels, max(currentHeight, h)))
        case .dimensions:
            let reqW = max(1, canvas.targetWidth ?? currentWidth)
            let reqH = max(1, canvas.targetHeight ?? currentHeight)
            return (min(maxEdgePixels, reqW), min(maxEdgePixels, reqH))
        }
    }

    static func borderedDimensions(
        currentWidth: Int,
        currentHeight: Int,
        border: ImageBorderFrameConfig
    ) -> (width: Int, height: Int) {
        guard border.enabled else { return (currentWidth, currentHeight) }
        let margin = border.shadowMarginPixels * 2
        if border.placement == .outer {
            let ins = border.effectiveInsets
            let w = currentWidth + ins.left + ins.right + margin
            let h = currentHeight + ins.top + ins.bottom + margin
            return (min(maxEdgePixels, max(1, w)), min(maxEdgePixels, max(1, h)))
        }
        return (currentWidth, currentHeight)
    }

    static func dpiAdjustedDimensions(
        currentWidth: Int,
        currentHeight: Int,
        dpi: ImageDPIConfig
    ) -> (width: Int, height: Int) {
        guard dpi.enabled, dpi.resamplePixels, dpi.sourceDPI > 0, dpi.targetDPI > 0 else {
            return (currentWidth, currentHeight)
        }
        let scale = dpi.targetDPI / dpi.sourceDPI
        let w = max(1, min(maxEdgePixels, Int((Double(currentWidth) * scale).rounded())))
        let h = max(1, min(maxEdgePixels, Int((Double(currentHeight) * scale).rounded())))
        return (w, h)
    }

    static func expectedOutputDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        config: ImageToolboxConfig
    ) -> (width: Int, height: Int) {
        var cur = croppedDimensions(sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: config.cropTransform)
        if config.resizeStrategy != .none {
            cur = resizedDimensions(
                currentWidth: cur.width,
                currentHeight: cur.height,
                strategy: config.resizeStrategy,
                width: config.resizeWidth,
                height: config.resizeHeight,
                percentage: config.resizePercentage,
                preserveAspectRatio: config.preserveAspectRatio
            )
        }
        if config.upscale.enabled {
            let up = upscaledDimensions(currentWidth: cur.width, currentHeight: cur.height, upscale: config.upscale)
            cur = (up.width, up.height)
        }
        if config.dpiConfig.enabled && config.dpiConfig.resamplePixels {
            cur = dpiAdjustedDimensions(currentWidth: cur.width, currentHeight: cur.height, dpi: config.dpiConfig)
        }
        if config.canvasExtension.enabled {
            cur = extendedCanvasDimensions(currentWidth: cur.width, currentHeight: cur.height, canvas: config.canvasExtension)
        }
        if config.borderFrame.enabled {
            cur = borderedDimensions(currentWidth: cur.width, currentHeight: cur.height, border: config.borderFrame)
        }
        return cur
    }
}

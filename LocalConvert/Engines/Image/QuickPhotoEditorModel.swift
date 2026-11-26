import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision
import os.log

// MARK: - Quick Photo Editor Models

enum QuickPhotoCropAspect: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case free = "Free"
    case square = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"

    var id: String { rawValue }

    var ratioValue: Double? {
        switch self {
        case .free: return nil
        case .square: return 1.0
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        }
    }
}

enum QuickPhotoAnnotationKind: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case arrow = "Arrow"
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case pen = "Pen"
    case highlighter = "Highlighter"
    case text = "Text"
    case stepBadge = "Step"
    case spotHeal = "Spot Heal"
    case redactMosaic = "Mosaic"
    case redactBlur = "Blur"
    case redactSolid = "Blackout"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .stepBadge: return "1.circle.fill"
        case .spotHeal: return "bandage"
        case .redactMosaic: return "squareshape.split.3x3"
        case .redactBlur: return "aqi.medium"
        case .redactSolid: return "rectangle.fill"
        }
    }

    var isFreehandStroke: Bool {
        switch self {
        case .pen, .highlighter, .spotHeal:
            return true
        default:
            return false
        }
    }

    var isDragBox: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .redactMosaic, .redactBlur, .redactSolid:
            return true
        default:
            return false
        }
    }

    var isRedactionOrHeal: Bool {
        switch self {
        case .spotHeal, .redactMosaic, .redactBlur, .redactSolid:
            return true
        default:
            return false
        }
    }
}

enum QuickPhotoEditorTool: String, CaseIterable, Sendable, Equatable, Hashable, Identifiable {
    case none = "Browse"
    case crop = "Crop"
    case annotation = "Markup"

    var id: String { rawValue }
}

struct QuickPhotoAnnotation: Identifiable, Codable, Sendable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: QuickPhotoAnnotationKind
    /// Normalized `[0, 1]` top-left coordinates in oriented/cropped image space.
    var startPoint: CodableNormalizedPoint
    var endPoint: CodableNormalizedPoint
    var points: [CodableNormalizedPoint] = []
    var color: CodableRGBAColor = CodableRGBAColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
    var strokeWidth: Double = 4.0
    var text: String = ""
    var stepNumber: Int = 1
    var fontSize: Double = 22.0

    init(
        id: UUID = UUID(),
        kind: QuickPhotoAnnotationKind,
        startPoint: CodableNormalizedPoint,
        endPoint: CodableNormalizedPoint? = nil,
        points: [CodableNormalizedPoint] = [],
        color: CodableRGBAColor = CodableRGBAColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),
        strokeWidth: Double = 4.0,
        text: String = "",
        stepNumber: Int = 1,
        fontSize: Double = 22.0
    ) {
        self.id = id
        self.kind = kind
        self.startPoint = startPoint
        self.endPoint = endPoint ?? startPoint
        self.points = points
        self.color = color
        self.strokeWidth = max(1.0, min(64.0, strokeWidth))
        self.text = text
        self.stepNumber = max(1, stepNumber)
        self.fontSize = max(10.0, min(120.0, fontSize))
    }

    var normalizedBounds: CGRect {
        let minX = min(startPoint.x, endPoint.x)
        let minY = min(startPoint.y, endPoint.y)
        let maxX = max(startPoint.x, endPoint.x)
        let maxY = max(startPoint.y, endPoint.y)
        return CGRect(x: minX, y: minY, width: max(0.002, maxX - minX), height: max(0.002, maxY - minY))
    }
}

struct QuickPhotoAdjustments: Codable, Sendable, Equatable, Hashable {
    var autoEnhanceEnabled: Bool = false
    var exposure: Double = 0.0       // -2.0 ... +2.0 EV
    var brightness: Double = 0.0     // -0.5 ... +0.5
    var contrast: Double = 1.0       // 0.5 ... 2.0
    var saturation: Double = 1.0     // 0.0 ... 2.0
    var temperature: Double = 0.0    // -100.0 ... +100.0
    var sharpness: Double = 0.0      // 0.0 ... 2.0

    var isNeutral: Bool {
        !autoEnhanceEnabled
            && abs(exposure) < 0.001
            && abs(brightness) < 0.001
            && abs(contrast - 1.0) < 0.001
            && abs(saturation - 1.0) < 0.001
            && abs(temperature) < 0.01
            && abs(sharpness) < 0.001
    }

    mutating func clamped() {
        exposure = min(2.0, max(-2.0, exposure))
        brightness = min(0.5, max(-0.5, brightness))
        contrast = min(2.0, max(0.5, contrast))
        saturation = min(2.0, max(0.0, saturation))
        temperature = min(100.0, max(-100.0, temperature))
        sharpness = min(2.0, max(0.0, sharpness))
    }
}

enum QuickPhotoBackdropStyle: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case gradient = "Gradient"
    case solid = "Solid"

    var id: String { rawValue }
}

enum QuickPhotoBackdropGradientPreset: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case ocean = "Ocean"
    case sunset = "Sunset"
    case graphite = "Graphite"
    case aurora = "Aurora"
    case custom = "Custom"

    var id: String { rawValue }

    var colors: (start: CodableRGBAColor, end: CodableRGBAColor) {
        switch self {
        case .ocean:
            return (
                CodableRGBAColor(red: 0.14, green: 0.44, blue: 0.88, alpha: 1.0),
                CodableRGBAColor(red: 0.12, green: 0.78, blue: 0.76, alpha: 1.0)
            )
        case .sunset:
            return (
                CodableRGBAColor(red: 0.96, green: 0.45, blue: 0.28, alpha: 1.0),
                CodableRGBAColor(red: 0.65, green: 0.24, blue: 0.72, alpha: 1.0)
            )
        case .graphite:
            return (
                CodableRGBAColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0),
                CodableRGBAColor(red: 0.30, green: 0.33, blue: 0.39, alpha: 1.0)
            )
        case .aurora:
            return (
                CodableRGBAColor(red: 0.22, green: 0.72, blue: 0.56, alpha: 1.0),
                CodableRGBAColor(red: 0.24, green: 0.36, blue: 0.82, alpha: 1.0)
            )
        case .custom:
            return (
                CodableRGBAColor(red: 0.22, green: 0.48, blue: 0.86, alpha: 1.0),
                CodableRGBAColor(red: 0.46, green: 0.28, blue: 0.82, alpha: 1.0)
            )
        }
    }
}

struct QuickPhotoBackdropConfig: Codable, Sendable, Equatable, Hashable {
    var isEnabled: Bool = false
    var style: QuickPhotoBackdropStyle = .gradient
    var gradientPreset: QuickPhotoBackdropGradientPreset = .ocean
    var startColor: CodableRGBAColor = QuickPhotoBackdropGradientPreset.ocean.colors.start
    var endColor: CodableRGBAColor = QuickPhotoBackdropGradientPreset.ocean.colors.end
    var solidColor: CodableRGBAColor = CodableRGBAColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1.0)
    var padding: Double = 48.0          // 0 ... 240 px per edge
    var cornerRadius: Double = 14.0     // 0 ... 64 px
    var shadowRadius: Double = 18.0     // 0 ... 48 px
    var shadowOpacity: Double = 0.38    // 0.0 ... 1.0

    mutating func applyPreset(_ preset: QuickPhotoBackdropGradientPreset) {
        gradientPreset = preset
        if preset != .custom {
            let pair = preset.colors
            startColor = pair.start
            endColor = pair.end
        }
    }

    mutating func clamped() {
        padding = min(240.0, max(0.0, padding))
        cornerRadius = min(64.0, max(0.0, cornerRadius))
        shadowRadius = min(48.0, max(0.0, shadowRadius))
        shadowOpacity = min(1.0, max(0.0, shadowOpacity))
    }
}

struct QuickPhotoEditState: Codable, Sendable, Equatable, Hashable {
    var adjustments: QuickPhotoAdjustments = QuickPhotoAdjustments()
    var rotationQuarterTurns: Int = 0   // 0, 1, 2, 3 (90° CW increments)
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var cropAspect: QuickPhotoCropAspect = .free
    var cropRect: NormalizedRect? = nil
    var annotations: [QuickPhotoAnnotation] = []
    var backdrop: QuickPhotoBackdropConfig = QuickPhotoBackdropConfig()

    var normalizedRotationDegrees: Int {
        (((rotationQuarterTurns % 4) + 4) % 4) * 90
    }

    var isDefault: Bool {
        adjustments.isNeutral
            && normalizedRotationDegrees == 0
            && !flipHorizontal
            && !flipVertical
            && cropRect == nil
            && annotations.isEmpty
            && !backdrop.isEnabled
    }
}

struct QuickPhotoEXIFSummary: Sendable, Equatable {
    let formatName: String
    let pixelWidth: Int
    let pixelHeight: Int
    let fileSizeBytes: Int64
    let cameraSummary: String?
    let dateTaken: String?
    let dpiText: String?
    let gpsSummary: String?

    var dimensionsText: String {
        pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight) px" : "Unknown"
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: max(0, fileSizeBytes), countStyle: .file)
    }
}

// MARK: - Pure Non-Destructive Rendering, OCR, Sibling & Output Engine

enum QuickPhotoRenderEngine: Sendable {

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "QuickPhotoRenderEngine")

    /// Discovers sorted supported image siblings in the parent folder of `url`.
    static func loadSiblings(for url: URL) -> [URL] {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return fm.fileExists(atPath: url.path) ? [url] : []
        }

        let supported = entries.filter { candidate in
            guard isRegularSupportedImage(candidate) else { return false }
            return true
        }
        return supported.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func isRegularSupportedImage(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let format = FileFormat.from(extension: ext) {
            return format.category == .image
        }
        if let utType = UTType(filenameExtension: ext) {
            return utType.conforms(to: .image)
        }
        return false
    }

    static func writableFormat(for url: URL) -> FileFormat {
        let detected = FileDetector.detectFormat(url: url) ?? FileFormat.from(extension: url.pathExtension)
        guard let detected else { return .png }
        let cap = FormatCapabilityRegistry.shared.capability(for: detected)
        if cap.canWrite && detected.category == .image && ![FileFormat.ico, .icns, .gif, .apng].contains(detected) {
            return detected
        }
        return .png
    }

    static func canOverwriteOriginal(url: URL, format: FileFormat?) -> Bool {
        let fmt = format ?? FileDetector.detectFormat(url: url) ?? FileFormat.from(extension: url.pathExtension)
        guard let fmt else { return false }
        let cap = FormatCapabilityRegistry.shared.capability(for: fmt)
        return cap.canWrite && fmt.category == .image && ![FileFormat.ico, .icns, .gif, .apng].contains(fmt)
    }

    static func suggestedCopyURL(for sourceURL: URL) -> URL {
        let targetFormat = writableFormat(for: sourceURL)
        let baseName = FileFormat.baseNameByStrippingExtension(from: sourceURL)
        let copyBase = baseName.isEmpty ? "image_edited" : "\(baseName)_edited"
        return OutputReservationCoordinator.uniqueOutputURL(
            directory: sourceURL.deletingLastPathComponent(),
            baseName: copyBase,
            extension: targetFormat.fileExtension
        )
    }

    /// Computes final pixel dimensions given source pixel size and current edit state (orientation + crop + backdrop).
    static func predictedOutputDimensions(sourceWidth: Int, sourceHeight: Int, state: QuickPhotoEditState) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }
        let rot = state.normalizedRotationDegrees
        let swap = (rot == 90 || rot == 270)
        var w = swap ? sourceHeight : sourceWidth
        var h = swap ? sourceWidth : sourceHeight

        if let crop = state.cropRect {
            w = max(1, Int((crop.width * Double(w)).rounded()))
            h = max(1, Int((crop.height * Double(h)).rounded()))
        }

        if state.backdrop.isEnabled {
            let pad = max(0, Int(state.backdrop.padding.rounded()))
            w += pad * 2
            h += pad * 2
        }
        return (w, h)
    }

    /// On-device Apple Vision text recognition helper (`VNRecognizeTextRequest`).
    /// Returns empty string cleanly on tiny/blank images without crashing or performing network calls.
    static func extractText(from cgImage: CGImage) async throws -> String {
        guard cgImage.width >= 2, cgImage.height >= 2 else {
            return ""
        }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return lines.joined(separator: "\n")
        }.value
    }

    /// Full non-destructive Core Image + Core Graphics rendering pipeline.
    /// `maxDimension` optionally caps longest dimension for responsive interactive previews.
    static func renderCGImage(
        from sourceCGImage: CGImage,
        state: QuickPhotoEditState,
        maxDimension: Int? = nil
    ) -> CGImage? {
        guard sourceCGImage.width > 0, sourceCGImage.height > 0 else { return nil }

        return autoreleasepool {
            let workingSpace = (sourceCGImage.colorSpace?.model == .rgb ? sourceCGImage.colorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()

            // Optional preview downsample scale
            let sourceMax = max(sourceCGImage.width, sourceCGImage.height)
            let previewScale: CGFloat
            if let maxDim = maxDimension, maxDim > 0, sourceMax > maxDim {
                previewScale = CGFloat(maxDim) / CGFloat(sourceMax)
            } else {
                previewScale = 1.0
            }

            var ciImage = CIImage(cgImage: sourceCGImage)
            if previewScale < 0.999 {
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
                ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -ciImage.extent.minX, y: -ciImage.extent.minY))
            }

            // 1. Auto-Enhance (non-destructive CIFilter autoAdjustmentFilters)
            if state.adjustments.autoEnhanceEnabled {
                let filters = ciImage.autoAdjustmentFilters(options: [
                    .enhance: true,
                    .redEye: false
                ])
                let extent = ciImage.extent
                for filter in filters {
                    filter.setValue(ciImage, forKey: kCIInputImageKey)
                    if let out = filter.outputImage {
                        ciImage = out.cropped(to: extent)
                    }
                }
            }

            // 2. Lamina / Quick Color & Tone Adjustments
            ciImage = applyLaminaAdjustments(ciImage, adjustments: state.adjustments)

            // Rasterize adjustments before orientation/crop to ensure crisp pixel bounds
            let ciContext = ImageProcessor.sharedCIContext(for: workingSpace)
            let renderFmt = ImageProcessor.ciRenderFormat(for: sourceCGImage)
            let adjExtent = ciImage.extent.integral
            guard adjExtent.width >= 1, adjExtent.height >= 1,
                  var workingCG = ciContext.createCGImage(ciImage, from: adjExtent, format: renderFmt, colorSpace: workingSpace) else {
                return nil
            }

            // 3. Rotation (0/90/180/270) & Flip
            let rotDeg = state.normalizedRotationDegrees
            if rotDeg != 0 || state.flipHorizontal || state.flipVertical {
                if let oriented = try? ImageCropService.transformOrientation(
                    cgImage: workingCG,
                    rotationDegrees: rotDeg,
                    flipHorizontal: state.flipHorizontal,
                    flipVertical: state.flipVertical
                ) {
                    workingCG = oriented
                }
            }

            // 4. Rectangular Crop (top-left normalized coords)
            if let crop = state.cropRect {
                let w = CGFloat(workingCG.width)
                let h = CGFloat(workingCG.height)
                let pxRect = crop.pixelRect(for: CGSize(width: w, height: h))
                let x0 = max(0, min(w - 1, floor(pxRect.origin.x)))
                let y0 = max(0, min(h - 1, floor(pxRect.origin.y)))
                let cw = max(1, min(w - x0, round(pxRect.width)))
                let ch = max(1, min(h - y0, round(pxRect.height)))
                let bounded = CGRect(x: x0, y: y0, width: cw, height: ch)
                if let cropped = workingCG.cropping(to: bounded) {
                    workingCG = cropped
                }
            }

            // 5. Pixel-level Redaction & Spot-Heal Annotations
            let redactionAnnotations = state.annotations.filter(\.kind.isRedactionOrHeal)
            if !redactionAnnotations.isEmpty {
                workingCG = applyRedactionsAndSpotHeal(
                    to: workingCG,
                    annotations: redactionAnnotations,
                    ciContext: ciContext,
                    colorSpace: workingSpace,
                    scaleFactor: previewScale
                ) ?? workingCG
            }

            // 6. Vector Markup Annotations (Arrow, Rect, Ellipse, Pen, Highlighter, Text, Step Badges)
            let vectorAnnotations = state.annotations.filter { !$0.kind.isRedactionOrHeal }
            if !vectorAnnotations.isEmpty {
                workingCG = renderVectorAnnotations(
                    onto: workingCG,
                    annotations: vectorAnnotations,
                    colorSpace: workingSpace,
                    scaleFactor: previewScale
                ) ?? workingCG
            }

            // 7. CleanShot X-style Backdrop / Screenshot Frame
            if state.backdrop.isEnabled {
                workingCG = renderBackdrop(
                    around: workingCG,
                    config: state.backdrop,
                    colorSpace: workingSpace,
                    scaleFactor: previewScale
                ) ?? workingCG
            }

            if workingCG.width * workingCG.height >= 16_000_000 {
                ciContext.clearCaches()
            }

            return workingCG
        }
    }

    static func renderNSImage(
        from sourceCGImage: CGImage,
        state: QuickPhotoEditState,
        maxDimension: Int? = nil
    ) -> NSImage? {
        guard let cg = renderCGImage(from: sourceCGImage, state: state, maxDimension: maxDimension) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Pipeline Stages

    private static func applyLaminaAdjustments(_ input: CIImage, adjustments: QuickPhotoAdjustments) -> CIImage {
        var adj = adjustments
        adj.clamped()
        let extent = input.extent
        var current = input

        if abs(adj.temperature) > 0.01, let wb = CIFilter(name: "CITemperatureAndTint") {
            let neutralK = max(2_000.0, min(14_000.0, 6_500.0 + adj.temperature * 28.0))
            wb.setValue(current, forKey: kCIInputImageKey)
            wb.setValue(CIVector(x: neutralK, y: 0.0), forKey: "inputNeutral")
            wb.setValue(CIVector(x: 6_500.0, y: 0.0), forKey: "inputTargetNeutral")
            if let out = wb.outputImage {
                current = out.cropped(to: extent)
            }
        }

        if abs(adj.exposure) > 0.001, let exp = CIFilter(name: "CIExposureAdjust") {
            exp.setValue(current, forKey: kCIInputImageKey)
            exp.setValue(adj.exposure, forKey: kCIInputEVKey)
            if let out = exp.outputImage {
                current = out.cropped(to: extent)
            }
        }

        if abs(adj.brightness) > 0.001
            || abs(adj.contrast - 1.0) > 0.001
            || abs(adj.saturation - 1.0) > 0.001,
           let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(current, forKey: kCIInputImageKey)
            cc.setValue(adj.brightness, forKey: kCIInputBrightnessKey)
            cc.setValue(adj.contrast, forKey: kCIInputContrastKey)
            cc.setValue(adj.saturation, forKey: kCIInputSaturationKey)
            if let out = cc.outputImage {
                current = out.cropped(to: extent)
            }
        }

        if adj.sharpness > 0.001, let sharp = CIFilter(name: "CISharpenLuminance") {
            sharp.setValue(current, forKey: kCIInputImageKey)
            sharp.setValue(adj.sharpness, forKey: kCIInputSharpnessKey)
            if let out = sharp.outputImage {
                current = out.cropped(to: extent)
            }
        }

        return current
    }

    private static func applyRedactionsAndSpotHeal(
        to cgImage: CGImage,
        annotations: [QuickPhotoAnnotation],
        ciContext: CIContext,
        colorSpace: CGColorSpace,
        scaleFactor: CGFloat
    ) -> CGImage? {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        var current = CIImage(cgImage: cgImage)
        let extent = current.extent

        for ann in annotations {
            switch ann.kind {
            case .redactMosaic:
                let rect = ciRect(fromNormalizedTopLeft: ann.normalizedBounds, width: w, height: h).intersection(extent)
                guard !rect.isEmpty, let filter = CIFilter(name: "CIPixellate") else { continue }
                let blockScale = max(6.0, min(w, h) * 0.035)
                filter.setValue(current.clampedToExtent(), forKey: kCIInputImageKey)
                filter.setValue(blockScale, forKey: kCIInputScaleKey)
                filter.setValue(CIVector(x: rect.midX, y: rect.midY), forKey: kCIInputCenterKey)
                if let out = filter.outputImage?.cropped(to: rect) {
                    current = out.composited(over: current).cropped(to: extent)
                }

            case .redactBlur:
                let rect = ciRect(fromNormalizedTopLeft: ann.normalizedBounds, width: w, height: h).intersection(extent)
                guard !rect.isEmpty else { continue }
                let sigma = max(8.0, min(w, h) * 0.035)
                let blurred = current
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: sigma)
                    .cropped(to: rect)
                current = blurred.composited(over: current).cropped(to: extent)

            case .redactSolid:
                let rect = ciRect(fromNormalizedTopLeft: ann.normalizedBounds, width: w, height: h).intersection(extent)
                guard !rect.isEmpty else { continue }
                let blackPatch = CIImage(color: CIColor.black).cropped(to: rect)
                current = blackPatch.composited(over: current).cropped(to: extent)

            case .spotHeal:
                let strokePts = ann.points.isEmpty ? [ann.startPoint] : ann.points
                let brushRadius = max(6.0, CGFloat(ann.strokeWidth) * 2.2 * max(0.5, scaleFactor) * max(1.0, min(w, h) / 700.0))
                if let maskCI = makeSpotHealMask(points: strokePts, width: cgImage.width, height: cgImage.height, radius: brushRadius) {
                    // Build local neighborhood patch from surrounding pixels (median cleanup + smooth feather)
                    var patch = current.clampedToExtent()
                    if let median = CIFilter(name: "CIMedianFilter") {
                        median.setValue(patch, forKey: kCIInputImageKey)
                        if let mOut = median.outputImage {
                            patch = mOut
                        }
                    }
                    let blurSigma = max(6.0, brushRadius * 1.15)
                    let healed = patch.applyingGaussianBlur(sigma: blurSigma).cropped(to: extent)
                    let softMask = maskCI.applyingGaussianBlur(sigma: max(1.5, brushRadius * 0.25)).cropped(to: extent)
                    if let blend = CIFilter(name: "CIBlendWithMask") {
                        blend.setValue(healed, forKey: kCIInputImageKey)
                        blend.setValue(current, forKey: kCIInputBackgroundImageKey)
                        blend.setValue(softMask, forKey: kCIInputMaskImageKey)
                        if let out = blend.outputImage {
                            current = out.cropped(to: extent)
                        }
                    }
                }

            default:
                continue
            }
        }

        let fmt = ImageProcessor.ciRenderFormat(for: cgImage)
        return ciContext.createCGImage(current, from: extent, format: fmt, colorSpace: colorSpace)
    }

    private static func ciRect(fromNormalizedTopLeft norm: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let x = norm.minX * width
        let y = (1.0 - norm.maxY) * height
        let rw = max(1.0, norm.width * width)
        let rh = max(1.0, norm.height * height)
        return CGRect(x: x, y: y, width: rw, height: rh).integral
    }

    private static func makeSpotHealMask(
        points: [CodableNormalizedPoint],
        width: Int,
        height: Int,
        radius: CGFloat
    ) -> CIImage? {
        guard width > 0, height > 0, !points.isEmpty else { return nil }
        let grayCS = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: grayCS,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip to top-left normalized coordinates
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(gray: 1.0, alpha: 1.0)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(radius * 2.0)

        let w = CGFloat(width)
        let h = CGFloat(height)
        if points.count == 1 {
            let p = CGPoint(x: CGFloat(points[0].x) * w, y: CGFloat(points[0].y) * h)
            ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2.0, height: radius * 2.0))
        } else {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x) * w, y: CGFloat(points[0].y) * h))
            for pt in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(pt.x) * w, y: CGFloat(pt.y) * h))
            }
            ctx.strokePath()
        }

        guard let maskCG = ctx.makeImage() else { return nil }
        return CIImage(cgImage: maskCG)
    }

    private static func makeRGBContext(width: Int, height: Int, preferredColorSpace: CGColorSpace) -> CGContext? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: preferredColorSpace,
            bitmapInfo: bitmapInfo
        ) {
            return ctx
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgb,
            bitmapInfo: bitmapInfo
        )
    }

    private static func renderVectorAnnotations(
        onto cgImage: CGImage,
        annotations: [QuickPhotoAnnotation],
        colorSpace: CGColorSpace,
        scaleFactor: CGFloat
    ) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        guard let ctx = makeRGBContext(width: w, height: h, preferredColorSpace: colorSpace) else {
            return nil
        }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Flip to top-left coordinate system so normalized coordinates match UI directly
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let wf = CGFloat(w)
        let hf = CGFloat(h)
        let resMultiplier = max(1.0, min(wf, hf) / 900.0) * max(0.35, scaleFactor)

        for ann in annotations {
            let stroke = max(1.5, CGFloat(ann.strokeWidth) * resMultiplier)
            let cgColor = CGColor(
                srgbRed: ann.color.red,
                green: ann.color.green,
                blue: ann.color.blue,
                alpha: ann.color.alpha
            )

            switch ann.kind {
            case .rectangle:
                let rect = CGRect(
                    x: ann.normalizedBounds.minX * wf,
                    y: ann.normalizedBounds.minY * hf,
                    width: ann.normalizedBounds.width * wf,
                    height: ann.normalizedBounds.height * hf
                )
                ctx.setStrokeColor(cgColor)
                ctx.setLineWidth(stroke)
                ctx.setLineJoin(.round)
                ctx.stroke(rect)

            case .ellipse:
                let rect = CGRect(
                    x: ann.normalizedBounds.minX * wf,
                    y: ann.normalizedBounds.minY * hf,
                    width: ann.normalizedBounds.width * wf,
                    height: ann.normalizedBounds.height * hf
                )
                ctx.setStrokeColor(cgColor)
                ctx.setLineWidth(stroke)
                ctx.strokeEllipse(in: rect)

            case .arrow:
                let p1 = CGPoint(x: CGFloat(ann.startPoint.x) * wf, y: CGFloat(ann.startPoint.y) * hf)
                let p2 = CGPoint(x: CGFloat(ann.endPoint.x) * wf, y: CGFloat(ann.endPoint.y) * hf)
                drawArrow(in: ctx, from: p1, to: p2, color: cgColor, lineWidth: stroke)

            case .pen:
                let pts = ann.points.isEmpty ? [ann.startPoint, ann.endPoint] : ann.points
                drawStroke(in: ctx, points: pts, width: wf, height: hf, color: cgColor, lineWidth: stroke)

            case .highlighter:
                let pts = ann.points.isEmpty ? [ann.startPoint, ann.endPoint] : ann.points
                let hiColor = CGColor(
                    srgbRed: ann.color.red,
                    green: ann.color.green,
                    blue: ann.color.blue,
                    alpha: min(0.42, max(0.22, ann.color.alpha * 0.42))
                )
                drawStroke(in: ctx, points: pts, width: wf, height: hf, color: hiColor, lineWidth: stroke * 3.2)

            case .text:
                let trimmed = ann.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let anchor = CGPoint(x: CGFloat(ann.startPoint.x) * wf, y: CGFloat(ann.startPoint.y) * hf)
                let fontScale = max(0.5, min(wf, hf) >= 800 ? (min(wf, hf) / 800.0) : 1.0) * max(0.4, scaleFactor)
                let fontSize = max(12.0, CGFloat(ann.fontSize) * fontScale)
                let nsColor = NSColor(
                    srgbRed: ann.color.red,
                    green: ann.color.green,
                    blue: ann.color.blue,
                    alpha: ann.color.alpha
                )
                drawTextLabel(
                    trimmed,
                    at: anchor,
                    fontSize: fontSize,
                    color: nsColor,
                    canvasSize: CGSize(width: wf, height: hf),
                    in: ctx
                )

            case .stepBadge:
                let center = CGPoint(x: CGFloat(ann.startPoint.x) * wf, y: CGFloat(ann.startPoint.y) * hf)
                let radius = max(12.0, min(wf, hf) * 0.026 * max(0.45, scaleFactor))
                drawStepBadge(
                    number: ann.stepNumber,
                    center: center,
                    radius: radius,
                    fillColor: cgColor,
                    in: ctx
                )

            case .spotHeal, .redactMosaic, .redactBlur, .redactSolid:
                continue
            }
        }

        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func drawStroke(
        in ctx: CGContext,
        points: [CodableNormalizedPoint],
        width: CGFloat,
        height: CGFloat,
        color: CGColor,
        lineWidth: CGFloat
    ) {
        guard !points.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if points.count == 1 {
            let p = CGPoint(x: CGFloat(points[0].x) * width, y: CGFloat(points[0].y) * height)
            let r = lineWidth / 2.0
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: lineWidth, height: lineWidth))
        } else {
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(points[0].x) * width, y: CGFloat(points[0].y) * height))
            for pt in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: CGFloat(pt.x) * width, y: CGFloat(pt.y) * height))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawArrow(
        in ctx: CGContext,
        from p1: CGPoint,
        to p2: CGPoint,
        color: CGColor,
        lineWidth: CGFloat
    ) {
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let length = hypot(dx, dy)
        guard length > 1.0 else { return }

        let headLength = min(length * 0.45, max(12.0, lineWidth * 3.8))
        let headAngle: CGFloat = .pi / 6.5
        let angle = atan2(dy, dx)

        let shaftEnd = CGPoint(
            x: p2.x - cos(angle) * (headLength * 0.72),
            y: p2.y - sin(angle) * (headLength * 0.72)
        )

        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: p1)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let leftWing = CGPoint(
            x: p2.x - headLength * cos(angle - headAngle),
            y: p2.y - headLength * sin(angle - headAngle)
        )
        let rightWing = CGPoint(
            x: p2.x - headLength * cos(angle + headAngle),
            y: p2.y - headLength * sin(angle + headAngle)
        )
        ctx.beginPath()
        ctx.move(to: p2)
        ctx.addLine(to: leftWing)
        ctx.addLine(to: rightWing)
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawTextLabel(
        _ text: String,
        at anchor: CGPoint,
        fontSize: CGFloat,
        color: NSColor,
        canvasSize: CGSize,
        in ctx: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .shadow: shadow
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let measured = attrStr.size()
        let x = max(4, min(canvasSize.width - measured.width - 4, anchor.x))
        let y = max(4, min(canvasSize.height - measured.height - 4, anchor.y - measured.height * 0.5))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attrStr.draw(at: NSPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawStepBadge(
        number: Int,
        center: CGPoint,
        radius: CGFloat,
        fillColor: CGColor,
        in ctx: CGContext
    ) {
        let circleRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(fillColor)
        ctx.fillEllipse(in: circleRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.95))
        ctx.setLineWidth(max(1.5, radius * 0.14))
        ctx.strokeEllipse(in: circleRect)
        ctx.restoreGState()

        let text = "\(number)"
        let font = NSFont.systemFont(ofSize: radius * 1.1, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let drawPt = NSPoint(
            x: center.x - textSize.width / 2.0,
            y: center.y - textSize.height / 2.0
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attrStr.draw(at: drawPt)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func renderBackdrop(
        around cgImage: CGImage,
        config: QuickPhotoBackdropConfig,
        colorSpace: CGColorSpace,
        scaleFactor: CGFloat
    ) -> CGImage? {
        var cfg = config
        cfg.clamped()
        let imgW = cgImage.width
        let imgH = cgImage.height
        let pad = max(0, Int((CGFloat(cfg.padding) * scaleFactor).rounded()))
        let outW = imgW + pad * 2
        let outH = imgH + pad * 2
        guard outW > 0, outH > 0 else { return nil }

        guard let ctx = makeRGBContext(width: outW, height: outH, preferredColorSpace: colorSpace) else {
            return nil
        }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        let fullBounds = CGRect(x: 0, y: 0, width: outW, height: outH)
        switch cfg.style {
        case .solid:
            let fill = CGColor(
                srgbRed: cfg.solidColor.red,
                green: cfg.solidColor.green,
                blue: cfg.solidColor.blue,
                alpha: max(0.0, min(1.0, cfg.solidColor.alpha))
            )
            ctx.setFillColor(fill)
            ctx.fill(fullBounds)

        case .gradient:
            let c1 = CGColor(
                srgbRed: cfg.startColor.red,
                green: cfg.startColor.green,
                blue: cfg.startColor.blue,
                alpha: max(0.0, min(1.0, cfg.startColor.alpha))
            )
            let c2 = CGColor(
                srgbRed: cfg.endColor.red,
                green: cfg.endColor.green,
                blue: cfg.endColor.blue,
                alpha: max(0.0, min(1.0, cfg.endColor.alpha))
            )
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: [c1, c2] as CFArray, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: CGFloat(outH)),
                    end: CGPoint(x: CGFloat(outW), y: 0),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
        }

        let cardRect = CGRect(x: pad, y: pad, width: imgW, height: imgH)
        let cornerRadius = min(
            CGFloat(cfg.cornerRadius) * scaleFactor,
            min(cardRect.width, cardRect.height) / 2.0
        )
        let roundedPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        if cfg.shadowOpacity > 0.01 && cfg.shadowRadius > 0.1 {
            ctx.saveGState()
            let shadowOffset = CGSize(width: 0, height: -max(2.0, 6.0 * scaleFactor))
            let shadowBlur = CGFloat(cfg.shadowRadius) * scaleFactor
            ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: CGColor(gray: 0, alpha: cfg.shadowOpacity))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1.0))
            ctx.addPath(roundedPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(roundedPath)
        ctx.clip()
        ctx.draw(cgImage, in: cardRect)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

// MARK: - Observable Editor View Model (30-Step Undo/Redo + Safe Output + Sibling Navigation)

@MainActor
final class QuickPhotoEditorModel: ObservableObject {

    nonisolated static let defaultMaxHistoryCount = 30

    @Published private(set) var currentURL: URL
    @Published private(set) var siblings: [URL] = []
    @Published private(set) var currentSiblingIndex: Int = 0

    @Published private(set) var sourceCGImage: CGImage?
    private var sourceProperties: SendableImageProperties?
    @Published private(set) var sourceFormat: FileFormat?
    @Published private(set) var sourceFileSizeBytes: Int64 = 0
    @Published private(set) var exifSummary: QuickPhotoEXIFSummary?

    @Published private(set) var previewImage: NSImage?
    @Published private(set) var originalPreviewImage: NSImage?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isRendering: Bool = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    @Published private(set) var editState: QuickPhotoEditState = QuickPhotoEditState()
    @Published private(set) var undoStack: [QuickPhotoEditState] = []
    @Published private(set) var redoStack: [QuickPhotoEditState] = []

    @Published var activeTool: QuickPhotoEditorTool = .none
    @Published var activeAnnotationKind: QuickPhotoAnnotationKind = .arrow
    @Published var selectedColor: CodableRGBAColor = CodableRGBAColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
    @Published var strokeWidth: Double = 4.0
    @Published var textFontSize: Double = 22.0
    @Published private(set) var nextStepNumber: Int = 1
    @Published private(set) var lastExtractedOCRText: String?

    let maxHistoryCount: Int
    private let maxPreviewDimension: Int

    private var loadGeneration: Int = 0
    private var renderGeneration: Int = 0
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var continuousEditBaseline: QuickPhotoEditState?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasUnsavedChanges: Bool { !editState.isDefault }
    var canGoPrevious: Bool { currentSiblingIndex > 0 }
    var canGoNext: Bool { currentSiblingIndex + 1 < siblings.count }

    var canOverwriteOriginal: Bool {
        QuickPhotoRenderEngine.canOverwriteOriginal(url: currentURL, format: sourceFormat)
    }

    var predictedOutputDimensions: (width: Int, height: Int) {
        let w = sourceCGImage?.width ?? exifSummary?.pixelWidth ?? 0
        let h = sourceCGImage?.height ?? exifSummary?.pixelHeight ?? 0
        return QuickPhotoRenderEngine.predictedOutputDimensions(sourceWidth: w, sourceHeight: h, state: editState)
    }

    init(
        url: URL,
        maxHistoryCount: Int = 30,
        maxPreviewDimension: Int = 1800
    ) {
        self.currentURL = url
        self.maxHistoryCount = max(1, maxHistoryCount)
        self.maxPreviewDimension = max(256, maxPreviewDimension)
        self.siblings = QuickPhotoRenderEngine.loadSiblings(for: url)
        self.currentSiblingIndex = Self.findIndex(of: url, in: self.siblings) ?? 0
    }

    /// Deterministic initializer for unit testing without asynchronous disk loading.
    init(
        testImage: CGImage,
        url: URL = URL(fileURLWithPath: "/tmp/test-photo.png"),
        maxHistoryCount: Int = 30,
        maxPreviewDimension: Int = 1800
    ) {
        self.currentURL = url
        self.maxHistoryCount = max(1, maxHistoryCount)
        self.maxPreviewDimension = max(256, maxPreviewDimension)
        self.sourceCGImage = testImage
        self.sourceFormat = FileDetector.detectFormat(url: url) ?? .png
        self.exifSummary = QuickPhotoEXIFSummary(
            formatName: (self.sourceFormat ?? .png).displayName,
            pixelWidth: testImage.width,
            pixelHeight: testImage.height,
            fileSizeBytes: 0,
            cameraSummary: nil,
            dateTaken: nil,
            dpiText: nil,
            gpsSummary: nil
        )
        self.originalPreviewImage = NSImage(cgImage: testImage, size: NSSize(width: testImage.width, height: testImage.height))
        self.previewImage = self.originalPreviewImage
        self.siblings = QuickPhotoRenderEngine.loadSiblings(for: url)
        self.currentSiblingIndex = Self.findIndex(of: url, in: self.siblings) ?? 0
    }

    deinit {
        loadTask?.cancel()
        renderTask?.cancel()
    }

    // MARK: - Loading & Folder Sibling Navigation

    func startLoading() {
        loadTask?.cancel()
        let url = currentURL
        loadTask = Task { [weak self] in
            await self?.load(url: url)
        }
    }

    func load(url: URL) async {
        loadGeneration += 1
        let gen = loadGeneration
        renderTask?.cancel()

        currentURL = url
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        continuousEditBaseline = nil
        editState = QuickPhotoEditState()
        undoStack.removeAll()
        redoStack.removeAll()
        nextStepNumber = 1
        lastExtractedOCRText = nil

        let previewCap = maxPreviewDimension
        let result = await Task.detached(priority: .userInitiated) { () -> Result<LoadedImagePayload, Error> in
            do {
                let discoveredSiblings = QuickPhotoRenderEngine.loadSiblings(for: url)
                let decoded = try await ImageProcessingService.decodeInputImageWithRAW(
                    url: url,
                    maxPixelDimension: nil,
                    rawConfig: nil,
                    useProxyCache: false
                )
                let meta = ImageMetadataInspectorService.inspectDetailed(url: url)
                let cameraParts = [meta.cameraMake, meta.cameraModel, meta.lensModel]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let summary = QuickPhotoEXIFSummary(
                    formatName: meta.format?.displayName ?? url.pathExtension.uppercased(),
                    pixelWidth: decoded.cgImage.width,
                    pixelHeight: decoded.cgImage.height,
                    fileSizeBytes: decoded.fileSizeBytes,
                    cameraSummary: cameraParts.isEmpty ? nil : cameraParts.joined(separator: " · "),
                    dateTaken: meta.dateTaken,
                    dpiText: meta.dpiWidth.map { String(format: "%.0f DPI", $0) },
                    gpsSummary: meta.gpsSummary
                )
                let previewCG = QuickPhotoRenderEngine.renderCGImage(
                    from: decoded.cgImage,
                    state: QuickPhotoEditState(),
                    maxDimension: previewCap
                )
                return .success(LoadedImagePayload(
                    cgImage: decoded.cgImage,
                    properties: decoded.properties,
                    format: decoded.format,
                    fileSizeBytes: decoded.fileSizeBytes,
                    summary: summary,
                    previewCGImage: previewCG,
                    siblings: discoveredSiblings
                ))
            } catch {
                return .failure(error)
            }
        }.value

        guard gen == loadGeneration else { return }
        isLoading = false

        switch result {
        case .success(let payload):
            sourceCGImage = payload.cgImage
            sourceProperties = payload.properties
            sourceFormat = payload.format
            sourceFileSizeBytes = payload.fileSizeBytes
            exifSummary = payload.summary
            let previewNS = payload.previewCGImage.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            originalPreviewImage = previewNS
            previewImage = previewNS
            siblings = payload.siblings
            currentSiblingIndex = Self.findIndex(of: url, in: payload.siblings) ?? 0

        case .failure(let error):
            sourceCGImage = nil
            sourceProperties = nil
            previewImage = nil
            originalPreviewImage = nil
            errorMessage = error.localizedDescription
        }
    }

    func refreshSiblings() {
        let updated = QuickPhotoRenderEngine.loadSiblings(for: currentURL)
        siblings = updated
        currentSiblingIndex = Self.findIndex(of: currentURL, in: updated) ?? 0
    }

    func goToPreviousSibling() async {
        guard canGoPrevious else { return }
        await goToSibling(at: currentSiblingIndex - 1)
    }

    func goToNextSibling() async {
        guard canGoNext else { return }
        await goToSibling(at: currentSiblingIndex + 1)
    }

    func goToSibling(at index: Int) async {
        guard index >= 0, index < siblings.count else { return }
        let target = siblings[index]
        currentSiblingIndex = index
        await load(url: target)
    }

    // MARK: - 30-Step Undo / Redo & Edit State

    func applyEdit(_ mutate: (inout QuickPhotoEditState) -> Void) {
        var next = editState
        mutate(&next)
        next.adjustments.clamped()
        next.backdrop.clamped()
        guard next != editState else { return }

        pushUndoState(editState)
        redoStack.removeAll()
        editState = next
        syncNextStepNumber()
        schedulePreviewRender()
    }

    func beginContinuousEdit() {
        if continuousEditBaseline == nil {
            continuousEditBaseline = editState
        }
    }

    func updateInteractiveState(_ mutate: (inout QuickPhotoEditState) -> Void) {
        if continuousEditBaseline == nil {
            continuousEditBaseline = editState
        }
        var next = editState
        mutate(&next)
        next.adjustments.clamped()
        next.backdrop.clamped()
        guard next != editState else { return }
        editState = next
        schedulePreviewRender()
    }

    func endContinuousEdit() {
        guard let baseline = continuousEditBaseline else { return }
        continuousEditBaseline = nil
        guard editState != baseline else { return }
        pushUndoState(baseline)
        redoStack.removeAll()
    }

    func undo() {
        continuousEditBaseline = nil
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(editState)
        if redoStack.count > maxHistoryCount {
            redoStack.removeFirst(redoStack.count - maxHistoryCount)
        }
        editState = previous
        syncNextStepNumber()
        schedulePreviewRender()
    }

    func redo() {
        continuousEditBaseline = nil
        guard let next = redoStack.popLast() else { return }
        pushUndoState(editState)
        editState = next
        syncNextStepNumber()
        schedulePreviewRender()
    }

    func resetAllEdits() {
        applyEdit { state in
            state = QuickPhotoEditState()
        }
    }

    // MARK: - Lamina Adjustments & Geometry Shortcuts

    func toggleAutoEnhance() {
        applyEdit { state in
            state.adjustments.autoEnhanceEnabled.toggle()
        }
    }

    func rotateClockwise() {
        applyEdit { state in
            state.rotationQuarterTurns = (state.rotationQuarterTurns + 1) % 4
            state.cropRect = nil
        }
    }

    func rotateCounterClockwise() {
        applyEdit { state in
            state.rotationQuarterTurns = (state.rotationQuarterTurns + 3) % 4
            state.cropRect = nil
        }
    }

    func toggleFlipHorizontal() {
        applyEdit { state in
            state.flipHorizontal.toggle()
        }
    }

    func toggleFlipVertical() {
        applyEdit { state in
            state.flipVertical.toggle()
        }
    }

    func setCropAspect(_ aspect: QuickPhotoCropAspect) {
        applyEdit { state in
            state.cropAspect = aspect
            if let ratio = aspect.ratioValue {
                let dims = QuickPhotoRenderEngine.predictedOutputDimensions(
                    sourceWidth: sourceCGImage?.width ?? 100,
                    sourceHeight: sourceCGImage?.height ?? 100,
                    state: QuickPhotoEditState(
                        rotationQuarterTurns: state.rotationQuarterTurns,
                        flipHorizontal: state.flipHorizontal,
                        flipVertical: state.flipVertical
                    )
                )
                let imgRatio = Double(max(1, dims.width)) / Double(max(1, dims.height))
                var w = 0.85
                var h = w * (imgRatio / ratio)
                if h > 0.85 {
                    h = 0.85
                    w = h * (ratio / imgRatio)
                }
                state.cropRect = NormalizedRect(
                    x: (1.0 - w) / 2.0,
                    y: (1.0 - h) / 2.0,
                    width: w,
                    height: h
                )
            }
        }
    }

    func clearCrop() {
        applyEdit { state in
            state.cropRect = nil
            state.cropAspect = .free
        }
    }

    // MARK: - Annotations

    func addAnnotation(_ annotation: QuickPhotoAnnotation) {
        var resolved = annotation
        if resolved.kind == .stepBadge {
            resolved.stepNumber = nextStepNumber
        }
        applyEdit { state in
            state.annotations.append(resolved)
        }
    }

    func removeLastAnnotation() {
        guard !editState.annotations.isEmpty else { return }
        applyEdit { state in
            state.annotations.removeLast()
        }
    }

    func clearAnnotations() {
        guard !editState.annotations.isEmpty else { return }
        applyEdit { state in
            state.annotations.removeAll()
        }
    }

    // MARK: - Rendering

    func schedulePreviewRender() {
        guard let source = sourceCGImage else { return }
        renderGeneration += 1
        let gen = renderGeneration
        let snapshotState = editState
        let cap = maxPreviewDimension

        renderTask?.cancel()
        isRendering = true
        renderTask = Task { [weak self] in
            let renderedCG = await Task.detached(priority: .userInitiated) {
                QuickPhotoRenderEngine.renderCGImage(from: source, state: snapshotState, maxDimension: cap)
            }.value
            guard let self, !Task.isCancelled, gen == self.renderGeneration else { return }
            self.isRendering = false
            if let renderedCG {
                self.previewImage = NSImage(cgImage: renderedCG, size: NSSize(width: renderedCG.width, height: renderedCG.height))
            }
        }
    }

    func renderFullResolutionCGImage() -> CGImage? {
        guard let source = sourceCGImage else { return nil }
        return QuickPhotoRenderEngine.renderCGImage(from: source, state: editState, maxDimension: nil)
    }

    func renderFullResolutionCGImageAsync() async -> CGImage? {
        guard let source = sourceCGImage else { return nil }
        let snapshotState = editState
        return await Task.detached(priority: .userInitiated) {
            QuickPhotoRenderEngine.renderCGImage(from: source, state: snapshotState, maxDimension: nil)
        }.value
    }

    // MARK: - Vision OCR & Pasteboard

    func extractTextFromCurrentImage() async throws -> String {
        guard let cg = await renderFullResolutionCGImageAsync() else {
            return ""
        }
        let text = try await QuickPhotoRenderEngine.extractText(from: cg)
        lastExtractedOCRText = text
        return text
    }

    @discardableResult
    func copyExtractedTextToPasteboard() async throws -> String {
        let text = try await extractTextFromCurrentImage()
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusMessage = "Copied recognized text to clipboard."
        } else {
            statusMessage = "No text detected in image."
        }
        return text
    }

    @discardableResult
    func copyRenderedImageToPasteboard() async -> Bool {
        guard let cg = await renderFullResolutionCGImageAsync() else { return false }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.writeObjects([nsImage])
        statusMessage = ok ? "Copied image to clipboard." : "Failed to copy image."
        return ok
    }

    // MARK: - Atomic Output (Save Copy & Overwrite Original)

    func suggestedCopyURL() -> URL {
        QuickPhotoRenderEngine.suggestedCopyURL(for: currentURL)
    }

    @discardableResult
    func saveCopy(
        to destinationURL: URL,
        policy: ExistingFileHandling = .overwrite
    ) async throws -> URL {
        let stdDest = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        let stdSource = currentURL.standardizedFileURL.resolvingSymlinksInPath()
        if stdDest == stdSource {
            throw ConversionError.invalidInput(
                "Save Copy cannot overwrite the original file directly. Choose a new destination or use Overwrite Original."
            )
        }

        guard let rendered = await renderFullResolutionCGImageAsync() else {
            throw ConversionError.engineExecutionFailed("No image loaded to save.", underlyingError: nil)
        }

        let targetFormat = QuickPhotoRenderEngine.writableFormat(for: destinationURL)
        let props = sourceProperties
        let committed = try await Task.detached(priority: .userInitiated) {
            let encoded = try ImageProcessor.encodeToMemory(
                cgImage: rendered,
                format: targetFormat,
                quality: 0.92,
                lossless: (targetFormat == .png || targetFormat == .tiff || targetFormat == .bmp),
                sourceProperties: props?.raw,
                preserveMetadata: true
            )
            let parentDir = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let tempURL = parentDir.appendingPathComponent(".LocalConvert-stage-\(UUID().uuidString).\(targetFormat.fileExtension)")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try encoded.write(to: tempURL, options: .atomic)
            return try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempURL,
                to: destinationURL,
                policy: policy
            )
        }.value

        refreshSiblings()
        statusMessage = "Saved copy to \(committed.lastPathComponent)."
        return committed
    }

    @discardableResult
    func overwriteOriginal() async throws -> URL {
        guard canOverwriteOriginal else {
            throw ConversionError.unsupportedConversion(
                from: sourceFormat ?? .dng,
                to: sourceFormat ?? .png
            )
        }
        guard let rendered = await renderFullResolutionCGImageAsync() else {
            throw ConversionError.engineExecutionFailed("No image loaded to overwrite.", underlyingError: nil)
        }

        let destinationURL = currentURL
        let targetFormat = QuickPhotoRenderEngine.writableFormat(for: destinationURL)
        let props = sourceProperties

        let committed = try await Task.detached(priority: .userInitiated) {
            let encoded = try ImageProcessor.encodeToMemory(
                cgImage: rendered,
                format: targetFormat,
                quality: 0.92,
                lossless: (targetFormat == .png || targetFormat == .tiff || targetFormat == .bmp),
                sourceProperties: props?.raw,
                preserveMetadata: true
            )
            let parentDir = destinationURL.deletingLastPathComponent()
            let tempURL = parentDir.appendingPathComponent(".LocalConvert-overwrite-\(UUID().uuidString).\(targetFormat.fileExtension)")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try encoded.write(to: tempURL, options: .atomic)
            return try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempURL,
                to: destinationURL,
                policy: .overwrite
            )
        }.value

        await load(url: committed)
        statusMessage = "Updated \(committed.lastPathComponent)."
        return committed
    }

    @discardableResult
    func moveCurrentFileToTrash() async throws -> URL? {
        let target = currentURL
        let remaining = try await Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &resultingURL)
            return QuickPhotoRenderEngine.loadSiblings(for: target)
        }.value

        siblings = remaining
        if remaining.isEmpty {
            return nil
        }
        let nextIndex = min(currentSiblingIndex, remaining.count - 1)
        let nextURL = remaining[nextIndex]
        currentSiblingIndex = nextIndex
        await load(url: nextURL)
        return nextURL
    }

    // MARK: - Private Helpers

    private func pushUndoState(_ state: QuickPhotoEditState) {
        undoStack.append(state)
        if undoStack.count > maxHistoryCount {
            undoStack.removeFirst(undoStack.count - maxHistoryCount)
        }
    }

    private func syncNextStepNumber() {
        let maxStep = editState.annotations
            .filter { $0.kind == .stepBadge }
            .map(\.stepNumber)
            .max() ?? 0
        nextStepNumber = maxStep + 1
    }

    private static func findIndex(of url: URL, in list: [URL]) -> Int? {
        let std = url.standardizedFileURL
        return list.firstIndex { $0.standardizedFileURL == std }
    }
}

private struct LoadedImagePayload: Sendable {
    let cgImage: CGImage
    let properties: SendableImageProperties?
    let format: FileFormat?
    let fileSizeBytes: Int64
    let summary: QuickPhotoEXIFSummary
    let previewCGImage: CGImage?
    let siblings: [URL]
}

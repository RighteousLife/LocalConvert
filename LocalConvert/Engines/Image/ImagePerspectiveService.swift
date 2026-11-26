import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Projective Perspective Correction Service

enum ImagePerspectiveService {

    /// Detects the most prominent rectangular quad in the image via Apple Vision (`VNDetectRectanglesRequest`).
    /// Returns normalized corners in top-left display coordinates `(0...1)`.
    static func detectRectangleCorners(in cgImage: CGImage) -> (
        topLeft: CodableNormalizedPoint,
        topRight: CodableNormalizedPoint,
        bottomRight: CodableNormalizedPoint,
        bottomLeft: CodableNormalizedPoint
    )? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.55
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 45.0
        request.maximumObservations = 1

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let obs = request.results?.first else { return nil }
        return (
            topLeft: CodableNormalizedPoint(id: 0, x: Double(obs.topLeft.x), y: 1.0 - Double(obs.topLeft.y)),
            topRight: CodableNormalizedPoint(id: 1, x: Double(obs.topRight.x), y: 1.0 - Double(obs.topRight.y)),
            bottomRight: CodableNormalizedPoint(id: 2, x: Double(obs.bottomRight.x), y: 1.0 - Double(obs.bottomRight.y)),
            bottomLeft: CodableNormalizedPoint(id: 3, x: Double(obs.bottomLeft.x), y: 1.0 - Double(obs.bottomLeft.y))
        )
    }

    /// Applies a projective / homography transformation mapping the 4 source corners to a rectified rectangle.
    static func apply(
        cgImage: CGImage,
        config: ImagePerspectiveConfig,
        outputFormat: FileFormat
    ) throws -> CGImage {
        guard config.enabled else { return cgImage }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 1, h > 1 else { return cgImage }

        // Map top-down normalized coordinates -> Core Image bottom-left pixel coordinates
        func toCI(_ pt: CodableNormalizedPoint) -> CGPoint {
            CGPoint(x: CGFloat(pt.x) * w, y: (1.0 - CGFloat(pt.y)) * h)
        }

        let tl = toCI(config.topLeft)
        let tr = toCI(config.topRight)
        let br = toCI(config.bottomRight)
        let bl = toCI(config.bottomLeft)

        // Guard against degenerate zero-area quadrilaterals
        let topW = hypot(tr.x - tl.x, tr.y - tl.y)
        let botW = hypot(br.x - bl.x, br.y - bl.y)
        let leftH = hypot(tl.x - bl.x, tl.y - bl.y)
        let rightH = hypot(tr.x - br.x, tr.y - br.y)
        guard max(topW, botW) >= 4.0, max(leftH, rightH) >= 4.0 else {
            throw ConversionError.invalidInput("Perspective corners form a degenerate region.")
        }

        let ciInput = CIImage(cgImage: cgImage)
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciInput
        filter.topLeft = tl
        filter.topRight = tr
        filter.bottomRight = br
        filter.bottomLeft = bl

        guard var corrected = filter.outputImage else {
            throw ConversionError.engineExecutionFailed("Perspective correction filter produced no output.", underlyingError: nil)
        }

        let extent = corrected.extent.integral
        guard !extent.isEmpty, extent.width >= 1, extent.height >= 1 else {
            throw ConversionError.engineExecutionFailed("Perspective correction extent was empty.", underlyingError: nil)
        }

        let targetFormatSupportsAlpha = FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency
        let useTransparent = (config.fillMode == .transparent) && targetFormatSupportsAlpha

        if !useTransparent {
            let fillRGBA: CodableRGBAColor = {
                switch config.fillMode {
                case .transparent, .black: return .black
                case .white: return .white
                case .custom: return config.customColor
                }
            }()
            let bgCI = CIImage(color: CIColor(
                red: CGFloat(fillRGBA.red),
                green: CGFloat(fillRGBA.green),
                blue: CGFloat(fillRGBA.blue),
                alpha: 1.0
            )).cropped(to: extent)
            corrected = corrected.composited(over: bgCI)
        }

        // Enforce memory ceiling matching ImageDimensionCalculator (16,384 px / 100 MP)
        let maxEdge = CGFloat(ImageDimensionCalculator.maxEdgePixels)
        let maxTotal = Double(ImageDimensionCalculator.maxTotalPixels)
        var renderScale: CGFloat = 1.0
        if extent.width > maxEdge || extent.height > maxEdge {
            renderScale = min(maxEdge / extent.width, maxEdge / extent.height)
        }
        let area = Double(extent.width * renderScale) * Double(extent.height * renderScale)
        if area > maxTotal {
            renderScale *= CGFloat(sqrt(maxTotal / area))
        }

        if renderScale < 0.999 {
            corrected = corrected.transformed(by: CGAffineTransform(scaleX: renderScale, y: renderScale))
        }

        let finalExtent = corrected.extent.integral
        let outCS = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let targetFormat = ImageProcessor.ciRenderFormat(for: cgImage)
        let rendered = autoreleasepool { () -> CGImage? in
            let ciContext = ImageProcessor.sharedCIContext(for: outCS)
            let img = ciContext.createCGImage(corrected, from: finalExtent, format: targetFormat, colorSpace: outCS)
            if Int(finalExtent.width) * Int(finalExtent.height) >= 16_000_000 {
                ciContext.clearCaches()
            }
            return img
        }
        guard let rendered else {
            throw ConversionError.engineExecutionFailed("Failed to render perspective-corrected image.", underlyingError: nil)
        }
        return rendered
    }
}

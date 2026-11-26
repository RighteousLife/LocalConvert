import Foundation
import CoreGraphics
import CoreImage
import Vision

// MARK: - Image Background Removal Service (On-Device Vision Segmentation)

enum ImageBackgroundRemovalService {

    /// Segments foreground subjects via Apple Vision (`VNGenerateForegroundInstanceMaskRequest`)
    /// and composites onto transparent alpha or a chosen solid color, with optional mask edge refinement.
    static func removeBackground(
        cgImage: CGImage,
        config: ImageBackgroundRemovalConfig
    ) throws -> CGImage {
        guard config.enabled else { return cgImage }
        let rawMask = try computeRawMaskCGImage(cgImage: cgImage)
        return try compositeWithMask(cgImage: cgImage, rawMaskCGImage: rawMask, config: config)
    }

    static func computeRawMaskCGImage(cgImage: CGImage) throws -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw ConversionError.invalidInput("Cannot remove background from a zero-sized image.")
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ConversionError.engineExecutionFailed(
                "No foreground subject could be detected for background removal.",
                underlyingError: nil
            )
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let ciMask = CIImage(cvPixelBuffer: maskBuffer)
        let maskCS = CGColorSpaceCreateDeviceGray()
        let ciContext = ImageProcessor.sharedCIContext(for: maskCS)
        let renderedMask = autoreleasepool {
            ciContext.createCGImage(ciMask, from: ciMask.extent, format: .L8, colorSpace: maskCS)
        }
        guard let renderedMask else {
            throw ConversionError.engineExecutionFailed("Failed to rasterize foreground mask.", underlyingError: nil)
        }
        return renderedMask
    }

    static func compositeWithMask(
        cgImage: CGImage,
        rawMaskCGImage: CGImage,
        config: ImageBackgroundRemovalConfig
    ) throws -> CGImage {
        guard config.enabled else { return cgImage }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw ConversionError.invalidInput("Cannot remove background from a zero-sized image.")
        }

        let ciInput = CIImage(cgImage: cgImage)
        var ciMask = CIImage(cgImage: rawMaskCGImage)

        // Ensure mask aligns pixel-for-pixel with input extent
        if ciMask.extent.size != ciInput.extent.size {
            let sx = ciInput.extent.width / max(1.0, ciMask.extent.width)
            let sy = ciInput.extent.height / max(1.0, ciMask.extent.height)
            ciMask = ciMask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        // Edge refinement (soft blur + gentle contrast tightening on mask boundary)
        let radius = max(0.0, min(8.0, config.edgeRefinement))
        if radius > 0.05 {
            ciMask = ciMask
                .clampedToExtent()
                .applyingGaussianBlur(sigma: radius * 0.5)
                .cropped(to: ciInput.extent)
            if let controls = CIFilter(name: "CIColorControls") {
                controls.setValue(ciMask, forKey: kCIInputImageKey)
                controls.setValue(1.18, forKey: kCIInputContrastKey)
                controls.setValue(-0.04, forKey: kCIInputBrightnessKey)
                if let refined = controls.outputImage {
                    ciMask = refined.cropped(to: ciInput.extent)
                }
            }
        }

        let background: CIImage
        switch config.fillMode {
        case .transparent:
            background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: ciInput.extent)
        case .solidColor:
            let c = config.solidColor
            background = CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha))
                .cropped(to: ciInput.extent)
        }

        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw ConversionError.engineExecutionFailed("CoreImage CIBlendWithMask filter is unavailable.", underlyingError: nil)
        }
        blend.setValue(ciInput, forKey: kCIInputImageKey)
        blend.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend.setValue(ciMask, forKey: kCIInputMaskImageKey)

        guard let outputCI = blend.outputImage?.cropped(to: ciInput.extent) else {
            throw ConversionError.engineExecutionFailed("Failed to composite foreground segmentation mask.", underlyingError: nil)
        }

        let cs = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let targetFormat = ImageProcessor.ciRenderFormat(for: cgImage)
        let outputCG = autoreleasepool { () -> CGImage? in
            let ciContext = ImageProcessor.sharedCIContext(for: cs)
            let rendered = ciContext.createCGImage(outputCI, from: ciInput.extent, format: targetFormat, colorSpace: cs)
            if cgImage.width * cgImage.height >= 16_000_000 {
                ciContext.clearCaches()
            }
            return rendered
        }
        guard let outputCG else {
            throw ConversionError.engineExecutionFailed("Failed to render background-removed image.", underlyingError: nil)
        }
        return outputCG
    }
}

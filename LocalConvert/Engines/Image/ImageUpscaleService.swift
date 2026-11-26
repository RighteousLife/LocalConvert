import Foundation
import CoreGraphics
import CoreImage

// MARK: - Conventional High-Quality Image Upscale Service

enum ImageUpscaleService {

    struct UpscaleOutput: Sendable {
        let cgImage: CGImage
        let requestedWidth: Int
        let requestedHeight: Int
        let wasMemoryClamped: Bool
    }

    static func upscale(
        cgImage: CGImage,
        config: ImageUpscaleConfig
    ) throws -> UpscaleOutput {
        guard config.enabled else {
            return UpscaleOutput(
                cgImage: cgImage,
                requestedWidth: cgImage.width,
                requestedHeight: cgImage.height,
                wasMemoryClamped: false
            )
        }
        guard cgImage.width > 0, cgImage.height > 0 else {
            throw ConversionError.invalidInput("Cannot upscale zero-sized image.")
        }

        let target = ImageDimensionCalculator.upscaledDimensions(
            currentWidth: cgImage.width,
            currentHeight: cgImage.height,
            upscale: config
        )

        if target.width == cgImage.width && target.height == cgImage.height {
            return UpscaleOutput(
                cgImage: cgImage,
                requestedWidth: target.width,
                requestedHeight: target.height,
                wasMemoryClamped: target.clampedByMemoryGuard
            )
        }

        let colorSpace = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = ImageProcessor.sharedCIContext(for: colorSpace)

        var workingImage = cgImage

        // Optional pre-denoise for compressed JPEG sources before enlargement
        if config.artifactReduction > 0.02, let nr = CIFilter(name: "CINoiseReduction") {
            let denoised: CGImage? = autoreleasepool {
                let ciInput = CIImage(cgImage: workingImage)
                nr.setValue(ciInput, forKey: kCIInputImageKey)
                nr.setValue(0.015 * config.artifactReduction, forKey: "inputNoiseLevel")
                nr.setValue(0.35, forKey: kCIInputSharpnessKey)
                guard let out = nr.outputImage else { return nil }
                let fmt = ImageProcessor.ciRenderFormat(for: workingImage)
                let rendered = ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: workingImage.width, height: workingImage.height), format: fmt, colorSpace: colorSpace)
                if workingImage.width * workingImage.height >= 16_000_000 {
                    ciContext.clearCaches()
                }
                return rendered
            }
            if let cg = denoised {
                workingImage = cg
            }
        }

        try Task.checkCancellation()

        // Multi-step progressive scaling (max <= 2.0x per pass) reduces Lanczos haloing on 3x / 4x enlargements
        let totalScaleX = Double(target.width) / Double(workingImage.width)
        let totalScaleY = Double(target.height) / Double(workingImage.height)
        let maxRatio = max(totalScaleX, totalScaleY)

        let resampleMethod: ImageResamplingMethod = (config.method == .bicubic) ? .bicubic : .lanczos
        var stepped = workingImage

        if maxRatio > 2.1 {
            let intermediateW = max(1, Int((Double(workingImage.width) * sqrt(totalScaleX)).rounded()))
            let intermediateH = max(1, Int((Double(workingImage.height) * sqrt(totalScaleY)).rounded()))
            stepped = try ImageProcessor.resampleCGImage(
                stepped,
                width: intermediateW,
                height: intermediateH,
                method: resampleMethod,
                sharpenAmount: 0.0
            )
            try Task.checkCancellation()
        }

        var upscaled = try ImageProcessor.resampleCGImage(
            stepped,
            width: target.width,
            height: target.height,
            method: resampleMethod,
            sharpenAmount: 0.0
        )

        try Task.checkCancellation()

        // Edge-preserving detail / micro-contrast recovery
        let detail = max(0.0, min(1.0, config.detailEnhancement))
        if (config.method == .lanczosDetail || detail > 0.02), detail > 0.01 {
            let outCS = (upscaled.colorSpace?.model == .rgb ? upscaled.colorSpace : nil) ?? colorSpace
            let outFmt = ImageProcessor.ciRenderFormat(for: upscaled)
            let enhanced: CGImage? = autoreleasepool {
                let ciInput = CIImage(cgImage: upscaled)
                var refined = ciInput

                if let unsharp = CIFilter(name: "CIUnsharpMask") {
                    unsharp.setValue(refined, forKey: kCIInputImageKey)
                    unsharp.setValue(1.1 + detail * 1.4, forKey: kCIInputRadiusKey)
                    unsharp.setValue(0.20 + detail * 0.55, forKey: kCIInputIntensityKey)
                    if let out = unsharp.outputImage {
                        refined = out
                    }
                }

                if config.method == .lanczosDetail, let sharpen = CIFilter(name: "CISharpenLuminance") {
                    sharpen.setValue(refined, forKey: kCIInputImageKey)
                    sharpen.setValue(0.12 + detail * 0.35, forKey: kCIInputSharpnessKey)
                    if let out = sharpen.outputImage {
                        refined = out
                    }
                }

                let targetBounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
                let ctx = ImageProcessor.sharedCIContext(for: outCS)
                let rendered = ctx.createCGImage(refined.cropped(to: targetBounds), from: targetBounds, format: outFmt, colorSpace: outCS)
                if target.width * target.height >= 16_000_000 {
                    ctx.clearCaches()
                }
                return rendered
            }
            if let cg = enhanced {
                upscaled = cg
            }
        }

        return UpscaleOutput(
            cgImage: upscaled,
            requestedWidth: target.width,
            requestedHeight: target.height,
            wasMemoryClamped: target.clampedByMemoryGuard
        )
    }
}

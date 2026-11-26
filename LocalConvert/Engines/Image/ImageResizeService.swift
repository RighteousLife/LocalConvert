import Foundation
import CoreGraphics

// MARK: - Image Resize Service

enum ImageResizeService {

    static func resize(
        cgImage: CGImage,
        strategy: ImageResizeStrategy,
        width: Int?,
        height: Int?,
        percentage: Double,
        preserveAspectRatio: Bool,
        method: ImageResamplingMethod,
        sharpenAmount: Double
    ) throws -> CGImage {
        let curW = Double(cgImage.width)
        let curH = Double(cgImage.height)
        guard curW > 0, curH > 0 else {
            throw ConversionError.invalidInput("Image has invalid zero dimensions.")
        }

        let ratio = curW / curH
        let clamp: (Double) -> Int = { max(1, min(16384, Int($0.rounded()))) }

        switch strategy {
        case .none:
            return cgImage

        case .percentage:
            guard percentage > 0 else {
                throw ConversionError.invalidInput("Resize percentage must be positive.")
            }
            let factor = percentage / 100.0
            let targetW = clamp(curW * factor)
            let targetH = clamp(curH * factor)
            if targetW == cgImage.width && targetH == cgImage.height { return cgImage }
            return try ImageProcessor.resampleCGImage(cgImage, width: targetW, height: targetH, method: method, sharpenAmount: sharpenAmount)

        case .maxWidth:
            let maxW = Double(width ?? Int(curW))
            guard maxW > 0 else { throw ConversionError.invalidInput("Width must be positive.") }
            if curW <= maxW { return cgImage }
            let targetW = clamp(maxW)
            let targetH = clamp(maxW / ratio)
            return try ImageProcessor.resampleCGImage(cgImage, width: targetW, height: targetH, method: method, sharpenAmount: sharpenAmount)

        case .maxHeight:
            let maxH = Double(height ?? Int(curH))
            guard maxH > 0 else { throw ConversionError.invalidInput("Height must be positive.") }
            if curH <= maxH { return cgImage }
            let targetH = clamp(maxH)
            let targetW = clamp(maxH * ratio)
            return try ImageProcessor.resampleCGImage(cgImage, width: targetW, height: targetH, method: method, sharpenAmount: sharpenAmount)

        case .fitInside:
            let boxW = Double(width ?? Int(curW))
            let boxH = Double(height ?? Int(curH))
            guard boxW > 0, boxH > 0 else { throw ConversionError.invalidInput("Target dimensions must be positive.") }
            let scale = min(boxW / curW, boxH / curH)
            let targetW = clamp(curW * scale)
            let targetH = clamp(curH * scale)
            if targetW == cgImage.width && targetH == cgImage.height { return cgImage }
            return try ImageProcessor.resampleCGImage(cgImage, width: targetW, height: targetH, method: method, sharpenAmount: sharpenAmount)

        case .fill:
            let targetW = clamp(Double(width ?? Int(curW)))
            let targetH = clamp(Double(height ?? Int(curH)))
            let scale = max(Double(targetW) / curW, Double(targetH) / curH)
            let scaledW = clamp(curW * scale)
            let scaledH = clamp(curH * scale)
            let scaled = try ImageProcessor.resampleCGImage(cgImage, width: scaledW, height: scaledH, method: method, sharpenAmount: sharpenAmount)
            if scaled.width == targetW && scaled.height == targetH {
                return scaled
            }
            let originX = max(0, (scaled.width - targetW) / 2)
            let originY = max(0, (scaled.height - targetH) / 2)
            let cropRect = CGRect(x: originX, y: originY, width: min(targetW, scaled.width), height: min(targetH, scaled.height))
            return scaled.cropping(to: cropRect) ?? scaled

        case .exactDimensions:
            let reqW = Double(width ?? Int(curW))
            let reqH = Double(height ?? Int(curH))
            guard reqW > 0, reqH > 0 else { throw ConversionError.invalidInput("Target dimensions must be positive.") }
            let targetW: Int
            let targetH: Int
            if preserveAspectRatio {
                if let width, height == nil {
                    targetW = clamp(Double(width))
                    targetH = clamp(Double(width) / ratio)
                } else if let height, width == nil {
                    targetH = clamp(Double(height))
                    targetW = clamp(Double(height) * ratio)
                } else {
                    let scale = min(reqW / curW, reqH / curH)
                    targetW = clamp(curW * scale)
                    targetH = clamp(curH * scale)
                }
            } else {
                targetW = clamp(reqW)
                targetH = clamp(reqH)
            }
            if targetW == cgImage.width && targetH == cgImage.height { return cgImage }
            return try ImageProcessor.resampleCGImage(cgImage, width: targetW, height: targetH, method: method, sharpenAmount: sharpenAmount)
        }
    }
}

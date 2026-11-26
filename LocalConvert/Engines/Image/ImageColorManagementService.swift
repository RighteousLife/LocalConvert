import Foundation
import CoreGraphics
import ImageIO

// MARK: - Image Color Management Service

enum ImageColorManagementService {

    /// Inspects embedded color space / ICC metadata for any raster or JXL image.
    static func inspectColorProfile(url: URL, cgImage: CGImage? = nil) -> ImageColorProfileInfo {
        let format = FileDetector.detectFormat(url: url)

        if format == .jxl, let info = try? JPEGXLCodec.inspect(url: url) {
            let cs = info.iccData.flatMap { CGColorSpace(iccData: $0 as CFData) }
            let name = friendlyProfileName(for: cs) ?? (info.hasICCProfile ? "Embedded ICC" : "sRGB IEC61966-2.1")
            let isWide = cs?.isWideGamutRGB ?? false
            return ImageColorProfileInfo(
                profileName: name,
                colorModel: info.numColorChannels == 1 ? "Gray" : "RGB",
                bitDepth: info.bitsPerSample,
                hasAlpha: info.hasAlpha,
                hasEmbeddedICC: info.hasICCProfile,
                iccSizeBytes: info.iccData?.count ?? 0,
                isWideGamut: isWide
            )
        }

        var workingImage = cgImage
        if workingImage == nil, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            workingImage = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }

        let cs = workingImage?.colorSpace
        let icc = cs?.copyICCData() as Data?
        let modelStr: String = {
            switch cs?.model {
            case .rgb: return "RGB"
            case .monochrome: return "Grayscale"
            case .cmyk: return "CMYK"
            case .lab: return "Lab"
            default: return "RGB"
            }
        }()

        return ImageColorProfileInfo(
            profileName: friendlyProfileName(for: cs) ?? "sRGB IEC61966-2.1",
            colorModel: modelStr,
            bitDepth: workingImage?.bitsPerComponent ?? 8,
            hasAlpha: workingImage.map {
                $0.alphaInfo != .none && $0.alphaInfo != .noneSkipFirst && $0.alphaInfo != .noneSkipLast
            } ?? false,
            hasEmbeddedICC: icc != nil && !(icc?.isEmpty ?? true),
            iccSizeBytes: icc?.count ?? 0,
            isWideGamut: cs?.isWideGamutRGB ?? false
        )
    }

    /// Transforms an image into a target color space cleanly via CoreGraphics color management while preserving alpha.
    static func convertColorProfile(
        cgImage: CGImage,
        target: ImageColorProfileTarget
    ) throws -> CGImage {
        guard target != .preserve else { return cgImage }

        let targetCSName: CFString = switch target {
        case .preserve: CGColorSpace.sRGB
        case .sRGB: CGColorSpace.sRGB
        case .displayP3: CGColorSpace.displayP3
        }

        guard let targetSpace = CGColorSpace(name: targetCSName) else {
            throw ConversionError.engineExecutionFailed("Target color space is unavailable on this system.", underlyingError: nil)
        }

        // Skip redundant conversion if source profile already matches target
        if let srcName = cgImage.colorSpace?.name, srcName == targetCSName {
            return cgImage
        }

        let hasAlpha = !(cgImage.alphaInfo == .none || cgImage.alphaInfo == .noneSkipLast || cgImage.alphaInfo == .noneSkipFirst)
        let bpc = cgImage.bitsPerComponent > 8 ? 16 : 8
        let byteOrder16 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue

        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        let bitmapInfo: UInt32 = (bpc == 16)
            ? (byteOrder16 | alphaInfo.rawValue)
            : (CGBitmapInfo.byteOrder32Big.rawValue | alphaInfo.rawValue)

        guard let ctx = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: bpc,
            bytesPerRow: 0,
            space: targetSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate color conversion context.", underlyingError: nil)
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let converted = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Color profile conversion failed.", underlyingError: nil)
        }
        return converted
    }

    private static func friendlyProfileName(for colorSpace: CGColorSpace?) -> String? {
        guard let colorSpace else { return nil }
        if let rawName = colorSpace.name as String? {
            if rawName.contains("DisplayP3") { return "Display P3" }
            if rawName.contains("SRGB") || rawName.contains("sRGB") { return "sRGB IEC61966-2.1" }
            if rawName.contains("AdobeRGB") { return "Adobe RGB (1998)" }
            if rawName.contains("ROMMRGB") || rawName.contains("ProPhoto") { return "ProPhoto RGB" }
            if rawName.contains("GenericRGB") { return "Generic RGB" }
            if rawName.contains("Gray") { return "Generic Gray" }
            return rawName
        }
        return nil
    }
}

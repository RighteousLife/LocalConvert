import Foundation
import CoreGraphics
import CoreImage
import AppKit
import ImageIO

// MARK: - Image Watermark Service

enum ImageWatermarkService {

    static func apply(
        cgImage: CGImage,
        config: ImageWatermarkConfig
    ) throws -> CGImage {
        guard config.enabled else { return cgImage }

        let baseW = CGFloat(cgImage.width)
        let baseH = CGFloat(cgImage.height)
        guard baseW > 0, baseH > 0 else {
            throw ConversionError.invalidInput("Cannot watermark an empty image.")
        }

        let overlayImage: CGImage
        switch config.kind {
        case .text:
            let trimmed = config.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return cgImage }
            overlayImage = try renderTextWatermark(text: trimmed, baseWidth: baseW, baseHeight: baseH, config: config)

        case .image:
            guard let path = config.watermarkImagePath, !path.isEmpty else { return cgImage }
            let url = URL(fileURLWithPath: path)
            overlayImage = try loadLogoImage(url: url, baseWidth: baseW, scalePercent: config.scalePercent)
        }

        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate watermark graphics context.", underlyingError: nil)
        }

        // Draw base image full-bleed
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: baseW, height: baseH))

        let clampedOpacity = max(0.0, min(1.0, config.opacity))
        ctx.setAlpha(clampedOpacity)

        let ow = CGFloat(overlayImage.width)
        let oh = CGFloat(overlayImage.height)
        let radians = -CGFloat(config.rotationDegrees) * .pi / 180.0

        if config.tiled {
            let stepX = max(ow + 24, ow * CGFloat(max(1.2, config.tileSpacingMultiplier)))
            let stepY = max(oh + 24, oh * CGFloat(max(1.2, config.tileSpacingMultiplier)))
            let startX = -baseW * 0.25
            let endX = baseW * 1.25
            let startY = -baseH * 0.25
            let endY = baseH * 1.25

            var y = startY
            var rowIndex = 0
            while y < endY {
                var x = startX + (rowIndex % 2 == 1 ? stepX * 0.5 : 0)
                while x < endX {
                    drawRotatedOverlay(ctx: ctx, overlay: overlayImage, center: CGPoint(x: x, y: y), size: CGSize(width: ow, height: oh), radians: radians)
                    x += stepX
                }
                y += stepY
                rowIndex += 1
            }
        } else {
            let margin = min(baseW, baseH) * CGFloat(max(0.0, min(25.0, config.marginPercent)) / 100.0)
            let center = anchorCenter(
                overlaySize: CGSize(width: ow, height: oh),
                canvasSize: CGSize(width: baseW, height: baseH),
                margin: margin,
                anchor: config.anchor
            )
            drawRotatedOverlay(ctx: ctx, overlay: overlayImage, center: center, size: CGSize(width: ow, height: oh), radians: radians)
        }

        guard let outImage = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to composite watermark onto image.", underlyingError: nil)
        }
        return outImage
    }

    private static func drawRotatedOverlay(
        ctx: CGContext,
        overlay: CGImage,
        center: CGPoint,
        size: CGSize,
        radians: CGFloat
    ) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        if abs(radians) > 0.0001 {
            ctx.rotate(by: radians)
        }
        ctx.draw(overlay, in: CGRect(x: -size.width / 2.0, y: -size.height / 2.0, width: size.width, height: size.height))
        ctx.restoreGState()
    }

    private static func anchorCenter(
        overlaySize: CGSize,
        canvasSize: CGSize,
        margin: CGFloat,
        anchor: ImageAnchorPosition
    ) -> CGPoint {
        // CoreGraphics coordinate system has y=0 at bottom-left
        let minX = margin + overlaySize.width / 2.0
        let midX = canvasSize.width / 2.0
        let maxX = canvasSize.width - margin - overlaySize.width / 2.0

        let topY = canvasSize.height - margin - overlaySize.height / 2.0
        let midY = canvasSize.height / 2.0
        let bottomY = margin + overlaySize.height / 2.0

        switch anchor {
        case .topLeft:     return CGPoint(x: minX, y: topY)
        case .top:         return CGPoint(x: midX, y: topY)
        case .topRight:    return CGPoint(x: maxX, y: topY)
        case .left:        return CGPoint(x: minX, y: midY)
        case .center:      return CGPoint(x: midX, y: midY)
        case .right:       return CGPoint(x: maxX, y: midY)
        case .bottomLeft:  return CGPoint(x: minX, y: bottomY)
        case .bottom:      return CGPoint(x: midX, y: bottomY)
        case .bottomRight: return CGPoint(x: maxX, y: bottomY)
        }
    }

    private static func renderTextWatermark(
        text: String,
        baseWidth: CGFloat,
        baseHeight: CGFloat,
        config: ImageWatermarkConfig
    ) throws -> CGImage {
        let shortest = min(baseWidth, baseHeight)
        let fontSize = max(12.0, shortest * CGFloat(max(1.0, min(25.0, config.fontSizePercent)) / 100.0))
        let font = NSFont(name: config.fontName, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)

        let nsColor = NSColor(
            srgbRed: config.textColor.red,
            green: config.textColor.green,
            blue: config.textColor.blue,
            alpha: config.textColor.alpha
        )

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = max(2.0, fontSize * 0.08)
        shadow.shadowOffset = NSSize(width: 1, height: -1)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor,
            .shadow: shadow
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let bounds = attrStr.boundingRect(
            with: NSSize(width: baseWidth * 2.0, height: baseHeight * 2.0),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let pad = ceil(fontSize * 0.35)
        let w = max(8, Int(ceil(bounds.width + pad * 2)))
        let h = max(8, Int(ceil(bounds.height + pad * 2)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate text watermark bitmap.", underlyingError: nil)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        attrStr.draw(in: NSRect(x: pad, y: pad, width: ceil(bounds.width) + 2, height: ceil(bounds.height) + 2))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = rep.cgImage else {
            throw ConversionError.engineExecutionFailed("Failed to rasterize text watermark.", underlyingError: nil)
        }
        return cg
    }

    private static func loadLogoImage(
        url: URL,
        baseWidth: CGFloat,
        scalePercent: Double
    ) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.invalidInput("Watermark image file not found: \(url.lastPathComponent)")
        }

        let rawLogo: CGImage
        if url.pathExtension.lowercased() == "jxl" {
            let dec = try JPEGXLCodec.decode(url: url, prefer16Bit: false, decodeAllFrames: false)
            guard let first = dec.primaryImage else {
                throw ConversionError.invalidInput("Could not decode JPEG XL watermark image.")
            }
            rawLogo = first
        } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            rawLogo = img
        } else if let nsImg = NSImage(contentsOf: url),
                  let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            rawLogo = cg
        } else {
            throw ConversionError.invalidInput("Unsupported watermark image file: \(url.lastPathComponent)")
        }

        let targetW = max(16, Int(round(baseWidth * CGFloat(max(2.0, min(90.0, scalePercent)) / 100.0))))
        let aspect = CGFloat(rawLogo.height) / max(1.0, CGFloat(rawLogo.width))
        let targetH = max(16, Int(round(CGFloat(targetW) * aspect)))
        return try ImageProcessor.resampleCGImage(rawLogo, width: targetW, height: targetH, method: .lanczos)
    }
}

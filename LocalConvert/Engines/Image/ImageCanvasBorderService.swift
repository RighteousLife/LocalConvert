import Foundation
import CoreGraphics

// MARK: - Shared Canvas Extension & Border/Frame Engine

enum ImageCanvasBorderService {

    /// Extends or crops canvas bounds without scaling existing image pixels.
    static func extendCanvas(
        cgImage: CGImage,
        config: ImageCanvasExtensionConfig,
        outputFormat: FileFormat
    ) throws -> CGImage {
        guard config.enabled else { return cgImage }

        let targetDims = ImageDimensionCalculator.extendedCanvasDimensions(
            currentWidth: cgImage.width,
            currentHeight: cgImage.height,
            canvas: config
        )

        let supportsAlpha = FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency
        let useTransparent = (config.fillMode == .transparent) && supportsAlpha
        let fillColor: CodableRGBAColor = {
            switch config.fillMode {
            case .transparent: return supportsAlpha ? .transparent : .white
            case .white: return .white
            case .black: return .black
            case .custom: return config.customColor
            }
        }()

        guard let ctx = makeContext(
            width: targetDims.width,
            height: targetDims.height,
            colorSpace: cgImage.colorSpace,
            opaque: !useTransparent
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate canvas extension buffer.", underlyingError: nil)
        }

        if !useTransparent {
            ctx.setFillColor(red: fillColor.red, green: fillColor.green, blue: fillColor.blue, alpha: max(0.0, min(1.0, fillColor.alpha)))
            ctx.fill(CGRect(x: 0, y: 0, width: targetDims.width, height: targetDims.height))
        } else {
            ctx.clear(CGRect(x: 0, y: 0, width: targetDims.width, height: targetDims.height))
        }

        let drawRect: CGRect
        switch config.mode {
        case .padding:
            // Core Graphics origin is bottom-left: y = padBottom places image cleanly with padTop above
            drawRect = CGRect(
                x: CGFloat(max(0, config.padLeft)),
                y: CGFloat(max(0, config.padBottom)),
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
        case .dimensions:
            let origin = anchoredOrigin(
                contentWidth: cgImage.width,
                contentHeight: cgImage.height,
                canvasWidth: targetDims.width,
                canvasHeight: targetDims.height,
                anchor: config.anchor
            )
            drawRect = CGRect(x: origin.x, y: origin.y, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        }

        ctx.draw(cgImage, in: drawRect)
        guard let output = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to finalize extended canvas.", underlyingError: nil)
        }
        return output
    }

    /// Applies an outer or inner border / frame with optional gradient, rounded corners, and drop shadow.
    static func applyBorder(
        cgImage: CGImage,
        config: ImageBorderFrameConfig,
        outputFormat: FileFormat
    ) throws -> CGImage {
        guard config.enabled else { return cgImage }

        let insets = config.effectiveInsets
        let margin = config.shadowMarginPixels
        let supportsAlpha = FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency
        let dims = ImageDimensionCalculator.borderedDimensions(
            currentWidth: cgImage.width,
            currentHeight: cgImage.height,
            border: config
        )

        let needsAlphaCanvas = (config.cornerRadius > 0 || (config.shadowEnabled && config.placement == .outer)) && supportsAlpha
        guard let ctx = makeContext(
            width: dims.width,
            height: dims.height,
            colorSpace: cgImage.colorSpace,
            opaque: !needsAlphaCanvas
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate border frame context.", underlyingError: nil)
        }

        if needsAlphaCanvas {
            ctx.clear(CGRect(x: 0, y: 0, width: dims.width, height: dims.height))
        } else {
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: dims.width, height: dims.height))
        }

        if config.placement == .outer {
            let cardRect = CGRect(
                x: CGFloat(margin),
                y: CGFloat(margin),
                width: CGFloat(dims.width - margin * 2),
                height: CGFloat(dims.height - margin * 2)
            )
            let outerRadius = min(CGFloat(max(0, config.cornerRadius)), min(cardRect.width, cardRect.height) / 2.0)
            let outerPath = CGPath(roundedRect: cardRect, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)

            // Draw real drop shadow under the framed outer card
            if config.shadowEnabled {
                ctx.saveGState()
                ctx.setShadow(
                    offset: CGSize(width: 0, height: -max(2.0, config.shadowRadius * 0.25)),
                    blur: CGFloat(max(1.0, config.shadowRadius)),
                    color: CGColor(red: 0, green: 0, blue: 0, alpha: max(0.05, min(1.0, config.shadowOpacity)))
                )
                ctx.setFillColor(red: config.primaryColor.red, green: config.primaryColor.green, blue: config.primaryColor.blue, alpha: 1.0)
                ctx.addPath(outerPath)
                ctx.fillPath()
                ctx.restoreGState()
            }

            // Fill frame background (solid or linear gradient) clipped to outer rounded path
            ctx.saveGState()
            ctx.addPath(outerPath)
            ctx.clip()
            fillShapeRect(in: ctx, rect: cardRect, config: config)

            // Draw original image inside the frame insets
            let innerRect = CGRect(
                x: cardRect.minX + CGFloat(insets.left),
                y: cardRect.minY + CGFloat(insets.bottom),
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
            let maxInset = max(insets.left, max(insets.right, max(insets.top, insets.bottom)))
            let innerRadius = max(0, outerRadius - CGFloat(maxInset) * 0.5)
            if innerRadius > 0 {
                let innerPath = CGPath(roundedRect: innerRect, cornerWidth: min(innerRadius, min(innerRect.width, innerRect.height) / 2.0), cornerHeight: min(innerRadius, min(innerRect.width, innerRect.height) / 2.0), transform: nil)
                ctx.addPath(innerPath)
                ctx.clip()
            }
            ctx.draw(cgImage, in: innerRect)
            ctx.restoreGState()
        } else {
            // Inner Inset border overlaid around edges of original dimensions
            let fullRect = CGRect(x: 0, y: 0, width: CGFloat(dims.width), height: CGFloat(dims.height))
            let radius = min(CGFloat(max(0, config.cornerRadius)), min(fullRect.width, fullRect.height) / 2.0)
            let outerPath = CGPath(roundedRect: fullRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            ctx.saveGState()
            if radius > 0 {
                ctx.addPath(outerPath)
                ctx.clip()
            }
            ctx.draw(cgImage, in: fullRect)

            let innerHole = CGRect(
                x: CGFloat(insets.left),
                y: CGFloat(insets.bottom),
                width: max(0, fullRect.width - CGFloat(insets.left + insets.right)),
                height: max(0, fullRect.height - CGFloat(insets.top + insets.bottom))
            )
            let borderBand = CGMutablePath()
            borderBand.addPath(outerPath)
            let holeRadius = max(0, radius - CGFloat(min(insets.left, insets.bottom)) * 0.5)
            borderBand.addRoundedRect(in: innerHole, cornerWidth: min(holeRadius, min(innerHole.width, innerHole.height) / 2.0), cornerHeight: min(holeRadius, min(innerHole.width, innerHole.height) / 2.0))
            ctx.addPath(borderBand)
            ctx.clip(using: .evenOdd)
            fillShapeRect(in: ctx, rect: fullRect, config: config)
            ctx.restoreGState()
        }

        guard let output = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to finalize bordered image.", underlyingError: nil)
        }
        return output
    }

    // MARK: - Private Drawing Helpers

    private static func fillShapeRect(in ctx: CGContext, rect: CGRect, config: ImageBorderFrameConfig) {
        if config.fillStyle == .solidColor {
            ctx.setFillColor(
                red: config.primaryColor.red,
                green: config.primaryColor.green,
                blue: config.primaryColor.blue,
                alpha: config.primaryColor.alpha
            )
            ctx.fill(rect)
            return
        }

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let c1 = CGColor(
            colorSpace: cs,
            components: [config.primaryColor.red, config.primaryColor.green, config.primaryColor.blue, config.primaryColor.alpha]
        )!
        let c2 = CGColor(
            colorSpace: cs,
            components: [config.secondaryColor.red, config.secondaryColor.green, config.secondaryColor.blue, config.secondaryColor.alpha]
        )!
        guard let gradient = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0.0, 1.0]) else {
            ctx.setFillColor(red: config.primaryColor.red, green: config.primaryColor.green, blue: config.primaryColor.blue, alpha: config.primaryColor.alpha)
            ctx.fill(rect)
            return
        }

        let rad = CGFloat(config.gradientAngleDegrees) * .pi / 180.0
        let dx = cos(rad) * rect.width * 0.5
        let dy = sin(rad) * rect.height * 0.5
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: center.x - dx, y: center.y - dy)
        let end = CGPoint(x: center.x + dx, y: center.y + dy)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?, opaque: Bool) -> CGContext? {
        let cs: CGColorSpace = {
            if let colorSpace, colorSpace.model == .rgb { return colorSpace }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | alpha.rawValue
        return CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        )
    }

    /// Maps `ImageAnchorPosition` to CoreGraphics bottom-left canvas coordinates.
    private static func anchoredOrigin(
        contentWidth: Int,
        contentHeight: Int,
        canvasWidth: Int,
        canvasHeight: Int,
        anchor: ImageAnchorPosition
    ) -> CGPoint {
        let cw = CGFloat(canvasWidth)
        let ch = CGFloat(canvasHeight)
        let iw = CGFloat(contentWidth)
        let ih = CGFloat(contentHeight)

        let x: CGFloat
        switch anchor {
        case .topLeft, .left, .bottomLeft: x = 0
        case .top, .center, .bottom: x = (cw - iw) / 2.0
        case .topRight, .right, .bottomRight: x = cw - iw
        }

        // CGContext y=0 is at the bottom edge
        let y: CGFloat
        switch anchor {
        case .bottomLeft, .bottom, .bottomRight: y = 0
        case .left, .center, .right: y = (ch - ih) / 2.0
        case .topLeft, .top, .topRight: y = ch - ih
        }

        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}

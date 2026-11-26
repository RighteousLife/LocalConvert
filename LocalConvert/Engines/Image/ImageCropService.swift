import Foundation
import CoreGraphics
import CoreImage
import Vision

// MARK: - Image Crop & Geometric Masking Service

enum ImageCropService {

    static func apply(
        cgImage: CGImage,
        config: ImageCropAndTransformConfig,
        outputFormat: FileFormat? = nil
    ) throws -> CGImage {
        var current = cgImage

        // 1. Apply Orientation (Rotation + Horizontal/Vertical Flip) first so normalized crop coordinates
        //    always map 1:1 with what the user sees on the interactive canvas.
        let normalizedRot = ((config.rotationDegrees % 360) + 360) % 360
        if normalizedRot != 0 || config.flipHorizontal || config.flipVertical {
            current = try transformOrientation(
                cgImage: current,
                rotationDegrees: normalizedRot,
                flipHorizontal: config.flipHorizontal,
                flipVertical: config.flipVertical
            )
        }

        // 1B. Continuous Straighten (-45° ... +45°) + optional auto-inscribed crop
        if abs(config.straightenDegrees) > 0.01 {
            current = try straighten(
                cgImage: current,
                degrees: config.straightenDegrees,
                autoCropInscribed: config.autoCropOnStraighten
            )
        }

        // 2. Stage A: True rectangular pixel crop
        if config.cropMode != .none {
            current = try performRectangularCrop(cgImage: current, config: config)
        }

        // 3. Stage B: Separated geometric shape mask & background fill
        if config.shape.isGeometricMask {
            let targetSupportsAlpha = outputFormat.map {
                FormatCapabilityRegistry.shared.capability(for: $0).supportsTransparency
            } ?? true

            current = try applyShapeMask(
                cgImage: current,
                config: config,
                preserveTransparency: (config.shapeBackgroundFill == .transparent) && targetSupportsAlpha
            )
        }

        return current
    }

    // MARK: - Stage A: Rectangular Pixel Crop

    static func performRectangularCrop(
        cgImage: CGImage,
        config: ImageCropAndTransformConfig
    ) throws -> CGImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 0, h > 0 else {
            throw ConversionError.invalidInput("Cannot crop zero-sized image.")
        }

        let rect: CGRect
        switch config.cropMode {
        case .none:
            return cgImage

        case .customRect:
            if let norm = config.normalizedRect {
                rect = norm.pixelRect(for: CGSize(width: w, height: h))
            } else if let cw = config.customWidth, let ch = config.customHeight, cw > 0, ch > 0 {
                let targetW = min(w, CGFloat(cw))
                let targetH = min(h, CGFloat(ch))
                rect = anchoredRect(width: targetW, height: targetH, inWidth: w, inHeight: h, anchor: config.anchor)
            } else {
                return cgImage
            }

        case .centerCrop:
            if let cw = config.customWidth, let ch = config.customHeight,
               config.aspectRatio == .original, config.ratioPreset == nil, cw > 0, ch > 0 {
                let targetW = min(w, CGFloat(cw))
                let targetH = min(h, CGFloat(ch))
                rect = anchoredRect(width: targetW, height: targetH, inWidth: w, inHeight: h, anchor: config.anchor)
            } else {
                let targetRatio = CGFloat(config.resolvedAspectRatio(sourceWidth: cgImage.width, sourceHeight: cgImage.height) ?? Double(w / h))
                let curRatio = w / h
                let targetW: CGFloat
                let targetH: CGFloat
                if curRatio > targetRatio {
                    targetH = h
                    targetW = round(h * targetRatio)
                } else {
                    targetW = w
                    targetH = round(w / max(0.001, targetRatio))
                }
                rect = anchoredRect(width: targetW, height: targetH, inWidth: w, inHeight: h, anchor: config.anchor)
            }
        }

        let x0 = max(0, min(w - 1, floor(rect.origin.x)))
        let y0 = max(0, min(h - 1, floor(rect.origin.y)))
        let cw = max(1, min(w - x0, round(rect.width)))
        let ch = max(1, min(h - y0, round(rect.height)))
        let bounded = CGRect(x: x0, y: y0, width: cw, height: ch)

        guard let cropped = cgImage.cropping(to: bounded) else {
            throw ConversionError.engineExecutionFailed("Crop operation failed at \(bounded).", underlyingError: nil)
        }
        return cropped
    }

    // MARK: - Stage B: Separated Geometric Shape Masking

    static func applyShapeMask(
        cgImage: CGImage,
        config: ImageCropAndTransformConfig,
        preserveTransparency: Bool
    ) throws -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return cgImage }

        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let colorSpace = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bpc = cgImage.bitsPerComponent > 8 ? 16 : 8
        let byteOrder16 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let alphaInfo: CGImageAlphaInfo = preserveTransparency ? .premultipliedLast : .noneSkipLast
        let bitmapInfo: UInt32 = (bpc == 16) ? (byteOrder16 | alphaInfo.rawValue) : alphaInfo.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: bpc,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate bitmap context for shape masking.", underlyingError: nil)
        }

        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        if preserveTransparency {
            ctx.clear(bounds)
        } else {
            let bg = config.shapeBackgroundColor
            ctx.setFillColor(red: bg.red, green: bg.green, blue: bg.blue, alpha: 1.0)
            ctx.fill(bounds)
        }

        // CoreGraphics origin is bottom-left; flip vertically so normalized UI top-left polygon vertices match pixel output.
        let path = cgPath(
            for: config.shape,
            in: bounds,
            cornerRadiusPercent: config.roundedCornerRadiusPercent,
            polygonVertices: config.effectivePolygonVertices,
            flippedTopLeftToCG: true
        )
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(cgImage, in: bounds)

        guard let masked = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to composite geometric crop mask.", underlyingError: nil)
        }
        return masked
    }

    /// Generates a CGPath for the requested geometric crop shape inside `rect`.
    static func cgPath(
        for shape: ImageCropShape,
        in rect: CGRect,
        cornerRadiusPercent: Double = 18.0,
        polygonVertices: [CodableNormalizedPoint] = [],
        flippedTopLeftToCG: Bool = false
    ) -> CGPath {
        let minEdge = min(rect.width, rect.height)

        func mapPoint(normX: Double, normY: Double) -> CGPoint {
            let px = rect.minX + CGFloat(normX) * rect.width
            let py = flippedTopLeftToCG
                ? rect.maxY - CGFloat(normY) * rect.height
                : rect.minY + CGFloat(normY) * rect.height
            return CGPoint(x: px, y: py)
        }

        switch shape {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)

        case .roundedRectangle:
            let clampedPct = max(0.0, min(50.0, cornerRadiusPercent))
            let radius = (clampedPct / 100.0) * minEdge
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        case .circle:
            let circleRect = CGRect(
                x: rect.midX - minEdge / 2.0,
                y: rect.midY - minEdge / 2.0,
                width: minEdge,
                height: minEdge
            )
            return CGPath(ellipseIn: circleRect, transform: nil)

        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)

        case .triangle:
            let path = CGMutablePath()
            path.move(to: mapPoint(normX: 0.5, normY: 0.0))
            path.addLine(to: mapPoint(normX: 1.0, normY: 1.0))
            path.addLine(to: mapPoint(normX: 0.0, normY: 1.0))
            path.closeSubpath()
            return path

        case .diamond:
            let path = CGMutablePath()
            path.move(to: mapPoint(normX: 0.5, normY: 0.0))
            path.addLine(to: mapPoint(normX: 1.0, normY: 0.5))
            path.addLine(to: mapPoint(normX: 0.5, normY: 1.0))
            path.addLine(to: mapPoint(normX: 0.0, normY: 0.5))
            path.closeSubpath()
            return path

        case .hexagon:
            let verts = CodableNormalizedPoint.regularPolygon(sides: 6, rotationDegrees: 0.0)
            let path = CGMutablePath()
            if let first = verts.first {
                path.move(to: mapPoint(normX: first.x, normY: first.y))
                for v in verts.dropFirst() {
                    path.addLine(to: mapPoint(normX: v.x, normY: v.y))
                }
                path.closeSubpath()
            }
            return path

        case .customPolygon:
            let verts = polygonVertices.count >= 3
                ? polygonVertices
                : CodableNormalizedPoint.regularPolygon(sides: 5, rotationDegrees: 0.0)
            let path = CGMutablePath()
            if let first = verts.first {
                path.move(to: mapPoint(normX: first.x, normY: first.y))
                for v in verts.dropFirst() {
                    path.addLine(to: mapPoint(normX: v.x, normY: v.y))
                }
                path.closeSubpath()
            }
            return path
        }
    }

    // MARK: - Orientation Helpers

    private static func anchoredRect(
        width targetW: CGFloat,
        height targetH: CGFloat,
        inWidth w: CGFloat,
        inHeight h: CGFloat,
        anchor: ImageAnchorPosition
    ) -> CGRect {
        let dx = max(0, w - targetW)
        let dy = max(0, h - targetH)
        let originX: CGFloat
        let originY: CGFloat

        switch anchor {
        case .topLeft:     originX = 0;       originY = 0
        case .top:         originX = dx / 2;  originY = 0
        case .topRight:    originX = dx;      originY = 0
        case .left:        originX = 0;       originY = dy / 2
        case .center:      originX = dx / 2;  originY = dy / 2
        case .right:       originX = dx;      originY = dy / 2
        case .bottomLeft:  originX = 0;       originY = dy
        case .bottom:      originX = dx / 2;  originY = dy
        case .bottomRight: originX = dx;      originY = dy
        }
        return CGRect(x: round(originX), y: round(originY), width: targetW, height: targetH)
    }

    static func transformOrientation(
        cgImage: CGImage,
        rotationDegrees: Int,
        flipHorizontal: Bool,
        flipVertical: Bool
    ) throws -> CGImage {
        let normRot = ((rotationDegrees % 360) + 360) % 360
        if normRot == 0 && !flipHorizontal && !flipVertical {
            return cgImage
        }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let swapDims = (normRot == 90 || normRot == 270)
        let outW = Int(swapDims ? h : w)
        let outH = Int(swapDims ? w : h)

        let colorSpace = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let hasAlpha = !(cgImage.alphaInfo == .none || cgImage.alphaInfo == .noneSkipLast || cgImage.alphaInfo == .noneSkipFirst)
        let bpc = cgImage.bitsPerComponent > 8 ? 16 : 8
        let byteOrder16 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let alphaBit = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let bitmapInfo: UInt32 = (bpc == 16) ? (byteOrder16 | alphaBit) : alphaBit

        let primaryCtx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: bpc,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
        let fallback16Ctx: CGContext? = (primaryCtx == nil && bpc == 16)
            ? CGColorSpace(name: CGColorSpace.itur_2020).flatMap {
                CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 16, bytesPerRow: 0, space: $0, bitmapInfo: bitmapInfo)
            }
            : nil
        guard let ctx = primaryCtx ?? fallback16Ctx ?? CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaBit
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate context for image rotation/flip.", underlyingError: nil)
        }

        ctx.translateBy(x: CGFloat(outW) / 2.0, y: CGFloat(outH) / 2.0)
        if normRot != 0 {
            ctx.rotate(by: -CGFloat(normRot) * .pi / 180.0)
        }
        ctx.scaleBy(x: flipHorizontal ? -1.0 : 1.0, y: flipVertical ? -1.0 : 1.0)
        ctx.draw(cgImage, in: CGRect(x: -w / 2.0, y: -h / 2.0, width: w, height: h))

        guard let result = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to render transformed image.", underlyingError: nil)
        }
        return result
    }

    // MARK: - Continuous Straightening & Inscribed Crop

    /// Computes exact inscribed axis-aligned dimensions (wOut, hOut) inside a rotated WxH rectangle with zero blank triangles.
    static func inscribedDimensions(width: Int, height: Int, angleDegrees: Double) -> (width: Int, height: Int) {
        let clampedAngle = min(45.0, max(-45.0, angleDegrees))
        guard abs(clampedAngle) > 0.01, width > 0, height > 0 else {
            return (width, height)
        }
        let W = Double(width)
        let H = Double(height)
        let a = abs(clampedAngle) * .pi / 180.0
        let cosA = cos(a)
        let sinA = sin(a)
        guard cosA > sinA else {
            let side = Int((min(W, H) / (cosA + sinA)).rounded(.down))
            return (max(1, side), max(1, side))
        }
        let cos2A = cosA * cosA - sinA * sinA
        // Standard largest inscribed rectangle with matching center inside rotated WxH bounds
        let aspectSameSign: Bool = (W >= H) ? (W * sinA <= H * cosA) : (H * sinA <= W * cosA)
        let rw: Double
        let rh: Double
        if aspectSameSign && cos2A > 0.0001 {
            rw = (W * cosA - H * sinA) / cos2A
            rh = (H * cosA - W * sinA) / cos2A
        } else if W >= H {
            rw = H / max(0.0001, 2.0 * sinA)
            rh = H / max(0.0001, 2.0 * cosA)
        } else {
            rw = W / max(0.0001, 2.0 * cosA)
            rh = W / max(0.0001, 2.0 * sinA)
        }
        return (
            max(1, min(width, Int(rw.rounded(.down)))),
            max(1, min(height, Int(rh.rounded(.down))))
        )
    }

    /// Rotates `ciImage` cleanly around its center and optionally crops to the largest inscribed rectangle with zero empty borders.
    static func straightenCI(
        _ input: CIImage,
        degrees: Double,
        autoCropInscribed: Bool
    ) -> CIImage {
        let clamped = min(45.0, max(-45.0, degrees))
        guard abs(clamped) > 0.01 else { return input }

        let extent = input.extent
        let cx = extent.midX
        let cy = extent.midY
        // Negative CI angle rotates clockwise visually for positive UI straighten degrees.
        let rad = -CGFloat(clamped) * .pi / 180.0

        var t = CGAffineTransform(translationX: cx, y: cy)
        t = t.rotated(by: rad)
        t = t.translatedBy(x: -cx, y: -cy)

        let rotated = input.transformed(by: t)
        if autoCropInscribed {
            let inscribed = inscribedDimensions(
                width: max(1, Int(extent.width.rounded())),
                height: max(1, Int(extent.height.rounded())),
                angleDegrees: clamped
            )
            let cropW = CGFloat(inscribed.width)
            let cropH = CGFloat(inscribed.height)
            let rotCenter = CGPoint(x: rotated.extent.midX, y: rotated.extent.midY)
            let cropRect = CGRect(
                x: rotCenter.x - cropW / 2.0,
                y: rotCenter.y - cropH / 2.0,
                width: cropW,
                height: cropH
            ).integral
            let cropped = rotated.cropped(to: cropRect)
            return cropped.transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
        } else {
            let shifted = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
            return shifted
        }
    }

    static func straighten(
        cgImage: CGImage,
        degrees: Double,
        autoCropInscribed: Bool
    ) throws -> CGImage {
        let clamped = min(45.0, max(-45.0, degrees))
        guard abs(clamped) > 0.01 else { return cgImage }
        let outCS = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let fmt = ImageProcessor.ciRenderFormat(for: cgImage)
        let ciOut = straightenCI(CIImage(cgImage: cgImage), degrees: clamped, autoCropInscribed: autoCropInscribed)
        let targetExtent = ciOut.extent.integral
        let rendered = autoreleasepool { () -> CGImage? in
            let ciContext = ImageProcessor.sharedCIContext(for: outCS)
            let cg = ciContext.createCGImage(ciOut, from: targetExtent, format: fmt, colorSpace: outCS)
            if Int(targetExtent.width) * Int(targetExtent.height) >= 16_000_000 {
                ciContext.clearCaches()
            }
            return cg
        }
        guard let rendered else {
            throw ConversionError.engineExecutionFailed("Failed to render straightened image.", underlyingError: nil)
        }
        return rendered
    }

    /// Detects dominant horizon tilt angle (in UI degrees clamped to [-45, +45]) via Apple Vision (`VNDetectHorizonRequest`).
    static func detectHorizonAngle(cgImage: CGImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let obs = request.results?.first, obs.confidence >= 0.25 else {
            return nil
        }
        // obs.angle is in radians counter-clockwise to level the horizon; negate for corrective rotation
        let correctionDeg = -Double(obs.angle) * (180.0 / .pi)
        return min(45.0, max(-45.0, correctionDeg))
    }
}

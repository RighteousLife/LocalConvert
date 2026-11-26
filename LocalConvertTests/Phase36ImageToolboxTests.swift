import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import LocalConvert

@Suite("Phase 36 — Image Toolbox Pro UX, Upscale & Geometric Crop Tests")
struct Phase36ImageToolboxTests {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase36-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSolidCGImage(
        width: Int,
        height: Int,
        r: CGFloat = 0.2,
        g: CGFloat = 0.55,
        b: CGFloat = 0.9,
        alpha: Bool = true
    ) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info: UInt32 = alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: info
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate test CGImage.", underlyingError: nil)
        }
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to create test CGImage.", underlyingError: nil)
        }
        return cg
    }

    private func writePNG(_ cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to create PNG destination.", underlyingError: nil)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize PNG.", underlyingError: nil)
        }
    }

    private func pixelRGBA(of cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, x < cgImage.width, y >= 0, y < cgImage.height else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Draw 1x1 shifted so (x, y) in CG bottom-left coordinates lands at (0, 0)
        ctx.draw(cgImage, in: CGRect(x: -x, y: -y, width: cgImage.width, height: cgImage.height))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    @Test("ImageDimensionCalculator computes rotation, crop, resize, upscale & memory guard clamps accurately")
    func testDimensionCalculatorAndMemoryGuard() {
        // Orientation swap
        let rotated = ImageDimensionCalculator.orientedDimensions(width: 400, height: 200, rotationDegrees: 90)
        #expect(rotated.width == 200 && rotated.height == 400)

        // Custom normalized rect in rotated space
        var crop = ImageCropAndTransformConfig()
        crop.cropMode = .customRect
        crop.rotationDegrees = 90
        crop.normalizedRect = NormalizedRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5)
        let cropped = ImageDimensionCalculator.croppedDimensions(sourceWidth: 400, sourceHeight: 200, crop: crop)
        #expect(cropped.width == 200 && cropped.height == 200)

        // Upscale 3x
        var up3 = ImageUpscaleConfig()
        up3.enabled = true
        up3.preset = .scale3x
        let out3 = ImageDimensionCalculator.upscaledDimensions(currentWidth: 300, currentHeight: 200, upscale: up3)
        #expect(out3.width == 900 && out3.height == 600 && !out3.clampedByMemoryGuard)

        // Upscale safety clamp above 16384px / 100MP
        var huge = ImageUpscaleConfig()
        huge.enabled = true
        huge.preset = .scale4x
        let clamped = ImageDimensionCalculator.upscaledDimensions(currentWidth: 6000, currentHeight: 5000, upscale: huge)
        #expect(clamped.clampedByMemoryGuard)
        #expect(clamped.width <= ImageDimensionCalculator.maxEdgePixels)
        #expect(Int64(clamped.width) * Int64(clamped.height) <= ImageDimensionCalculator.maxTotalPixels)
    }

    @Test("Conventional Upscale 2x/3x/4x & custom target dimensions work with accurate preview telemetry")
    func testConventionalUpscalePipelineAndProxyTelemetry() async throws {
        let dir = try makeTempDir("upscale")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cg = try makeSolidCGImage(width: 120, height: 80, r: 0.15, g: 0.65, b: 0.85, alpha: false)
        let srcURL = dir.appendingPathComponent("small.png")
        try writePNG(cg, to: srcURL)

        for (preset, mult) in [(ImageUpscalePreset.scale2x, 2), (.scale3x, 3), (.scale4x, 4)] {
            var cfg = ImageToolboxConfig()
            cfg.upscale.enabled = true
            cfg.upscale.preset = preset
            cfg.upscale.method = .lanczosDetail
            cfg.upscale.detailEnhancement = 0.4
            cfg.upscale.artifactReduction = 0.2

            // Full export pipeline check
            let fullOut = try await ImageProcessingService.processInMemory(
                url: srcURL,
                outputFormat: .png,
                config: cfg,
                previewMaxDimension: nil
            )
            #expect(fullOut.telemetry.originalWidth == 120)
            #expect(fullOut.telemetry.originalHeight == 80)
            #expect(fullOut.telemetry.outputWidth == 120 * mult)
            #expect(fullOut.telemetry.outputHeight == 80 * mult)

            // Proxy preview check reports true target dimensions too
            let proxyOut = try await ImageProcessingService.processInMemory(
                url: srcURL,
                outputFormat: .jxl,
                config: cfg,
                previewMaxDimension: 200
            )
            #expect(proxyOut.telemetry.outputWidth == 120 * mult)
            #expect(proxyOut.telemetry.outputHeight == 80 * mult)
        }

        // Target width/height custom upscale via Lanczos / Bicubic
        var customUp = ImageToolboxConfig()
        customUp.upscale.enabled = true
        customUp.upscale.preset = .targetDimensions
        customUp.upscale.targetWidth = 360
        customUp.upscale.targetHeight = 240
        customUp.upscale.method = .bicubic
        let res = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .png, config: customUp)
        #expect(res.telemetry.outputWidth == 360 && res.telemetry.outputHeight == 240)
    }

    @Test("Interactive Crop orientation coordinate mapping & all 8 Geometric Crop Shapes preserve transparency or warn on JPEG")
    func testInteractiveCropAndGeometricShapes() async throws {
        let dir = try makeTempDir("geom-crop")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cg = try makeSolidCGImage(width: 200, height: 100, r: 0.9, g: 0.25, b: 0.2, alpha: true)
        let srcURL = dir.appendingPathComponent("rect.png")
        try writePNG(cg, to: srcURL)

        // Rotated 90deg -> 100x200 oriented space; crop normalized bottom half -> 100x100
        var orientedCrop = ImageCropAndTransformConfig()
        orientedCrop.rotationDegrees = 90
        orientedCrop.flipHorizontal = true
        orientedCrop.cropMode = .customRect
        orientedCrop.normalizedRect = NormalizedRect(x: 0.0, y: 0.5, width: 1.0, height: 0.5)
        let croppedOnly = try ImageCropService.apply(cgImage: cg, config: orientedCrop, outputFormat: .png)
        #expect(croppedOnly.width == 100 && croppedOnly.height == 100)

        // All 7 non-rectangle geometric shapes produce transparent outer corners in PNG & preserve center pixels
        let shapes: [ImageCropShape] = [.roundedRectangle, .circle, .ellipse, .triangle, .diamond, .hexagon, .customPolygon]
        for shape in shapes {
            var cfg = ImageToolboxConfig()
            cfg.cropTransform.cropMode = .customRect
            cfg.cropTransform.normalizedRect = NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0) // 100x100 square
            cfg.cropTransform.shape = shape
            cfg.cropTransform.roundedCornerRadiusPercent = 25
            cfg.cropTransform.polygonSides = 6
            cfg.cropTransform.shapeBackgroundFill = .transparent

            let outPNG = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .png, config: cfg)
            #expect(outPNG.telemetry.outputWidth == 100 && outPNG.telemetry.outputHeight == 100)

            let decoded = try await ImageProcessingService.decodeInputImage(url: {
                let tmp = dir.appendingPathComponent("out-\(shape.rawValue).png")
                try outPNG.encodedData.write(to: tmp)
                return tmp
            }())
            // Pick an outer pixel guaranteed outside each shape (bottom-left (2,2) except triangle whose base sits on bottom edge -> check top-left (2,97))
            let outerCoord = (shape == .triangle) ? (x: 2, y: 97) : (x: 2, y: 2)
            let corner = pixelRGBA(of: decoded.cgImage, x: outerCoord.x, y: outerCoord.y)
            #expect(corner?.a == 0)
            // Center (50, 50) must remain opaque red pixel
            let center = pixelRGBA(of: decoded.cgImage, x: 50, y: 50)
            #expect(center?.a == 255)
        }

        // Solid background fill produces opaque colored corner
        var solidCfg = ImageToolboxConfig()
        solidCfg.cropTransform.cropMode = .customRect
        solidCfg.cropTransform.normalizedRect = NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)
        solidCfg.cropTransform.shape = .circle
        solidCfg.cropTransform.shapeBackgroundFill = .solidColor
        solidCfg.cropTransform.shapeBackgroundColor = CodableRGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        let solidOut = try ImageCropService.apply(cgImage: cg, config: solidCfg.cropTransform, outputFormat: .png)
        let solidCorner = pixelRGBA(of: solidOut, x: 1, y: 1)
        #expect(solidCorner?.a == 255 && (solidCorner?.g ?? 0) > 200)

        // JPEG export with transparent geometric shape flattens alpha & emits warning
        var jpegCfg = ImageToolboxConfig()
        jpegCfg.cropTransform.cropMode = .customRect
        jpegCfg.cropTransform.normalizedRect = NormalizedRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)
        jpegCfg.cropTransform.shape = .diamond
        jpegCfg.cropTransform.shapeBackgroundFill = .transparent
        let jpgOut = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .jpg, config: jpegCfg)
        #expect(jpgOut.telemetry.warnings.contains(where: { $0.contains("does not support alpha transparency") }))
    }

    @Test("ImageToolboxConfig preserves Codable roundtrip & backward compatibility for new fields")
    func testConfigCodableRoundtripAndLegacyDecode() throws {
        var cfg = ImageToolboxConfig()
        cfg.upscale.enabled = true
        cfg.upscale.preset = .scale3x
        cfg.upscale.method = .lanczosDetail
        cfg.cropTransform.shape = .customPolygon
        cfg.cropTransform.polygonSides = 7
        cfg.cropTransform.ratioPreset = .ratio5x4
        cfg.cropTransform.customAspectWidth = 5
        cfg.cropTransform.customAspectHeight = 4
        cfg.cropTransform.overlayGrid = .goldenRatio

        let opts = cfg.applying(to: .default, outputFormat: .jxl)
        let decoded = ImageToolboxConfig.from(options: opts)
        #expect(decoded?.upscale.enabled == true)
        #expect(decoded?.upscale.preset == .scale3x)
        #expect(decoded?.cropTransform.shape == .customPolygon)
        #expect(decoded?.cropTransform.polygonSides == 7)
        #expect(decoded?.cropTransform.ratioPreset == .ratio5x4)
        #expect(decoded?.cropTransform.overlayGrid == .goldenRatio)

        // Legacy minimal JSON without upscale / shape keys decodes cleanly with defaults
        let legacyJSON = #"{"quality":0.8,"resizeStrategy":"Original Size","cropTransform":{"rotationDegrees":90}}"#
        let legacyData = legacyJSON.data(using: .utf8)!
        let legacyDecoded = try JSONDecoder().decode(ImageToolboxConfig.self, from: legacyData)
        #expect(legacyDecoded.upscale.enabled == false)
        #expect(legacyDecoded.cropTransform.rotationDegrees == 90)
        #expect(legacyDecoded.cropTransform.shape == .rectangle)
    }
}

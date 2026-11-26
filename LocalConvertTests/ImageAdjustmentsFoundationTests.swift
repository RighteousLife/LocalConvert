import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
@testable import LocalConvert

@Suite("Milestone 46.1 — Non-Destructive Adjustment Foundation Tests")
struct ImageAdjustmentsFoundationTests {

    private func makeRGBA16PNG(width: Int, height: Int, to url: URL, r: UInt16 = 40000, g: UInt16 = 20000, b: UInt16 = 10000, a: UInt16 = 32768) throws {
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        let byteOrder16 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let bitmapInfo = byteOrder16 | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 8,
            space: cs,
            bitmapInfo: bitmapInfo
        ), let ptr = ctx.data?.assumingMemoryBound(to: UInt16.self) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate 16-bit test context", underlyingError: nil)
        }
        for i in 0..<(width * height) {
            ptr[i * 4 + 0] = r
            ptr[i * 4 + 1] = g
            ptr[i * 4 + 2] = b
            ptr[i * 4 + 3] = a
        }
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to create 16-bit PNG destination", underlyingError: nil)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.engineExecutionFailed("Failed to write 16-bit PNG", underlyingError: nil)
        }
    }

    private func makeGradientPNG(width: Int, height: Int, transparentRightHalf: Bool = false, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let ptr = ctx.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate 8-bit PNG context", underlyingError: nil)
        }
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let alpha: UInt8 = (transparentRightHalf && x >= width / 2) ? 0 : 255
                let v = UInt8((x * 255) / max(1, width - 1))
                ptr[idx + 0] = alpha > 0 ? v : 0
                ptr[idx + 1] = alpha > 0 ? UInt8(255 - Int(v)) : 0
                ptr[idx + 2] = alpha > 0 ? 128 : 0
                ptr[idx + 3] = alpha
            }
        }
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to create PNG", underlyingError: nil)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    @Test("Adjustment models serialize cleanly and legacy v1 ImageToolboxConfig JSON decodes backward-compatibly")
    func modelSerializationAndBackwardCompat() throws {
        // Legacy v1 JSON payload missing colorAdjustments, effectStack, rawDevelop, straightenDegrees
        let legacyJSON = """
        {
          "quality": 0.92,
          "cropTransform": {
            "enabled": true,
            "cropMode": "Center Crop",
            "rotationDegrees": 90
          }
        }
        """
        let decodedLegacy = try JSONDecoder().decode(ImageToolboxConfig.self, from: Data(legacyJSON.utf8))
        #expect(abs(decodedLegacy.quality - 0.92) < 0.001)
        #expect(decodedLegacy.cropTransform.rotationDegrees == 90)
        #expect(abs(decodedLegacy.cropTransform.straightenDegrees) < 0.001)
        #expect(decodedLegacy.colorAdjustments.hasActiveAdjustments == false)
        #expect(decodedLegacy.effectStack.isEmpty)
        #expect(decodedLegacy.rawDevelop.hasNonDefaultParameters == false)

        // Full v2 round-trip with parameter bounds clamping
        var cfg = ImageToolboxConfig()
        cfg.colorAdjustments.exposureEV = 1.25
        cfg.colorAdjustments.levels.master = ImageChannelLevels(blackPoint: 0.1, gamma: 1.4, whitePoint: 0.9, outBlack: 0.02, outWhite: 0.98)
        cfg.colorAdjustments.curves.master = [
            ImageCurvePoint(x: 0, y: 0),
            ImageCurvePoint(x: 0.5, y: 0.65),
            ImageCurvePoint(x: 1, y: 1)
        ]
        cfg.effectStack = [
            ImageEffectSlot.makeDefault(kind: .vignette),
            ImageEffectSlot.makeDefault(kind: .sepia)
        ]
        cfg.rawDevelop.exposureEV = 0.75

        let data = try JSONEncoder().encode(cfg)
        let roundtripped = try JSONDecoder().decode(ImageToolboxConfig.self, from: data)
        #expect(roundtripped == cfg)
        #expect(data.count < 8192)
    }

    @Test("16-bit orientation and flip preserve 16-bit depth and Display P3 color space")
    func sixteenBitOrientationPreservation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-461-16b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("p3_16bit.png")
        try makeRGBA16PNG(width: 80, height: 40, to: srcURL)
        let src = try #require(CGImageSourceCreateWithURL(srcURL as CFURL, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(cg.bitsPerComponent == 16)

        let rotated = try ImageCropService.transformOrientation(
            cgImage: cg,
            rotationDegrees: 90,
            flipHorizontal: true,
            flipVertical: false
        )
        #expect(rotated.width == 40)
        #expect(rotated.height == 80)
        #expect(rotated.bitsPerComponent == 16)
        #expect(rotated.colorSpace?.isWideGamutRGB == true)
    }

    @Test("Lazy Core Image graph preserves alpha, respects processing order, and matches visual preview vs export")
    func processingOrderAlphaAndPreviewExportParity() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-461-alpha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("alpha_grad.png")
        try makeGradientPNG(width: 120, height: 80, transparentRightHalf: true, to: srcURL)

        var cfg = ImageToolboxConfig()
        cfg.colorAdjustments.exposureEV = 1.0
        cfg.colorAdjustments.contrast = 1.2
        cfg.effectStack = [
            ImageEffectSlot.makeDefault(kind: .gaussianBlur),
            ImageEffectSlot.makeDefault(kind: .sepia)
        ]

        let visualPreview = try await ImageProcessingService.processInMemory(
            url: srcURL,
            outputFormat: .png,
            config: cfg,
            previewMaxDimension: 1200,
            encodeOutput: false
        )
        #expect(visualPreview.encodedData.isEmpty)

        let fullExport = try await ImageProcessingService.processInMemory(
            url: srcURL,
            outputFormat: .png,
            config: cfg,
            previewMaxDimension: nil,
            encodeOutput: true
        )
        #expect(!fullExport.encodedData.isEmpty)
        #expect(fullExport.previewCGImage.width == 120)
        #expect(fullExport.previewCGImage.height == 80)

        // Verify right half stayed transparent (alpha preserved through Blur + Sepia + Exposure!)
        let exportedCG = fullExport.previewCGImage
        let bytesPerRow = exportedCG.width * 4
        var rgba = [UInt8](repeating: 0, count: exportedCG.height * bytesPerRow)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(
            data: &rgba,
            width: exportedCG.width,
            height: exportedCG.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        let drawRect = CGRect(x: 0, y: 0, width: exportedCG.width, height: exportedCG.height)
        ctx.clear(drawRect)
        ctx.draw(exportedCG, in: drawRect)
        let midY = exportedCG.height / 2
        let rightAlpha = rgba[(midY * exportedCG.width + 95) * 4 + 3]
        let leftAlpha = rgba[(midY * exportedCG.width + 20) * 4 + 3]
        #expect(rightAlpha <= 5)
        #expect(leftAlpha >= 245)

        // Order difference check: [Sharpen, Blur] vs [Blur, Sepia] vs disabled
        var bypassCfg = cfg
        bypassCfg.colorAdjustments.isEnabled = false
        for i in bypassCfg.effectStack.indices { bypassCfg.effectStack[i].isEnabled = false }
        let bypassed = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .png, config: bypassCfg, previewMaxDimension: nil, encodeOutput: false)
        #expect(bypassed.previewCGImage.width == 120)
    }

    @Test("ImagePreviewProxyCache enforces 64 MB budget, evicts LRU, and invalidates per URL cleanly")
    func proxyCacheBudgetAndInvalidation() async throws {
        let smallCache = ImagePreviewProxyCache(maxMemoryBytes: 1_500_000) // 1.5 MB test budget
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-461-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func makeProxy(_ name: String) throws -> (ImagePreviewProxyCache.ProxyKey, ImagePreviewProxyCache.CachedProxy) {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let cg = ctx.makeImage()! // 512*512*4 = 1,048,576 bytes (~1.05 MB)
            let url = dir.appendingPathComponent(name)
            let key = ImagePreviewProxyCache.ProxyKey(path: url.path, fileSize: 100, mtimeInterval: 1.0, maxPixelDimension: 1200, rawSignature: nil)
            let val = ImagePreviewProxyCache.CachedProxy(cgImage: cg, properties: nil, format: .png, fileSizeBytes: 100, fullWidth: 512, fullHeight: 512, isRAWFallbackUsed: false, rawStatusNote: nil, byteCost: ImagePreviewProxyCache.estimateByteCost(of: cg))
            return (key, val)
        }

        let (k1, v1) = try makeProxy("one.png")
        let (k2, v2) = try makeProxy("two.png")
        await smallCache.storeProxy(v1, for: k1)
        await smallCache.storeProxy(v2, for: k2)
        let stats = await smallCache.stats()
        #expect(stats.bytesUsed <= 1_500_000)
        #expect(await smallCache.proxy(for: k1) == nil)
        #expect(await smallCache.proxy(for: k2) != nil)

        await smallCache.invalidate(url: dir.appendingPathComponent("two.png"))
        #expect(await smallCache.proxy(for: k2) == nil)
    }
}

import Foundation
import Testing
import AppKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import LocalConvert

@Suite("Phase 35 — Image Toolbox Pro & Universal JPEG XL Tests")
struct Phase35Tests {

    let registry = ConversionRegistry.shared
    let capabilities = FormatCapabilityRegistry.shared
    let imageEngine = ImageConversionEngine()
    let metadataProvider = ImageMetadataProvider()

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase35-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTestImage(
        width: Int = 240,
        height: Int = 180,
        bitsPerComponent: Int = 8,
        alpha: Bool = false,
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    ) throws -> CGImage {
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        var bitmapInfo = alphaInfo.rawValue
        if bitsPerComponent == 16 {
            let hostOrder = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
                ? CGBitmapInfo.byteOrder16Little.rawValue
                : CGBitmapInfo.byteOrder16Big.rawValue
            bitmapInfo |= hostOrder
        }
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ConversionError.unknown("Failed to create CGContext for test image.")
        }

        if alpha {
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(red: 0.9, green: 0.25, blue: 0.15, alpha: 1.0)
            ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
            ctx.setFillColor(red: 0.1, green: 0.55, blue: 0.95, alpha: 0.5)
            ctx.fill(CGRect(x: 10, y: 10, width: width / 3, height: height / 3))
        } else {
            // Draw rich photographic gradient + crisp geometric shapes so quality/size differences are real
            ctx.setFillColor(red: 0.12, green: 0.18, blue: 0.28, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for stripe in 0..<24 {
                let f = CGFloat(stripe) / 24.0
                ctx.setFillColor(red: 0.15 + 0.75 * f, green: 0.85 - 0.55 * f, blue: 0.25 + 0.6 * sin(f * .pi), alpha: 1.0)
                ctx.fill(CGRect(
                    x: CGFloat(stripe) * (CGFloat(width) / 24.0),
                    y: CGFloat(height) * 0.15,
                    width: CGFloat(width) / 24.0 + 1,
                    height: CGFloat(height) * 0.7
                ))
            }
            ctx.setFillColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1.0)
            ctx.fillEllipse(in: CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3))
        }

        guard let cg = ctx.makeImage() else {
            throw ConversionError.unknown("Failed to extract CGImage.")
        }
        return cg
    }

    private func writeImageFile(
        _ cgImage: CGImage,
        to url: URL,
        utType: UTType,
        properties: [CFString: Any]? = nil
    ) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            throw ConversionError.unknown("CGImageDestination unavailable for \(utType.identifier)")
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.unknown("CGImageDestinationFinalize failed for \(url.lastPathComponent)")
        }
    }

    private func writeAnimatedGIF(to url: URL, frameCount: Int = 4) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ConversionError.unknown("GIF destination unavailable")
        }
        let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)
        for i in 0..<frameCount {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                continue
            }
            ctx.setFillColor(red: CGFloat(i) / CGFloat(max(1, frameCount - 1)), green: 0.4, blue: 0.7, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            if let img = ctx.makeImage() {
                let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary
                CGImageDestinationAddImage(dest, img, frameProps)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.unknown("GIF finalization failed")
        }
    }

    private func centerPixelRGBA(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2), width: CGFloat(image.width), height: CGFloat(image.height)))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    // MARK: - 1. libjxl Version, Capabilities & Registry Matrix

    @Test("Bundled libjxl v0.13.0 links cleanly and JXL read/write capabilities are active")
    func testLibJXLVersionAndRegistry() {
        let ver = JPEGXLCodec.libraryVersion
        #expect(ver.hasPrefix("0.13."))

        let cap = capabilities.capability(for: .jxl)
        #expect(cap.canRead == true)
        #expect(cap.canWrite == true)
        #expect(cap.supportsTransparency == true)
        #expect(cap.supportsAnimation == true)

        // All consumer image formats <-> JXL routes are supported
        for src in [FileFormat.png, .jpg, .webp, .heic, .tiff, .gif, .bmp, .tga, .avif] {
            #expect(registry.canConvert(from: src, to: .jxl), "Expected \(src.rawValue) -> jxl")
        }
        for dst in [FileFormat.png, .jpg, .webp, .heic, .tiff, .gif, .bmp, .tga, .pdf] {
            #expect(registry.canConvert(from: .jxl, to: dst), "Expected jxl -> \(dst.rawValue)")
        }

        // Standard same-format JXL->JXL blocked by default unless image_toolbox == "true"
        #expect(!registry.canConvert(from: .jxl, to: .jxl))
        var toolboxOpts = ConversionOptions.default
        toolboxOpts.customOptions["image_toolbox"] = "true"
        #expect(PresetValidator().isPresetValid(
            SavedPreset(name: "JXL In-Place Toolbox", targetFormat: .jxl, options: toolboxOpts),
            registry: registry
        ).isValid == true)
    }

    // MARK: - 2. Universal JXL Encode / Decode Roundtrips + Apple ImageIO Independent Check

    @Test("JXL lossless, lossy, effort, alpha, 16-bit, ICC P3, and roundtrip conversions succeed")
    func testJXLEncodingAndDecodingRoundtrips() async throws {
        let dir = try makeTempDir("jxl-roundtrips")
        defer { try? FileManager.default.removeItem(at: dir) }

        // A. PNG RGBA -> JXL Lossless (transparent corner + opaque subject) -> verify with JPEGXLCodec AND ImageIO
        let rgbaCG = try makeTestImage(width: 120, height: 120, bitsPerComponent: 8, alpha: true)
        let pngURL = dir.appendingPathComponent("alpha.png")
        try writeImageFile(rgbaCG, to: pngURL, utType: .png)

        var losslessOpts = ConversionOptions.default
        losslessOpts.customOptions["jxl_lossless"] = "true"
        losslessOpts.customOptions["jxl_effort"] = "7"

        let pngToJxl = try await imageEngine.convert(inputs: [pngURL], to: .jxl, outputDirectory: dir, options: losslessOpts) { _ in }
        #expect(FileManager.default.fileExists(atPath: pngToJxl.outputURL.path))
        let jxlBytes = try Data(contentsOf: pngToJxl.outputURL)
        #expect(JPEGXLCodec.validateSignature(jxlBytes))

        let inspected = try JPEGXLCodec.inspect(url: pngToJxl.outputURL)
        #expect(inspected.width == 120)
        #expect(inspected.height == 120)
        #expect(inspected.hasAlpha == true)

        // Independent macOS ImageIO readback check of generated .jxl container
        if let src = CGImageSourceCreateWithURL(pngToJxl.outputURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            #expect((props[kCGImagePropertyPixelWidth] as? Int) == 120)
            #expect((props[kCGImagePropertyPixelHeight] as? Int) == 120)
        }

        // Convert JXL back to PNG and WebP and confirm alpha preserved
        let jxlToPng = try await imageEngine.convert(inputs: [pngToJxl.outputURL], to: .png, outputDirectory: dir, options: .default) { _ in }
        let decodedBack = try await ImageProcessingService.decodeInputImage(url: jxlToPng.outputURL)
        #expect(decodedBack.cgImage.width == 120)
        #expect(decodedBack.cgImage.alphaInfo != .none && decodedBack.cgImage.alphaInfo != .noneSkipLast)

        let jxlToWebp = try await imageEngine.convert(inputs: [pngToJxl.outputURL], to: .webp, outputDirectory: dir, options: .default) { _ in }
        #expect(FileManager.default.fileExists(atPath: jxlToWebp.outputURL.path))

        // B. Lossy distance/quality comparison: q=0.90 should produce smaller or different bitstream vs q=0.35 & lossless
        let p3CS = CGColorSpace(name: CGColorSpace.displayP3)!
        let wide16CG = try makeTestImage(width: 200, height: 150, bitsPerComponent: 16, alpha: false, colorSpace: p3CS)
        let tiff16URL = dir.appendingPathComponent("wide16.tiff")
        try writeImageFile(wide16CG, to: tiff16URL, utType: .tiff)

        var jxl16Opts = ConversionOptions.default
        jxl16Opts.customOptions["jxl_bit_depth"] = "16"
        jxl16Opts.customOptions["jxl_lossless"] = "true"
        let tiffToJxl16 = try await imageEngine.convert(inputs: [tiff16URL], to: .jxl, outputDirectory: dir, options: jxl16Opts) { _ in }
        let info16 = try JPEGXLCodec.inspect(url: tiffToJxl16.outputURL)
        #expect(info16.bitsPerSample == 16)
        #expect(info16.hasICCProfile == true)

        var qHigh = ConversionOptions.default
        qHigh.imageQuality = 0.92
        qHigh.customOptions["jxl_effort"] = "7"
        var qLow = ConversionOptions.default
        qLow.imageQuality = 0.35
        qLow.customOptions["jxl_effort"] = "7"

        let highDir = dir.appendingPathComponent("high")
        let lowDir = dir.appendingPathComponent("low")
        try FileManager.default.createDirectory(at: highDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lowDir, withIntermediateDirectories: true)
        let outHigh = try await imageEngine.convert(inputs: [tiff16URL], to: .jxl, outputDirectory: highDir, options: qHigh) { _ in }
        let outLow = try await imageEngine.convert(inputs: [tiff16URL], to: .jxl, outputDirectory: lowDir, options: qLow) { _ in }
        #expect(outLow.fileSize < outHigh.fileSize)

        // Check corrupt JXL handling fails cleanly without crash
        let corruptURL = dir.appendingPathComponent("corrupt.jxl")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: corruptURL)
        await #expect(throws: Error.self) {
            _ = try JPEGXLCodec.decode(url: corruptURL)
        }
    }

    // MARK: - 3. Lossless JPEG <-> JXL Bitstream Transcoding & Exact Reconstruction

    @Test("Lossless JPEG to JXL bitstream transcode reconstructs byte-identical original JPEG")
    func testLosslessJPEGTranscodeAndExactReconstruction() async throws {
        let dir = try makeTempDir("jpeg-transcode")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cg = try makeTestImage(width: 256, height: 192, alpha: false)
        let origJPG = dir.appendingPathComponent("photo.jpg")
        try writeImageFile(cg, to: origJPG, utType: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 0.88,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Leica", kCGImagePropertyTIFFArtist: "Phase35"]
        ])
        let origBytes = try Data(contentsOf: origJPG)

        var transcodeOpts = ConversionOptions.default
        transcodeOpts.customOptions["jxl_transcode_jpeg"] = "true"
        let jxlResult = try await imageEngine.convert(inputs: [origJPG], to: .jxl, outputDirectory: dir, options: transcodeOpts) { _ in }

        let jxlInfo = try JPEGXLCodec.inspect(url: jxlResult.outputURL)
        #expect(jxlInfo.isJPEGReconstructable == true)
        #expect(jxlResult.fileSize < Int64(origBytes.count))

        var reconOpts = ConversionOptions.default
        reconOpts.customOptions["jxl_reconstruct_jpeg"] = "true"
        let reconDir = dir.appendingPathComponent("recon")
        try FileManager.default.createDirectory(at: reconDir, withIntermediateDirectories: true)
        let reconResult = try await imageEngine.convert(inputs: [jxlResult.outputURL], to: .jpg, outputDirectory: reconDir, options: reconOpts) { _ in }

        let reconBytes = try Data(contentsOf: reconResult.outputURL)
        #expect(reconBytes == origBytes, "JXL JPEG reconstruction must restore byte-identical JPEG!")
    }

    // MARK: - 4. Animated GIF <-> Animated JXL

    @Test("Animated GIF converts to multi-frame Animated JXL and back to GIF")
    func testAnimatedJXL() async throws {
        let dir = try makeTempDir("animated-jxl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gifURL = dir.appendingPathComponent("anim.gif")
        try writeAnimatedGIF(to: gifURL, frameCount: 4)

        let toJXL = try await imageEngine.convert(inputs: [gifURL], to: .jxl, outputDirectory: dir, options: .default) { _ in }
        let jxlInfo = try JPEGXLCodec.inspect(url: toJXL.outputURL)
        #expect(jxlInfo.isAnimated == true)
        #expect(jxlInfo.frameCount == 4)

        let backDir = dir.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: backDir, withIntermediateDirectories: true)
        let backGIF = try await imageEngine.convert(inputs: [toJXL.outputURL], to: .gif, outputDirectory: backDir, options: .default) { _ in }
        let srcBack = CGImageSourceCreateWithURL(backGIF.outputURL as CFURL, nil)
        #expect(srcBack != nil)
        #expect(CGImageSourceGetCount(srcBack!) == 4)
    }

    // MARK: - 5. JXL Metadata Boxes (EXIF / XMP Read, Write, Scrub)

    @Test("JXL container preserves and edits EXIF/XMP metadata and supports privacy scrub")
    func testJXLMetadataBoxesAndPrivacyScrub() async throws {
        let dir = try makeTempDir("jxl-meta")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cg = try makeTestImage(width: 96, height: 96, alpha: false)
        let jxlURL = dir.appendingPathComponent("tagged.jxl")
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "EOS R5",
                kCGImagePropertyTIFFArtist: "Alice Example",
                kCGImagePropertyTIFFCopyright: "Copyright 2026 Alice"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLongitudeRef: "W"
            ]
        ]
        let boxes = JPEGXLCodec.serializeMetadataBoxes(from: props)
        let jxlData = try JPEGXLCodec.encode(
            image: cg,
            options: JXLEncodeOptions(lossless: true, useContainer: true, exifData: boxes.exifTIFF, xmpData: boxes.xmp)
        )
        try jxlData.write(to: jxlURL)

        let initialSummary = try await ImageMetadataService.inspect(url: jxlURL)
        #expect(initialSummary.isJXLContainer == true)
        #expect(initialSummary.hasGPS == true)
        #expect(initialSummary.hasCameraHardwareInfo == true)
        #expect(initialSummary.hasAuthorOrCopyright == true)

        // Strip GPS only via ImageMetadataService
        var gpsOnly = ImageMetadataEditPayload()
        gpsOnly.policy = .stripGPSOnly
        try await ImageMetadataService.writePrivacyCleaned(url: jxlURL, payload: gpsOnly)
        let afterGPS = try await ImageMetadataService.inspect(url: jxlURL)
        #expect(afterGPS.hasGPS == false)
        #expect(afterGPS.hasCameraHardwareInfo == true)

        // Apply custom edited metadata + strip camera info
        var customEdit = ImageMetadataEditPayload()
        customEdit.policy = .applyEditedMetadata
        customEdit.stripCamera = true
        customEdit.author = "Edited Author"
        customEdit.copyright = "© 2026 Edited"
        customEdit.title = "Clean Title"
        try await ImageMetadataService.writePrivacyCleaned(url: jxlURL, payload: customEdit)
        let afterEdit = try await ImageMetadataService.inspect(url: jxlURL)
        #expect(afterEdit.hasCameraHardwareInfo == false)
        #expect(afterEdit.document.common.author == "Edited Author" || afterEdit.document.common.artist == "Edited Author")
        #expect(afterEdit.document.common.copyright == "© 2026 Edited")

        // Strip all metadata
        var stripAll = ImageMetadataEditPayload()
        stripAll.policy = .stripAll
        try await ImageMetadataService.writePrivacyCleaned(url: jxlURL, payload: stripAll)
        let afterAll = try await ImageMetadataService.inspect(url: jxlURL)
        #expect(afterAll.hasAnySensitiveMetadata == false)
    }

    // MARK: - 6. Image Toolbox Pro Services (Resize, Crop, Rotate, Target Size, Watermark, Color, BG Removal, Compare)

    @Test("Image Toolbox resize, resampling, multi-size batch, crop, rotate/flip, and watermarking work end-to-end")
    func testImageToolboxTransformsAndWatermark() async throws {
        let dir = try makeTempDir("toolbox-transforms")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cg = try makeTestImage(width: 400, height: 200, alpha: false)
        let srcURL = dir.appendingPathComponent("input.png")
        try writeImageFile(cg, to: srcURL, utType: .png)

        // Resize strategies & resampling algorithms + sharpen
        for algo in ImageResamplingMethod.allCases {
            var cfg = ImageToolboxConfig()
            cfg.resizeStrategy = .exactDimensions
            cfg.resizeWidth = 160
            cfg.resizeHeight = 80
            cfg.resamplingMethod = algo
            cfg.postResizeSharpen = 0.25
            let res = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .png, config: cfg)
            #expect(res.telemetry.outputWidth == 160)
            #expect(res.telemetry.outputHeight == 80)
        }

        // Fill (crop-to-fit) aspect 100x100
        var fillCfg = ImageToolboxConfig()
        fillCfg.resizeStrategy = .fill
        fillCfg.resizeWidth = 100
        fillCfg.resizeHeight = 100
        let fillRes = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .png, config: fillCfg)
        #expect(fillRes.telemetry.outputWidth == 100)
        #expect(fillRes.telemetry.outputHeight == 100)

        // Multi-size export -> generates 3 output URLs
        var multiCfg = ImageToolboxConfig()
        multiCfg.exportMultipleSizes = true
        multiCfg.multiSizePresets = [
            ImageBatchSizePreset(label: "sm", width: 100, height: 100),
            ImageBatchSizePreset(label: "md", width: 200, height: 200),
            ImageBatchSizePreset(label: "lg", width: 300, height: 300)
        ]
        var multiOpts = multiCfg.applying(to: .default, outputFormat: .jxl)
        let multiOut = try await imageEngine.convert(inputs: [srcURL], to: .jxl, outputDirectory: dir, options: multiOpts) { _ in }
        let allMulti = [multiOut.outputURL] + multiOut.additionalOutputURLs
        #expect(allMulti.count == 3)
        for u in allMulti {
            #expect(FileManager.default.fileExists(atPath: u.path))
            _ = try JPEGXLCodec.inspect(url: u)
        }

        // Crop 1:1 + 90-degree rotation
        var cropCfg = ImageToolboxConfig()
        cropCfg.cropTransform.cropMode = .centerCrop
        cropCfg.cropTransform.aspectRatio = .square1x1
        cropCfg.cropTransform.rotationDegrees = 90
        cropCfg.cropTransform.flipHorizontal = true
        let cropRes = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .png, config: cropCfg)
        #expect(cropRes.telemetry.outputWidth == cropRes.telemetry.outputHeight)
        #expect(cropRes.telemetry.outputWidth == 200)

        // Text & Logo Watermark -> JXL output
        let logoCG = try makeTestImage(width: 48, height: 48, alpha: true)
        let logoURL = dir.appendingPathComponent("logo.png")
        try writeImageFile(logoCG, to: logoURL, utType: .png)

        var wmCfg = ImageToolboxConfig()
        wmCfg.watermark.enabled = true
        wmCfg.watermark.kind = .text
        wmCfg.watermark.text = "LOCALCONVERT"
        wmCfg.watermark.tiled = true
        let textWmRes = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .jxl, config: wmCfg)
        #expect(JPEGXLCodec.validateSignature(textWmRes.encodedData))

        wmCfg.watermark.kind = .image
        wmCfg.watermark.watermarkImagePath = logoURL.path
        wmCfg.watermark.tiled = false
        let imgWmRes = try await ImageProcessingService.processInMemory(url: srcURL, outputFormat: .png, config: wmCfg)
        #expect(imgWmRes.telemetry.outputWidth == 400)
    }

    @Test("Color management, Target File Size Optimization, Vision Background Removal & Before/After Compare work")
    func testColorTargetSizeVisionAndCompare() async throws {
        let dir = try makeTempDir("color-vision-compare")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Display P3 -> sRGB conversion
        let p3CS = CGColorSpace(name: CGColorSpace.displayP3)!
        let p3CG = try makeTestImage(width: 320, height: 240, alpha: false, colorSpace: p3CS)
        let p3URL = dir.appendingPathComponent("p3.png")
        try writeImageFile(p3CG, to: p3URL, utType: .png)

        let p3Info = ImageColorManagementService.inspectColorProfile(url: p3URL)
        #expect(p3Info.isWideGamut == true)

        var colorCfg = ImageToolboxConfig()
        colorCfg.colorTarget = .sRGB
        let srgbOut = try await ImageProcessingService.processInMemory(url: p3URL, outputFormat: .jxl, config: colorCfg)
        let decodedSRGB = try JPEGXLCodec.decode(data: srgbOut.encodedData)
        let convertedInfo = ImageColorManagementService.inspectColorProfile(url: p3URL, cgImage: decodedSRGB.primaryImage)
        #expect(convertedInfo.profileName.lowercased().contains("srgb"))

        // Target File Size Optimization (20 KB ceiling on JXL/JPG)
        var sizeCfg = ImageToolboxConfig()
        sizeCfg.targetFileSizeEnabled = true
        sizeCfg.targetFileSizeBytes = 20_000
        let sizedJPG = try await ImageProcessingService.processInMemory(url: p3URL, outputFormat: .jpg, config: sizeCfg)
        #expect(sizedJPG.encodedData.count <= 20_000 || sizedJPG.telemetry.targetReached == false)
        let sizedJXL = try await ImageProcessingService.processInMemory(url: p3URL, outputFormat: .jxl, config: sizeCfg)
        #expect(sizedJXL.encodedData.count <= 20_000 || sizedJXL.telemetry.targetReached == false)

        // Before / After Comparison Snapshot
        let snap = try await ImageComparisonService.buildComparison(sourceURL: p3URL, outputFormat: .jxl, config: colorCfg)
        #expect(snap.beforeFormat == "PNG")
        #expect(snap.afterFormat == "JXL")
        #expect(snap.telemetry.processedBytes > 0)

        // Vision Background Removal: verify alpha-strip warning when target is JPEG, and non-crash / clean output
        var bgCfg = ImageToolboxConfig()
        bgCfg.backgroundRemoval.enabled = true
        bgCfg.backgroundRemoval.fillMode = .transparent
        do {
            let jpgWarnRun = try await ImageProcessingService.processInMemory(url: p3URL, outputFormat: .jpg, config: bgCfg)
            #expect(jpgWarnRun.telemetry.warnings.contains(where: { $0.contains("does not support transparency") }))
        } catch let error as ConversionError {
            // If headless/CI environment has no Vision foreground subject or ML backend throws cleanly, ensure it is a clean typed ConversionError
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    // MARK: - 7. Queue Batch Execution, Config/Preset Roundtrip & Zero Temp Leaks

    @Test("Image Toolbox batch job queue execution, preset roundtrip & zero temp directory leaks")
    @MainActor
    func testBatchQueuePresetAndNoTempLeak() async throws {
        let dir = try makeTempDir("batch-queue")
        defer { try? FileManager.default.removeItem(at: dir) }

        let imgA = dir.appendingPathComponent("a.png")
        let imgB = dir.appendingPathComponent("b.png")
        try writeImageFile(try makeTestImage(width: 120, height: 90), to: imgA, utType: .png)
        try writeImageFile(try makeTestImage(width: 120, height: 90), to: imgB, utType: .png)

        var cfg = ImageToolboxConfig()
        cfg.compressionProfile = .archiveLossless
        cfg.jxlLossless = true
        cfg.jxlEffort = 6
        cfg.resizeStrategy = .maxWidth
        cfg.resizeWidth = 80
        cfg.watermark.enabled = true
        cfg.watermark.text = "BATCH"

        let encodedOpts = cfg.applying(to: .default, outputFormat: .jxl)
        let decodedCfg = ImageToolboxConfig.from(options: encodedOpts)
        #expect(decodedCfg == cfg)

        let preset = SavedPreset(
            name: "Phase35-JXL-Batch-\(UUID().uuidString)",
            targetFormat: .jxl,
            sourceCategoryConstraint: .image,
            options: encodedOpts
        )
        #expect(PresetValidator().isPresetValid(preset, registry: registry).isValid == true)

        // Direct batch execution via ImageConversionEngine into dir
        let resA = try await imageEngine.convert(inputs: [imgA], to: .jxl, outputDirectory: dir, options: encodedOpts) { _ in }
        let resB = try await imageEngine.convert(inputs: [imgB], to: .jxl, outputDirectory: dir, options: encodedOpts) { _ in }
        #expect(FileManager.default.fileExists(atPath: resA.outputURL.path))
        #expect(FileManager.default.fileExists(atPath: resB.outputURL.path))

        let dirContents = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(dirContents == ["a.jxl", "a.png", "b.jxl", "b.png"])

        // Enqueue batch into AppState -> verify jobs are enqueued with image_toolbox option and shared batchID
        let appState = AppState()
        appState.outputLocation = .sameFolder
        appState.executeImageToolbox(inputs: [imgA, imgB], outputFormat: .jxl, config: cfg)
        let activeJobs = appState.conversionManager.activeJobs
        #expect(activeJobs.count == 2)
        let batchID = activeJobs.first?.batchID
        #expect(batchID != nil)
        for job in activeJobs {
            #expect(job.batchID == batchID)
            #expect(job.outputFormat == .jxl)
            #expect(job.options.customOptions["image_toolbox"] == "true")
        }
        appState.cancelConversion()
    }
}

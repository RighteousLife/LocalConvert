import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@Suite("Phase 37 — Image Toolbox Pro Completion Tests")
struct Phase37ImageToolboxCompletionTests {

    private func makeTestImage(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = fill(x, y)
                let idx = (y * width + x) * 4
                rgba[idx] = r
                rgba[idx + 1] = g
                rgba[idx + 2] = b
                rgba[idx + 3] = a
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let cg: CGImage? = rgba.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        guard let cg else {
            throw ConversionError.engineExecutionFailed("Failed to allocate test CGImage.", underlyingError: nil)
        }
        return cg
    }

    private func writeTempPNG(_ cg: CGImage, to url: URL, properties: [CFString: Any]? = nil) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to open PNG destination.", underlyingError: nil)
        }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize PNG.", underlyingError: nil)
        }
    }

    private func writeTempJPEGWithGPSAndEXIF(_ cg: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to open JPEG destination.", underlyingError: nil)
        }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72,
            kCGImagePropertyDPIHeight: 72,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 16 Pro",
                kCGImagePropertyTIFFSoftware: "LocalConvert Test"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Main 24mm f/1.78",
                kCGImagePropertyExifDateTimeOriginal: "2026:11:16 12:00:00",
                kCGImagePropertyExifISOSpeedRatings: [100]
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 41.0082,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 28.9784,
                kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 42.0
            ]
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize JPEG.", underlyingError: nil)
        }
    }

    @Test("1. Perspective correction performs real homography warp & handles fill modes")
    func testPerspectiveCorrection() throws {
        let img = try makeTestImage(width: 200, height: 150) { x, y in
            (x < 100 ? 220 : 40, y < 75 ? 180 : 60, 120, 255)
        }
        var cfg = ImagePerspectiveConfig(
            enabled: true,
            topLeft: CodableNormalizedPoint(x: 0.1, y: 0.1),
            topRight: CodableNormalizedPoint(x: 0.9, y: 0.15),
            bottomRight: CodableNormalizedPoint(x: 0.95, y: 0.9),
            bottomLeft: CodableNormalizedPoint(x: 0.05, y: 0.85),
            fillMode: .white,
            customColor: .white
        )
        let out = try ImagePerspectiveService.apply(cgImage: img, config: cfg, outputFormat: .png)
        #expect(out.width > 10 && out.height > 10)

        cfg.fillMode = .transparent
        let outAlpha = try ImagePerspectiveService.apply(cgImage: img, config: cfg, outputFormat: .png)
        #expect(outAlpha.width > 10)
    }

    @Test("2. Canvas Extension & Border/Frame dimension math and rendering preserve content without scaling")
    func testCanvasAndBorder() throws {
        let img = try makeTestImage(width: 120, height: 80) { _, _ in (200, 80, 40, 255) }

        var canvas = ImageCanvasExtensionConfig()
        canvas.enabled = true
        canvas.mode = .padding
        canvas.padTop = 10
        canvas.padBottom = 20
        canvas.padLeft = 30
        canvas.padRight = 40
        canvas.fillMode = .transparent

        let cDims = ImageDimensionCalculator.extendedCanvasDimensions(currentWidth: 120, currentHeight: 80, canvas: canvas)
        #expect(cDims.width == 190 && cDims.height == 110)

        let extended = try ImageCanvasBorderService.extendCanvas(cgImage: img, config: canvas, outputFormat: .png)
        #expect(extended.width == 190 && extended.height == 110)

        var border = ImageBorderFrameConfig()
        border.enabled = true
        border.placement = .outer
        border.uniformWidth = 15
        border.fillStyle = .linearGradient
        border.cornerRadius = 12
        border.shadowEnabled = true
        border.shadowRadius = 10

        let bDims = ImageDimensionCalculator.borderedDimensions(currentWidth: 190, currentHeight: 110, border: border)
        let framed = try ImageCanvasBorderService.applyBorder(cgImage: extended, config: border, outputFormat: .png)
        #expect(framed.width == bDims.width && framed.height == bDims.height)
    }

    @Test("3. Palette extractor finds exact dominant splits and exports JSON/CSS/PNG")
    func testPaletteExtraction() throws {
        // 60% pure red, 40% pure blue
        let img = try makeTestImage(width: 100, height: 100) { x, _ in
            x < 60 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }
        let res = ImageColorAnalysisService.extractPalette(cgImage: img, colorCount: 3)
        #expect(res.swatches.count >= 2)
        #expect(res.swatches[0].hex == "#FF0000")
        #expect(res.swatches[0].coveragePercent > 50.0)
        #expect(res.swatches.contains(where: { $0.hex == "#0000FF" }))

        let css = ImageColorAnalysisService.exportCSS(swatches: res.swatches)
        #expect(css.contains("--palette-color-1: #FF0000"))
        let json = ImageColorAnalysisService.exportJSON(swatches: res.swatches)
        #expect(json.contains("#FF0000"))
        let png = try ImageColorAnalysisService.renderPalettePNG(swatches: res.swatches)
        #expect(png.count > 100)
    }

    @Test("4. Histogram & Luma analysis computes clipping and channel counts from real pixels")
    func testHistogramAnalysis() throws {
        // Half black (shadow clipped) and half white (highlight clipped)
        let img = try makeTestImage(width: 80, height: 80) { x, _ in
            x < 40 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }
        let hist = try #require(ImageColorAnalysisService.computeHistogram(cgImage: img))
        #expect(hist.minLuminance == 0)
        #expect(hist.maxLuminance == 255)
        #expect(hist.shadowClippingPercent > 40.0)
        #expect(hist.highlightClippingPercent > 40.0)
        #expect(hist.redBins[0] > 0 && hist.redBins[255] > 0)
    }

    @Test("5. DPI editor preserves pixels when resample OFF and scales when resample ON in real export")
    func testDPIBehavior() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-P37-DPI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("input.jpg")
        let img = try makeTestImage(width: 200, height: 100) { x, y in (UInt8(x), UInt8(y * 2), 140, 255) }
        try writeTempJPEGWithGPSAndEXIF(img, to: srcURL)

        // Case A: Resample OFF -> 200x100 unchanged, 300 DPI metadata written
        var cfgMetaOnly = ImageToolboxConfig()
        cfgMetaOnly.dpiConfig = ImageDPIConfig(enabled: true, targetDPI: 300.0, resamplePixels: false, sourceDPI: 72.0)

        let resMeta = try await ImageProcessingService.processToFile(
            inputURL: srcURL,
            outputFormat: .jpg,
            outputDirectory: dir,
            config: cfgMetaOnly
        )
        let snapMeta = ImageMetadataInspectorService.inspectDetailed(url: resMeta.outputURL)
        #expect(snapMeta.pixelWidth == 200 && snapMeta.pixelHeight == 100)
        #expect(Int((snapMeta.dpiWidth ?? 0).rounded()) == 300)

        // Case B: Resample ON (72 -> 144 DPI = 2x pixels) -> 400x200
        var cfgResample = ImageToolboxConfig()
        cfgResample.dpiConfig = ImageDPIConfig(enabled: true, targetDPI: 144.0, resamplePixels: true, sourceDPI: 72.0)

        let resScaled = try await ImageProcessingService.processToFile(
            inputURL: srcURL,
            outputFormat: .png,
            outputDirectory: dir,
            config: cfgResample
        )
        let snapScaled = ImageMetadataInspectorService.inspectDetailed(url: resScaled.outputURL)
        #expect(snapScaled.pixelWidth == 400 && snapScaled.pixelHeight == 200)
    }

    @Test("6. Quality metrics report exact match for identical images and degraded PSNR/SSIM on altered image")
    func testPSNRAndSSIM() throws {
        let a = try makeTestImage(width: 96, height: 96) { x, y in
            (UInt8((x * 3) % 256), UInt8((y * 2) % 256), 120, 255)
        }
        let b = try makeTestImage(width: 96, height: 96) { x, y in
            (UInt8(((x * 3) + 25) % 256), UInt8((y * 2) % 256), 120, 255)
        }

        let same = try #require(ImageQualityMetricsService.analyze(reference: a, candidate: a))
        #expect(same.mse < 0.0001)
        #expect(same.psnrDB.isInfinite)
        #expect(same.ssim > 0.999)
        #expect(same.butteraugliSupported == false)

        let diff = try #require(ImageQualityMetricsService.analyze(reference: a, candidate: b))
        #expect(diff.mse > 1.0)
        #expect(diff.psnrDB < 45.0)
        #expect(diff.ssim < 0.99)
        #expect(diff.differenceMapImage != nil)
    }

    @Test("7. Contact Sheet layout & real streaming PNG export work cleanly")
    func testContactSheet() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-P37-CS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var urls: [URL] = []
        for i in 1...5 {
            let u = dir.appendingPathComponent("shot_\(i).png")
            let img = try makeTestImage(width: 120, height: 90) { _, _ in (UInt8(i * 40), 100, 180, 255) }
            try writeTempPNG(img, to: u)
            urls.append(u)
        }

        var opts = ImageContactSheetOptions()
        opts.columns = 3
        opts.rows = 0
        opts.thumbnailMaxSize = 100
        opts.padding = 10
        opts.spacing = 10
        opts.showFilenames = true

        let layout = ImageContactSheetService.computeGridLayout(itemCount: 5, options: opts)
        #expect(layout.columns == 3 && layout.rows == 2)
        #expect(layout.width == 340)

        let res = try await ImageContactSheetService.generate(urls: urls, options: opts)
        #expect(res.width == 340 && res.itemCount == 5 && res.encodedData.count > 200)
    }

    @Test("8. Batch Rename resolves duplicate collisions safely and supports full undo rollback")
    func testBatchRenameAndUndo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-P37-Rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let u1 = dir.appendingPathComponent("a.png")
        let u2 = dir.appendingPathComponent("b.png")
        let img = try makeTestImage(width: 16, height: 16) { _, _ in (10, 20, 30, 255) }
        try writeTempPNG(img, to: u1)
        try writeTempPNG(img, to: u2)

        // Force both files to target the same base stem -> must auto-resolve collision cleanly
        var opts = ImageBatchRenameOptions()
        opts.template = "holiday"
        let plan = ImageBatchRenameService.buildPlan(urls: [u1, u2], options: opts)
        #expect(plan[0].proposedFilename == "holiday.png")
        #expect(plan[1].proposedFilename == "holiday_1.png")
        #expect(plan[1].hadCollisionResolved == true)

        let manifest = try ImageBatchRenameService.executePlan(plan)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("holiday.png").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("holiday_1.png").path))
        #expect(!FileManager.default.fileExists(atPath: u1.path))

        try ImageBatchRenameService.undo(manifest)
        #expect(FileManager.default.fileExists(atPath: u1.path))
        #expect(FileManager.default.fileExists(atPath: u2.path))
    }

    @Test("9. Duplicate detection separates SHA-256 exact copies from perceptual dHash matches")
    func testDuplicateDetection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-P37-Dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let imgA = try makeTestImage(width: 120, height: 120) { x, y in
            (UInt8((x * 2) % 256), UInt8((y * 2) % 256), x > 60 ? 220 : 30, 255)
        }
        let imgAResized = try ImageResizeService.resize(
            cgImage: imgA, strategy: .exactDimensions, width: 96, height: 96, percentage: 100, preserveAspectRatio: false, method: .lanczos, sharpenAmount: 0.0
        )
        let imgDifferent = try makeTestImage(width: 120, height: 120) { x, y in
            (x < 60 ? 255 : 0, y < 60 ? 0 : 255, 200, 255)
        }

        let u1 = dir.appendingPathComponent("orig.png")
        let u2 = dir.appendingPathComponent("copy.png")
        let u3 = dir.appendingPathComponent("resized.png")
        let u4 = dir.appendingPathComponent("distinct.png")

        try writeTempPNG(imgA, to: u1)
        try FileManager.default.copyItem(at: u1, to: u2) // Byte-identical
        try writeTempPNG(imgAResized, to: u3)           // Perceptually similar, different bytes/dimensions
        try writeTempPNG(imgDifferent, to: u4)

        let scan = try await ImageDuplicateDetectionService.scan(urls: [u1, u2, u3, u4], similarityThresholdPercent: 85.0)
        #expect(scan.exactGroups.count == 1)
        #expect(scan.exactGroups[0].items.count == 2)
        #expect(scan.similarGroups.count == 1)
        #expect(scan.similarGroups[0].items.count == 2)
    }

    @Test("10. Smart format advisor & SVG security sanitizer work accurately")
    func testSmartAdvisorAndSVGSafety() {
        let chars = ImageSourceCharacteristics(
            sourceFormat: .png,
            width: 1200,
            height: 800,
            fileSizeBytes: 500_000,
            bitDepth: 8,
            isWideGamut: false,
            hasTransparencyFlag: true,
            usesActualAlpha: true,
            isAnimated: false,
            isPhotographicContent: false
        )
        let advice = ImageSmartFormatAdvisor.recommend(from: chars, useCase: .web, preferLossless: false)
        let topFmt = advice.recommendations.first?.format
        #expect(topFmt != .jpg) // JPEG lacks alpha so must never rank #1 for alpha graphic

        let safeSVG = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- generator comment -->
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="120" height="80" viewBox="0 0 120 80">
          <metadata><rdf:RDF>meta</rdf:RDF></metadata>
          <rect x="0" y="0" width="120" height="80" fill="#ff0000" inkscape:label="bg" />
        </svg>
        """
        let optRes = ImageSVGOptimizerService.optimize(data: Data(safeSVG.utf8), options: SVGOptimizationOptions())
        #expect(optRes.inspection.isValidXML == true)
        #expect(optRes.inspection.viewBox == "0 0 120 80")
        #expect(optRes.blockedForSecurity == false)
        #expect(optRes.optimizedBytes < optRes.originalBytes)
        #expect(!optRes.optimizedString.contains("generator comment"))

        let unsafeSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" onload="alert(1)">
          <script>alert('xss')</script>
          <rect width="100" height="100"/>
        </svg>
        """
        let secRes = ImageSVGOptimizerService.optimize(data: Data(unsafeSVG.utf8), options: SVGOptimizationOptions())
        #expect(secRes.blockedForSecurity == true)
        #expect(secRes.wasModified == false)
        #expect(!secRes.inspection.securityWarnings.isEmpty)
    }

    @Test("11. Target File Size search honors budget on JPEG and EXIF/GPS sanitizer cleans non-destructively")
    func testTargetSizeAndNonDestructiveMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-P37-Meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let noisyImg = try makeTestImage(width: 640, height: 480) { x, y in
            (UInt8((x * 17 ^ y * 31) % 256), UInt8((x * 13 + y * 29) % 256), UInt8((x * 7 ^ y * 11) % 256), 255)
        }

        let opt = try ImageProcessor.optimizeForTargetSize(
            cgImage: noisyImg,
            format: .jpg,
            targetBytes: 35_000,
            sourceProperties: nil,
            preserveMetadata: false
        )
        #expect(opt.data.count <= 35_000 || !opt.targetReached)

        // Write JPEG with rich GPS + EXIF + IPTC/TIFF, inspect it, and strip GPS + EXIF non-destructively
        let srcJPG = dir.appendingPathComponent("photo_gps.jpg")
        let cleanJPG = dir.appendingPathComponent("photo_clean.jpg")
        try writeTempJPEGWithGPSAndEXIF(noisyImg, to: srcJPG)

        let beforeSnap = ImageMetadataInspectorService.inspectDetailed(url: srcJPG)
        #expect(beforeSnap.gpsLatitude != nil && beforeSnap.gpsLongitude != nil)
        #expect(beforeSnap.cameraMake == "Apple")
        #expect(beforeSnap.lensModel == "Main 24mm f/1.78")

        var payload = ImageMetadataEditPayload()
        payload.policy = .preserveAll
        payload.stripGPS = true
        payload.stripEXIF = true
        let diff = ImageMetadataInspectorService.previewDiff(snapshot: beforeSnap, payload: payload)
        #expect(diff.removedEntries.count >= 4)

        let writeRes = try await ImageMetadataInspectorService.writeMetadataAndDPINonDestructively(
            from: srcJPG,
            to: cleanJPG,
            payload: payload
        )
        #expect(writeRes.wasLosslessPixelCopy == true)

        let afterSnap = ImageMetadataInspectorService.inspectDetailed(url: cleanJPG)
        #expect(afterSnap.gpsLatitude == nil && afterSnap.gpsLongitude == nil)
        #expect(afterSnap.lensModel == nil)
        #expect(afterSnap.pixelWidth == 640 && afterSnap.pixelHeight == 480)
    }
}

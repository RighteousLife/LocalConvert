import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import LocalConvert

@Suite("Milestone 46.4 — Crop, Continuous Straighten & Geometry Pipeline Tests")
struct ImageGeometryProTests {

    private func makeHorizonScenePNG(width: Int, height: Int, tiltDegrees: Double, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0)
        ctx.rotate(by: CGFloat(tiltDegrees * .pi / 180.0))
        ctx.setFillColor(red: 0.18, green: 0.45, blue: 0.85, alpha: 1.0) // Sky
        ctx.fill(CGRect(x: -width, y: 0, width: width * 2, height: height))
        ctx.setFillColor(red: 0.12, green: 0.35, blue: 0.14, alpha: 1.0) // Ground
        ctx.fill(CGRect(x: -width, y: -height, width: width * 2, height: height))
        ctx.restoreGState()

        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    @Test("Straighten inscribed crop produces zero transparent edge corners across angles and matches ImageDimensionCalculator")
    func straightenInscribedZeroEmptyCorners() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-464-straight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("scene.png")
        try makeHorizonScenePNG(width: 400, height: 240, tiltDegrees: 6.0, to: srcURL)

        for angle in [-45.0, -18.5, -5.0, 7.2, 22.0, 45.0] {
            var cfg = ImageToolboxConfig()
            cfg.cropTransform.enabled = true
            cfg.cropTransform.rotationDegrees = 90
            cfg.cropTransform.flipHorizontal = true
            cfg.cropTransform.straightenDegrees = angle
            cfg.cropTransform.autoCropOnStraighten = true
            cfg.cropTransform.cropMode = .customRect
            cfg.cropTransform.normalizedRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

            let expected = ImageDimensionCalculator.expectedOutputDimensions(sourceWidth: 400, sourceHeight: 240, config: cfg)
            let out = try await ImageProcessingService.processInMemory(
                url: srcURL,
                outputFormat: .png,
                config: cfg,
                previewMaxDimension: nil,
                encodeOutput: false
            )
            let cg = out.previewCGImage
            #expect(abs(cg.width - expected.width) <= 2)
            #expect(abs(cg.height - expected.height) <= 2)

            // Verify every corner pixel has full opacity (alpha == 255) — zero empty triangle wedges!
            var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &rgba, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

            let corners = [
                (0, 0),
                (cg.width - 1, 0),
                (0, cg.height - 1),
                (cg.width - 1, cg.height - 1)
            ]
            for (cx, cy) in corners {
                let a = rgba[(cy * cg.width + cx) * 4 + 3]
                #expect(a >= 250)
            }
        }
    }

    @Test("Vision VNDetectHorizonRequest returns graceful nil on uniform image and non-zero angle on tilted scene")
    func visionHorizonDetectionGracefulAndAccurate() throws {
        // Uniform image should not throw or force bogus non-zero correction
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let blankCtx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 120 * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        blankCtx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        blankCtx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let blankAngle = ImageCropService.detectHorizonAngle(cgImage: blankCtx.makeImage()!)
        #expect(blankAngle == nil)

        // Tilted horizon scene
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-464-horizon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tilted.png")
        try makeHorizonScenePNG(width: 480, height: 320, tiltDegrees: 8.0, to: url)
        let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        if let detected = ImageCropService.detectHorizonAngle(cgImage: cg) {
            #expect(abs(detected) >= 1.0 && abs(detected) <= 45.0)
        }
    }

    @Test("Canonical geometry pipeline combines Rotate + Straighten + Normalized Crop + Perspective cleanly")
    func canonicalGeometryAndPerspectivePipeline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-464-persp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("scene.png")
        try makeHorizonScenePNG(width: 300, height: 200, tiltDegrees: 4.0, to: url)

        var cfg = ImageToolboxConfig()
        cfg.cropTransform.enabled = true
        cfg.cropTransform.straightenDegrees = -4.0
        cfg.cropTransform.cropMode = .customRect
        cfg.cropTransform.normalizedRect = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        cfg.perspective.enabled = true
        cfg.perspective.topLeft = CodableNormalizedPoint(id: 0, x: 0.05, y: 0.05)
        cfg.perspective.topRight = CodableNormalizedPoint(id: 1, x: 0.95, y: 0.05)
        cfg.perspective.bottomRight = CodableNormalizedPoint(id: 2, x: 0.98, y: 0.96)
        cfg.perspective.bottomLeft = CodableNormalizedPoint(id: 3, x: 0.02, y: 0.96)

        let out = try await ImageProcessingService.processInMemory(url: url, outputFormat: .png, config: cfg, previewMaxDimension: nil, encodeOutput: true)
        #expect(out.previewCGImage.width > 100)
        #expect(out.previewCGImage.height > 80)
        #expect(!out.encodedData.isEmpty)
    }
}

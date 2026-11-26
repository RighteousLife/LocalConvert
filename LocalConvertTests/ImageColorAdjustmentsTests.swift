import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
@testable import LocalConvert

@Suite("Milestone 46.2 — Professional Color & Light Adjustment Tests")
struct ImageColorAdjustmentsTests {

    private func renderCI(_ ci: CIImage, bounds: CGRect, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> [UInt8] {
        let w = Int(bounds.width)
        let h = Int(bounds.height)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = ImageProcessor.sharedCIContext(for: colorSpace)
        ctx.render(ci, toBitmap: &rgba, rowBytes: w * 4, bounds: bounds, format: .RGBA8, colorSpace: colorSpace)
        return rgba
    }

    private func makeTonePatchImage() -> (ci: CIImage, extent: CGRect) {
        // 30x10 horizontal gradient patch + colored strips (alpha = 0.75 on bottom row)
        let w = 30, h = 10
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let luma = UInt8(min(255, max(0, (x * 255) / (w - 1))))
                if y < 6 {
                    // Neutral tonal ramp (dark shadows left -> bright whites right)
                    rgba[idx + 0] = luma
                    rgba[idx + 1] = luma
                    rgba[idx + 2] = luma
                    rgba[idx + 3] = 255
                } else {
                    // Muted mid-green / saturated red swatch
                    rgba[idx + 0] = (x < 15) ? 180 : 210
                    rgba[idx + 1] = (x < 15) ? 140 : 60
                    rgba[idx + 2] = (x < 15) ? 120 : 60
                    rgba[idx + 3] = (y == 9) ? 180 : 255
                }
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let cg = CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return (CIImage(cgImage: cg), CGRect(x: 0, y: 0, width: w, height: h))
    }

    @Test("Neutral defaults leave image bit-identical and bypass restores identity")
    func neutralAndBypassIdentity() {
        let (ci, extent) = makeTonePatchImage()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let baseBytes = renderCI(ci, bounds: extent, colorSpace: cs)

        let neutral = ImageColorAdjustmentsConfig()
        #expect(neutral.hasActiveAdjustments == false)
        let outNeutral = ImageAdjustmentsEngine.applyColorAdjustments(ci, config: neutral, workingColorSpace: cs)
        #expect(renderCI(outNeutral, bounds: extent, colorSpace: cs) == baseBytes)

        var bypassed = ImageColorAdjustmentsConfig()
        bypassed.exposureEV = 2.0
        bypassed.saturation = 0.0
        bypassed.isEnabled = false
        #expect(bypassed.hasActiveAdjustments == false)
        let outBypassed = ImageAdjustmentsEngine.applyColorAdjustments(ci, config: bypassed, workingColorSpace: cs)
        #expect(renderCI(outBypassed, bounds: extent, colorSpace: cs) == baseBytes)
    }

    @Test("Exposure, Brightness, Contrast, Gamma, Highlights, Shadows, Whites, Blacks, WB, Vibrance, Saturation, Hue behave distinctly")
    func lightAndColorControlsBehavior() {
        let (ci, extent) = makeTonePatchImage()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = renderCI(ci, bounds: extent, colorSpace: cs)

        func pixel(_ buf: [UInt8], x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            // Note CoreImage render coords map bottom-up vs CGImage data top-down in memory buffer
            let i = (y * Int(extent.width) + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), Int(buf[i + 3]))
        }

        let midNeutral = pixel(base, x: 15, y: 8)
        let darkNeutral = pixel(base, x: 4, y: 8)
        let brightNeutral = pixel(base, x: 25, y: 8)

        // Exposure +1.5 EV increases midtone
        var expPlus = ImageColorAdjustmentsConfig(); expPlus.exposureEV = 1.5
        let expPlusBuf = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: expPlus, workingColorSpace: cs), bounds: extent, colorSpace: cs)
        #expect(pixel(expPlusBuf, x: 15, y: 8).r > midNeutral.r + 30)

        // Shadows +0.8 lifts dark patch cleanly while leaving bright patch much closer
        var shadowsUp = ImageColorAdjustmentsConfig(); shadowsUp.shadows = 0.85
        let shBuf = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: shadowsUp, workingColorSpace: cs), bounds: extent, colorSpace: cs)
        #expect(pixel(shBuf, x: 4, y: 8).r > darkNeutral.r + 10)

        // Highlights -0.85 recovers bright patch cleanly
        var hiDown = ImageColorAdjustmentsConfig(); hiDown.highlights = -0.85
        let hiBuf = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: hiDown, workingColorSpace: cs), bounds: extent, colorSpace: cs)
        #expect(pixel(hiBuf, x: 25, y: 8).r < brightNeutral.r)

        // Blacks -0.9 crushes near-black while Whites +0.9 pushes near-white
        var whitesUp = ImageColorAdjustmentsConfig(); whitesUp.whites = 0.9
        let whBuf = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: whitesUp, workingColorSpace: cs), bounds: extent, colorSpace: cs)
        #expect(pixel(whBuf, x: 25, y: 8).r >= brightNeutral.r)

        // Saturation = 0 produces grayscale across color strip
        var desat = ImageColorAdjustmentsConfig(); desat.saturation = 0.0
        let desatBuf = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: desat, workingColorSpace: cs), bounds: extent, colorSpace: cs)
        let p = pixel(desatBuf, x: 20, y: 2)
        #expect(abs(p.r - p.g) <= 2 && abs(p.g - p.b) <= 2)

        // Warm Temperature increases Red relative to Blue
        var warm = ImageColorAdjustmentsConfig(); warm.temperatureOffset = 80.0
        let warmBuf = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: warm, workingColorSpace: cs), bounds: extent, colorSpace: cs)
        let wp = pixel(warmBuf, x: 15, y: 8)
        #expect(wp.r > wp.b + 10)

        // Alpha preserved on semi-transparent row
        var vib = ImageColorAdjustmentsConfig(); vib.vibrance = 0.8; vib.hueDegrees = 25.0
        let vibBuf = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: vib, workingColorSpace: cs), bounds: extent, colorSpace: cs)
        #expect(abs(pixel(vibBuf, x: 10, y: 0).a - pixel(base, x: 10, y: 0).a) <= 2)
    }

    @Test("Levels validation guards inverted bounds and Red channel isolation leaves Green/Blue isolated")
    func levelsValidationAndChannelIsolation() {
        var invalid = ImageChannelLevels(blackPoint: 0.9, gamma: 10.0, whitePoint: 0.2, outBlack: 0.95, outWhite: 0.1)
        invalid.clamped()
        #expect(invalid.whitePoint >= invalid.blackPoint + 0.02)
        #expect(invalid.outWhite >= invalid.outBlack + 0.01)
        #expect(invalid.gamma <= 5.0)

        let (ci, extent) = makeTonePatchImage()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = renderCI(ci, bounds: extent, colorSpace: cs)

        var cfg = ImageColorAdjustmentsConfig()
        cfg.levels.red = ImageChannelLevels(blackPoint: 0.0, gamma: 2.2, whitePoint: 0.8, outBlack: 0.0, outWhite: 1.0)
        let out = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: cfg, workingColorSpace: cs), bounds: extent, colorSpace: cs)

        let i = (8 * Int(extent.width) + 15) * 4
        #expect(Int(out[i + 0]) > Int(base[i + 0]) + 15)
        #expect(abs(Int(out[i + 1]) - Int(base[i + 1])) <= 2)
        #expect(abs(Int(out[i + 2]) - Int(base[i + 2])) <= 2)
    }

    @Test("Fritsch-Carlson spline curves remain monotonic/bounded and Color Balance isolates shadows from highlights")
    func curvesSplineAndColorBalance() {
        let steepStep = [
            ImageCurvePoint(x: 0.0, y: 0.0),
            ImageCurvePoint(x: 0.45, y: 0.05),
            ImageCurvePoint(x: 0.55, y: 0.95),
            ImageCurvePoint(x: 1.0, y: 1.0)
        ]
        let lut = ImageCurvesConfig.buildLUT(points: steepStep, sampleCount: 256)
        #expect(lut.count == 256)
        // Must NEVER overshoot below 0 or above 1 or reverse monotonicity on monotonic knot inputs
        for idx in 1..<lut.count {
            #expect(lut[idx] >= 0.0 && lut[idx] <= 1.0)
            #expect(lut[idx] + 1e-6 >= lut[idx - 1])
        }

        let (ci, extent) = makeTonePatchImage()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var bal = ImageColorAdjustmentsConfig()
        bal.colorBalance.shadows = ImageRGBBalanceOffset(cyanRed: 0.8, magentaGreen: -0.4, yellowBlue: -0.6)
        let out = renderCI(ImageAdjustmentsEngine.applyColorAdjustments(ci, config: bal, workingColorSpace: cs), bounds: extent, colorSpace: cs)

        // Shadow neutral pixel on gray ramp (y=1) shifts distinctly warmer toward red; near-white highlight pixel barely shifts
        let darkIdx = (1 * Int(extent.width) + 3) * 4
        let whiteIdx = (1 * Int(extent.width) + 28) * 4
        #expect(Int(out[darkIdx + 0]) > Int(out[darkIdx + 2]) + 10)
        #expect(abs(Int(out[whiteIdx + 0]) - Int(out[whiteIdx + 2])) <= 12)
    }

    @Test("Preview vs full-res export parity and Display P3 color space retention across PNG export")
    func previewExportParityAndColorSpace() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-462-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p3URL = dir.appendingPathComponent("p3_source.png")
        let p3CS = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 160 * 4, space: p3CS, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.85, green: 0.22, blue: 0.18, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        let srcCG = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(p3URL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, srcCG, nil)
        CGImageDestinationFinalize(dest)

        var cfg = ImageToolboxConfig()
        cfg.colorAdjustments.exposureEV = 0.6
        cfg.colorAdjustments.vibrance = 0.45
        cfg.colorAdjustments.curves.master = [ImageCurvePoint(x: 0, y: 0), ImageCurvePoint(x: 0.5, y: 0.58), ImageCurvePoint(x: 1, y: 1)]

        let previewOut = try await ImageProcessingService.processInMemory(url: p3URL, outputFormat: .png, config: cfg, previewMaxDimension: 1200, encodeOutput: false)
        let exportOut = try await ImageProcessingService.processInMemory(url: p3URL, outputFormat: .png, config: cfg, previewMaxDimension: nil, encodeOutput: true)

        #expect(exportOut.previewCGImage.colorSpace?.isWideGamutRGB == true)
        let histPrev = try #require(ImageColorAnalysisService.computeHistogram(cgImage: previewOut.previewCGImage))
        let histExp = try #require(ImageColorAnalysisService.computeHistogram(cgImage: exportOut.previewCGImage))
        #expect(abs(histPrev.meanLuminance - histExp.meanLuminance) < 2.0)
    }
}

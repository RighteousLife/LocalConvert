import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import CryptoKit
@testable import LocalConvert

@Suite("Milestone 46.5 — Native Camera RAW Support & Fallback Tests")
struct ImageRAWDevelopTests {

    private func writeTIFFWithDNGExtension(to url: URL, width: Int = 120, height: Int = 80) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 0.35, green: 0.55, blue: 0.72, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    @Test("CIRAWFilter SDK capability check, parameter clamping, and ImageRAWDevelopConfig defaults")
    func rawSDKAvailabilityAndConfigBounds() throws {
        // Verify runtime SDK reports supported camera models dynamically (no hardcoded assertions)
        #expect(!CIRAWFilter.supportedCameraModels.isEmpty)

        var cfg = ImageRAWDevelopConfig()
        #expect(cfg.hasNonDefaultParameters == false)
        cfg.exposureEV = 12.0
        cfg.neutralTemperatureKelvin = 900.0
        cfg.neutralTint = -500.0
        cfg.lumaNoiseReduction = 4.0
        cfg.clamped()
        #expect(cfg.exposureEV == 4.0)
        #expect(cfg.neutralTemperatureKelvin == 2000.0)
        #expect(cfg.neutralTint == -150.0)
        #expect(cfg.lumaNoiseReduction == 1.0)
        #expect(cfg.hasNonDefaultParameters == true)

        #expect(ImageProcessingService.cameraRAWFormats.contains(.dng))
        #expect(ImageProcessingService.cameraRAWFormats.contains(.cr3))
        #expect(ImageProcessingService.cameraRAWFormats.contains(.nef))
        #expect(ImageProcessingService.cameraRAWFormats.contains(.arw))
    }

    @Test("Unsupported DNG triggers explicit ImageIO fallback warning, applies adjustments, keeps source untouched, and rejects corrupt CR3")
    func rawFallbackBehaviorAndSourceImmutability() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-465-raw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 16-bit TIFF payload with .dng extension is rejected by RA02/CIRAWFilter and handled cleanly via explicit ImageIO fallback
        let dngURL = dir.appendingPathComponent("linear_fallback.dng")
        try writeTIFFWithDNGExtension(to: dngURL, width: 160, height: 120)
        let hashBefore = SHA256.hash(data: try Data(contentsOf: dngURL)).map { String(format: "%02x", $0) }.joined()

        var darkCfg = ImageToolboxConfig()
        darkCfg.colorAdjustments.exposureEV = -1.5
        var brightCfg = ImageToolboxConfig()
        brightCfg.colorAdjustments.exposureEV = 1.5

        let darkOut = try await ImageProcessingService.processInMemory(
            url: dngURL, outputFormat: .png, config: darkCfg, previewMaxDimension: 100, encodeOutput: false
        )
        let brightOut = try await ImageProcessingService.processInMemory(
            url: dngURL, outputFormat: .png, config: brightCfg, previewMaxDimension: 1200, encodeOutput: false
        )
        #expect(darkOut.usedRAWFallback == true)
        #expect(brightOut.usedRAWFallback == true)
        #expect(brightOut.telemetry.warnings.contains(where: { $0.contains("CIRAWFilter") }))
        #expect(max(darkOut.previewCGImage.width, darkOut.previewCGImage.height) <= 105)

        let darkHist = try #require(ImageColorAnalysisService.computeHistogram(cgImage: darkOut.previewCGImage))
        let brightHist = try #require(ImageColorAnalysisService.computeHistogram(cgImage: brightOut.previewCGImage))
        #expect(brightHist.meanLuminance > darkHist.meanLuminance + 30.0)

        let expOut = try await ImageProcessingService.processToFile(
            inputURL: dngURL,
            outputFormat: .png,
            outputDirectory: dir,
            config: brightCfg,
            overwriteExisting: false
        )
        #expect(FileManager.default.fileExists(atPath: expOut.outputURL.path))
        let hashAfter = SHA256.hash(data: try Data(contentsOf: dngURL)).map { String(format: "%02x", $0) }.joined()
        #expect(hashBefore == hashAfter)

        // Corrupt RAW file fails cleanly without crashing
        let corruptCR3 = dir.appendingPathComponent("broken.cr3")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: corruptCR3)
        var didThrow = false
        do {
            _ = try await ImageProcessingService.processInMemory(url: corruptCR3, outputFormat: .jpg, config: ImageToolboxConfig())
        } catch {
            didThrow = true
        }
        #expect(didThrow)
    }
}

import Foundation
import CoreGraphics
import AppKit

// MARK: - Objective Image Comparison Metrics & Difference Map Service

struct ImageComparisonQualityReport: Sendable {
    let mse: Double
    let mae: Double
    let psnrDB: Double          // Double.infinity when images are identical
    let ssim: Double            // 0.0 ... 1.0
    let maxChannelDelta: Int    // 0 ... 255
    let comparedWidth: Int
    let comparedHeight: Int
    let hadDimensionMismatch: Bool
    let hadColorSpaceNormalization: Bool
    let butteraugliSupported: Bool
    let butteraugliNote: String
    let differenceMapImage: NSImage?
}

enum ImageQualityMetricsService {

    /// Computes MSE, MAE, PSNR (dB), SSIM, and an amplified visual Difference Map between two images.
    /// Automatically normalizes mismatched resolutions/color spaces to bounded sRGB RGBA8 and reports every normalization clearly.
    static func analyze(
        reference: CGImage,
        candidate: CGImage,
        maxComparisonDimension: Int = 1024,
        amplification: Double = 4.0
    ) -> ImageComparisonQualityReport? {
        let hadDimensionMismatch = (reference.width != candidate.width || reference.height != candidate.height)
        let refCSName = reference.colorSpace?.name as String?
        let candCSName = candidate.colorSpace?.name as String?
        let hadColorNorm = (refCSName != candCSName) || (refCSName != (CGColorSpace.sRGB as String))

        let maxDim = max(1, min(maxComparisonDimension, max(candidate.width, candidate.height)))
        let scale = min(1.0, Double(maxDim) / Double(max(1, max(candidate.width, candidate.height))))
        let compW = max(1, Int((Double(candidate.width) * scale).rounded()))
        let compH = max(1, Int((Double(candidate.height) * scale).rounded()))

        guard let refBytes = renderSRGB(cgImage: reference, width: compW, height: compH),
              let candBytes = renderSRGB(cgImage: candidate, width: compW, height: compH) else {
            return nil
        }

        let pixelCount = compW * compH
        var sumSqErr: Double = 0
        var sumAbsErr: Double = 0
        var maxDelta = 0

        var refLuma = [Double](repeating: 0, count: pixelCount)
        var candLuma = [Double](repeating: 0, count: pixelCount)
        var diffRGBA = [UInt8](repeating: 255, count: pixelCount * 4)

        for i in 0..<pixelCount {
            let o = i * 4
            let r1 = Int(refBytes[o])
            let g1 = Int(refBytes[o + 1])
            let b1 = Int(refBytes[o + 2])

            let r2 = Int(candBytes[o])
            let g2 = Int(candBytes[o + 1])
            let b2 = Int(candBytes[o + 2])

            let dr = abs(r1 - r2)
            let dg = abs(g1 - g2)
            let db = abs(b1 - b2)

            sumAbsErr += Double(dr + dg + db)
            sumSqErr += Double(dr * dr + dg * dg + db * db)

            let pixMax = max(dr, max(dg, db))
            if pixMax > maxDelta { maxDelta = pixMax }

            refLuma[i] = 0.2126 * Double(r1) + 0.7152 * Double(g1) + 0.0722 * Double(b1)
            candLuma[i] = 0.2126 * Double(r2) + 0.7152 * Double(g2) + 0.0722 * Double(b2)

            // Heatmap encoding for visual inspection of pixel delta
            let mag = min(255.0, Double(dr + dg + db) / 3.0 * amplification)
            if mag < 1.0 {
                diffRGBA[o] = 16
                diffRGBA[o + 1] = 18
                diffRGBA[o + 2] = 22
            } else if mag < 128.0 {
                let t = mag / 128.0
                diffRGBA[o] = UInt8(min(255, max(0, Int((40 + t * 215).rounded()))))
                diffRGBA[o + 1] = UInt8(min(255, max(0, Int((90 + t * 110).rounded()))))
                diffRGBA[o + 2] = UInt8(min(255, max(0, Int((220 - t * 180).rounded()))))
            } else {
                let t = (mag - 128.0) / 127.0
                diffRGBA[o] = 255
                diffRGBA[o + 1] = UInt8(min(255, max(0, Int((200 * (1.0 - t * 0.7)).rounded()))))
                diffRGBA[o + 2] = UInt8(min(255, max(0, Int((40 + t * 215).rounded()))))
            }
            diffRGBA[o + 3] = 255
        }

        let channelCount = Double(max(1, pixelCount * 3))
        let mse = sumSqErr / channelCount
        let mae = sumAbsErr / channelCount
        let psnr: Double = (mse <= 1e-12) ? .infinity : (10.0 * log10((255.0 * 255.0) / mse))
        let ssim = computeBlockSSIM(refLuma: refLuma, candLuma: candLuma, width: compW, height: compH)

        let diffImg = makeNSImage(rgba: diffRGBA, width: compW, height: compH)

        return ImageComparisonQualityReport(
            mse: mse,
            mae: mae,
            psnrDB: psnr,
            ssim: ssim,
            maxChannelDelta: maxDelta,
            comparedWidth: compW,
            comparedHeight: compH,
            hadDimensionMismatch: hadDimensionMismatch,
            hadColorSpaceNormalization: hadColorNorm,
            butteraugliSupported: false,
            butteraugliNote: "Butteraugli measurement API is not exposed by the bundled libjxl bridge; MSE, MAE, PSNR, and SSIM are measured over sRGB pixels.",
            differenceMapImage: diffImg
        )
    }

    // MARK: - Block-based Luminance SSIM (8×8 non-overlapping windows)

    private static func computeBlockSSIM(
        refLuma: [Double],
        candLuma: [Double],
        width: Int,
        height: Int
    ) -> Double {
        let block = 8
        let c1 = (0.01 * 255.0) * (0.01 * 255.0)
        let c2 = (0.03 * 255.0) * (0.03 * 255.0)

        if width < block || height < block {
            return blockSSIM(refLuma: refLuma, candLuma: candLuma, x0: 0, y0: 0, bw: width, bh: height, stride: width, c1: c1, c2: c2)
        }

        var sumSSIM = 0.0
        var windows = 0
        var y = 0
        while y + block <= height {
            var x = 0
            while x + block <= width {
                sumSSIM += blockSSIM(refLuma: refLuma, candLuma: candLuma, x0: x, y0: y, bw: block, bh: block, stride: width, c1: c1, c2: c2)
                windows += 1
                x += block
            }
            y += block
        }
        return windows > 0 ? max(0.0, min(1.0, sumSSIM / Double(windows))) : 1.0
    }

    private static func blockSSIM(
        refLuma: [Double],
        candLuma: [Double],
        x0: Int,
        y0: Int,
        bw: Int,
        bh: Int,
        stride: Int,
        c1: Double,
        c2: Double
    ) -> Double {
        let n = Double(max(1, bw * bh))
        var muX = 0.0
        var muY = 0.0
        for dy in 0..<bh {
            let row = (y0 + dy) * stride + x0
            for dx in 0..<bw {
                muX += refLuma[row + dx]
                muY += candLuma[row + dx]
            }
        }
        muX /= n
        muY /= n

        var varX = 0.0
        var varY = 0.0
        var covXY = 0.0
        for dy in 0..<bh {
            let row = (y0 + dy) * stride + x0
            for dx in 0..<bw {
                let vx = refLuma[row + dx] - muX
                let vy = candLuma[row + dx] - muY
                varX += vx * vx
                varY += vy * vy
                covXY += vx * vy
            }
        }
        varX /= n
        varY /= n
        covXY /= n

        let num = (2.0 * muX * muY + c1) * (2.0 * covXY + c2)
        let den = (muX * muX + muY * muY + c1) * (varX + varY + c2)
        return den > 0 ? (num / den) : 1.0
    }

    private static func renderSRGB(cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }

    private static func makeNSImage(rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var copy = rgba
        let cg: CGImage? = copy.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            return ctx.makeImage()
        }
        guard let cg else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}

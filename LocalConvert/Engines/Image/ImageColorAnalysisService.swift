import Foundation
import CoreGraphics
import ImageIO

// MARK: - Histogram & Dominant Color Palette Analysis Service

struct ImageHistogramData: Sendable, Equatable {
    let redBins: [Int]         // 256 bins
    let greenBins: [Int]       // 256 bins
    let blueBins: [Int]        // 256 bins
    let luminanceBins: [Int]   // 256 bins (Rec.709)
    let samplePixelCount: Int
    let minLuminance: Int      // 0...255
    let maxLuminance: Int      // 0...255
    let meanLuminance: Double  // 0.0...255.0
    let shadowClippingPercent: Double    // Luma <= 2
    let highlightClippingPercent: Double // Luma >= 253
    let profileName: String
    let bitDepth: Int
}

struct ImagePaletteSwatch: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: Int
    let red: Int               // 0...255
    let green: Int             // 0...255
    let blue: Int              // 0...255
    let hex: String            // "#RRGGBB"
    let hsl: String            // "hsl(h, s%, l%)"
    let rgbString: String      // "rgb(r, g, b)"
    let hue: Int               // 0...360
    let saturation: Int        // 0...100
    let lightness: Int         // 0...100
    let coveragePercent: Double
}

struct ImagePaletteExtractionResult: Sendable, Equatable {
    let swatches: [ImagePaletteSwatch]
    let analyzedSamplePixels: Int
}

enum ImageColorAnalysisService {

    /// Computes authentic pixel-level RGB & Luminance histograms plus clipping telemetry from a bounded sRGB buffer.
    static func computeHistogram(
        cgImage: CGImage,
        colorInfo: ImageColorProfileInfo? = nil,
        maxSampleDimension: Int = 512
    ) -> ImageHistogramData? {
        guard let buffer = downsampleToSRGBBytes(cgImage: cgImage, maxDimension: maxSampleDimension) else {
            return nil
        }

        var rBins = [Int](repeating: 0, count: 256)
        var gBins = [Int](repeating: 0, count: 256)
        var bBins = [Int](repeating: 0, count: 256)
        var yBins = [Int](repeating: 0, count: 256)

        var totalSamples = 0
        var minLuma = 255
        var maxLuma = 0
        var sumLuma: Int64 = 0
        var shadowClipped = 0
        var highlightClipped = 0

        let bytes = buffer.rgba
        let count = buffer.width * buffer.height

        for i in 0..<count {
            let offset = i * 4
            let a = bytes[offset + 3]
            if a <= 8 { continue } // Ignore fully transparent background pixels

            let r = Int(bytes[offset])
            let g = Int(bytes[offset + 1])
            let b = Int(bytes[offset + 2])

            let luma = min(255, max(0, Int((0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())))

            rBins[r] += 1
            gBins[g] += 1
            bBins[b] += 1
            yBins[luma] += 1

            totalSamples += 1
            sumLuma += Int64(luma)
            if luma < minLuma { minLuma = luma }
            if luma > maxLuma { maxLuma = luma }
            if luma <= 2 { shadowClipped += 1 }
            if luma >= 253 { highlightClipped += 1 }
        }

        guard totalSamples > 0 else {
            return ImageHistogramData(
                redBins: rBins,
                greenBins: gBins,
                blueBins: bBins,
                luminanceBins: yBins,
                samplePixelCount: 0,
                minLuminance: 0,
                maxLuminance: 0,
                meanLuminance: 0,
                shadowClippingPercent: 0,
                highlightClippingPercent: 0,
                profileName: colorInfo?.profileName ?? (cgImage.colorSpace?.name as String? ?? "sRGB"),
                bitDepth: colorInfo?.bitDepth ?? cgImage.bitsPerComponent
            )
        }

        let mean = Double(sumLuma) / Double(totalSamples)
        let shadowPct = (Double(shadowClipped) / Double(totalSamples)) * 100.0
        let highlightPct = (Double(highlightClipped) / Double(totalSamples)) * 100.0

        return ImageHistogramData(
            redBins: rBins,
            greenBins: gBins,
            blueBins: bBins,
            luminanceBins: yBins,
            samplePixelCount: totalSamples,
            minLuminance: minLuma,
            maxLuminance: maxLuma,
            meanLuminance: mean,
            shadowClippingPercent: shadowPct,
            highlightClippingPercent: highlightPct,
            profileName: colorInfo?.profileName ?? "sRGB IEC61966-2.1",
            bitDepth: colorInfo?.bitDepth ?? cgImage.bitsPerComponent
        )
    }

    /// Extracts dominant colors using deterministic k-means++ clustering on downsampled sRGB pixels.
    static func extractPalette(
        cgImage: CGImage,
        colorCount: Int,
        maxSampleDimension: Int = 160
    ) -> ImagePaletteExtractionResult {
        let targetK = max(2, min(16, colorCount))
        guard let buffer = downsampleToSRGBBytes(cgImage: cgImage, maxDimension: maxSampleDimension) else {
            return ImagePaletteExtractionResult(swatches: [], analyzedSamplePixels: 0)
        }

        struct RGBSample {
            let r: Double
            let g: Double
            let b: Double
        }

        var samples: [RGBSample] = []
        samples.reserveCapacity(buffer.width * buffer.height)
        let bytes = buffer.rgba
        for i in 0..<(buffer.width * buffer.height) {
            let o = i * 4
            let a = Int(bytes[o + 3])
            if a <= 16 { continue }
            samples.append(RGBSample(r: Double(bytes[o]), g: Double(bytes[o + 1]), b: Double(bytes[o + 2])))
        }

        guard !samples.isEmpty else {
            return ImagePaletteExtractionResult(swatches: [], analyzedSamplePixels: 0)
        }

        // Quantize unique colors first to keep clustering ultra-fast and exact on graphic art
        var bucketCounts: [Int: (r: Double, g: Double, b: Double, count: Int)] = [:]
        for s in samples {
            let rq = Int(s.r) >> 3
            let gq = Int(s.g) >> 3
            let bq = Int(s.b) >> 3
            let key = (rq << 10) | (gq << 5) | bq
            if var existing = bucketCounts[key] {
                existing.r += s.r
                existing.g += s.g
                existing.b += s.b
                existing.count += 1
                bucketCounts[key] = existing
            } else {
                bucketCounts[key] = (s.r, s.g, s.b, 1)
            }
        }

        let weightedPoints = bucketCounts.values
            .map { (r: $0.r / Double($0.count), g: $0.g / Double($0.count), b: $0.b / Double($0.count), weight: $0.count) }
            .sorted { $0.weight > $1.weight }

        let k = min(targetK, weightedPoints.count)

        // Farthest-first deterministic seeding from highest-weight anchor
        var centroids: [(r: Double, g: Double, b: Double)] = [(weightedPoints[0].r, weightedPoints[0].g, weightedPoints[0].b)]
        while centroids.count < k {
            var bestIdx = 0
            var bestScore = -1.0
            for (idx, pt) in weightedPoints.enumerated() {
                var minDistSq = Double.greatestFiniteMagnitude
                for c in centroids {
                    let dr = pt.r - c.r
                    let dg = pt.g - c.g
                    let db = pt.b - c.b
                    let d = dr * dr + dg * dg + db * db
                    if d < minDistSq { minDistSq = d }
                }
                let score = minDistSq * sqrt(Double(pt.weight))
                if score > bestScore {
                    bestScore = score
                    bestIdx = idx
                }
            }
            let chosen = weightedPoints[bestIdx]
            centroids.append((chosen.r, chosen.g, chosen.b))
        }

        var clusterWeights = [Int](repeating: 0, count: k)
        for _ in 0..<12 {
            var sumR = [Double](repeating: 0, count: k)
            var sumG = [Double](repeating: 0, count: k)
            var sumB = [Double](repeating: 0, count: k)
            clusterWeights = [Int](repeating: 0, count: k)

            for pt in weightedPoints {
                var nearest = 0
                var nearestDist = Double.greatestFiniteMagnitude
                for ci in 0..<k {
                    let c = centroids[ci]
                    let dr = pt.r - c.r
                    let dg = pt.g - c.g
                    let db = pt.b - c.b
                    let d = dr * dr + dg * dg + db * db
                    if d < nearestDist {
                        nearestDist = d
                        nearest = ci
                    }
                }
                let w = pt.weight
                clusterWeights[nearest] += w
                sumR[nearest] += pt.r * Double(w)
                sumG[nearest] += pt.g * Double(w)
                sumB[nearest] += pt.b * Double(w)
            }

            var shifted = false
            for ci in 0..<k where clusterWeights[ci] > 0 {
                let w = Double(clusterWeights[ci])
                let nr = sumR[ci] / w
                let ng = sumG[ci] / w
                let nb = sumB[ci] / w
                if abs(nr - centroids[ci].r) > 0.4 || abs(ng - centroids[ci].g) > 0.4 || abs(nb - centroids[ci].b) > 0.4 {
                    shifted = true
                }
                centroids[ci] = (nr, ng, nb)
            }
            if !shifted { break }
        }

        let totalW = max(1, clusterWeights.reduce(0, +))
        let sortedPairs = (0..<k)
            .filter { clusterWeights[$0] > 0 }
            .sorted { clusterWeights[$0] > clusterWeights[$1] }

        let swatches: [ImagePaletteSwatch] = sortedPairs.enumerated().map { idx, ci in
            let c = centroids[ci]
            let r = max(0, min(255, Int(c.r.rounded())))
            let g = max(0, min(255, Int(c.g.rounded())))
            let b = max(0, min(255, Int(c.b.rounded())))
            let hex = String(format: "#%02X%02X%02X", r, g, b)
            let (h, s, l) = rgbToHSL(r: r, g: g, b: b)
            let pct = (Double(clusterWeights[ci]) / Double(totalW)) * 100.0
            return ImagePaletteSwatch(
                id: idx + 1,
                red: r,
                green: g,
                blue: b,
                hex: hex,
                hsl: "hsl(\(h), \(s)%, \(l)%)",
                rgbString: "rgb(\(r), \(g), \(b))",
                hue: h,
                saturation: s,
                lightness: l,
                coveragePercent: pct
            )
        }

        return ImagePaletteExtractionResult(swatches: swatches, analyzedSamplePixels: samples.count)
    }

    // MARK: - Palette Exports (JSON, CSS, PNG Swatch Sheet)

    static func exportJSON(swatches: [ImagePaletteSwatch]) -> String {
        struct Entry: Encodable {
            let index: Int
            let hex: String
            let rgb: String
            let hsl: String
            let coveragePercent: Double
        }
        let entries = swatches.map {
            Entry(index: $0.id, hex: $0.hex, rgb: $0.rgbString, hsl: $0.hsl, coveragePercent: ($0.coveragePercent * 10).rounded() / 10)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries), let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    static func exportCSS(swatches: [ImagePaletteSwatch]) -> String {
        var lines = [":root {"]
        for s in swatches {
            lines.append("  --palette-color-\(s.id): \(s.hex); /* \(s.rgbString) · \(String(format: "%.1f%%", s.coveragePercent)) */")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    static func renderPalettePNG(swatches: [ImagePaletteSwatch]) throws -> Data {
        let count = max(1, swatches.count)
        let cardWidth = max(600, count * 110 + 40)
        let cardHeight = 200
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: cardWidth,
            height: cardHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to create palette PNG context.", underlyingError: nil)
        }

        ctx.setFillColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight))

        let pad: CGFloat = 20
        let gap: CGFloat = 10
        let availableW = CGFloat(cardWidth) - pad * 2 - gap * CGFloat(max(0, count - 1))
        let swatchW = availableW / CGFloat(count)

        for (idx, swatch) in swatches.enumerated() {
            let x = pad + CGFloat(idx) * (swatchW + gap)
            let rect = CGRect(x: x, y: 40, width: swatchW, height: CGFloat(cardHeight - 64))
            ctx.setFillColor(
                red: Double(swatch.red) / 255.0,
                green: Double(swatch.green) / 255.0,
                blue: Double(swatch.blue) / 255.0,
                alpha: 1.0
            )
            let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }

        guard let img = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to render palette image.", underlyingError: nil)
        }
        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to encode palette PNG.", underlyingError: nil)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize palette PNG.", underlyingError: nil)
        }
        return mutable as Data
    }

    // MARK: - Internal Helpers

    private static func rgbToHSL(r: Int, g: Int, b: Int) -> (Int, Int, Int) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxC = max(rf, max(gf, bf))
        let minC = min(rf, min(gf, bf))
        let l = (maxC + minC) / 2.0
        let delta = maxC - minC

        if delta < 0.0001 {
            return (0, 0, Int((l * 100.0).rounded()))
        }

        let s = l > 0.5 ? delta / (2.0 - maxC - minC) : delta / (maxC + minC)
        var h: Double
        if maxC == rf {
            h = (gf - bf) / delta + (gf < bf ? 6.0 : 0.0)
        } else if maxC == gf {
            h = (bf - rf) / delta + 2.0
        } else {
            h = (rf - gf) / delta + 4.0
        }
        h /= 6.0
        return (Int((h * 360.0).rounded()) % 360, Int((s * 100.0).rounded()), Int((l * 100.0).rounded()))
    }

    static func downsampleToSRGBBytes(cgImage: CGImage, maxDimension: Int) -> (width: Int, height: Int, rgba: [UInt8])? {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = min(1.0, Double(maxDimension) / Double(max(srcW, srcH)))
        let dstW = max(1, Int((Double(srcW) * scale).rounded()))
        let dstH = max(1, Int((Double(srcH) * scale).rounded()))

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: dstW * dstH * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: dstW * 4,
                space: cs,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            return true
        }
        return ok ? (dstW, dstH, bytes) : nil
    }
}

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Smart Format Recommendation Engine (Grounded in FormatCapabilityRegistry & ConversionMatrix)

enum ImageIntendedUseCase: String, CaseIterable, Codable, Sendable, Identifiable {
    case web = "Web Delivery"
    case archive = "Archival / Master"
    case print = "Print & Publishing"
    case sharing = "Universal Sharing"

    var id: String { rawValue }
}

struct ImageSourceCharacteristics: Sendable, Equatable {
    let sourceFormat: FileFormat?
    let width: Int
    let height: Int
    let fileSizeBytes: Int64
    let bitDepth: Int
    let isWideGamut: Bool
    let hasTransparencyFlag: Bool
    let usesActualAlpha: Bool
    let isAnimated: Bool
    let isPhotographicContent: Bool
}

struct ImageFormatRecommendation: Identifiable, Sendable, Equatable {
    let format: FileFormat
    let score: Int
    let prefersLossless: Bool
    let badgeText: String
    let rationale: String
    let tradeOffWarning: String?
    let matrixRouteWarning: String?

    var id: String { format.rawValue }
}

struct ImageSmartFormatReport: Sendable {
    let characteristics: ImageSourceCharacteristics
    let recommendations: [ImageFormatRecommendation]
    let estimationDisclaimer: String
}

enum ImageSmartFormatAdvisor {

    /// Inspects image pixel/alpha/bit-depth/animation properties and recommends optimal writable formats.
    static func analyze(
        url: URL,
        useCase: ImageIntendedUseCase,
        preferLossless: Bool
    ) async throws -> ImageSmartFormatReport {
        let decoded = try await ImageProcessingService.decodeInputImage(url: url, maxPixelDimension: 256)
        let colorInfo = ImageColorManagementService.inspectColorProfile(url: url, cgImage: decoded.cgImage)
        let fullDims = ImageProcessingService.inspectSourceDimensions(url: url)
        let srcFmt = decoded.format ?? FileDetector.detectFormat(url: url)
        let srcCap = srcFmt.map { FormatCapabilityRegistry.shared.capability(for: $0) }

        let jxlInfo = (srcFmt == .jxl) ? (try? JPEGXLCodec.inspect(url: url)) : nil
        let isAnimated = (jxlInfo?.isAnimated ?? false) || (srcCap?.supportsAnimation ?? false && srcFmt != .jxl && {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceGetCount(src) > 1
        }())

        let alphaCheck = inspectPixelAlphaAndContent(cgImage: decoded.cgImage)

        let chars = ImageSourceCharacteristics(
            sourceFormat: srcFmt,
            width: fullDims?.width ?? decoded.cgImage.width,
            height: fullDims?.height ?? decoded.cgImage.height,
            fileSizeBytes: decoded.fileSizeBytes,
            bitDepth: colorInfo.bitDepth,
            isWideGamut: colorInfo.isWideGamut,
            hasTransparencyFlag: colorInfo.hasAlpha,
            usesActualAlpha: alphaCheck.hasNonOpaquePixels,
            isAnimated: isAnimated,
            isPhotographicContent: alphaCheck.looksPhotographic
        )

        return recommend(from: chars, useCase: useCase, preferLossless: preferLossless)
    }

    /// Pure deterministic recommendation scorer for both UI and unit tests.
    static func recommend(
        from chars: ImageSourceCharacteristics,
        useCase: ImageIntendedUseCase,
        preferLossless: Bool
    ) -> ImageSmartFormatReport {
        let candidates: [FileFormat] = [.jxl, .avif, .webp, .png, .tiff, .jpg, .heic]
        let registry = FormatCapabilityRegistry.shared

        var scored: [ImageFormatRecommendation] = []
        for fmt in candidates {
            let cap = registry.capability(for: fmt)
            guard cap.canWrite else { continue }

            var score = 50
            var reasons: [String] = []
            var tradeOffs: [String] = []
            var formatLossless = preferLossless

            if chars.isAnimated {
                if cap.supportsAnimation {
                    score += 30
                    reasons.append("preserves animation frames")
                } else {
                    score -= 35
                    tradeOffs.append("flattens animation to frame 1")
                }
            }

            if chars.usesActualAlpha {
                if cap.supportsTransparency {
                    score += 22
                    reasons.append("preserves alpha transparency")
                } else {
                    score -= 45
                    tradeOffs.append("no alpha channel; transparency will flatten")
                }
            }

            if chars.bitDepth > 8 || chars.isWideGamut {
                if [.jxl, .png, .tiff, .avif, .heic].contains(fmt) {
                    score += 12
                    reasons.append("retains high bit-depth / wide color gamut")
                } else if fmt == .jpg || fmt == .webp {
                    score -= 10
                    tradeOffs.append("8-bit quantization limits wide-gamut precision")
                }
            }

            switch useCase {
            case .web:
                if fmt == .avif || fmt == .webp || fmt == .jxl {
                    score += 22
                    reasons.append("modern high-efficiency web compression")
                }
                if fmt == .png && !chars.isPhotographicContent && chars.usesActualAlpha {
                    score += 18
                    reasons.append("sharp edges on flat/UI graphics")
                }
                if fmt == .tiff { score -= 30 }

            case .archive:
                if fmt == .jxl {
                    score += 30
                    formatLossless = true
                    reasons.append("16-bit/ICC lossless JPEG XL archival")
                    if chars.sourceFormat == .jpg {
                        reasons.append("lossless JPEG bitstream transcoding available")
                    }
                } else if fmt == .png || fmt == .tiff {
                    score += 22
                    formatLossless = true
                    reasons.append("bit-exact lossless master storage")
                } else if fmt == .jpg {
                    score -= 30
                    tradeOffs.append("re-encoding introduces generation loss")
                }

            case .print:
                if fmt == .tiff || fmt == .png {
                    score += 28
                    formatLossless = true
                    reasons.append("uncompressed/lossless print pipeline compatibility")
                } else if fmt == .jxl {
                    score += 14
                    reasons.append("preserves embedded ICC & 16-bit precision")
                } else if fmt == .webp {
                    score -= 20
                    tradeOffs.append("limited prepress/RIP adoption")
                }

            case .sharing:
                if fmt == .jpg && !chars.usesActualAlpha && !preferLossless {
                    score += 26
                    reasons.append("universal cross-device compatibility")
                } else if fmt == .png && chars.usesActualAlpha {
                    score += 24
                    reasons.append("universal alpha compatibility")
                } else if fmt == .heic {
                    score += 15
                    reasons.append("compact Apple ecosystem support")
                } else if fmt == .jxl {
                    score += 8
                    tradeOffs.append("older viewers may need JPEG/PNG fallback")
                }
            }

            if preferLossless {
                if [.png, .tiff, .jxl, .webp].contains(fmt) {
                    score += 15
                    formatLossless = true
                } else {
                    score -= 20
                    formatLossless = false
                    tradeOffs.append("format is strictly lossy at export")
                }
            } else {
                if [.png, .tiff, .bmp, .tga].contains(fmt) {
                    formatLossless = true
                }
                if chars.isPhotographicContent && [.jxl, .avif, .webp, .heic, .jpg].contains(fmt) {
                    score += 10
                    reasons.append("well-suited for photographic textures")
                }
            }

            let matrixWarn = chars.sourceFormat.flatMap { ConversionMatrix.routeWarning(from: $0, to: fmt) }
            if let note = cap.limitationNote, tradeOffs.isEmpty && score < 70 {
                tradeOffs.append(note)
            }

            let badge = formatLossless ? "Lossless" : "Lossy"
            scored.append(ImageFormatRecommendation(
                format: fmt,
                score: score,
                prefersLossless: formatLossless,
                badgeText: badge,
                rationale: reasons.isEmpty ? "Supported target via \(fmt.displayName)." : reasons.joined(separator: "; ").capitalizingFirst() + ".",
                tradeOffWarning: tradeOffs.isEmpty ? nil : tradeOffs.joined(separator: " · "),
                matrixRouteWarning: matrixWarn
            ))
        }

        let ordered = scored.sorted { $0.score > $1.score }
        return ImageSmartFormatReport(
            characteristics: chars,
            recommendations: ordered,
            estimationDisclaimer: "Recommendations evaluate format capabilities and image traits; run Target Size / Live Preview to measure actual encoded byte size."
        )
    }

    private static func inspectPixelAlphaAndContent(cgImage: CGImage) -> (hasNonOpaquePixels: Bool, looksPhotographic: Bool) {
        guard let buf = ImageColorAnalysisService.downsampleToSRGBBytes(cgImage: cgImage, maxDimension: 128) else {
            let alphaFlag = !(cgImage.alphaInfo == .none || cgImage.alphaInfo == .noneSkipFirst || cgImage.alphaInfo == .noneSkipLast)
            return (alphaFlag, true)
        }

        var hasSemiOrTransparent = false
        var colorSet: Set<Int> = []
        let count = buf.width * buf.height

        for i in 0..<count {
            let o = i * 4
            let a = buf.rgba[o + 3]
            if a < 250 { hasSemiOrTransparent = true }
            if colorSet.count < 4000 {
                let rq = Int(buf.rgba[o]) >> 3
                let gq = Int(buf.rgba[o + 1]) >> 3
                let bq = Int(buf.rgba[o + 2]) >> 3
                colorSet.insert((rq << 10) | (gq << 5) | bq)
            }
        }

        // Graphic icons/UI generally use far fewer quantized colors than continuous-tone photographs
        let ratio = Double(colorSet.count) / Double(max(1, min(count, 4096)))
        let isPhoto = colorSet.count > 420 || ratio > 0.14
        return (hasSemiOrTransparent, isPhoto)
    }
}

private extension String {
    func capitalizingFirst() -> String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import os.log

// MARK: - Resampling Method

enum ImageResamplingMethod: String, Codable, CaseIterable, Sendable, Equatable, Hashable, Identifiable {
    case nearest = "Nearest Neighbor"
    case bilinear = "Bilinear"
    case bicubic = "Bicubic"
    case lanczos = "Lanczos"

    var id: String { rawValue }
}

// MARK: - Target Size Optimization Result

struct TargetSizeOptimizationResult: Sendable {
    let data: Data
    let finalQuality: Double
    let targetReached: Bool
    let note: String?
}

// MARK: - Image Processor

struct ImageProcessor: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "ImageProcessor")

    private enum CIContextCacheKey: Hashable {
        case named(String)
        case icc(Data)
        case fallback(Int32, Int)
    }

    private final class CIContextPoolBox: @unchecked Sendable {
        var contexts: [CIContextCacheKey: CIContext] = [:]
        var insertionOrder: [CIContextCacheKey] = []
    }

    private static let ciContextPool = OSAllocatedUnfairLock(initialState: CIContextPoolBox())
    private static let maxCachedCIContexts = 12

    /// Returns a thread-safe, color-space-keyed shared `CIContext` to avoid per-image GPU pipeline allocations.
    static func sharedCIContext(for colorSpace: CGColorSpace) -> CIContext {
        let key: CIContextCacheKey
        if let name = colorSpace.name as String? {
            key = .named(name)
        } else if let iccData = colorSpace.copyICCData() as Data? {
            key = .icc(iccData)
        } else {
            key = .fallback(colorSpace.model.rawValue, colorSpace.numberOfComponents)
        }

        return ciContextPool.withLock { pool in
            if let existing = pool.contexts[key] {
                return existing
            }
            let context = CIContext(options: [
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace,
                .useSoftwareRenderer: false,
                .cacheIntermediates: false
            ])
            pool.contexts[key] = context
            pool.insertionOrder.append(key)
            while pool.insertionOrder.count > maxCachedCIContexts {
                let evicted = pool.insertionOrder.removeFirst()
                pool.contexts.removeValue(forKey: evicted)
            }
            return context
        }
    }
    
    nonisolated static func ciRenderFormat(for cgImage: CGImage) -> CIFormat {
        if cgImage.bitsPerComponent > 8 {
            return cgImage.bitmapInfo.contains(.floatComponents) ? .RGBAh : .RGBA16
        }
        return .RGBA8
    }

    /// Applies an EXIF `CGImagePropertyOrientation` to pixels upright, using bounded `autoreleasepool` and >=16 MP cache clearing.
    static func orientCGImage(_ cgImage: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return cgImage }
        return autoreleasepool {
            let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
            let colorSpace: CGColorSpace = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let format = ciRenderFormat(for: cgImage)
            let ciContext = ImageProcessor.sharedCIContext(for: colorSpace)
            let rendered = ciContext.createCGImage(ciImage, from: ciImage.extent, format: format, colorSpace: colorSpace)
            if cgImage.width * cgImage.height >= 16_000_000 {
                ciContext.clearCaches()
            }
            return rendered ?? cgImage
        }
    }

    // MARK: - Crop & Resize Transformations
    
    /// Applies cropping and resizing transformations to a CGImage based on ConversionOptions
    static func applyTransformations(
        cgImage: CGImage,
        options: ConversionOptions
    ) throws -> CGImage {
        var currentImage = cgImage
        
        // 1. Apply Crop
        if options.cropMode != .none {
            currentImage = try applyCrop(cgImage: currentImage, options: options)
        }
        
        // 2. Apply Resize
        if options.resizeMode != .none {
            currentImage = try applyResize(cgImage: currentImage, options: options)
        }
        
        return currentImage
    }
    
    // MARK: - Crop Implementation
    
    static func applyCrop(
        cgImage: CGImage,
        options: ConversionOptions
    ) throws -> CGImage {
        let origW = CGFloat(cgImage.width)
        let origH = CGFloat(cgImage.height)
        
        guard origW > 0, origH > 0 else {
            throw ConversionError.invalidInput("Image has invalid zero dimensions for cropping.")
        }
        
        var cropRect: CGRect
        
        switch options.cropMode {
        case .none:
            return cgImage
            
        case .centerCrop:
            let targetRatio: CGFloat
            if let ratio = options.cropAspectRatio.ratioValue {
                targetRatio = ratio
            } else {
                targetRatio = origW / origH // original ratio
            }
            
            let currentRatio = origW / origH
            
            if currentRatio > targetRatio {
                // Image is wider than target crop: crop left and right
                let cropW = round(origH * targetRatio)
                let cropH = origH
                let originX = round((origW - cropW) / 2.0)
                let originY: CGFloat = 0.0
                cropRect = CGRect(x: originX, y: originY, width: cropW, height: cropH)
            } else {
                // Image is taller than target crop: crop top and bottom
                let cropW = origW
                let cropH = round(origW / targetRatio)
                let originX: CGFloat = 0.0
                let originY = round((origH - cropH) / 2.0)
                cropRect = CGRect(x: originX, y: originY, width: cropW, height: cropH)
            }
            
        case .customRect:
            if let normRect = options.cropRect {
                let pixel = normRect.pixelRect(for: CGSize(width: origW, height: origH))
                cropRect = CGRect(
                    x: round(pixel.origin.x),
                    y: round(pixel.origin.y),
                    width: round(pixel.size.width),
                    height: round(pixel.size.height)
                )
            } else {
                cropRect = CGRect(x: 0, y: 0, width: origW, height: origH)
            }
        }
        
        let boundedRect = CGRect(
            x: max(0, min(origW - 1, cropRect.origin.x)),
            y: max(0, min(origH - 1, cropRect.origin.y)),
            width: max(1, min(origW - cropRect.origin.x, cropRect.size.width)),
            height: max(1, min(origH - cropRect.origin.y, cropRect.size.height))
        )
        
        guard let cropped = cgImage.cropping(to: boundedRect) else {
            throw ConversionError.engineExecutionFailed(
                "Cropping failed for image coordinates \(boundedRect).",
                underlyingError: nil
            )
        }
        
        return cropped
    }
    
    // MARK: - Resize Implementation
    
    static func applyResize(
        cgImage: CGImage,
        options: ConversionOptions,
        resampling: ImageResamplingMethod? = nil,
        sharpenAmount: Double? = nil
    ) throws -> CGImage {
        let currentW = Double(cgImage.width)
        let currentH = Double(cgImage.height)
        
        guard currentW > 0, currentH > 0 else {
            throw ConversionError.invalidInput("Image has invalid zero dimensions for resizing.")
        }
        
        let currentRatio = currentW / currentH
        var targetW: Double = currentW
        var targetH: Double = currentH
        
        switch options.resizeMode {
        case .none:
            return cgImage
            
        case .exactWidth:
            if let w = options.resizeWidth, w > 0 {
                targetW = Double(w)
                if options.preserveAspectRatio {
                    targetH = max(1.0, round(targetW / currentRatio))
                }
            }
            
        case .exactHeight:
            if let h = options.resizeHeight, h > 0 {
                targetH = Double(h)
                if options.preserveAspectRatio {
                    targetW = max(1.0, round(targetH * currentRatio))
                }
            }
            
        case .exactDimensions:
            let reqW = Double(options.resizeWidth ?? Int(currentW))
            let reqH = Double(options.resizeHeight ?? Int(currentH))
            
            if options.preserveAspectRatio {
                let scaleW = reqW / currentW
                let scaleH = reqH / currentH
                let scale = min(scaleW, scaleH)
                targetW = max(1.0, round(currentW * scale))
                targetH = max(1.0, round(currentH * scale))
            } else {
                targetW = max(1.0, reqW)
                targetH = max(1.0, reqH)
            }
            
        case .percentage:
            let pct = options.resizePercentage ?? 1.0
            guard pct > 0 else { throw ConversionError.invalidInput("Resize percentage must be greater than zero.") }
            targetW = max(1.0, round(currentW * pct))
            targetH = max(1.0, round(currentH * pct))
            
        case .longestEdge:
            let maxEdge = Double(options.resizeWidth ?? options.resizeHeight ?? 1920)
            guard maxEdge > 0 else { throw ConversionError.invalidInput("Longest edge dimension must be greater than zero.") }
            if currentW >= currentH {
                targetW = maxEdge
                targetH = max(1.0, round(targetW / currentRatio))
            } else {
                targetH = maxEdge
                targetW = max(1.0, round(targetH * currentRatio))
            }
            
        case .shortestEdge:
            let minEdge = Double(options.resizeHeight ?? options.resizeWidth ?? 1080)
            guard minEdge > 0 else { throw ConversionError.invalidInput("Shortest edge dimension must be greater than zero.") }
            if currentW <= currentH {
                targetW = minEdge
                targetH = max(1.0, round(targetW / currentRatio))
            } else {
                targetH = minEdge
                targetW = max(1.0, round(targetH * currentRatio))
            }
        }
        
        // Safety bounds clamping (1px to 16,384px)
        let finalW = Int(max(1.0, min(16384.0, targetW)))
        let finalH = Int(max(1.0, min(16384.0, targetH)))
        
        // If unchanged, return early
        if finalW == cgImage.width && finalH == cgImage.height {
            return cgImage
        }

        let resolvedMethod: ImageResamplingMethod = resampling
            ?? options.customOptions["image_resampling"].flatMap { ImageResamplingMethod(rawValue: $0) }
            ?? .lanczos
        let resolvedSharpen = max(0.0, min(2.0, sharpenAmount
            ?? options.customOptions["image_sharpen"].flatMap { Double($0) }
            ?? 0.0))

        return try resampleCGImage(
            cgImage,
            width: finalW,
            height: finalH,
            method: resolvedMethod,
            sharpenAmount: resolvedSharpen
        )
    }

    static let opaqueOutputFormats: Set<FileFormat> = [.jpg, .bmp, .ppm, .pcx, .wbmp, .hdr]

    /// Composites alpha channels onto an opaque white background when encoding to opaque formats.
    static func flattenAlphaOntoWhiteIfNeeded(_ image: CGImage, for format: FileFormat) -> CGImage {
        guard opaqueOutputFormats.contains(format) else { return image }
        let hasAlpha = !(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst)
        guard hasAlpha else { return image }

        let targetSpace: CGColorSpace = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bpc = image.bitsPerComponent > 8 ? 16 : 8
        let byteOrder16Host: UInt32 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue

        let candidateSpaces: [CGColorSpace] = [
            targetSpace,
            CGColorSpace(name: CGColorSpace.itur_2020),
            bpc > 8 ? CGColorSpace(name: CGColorSpace.extendedSRGB) : nil,
            CGColorSpace(name: CGColorSpace.sRGB)
        ].compactMap { $0 }

        for space in candidateSpaces {
            let bpcCandidates = (bpc == 16) ? [16, 8] : [8]
            for candidateBPC in bpcCandidates {
                let spaceBitmapInfo = (candidateBPC == 16)
                    ? (CGImageAlphaInfo.noneSkipLast.rawValue | byteOrder16Host)
                    : CGImageAlphaInfo.noneSkipLast.rawValue
                if let ctx = CGContext(
                    data: nil,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: candidateBPC,
                    bytesPerRow: 0,
                    space: space,
                    bitmapInfo: spaceBitmapInfo
                ) {
                    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                    ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    if let composed = ctx.makeImage() {
                        return composed
                    }
                }
            }
        }
        return image
    }

    /// Prepares an image for encoding (opaque alpha flattening and ICO <= 256×256 square aspect-fit canvas).
    static func prepareImageForEncoding(_ image: CGImage, format: FileFormat) -> CGImage {
        var prepared = flattenAlphaOntoWhiteIfNeeded(image, for: format)
        if format == .ico && (prepared.width > 256 || prepared.height > 256 || prepared.width != prepared.height) {
            let side = min(256, max(16, max(prepared.width, prepared.height)))
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            if let ctx = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                ctx.interpolationQuality = .high
                ctx.setAllowsAntialiasing(true)
                ctx.setShouldAntialias(true)
                ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

                let origW = CGFloat(prepared.width)
                let origH = CGFloat(prepared.height)
                let scale = min(CGFloat(side) / origW, CGFloat(side) / origH)
                let fitW = origW * scale
                let fitH = origH * scale
                let originX = (CGFloat(side) - fitW) / 2.0
                let originY = (CGFloat(side) - fitH) / 2.0
                ctx.draw(prepared, in: CGRect(x: originX, y: originY, width: fitW, height: fitH))
                if let squared = ctx.makeImage() {
                    prepared = squared
                }
            }
        }
        return prepared
    }

    /// Resamples a CGImage using genuine Nearest, Bilinear, Bicubic, or Lanczos filtering with optional post-resize sharpening.
    static func resampleCGImage(
        _ cgImage: CGImage,
        width finalW: Int,
        height finalH: Int,
        method: ImageResamplingMethod,
        sharpenAmount: Double = 0.0
    ) throws -> CGImage {
        let colorSpace: CGColorSpace = (cgImage.colorSpace?.model == .rgb ? cgImage.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let targetBPC = cgImage.bitsPerComponent > 8 ? 16 : 8
        let targetCIFormat = ciRenderFormat(for: cgImage)
        let hasAlpha = !(cgImage.alphaInfo == .none || cgImage.alphaInfo == .noneSkipLast || cgImage.alphaInfo == .noneSkipFirst)

        var outputImage: CGImage?

        switch method {
        case .nearest, .bilinear:
            let alphaBit = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            let byteOrder16Host: UInt32 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
                ? CGBitmapInfo.byteOrder16Little.rawValue
                : CGBitmapInfo.byteOrder16Big.rawValue
            let bitmapInfo: UInt32 = (targetBPC == 16) ? (alphaBit | byteOrder16Host) : alphaBit

            let primaryContext = CGContext(
                data: nil,
                width: finalW,
                height: finalH,
                bitsPerComponent: targetBPC,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
            let rec2020Context: CGContext? = (primaryContext == nil && targetBPC == 16)
                ? CGColorSpace(name: CGColorSpace.itur_2020).flatMap {
                    CGContext(data: nil, width: finalW, height: finalH, bitsPerComponent: 16, bytesPerRow: 0, space: $0, bitmapInfo: bitmapInfo)
                }
                : nil
            let context = primaryContext ?? rec2020Context ?? CGContext(
                data: nil,
                width: finalW,
                height: finalH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? colorSpace,
                bitmapInfo: alphaBit
            )
            guard let context else {
                throw ConversionError.engineExecutionFailed(
                    "Failed to allocate bitmap context for resizing to \(finalW)x\(finalH).",
                    underlyingError: nil
                )
            }
            context.interpolationQuality = (method == .nearest) ? .none : .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))
            outputImage = context.makeImage()

        case .bicubic, .lanczos:
            let ciContext = ImageProcessor.sharedCIContext(for: colorSpace)
            outputImage = autoreleasepool {
                let ciInput = CIImage(cgImage: cgImage)
                let scaleX = CGFloat(finalW) / max(1.0, CGFloat(cgImage.width))
                let scaleY = CGFloat(finalH) / max(1.0, CGFloat(cgImage.height))
                var working: CIImage

                if method == .bicubic, let bicubic = CIFilter(name: "CIBicubicScaleTransform") {
                    bicubic.setValue(ciInput, forKey: kCIInputImageKey)
                    bicubic.setValue(scaleY, forKey: kCIInputScaleKey)
                    bicubic.setValue(scaleX / max(0.0001, scaleY), forKey: kCIInputAspectRatioKey)
                    working = bicubic.outputImage ?? ciInput.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                } else if method == .lanczos, let lanczos = CIFilter(name: "CILanczosScaleTransform") {
                    lanczos.setValue(ciInput, forKey: kCIInputImageKey)
                    lanczos.setValue(scaleY, forKey: kCIInputScaleKey)
                    lanczos.setValue(scaleX / max(0.0001, scaleY), forKey: kCIInputAspectRatioKey)
                    working = lanczos.outputImage ?? ciInput.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                } else {
                    working = ciInput.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                }

                let targetBounds = CGRect(x: 0, y: 0, width: finalW, height: finalH)
                working = working.cropped(to: targetBounds)
                let rendered = ciContext.createCGImage(working, from: targetBounds, format: targetCIFormat, colorSpace: colorSpace)
                    ?? CGColorSpace(name: CGColorSpace.itur_2020).flatMap {
                        ciContext.createCGImage(working, from: targetBounds, format: targetCIFormat, colorSpace: $0)
                    }
                if max(cgImage.width * cgImage.height, finalW * finalH) >= 16_000_000 {
                    ciContext.clearCaches()
                }
                return rendered
            }
        }

        guard var resized = outputImage else {
            throw ConversionError.engineExecutionFailed("Failed to render resized image.", underlyingError: nil)
        }

        if sharpenAmount > 0.01, let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            let targetRenderCS = (resized.colorSpace?.model == .rgb ? resized.colorSpace : nil) ?? colorSpace
            let sharpenedCG: CGImage? = autoreleasepool {
                let ciInput = CIImage(cgImage: resized)
                sharpenFilter.setValue(ciInput, forKey: kCIInputImageKey)
                sharpenFilter.setValue(sharpenAmount, forKey: kCIInputSharpnessKey)
                guard let sharpened = sharpenFilter.outputImage else { return nil }
                let ciContext = ImageProcessor.sharedCIContext(for: targetRenderCS)
                let rendered = ciContext.createCGImage(sharpened, from: CGRect(x: 0, y: 0, width: finalW, height: finalH), format: targetCIFormat, colorSpace: targetRenderCS)
                if finalW * finalH >= 16_000_000 {
                    ciContext.clearCaches()
                }
                return rendered
            }
            if let cg = sharpenedCG {
                resized = cg
            }
        }

        return resized
    }
    
    // MARK: - Centralized Thumbnail Configuration & Creation
    
    public static let standardThumbnailMaxPixelSize: CGFloat = 240.0 // Suitable for 120pt Retina @2x
    
    /// Creates a downsampled thumbnail image directly from a file URL using ImageIO without full-resolution decoding.
    /// Uses bounded pixel dimensions (`kCGImageSourceThumbnailMaxPixelSize`) to avoid loading entire multi-megapixel RAW/DNG images into memory.
    public static func createThumbnail(
        from url: URL,
        maxPixelSize: CGFloat = standardThumbnailMaxPixelSize
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return createThumbnail(from: source, index: 0, maxPixelSize: maxPixelSize)
    }
    
    /// Creates a downsampled thumbnail from an existing CGImageSource without full-resolution decoding.
    public static func createThumbnail(
        from source: CGImageSource,
        index: Int = 0,
        maxPixelSize: CGFloat = standardThumbnailMaxPixelSize
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
    
    /// Encodes a CGImage to in-memory Data with specified format and quality settings
    static func encodeToMemory(
        cgImage: CGImage,
        format: FileFormat,
        quality: Double,
        lossless: Bool,
        sourceProperties: [String: Any]?,
        preserveMetadata: Bool,
        jxlEffort: Int = 7,
        jxlBitDepth: Int = 8,
        jxlDistance: Double? = nil,
        cancelFlag: UnsafePointer<Int32>? = nil
    ) throws -> Data {
        let preparedImage = prepareImageForEncoding(cgImage, format: format)

        if format == .webp {
            let encoder = WebPEncoder()
            let mode: WebPEncodingMode = lossless
                ? .lossless
                : .lossy(quality: Float(max(0.0, min(1.0, quality)) * 100.0))

            var exifData: Data? = nil
            var xmpData: Data? = nil
            if preserveMetadata, let sourceProperties, !sourceProperties.isEmpty {
                var cfProps: [CFString: Any] = [:]
                for (k, v) in sourceProperties {
                    cfProps[k as CFString] = v
                }
                let serialized = JPEGXLCodec.serializeMetadataBoxes(from: cfProps)
                exifData = serialized.exifTIFF
                xmpData = serialized.xmp
            }
            let iccData = preparedImage.colorSpace?.copyICCData() as Data?
            return try encoder.encode(
                image: preparedImage,
                mode: mode,
                iccProfile: iccData,
                exifData: exifData,
                xmpData: xmpData,
                cancelFlag: cancelFlag
            )
        }

        if format == .jxl {
            var exifData: Data? = nil
            var xmpData: Data? = nil
            if preserveMetadata, let sourceProperties, !sourceProperties.isEmpty {
                var cfProps: [CFString: Any] = [:]
                for (k, v) in sourceProperties {
                    cfProps[k as CFString] = v
                }
                let serialized = JPEGXLCodec.serializeMetadataBoxes(from: cfProps)
                exifData = serialized.exifTIFF
                xmpData = serialized.xmp
            }
            let iccData = preparedImage.colorSpace?.copyICCData() as Data?
            let effectiveBitDepth = max(jxlBitDepth, preparedImage.bitsPerComponent > 8 ? 16 : 8)
            let jxlOpts = JXLEncodeOptions(
                lossless: lossless,
                quality: quality,
                distance: lossless ? nil : jxlDistance,
                effort: jxlEffort,
                bitDepth: effectiveBitDepth,
                preserveAlpha: true,
                useContainer: true,
                iccProfileData: iccData,
                exifData: exifData,
                xmpData: xmpData
            )
            return try JPEGXLCodec.encode(image: preparedImage, options: jxlOpts)
        }
        
        // ICNS Multi-representation Standard Sizes Export
        if format == .icns {
            let standardSizes = [16, 32, 128, 256, 512]
            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                mutableData as CFMutableData,
                "com.apple.icns" as CFString,
                standardSizes.count,
                nil
            ) else {
                throw ConversionError.engineExecutionFailed("Could not create ICNS destination.", underlyingError: nil)
            }
            
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            let origW = CGFloat(preparedImage.width)
            let origH = CGFloat(preparedImage.height)
            
            for size in standardSizes {
                guard let context = CGContext(
                    data: nil,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) else { continue }
                
                context.interpolationQuality = .high
                context.setAllowsAntialiasing(true)
                context.setShouldAntialias(true)
                context.clear(CGRect(x: 0, y: 0, width: size, height: size))
                
                let scale = min(CGFloat(size) / origW, CGFloat(size) / origH)
                let fitW = origW * scale
                let fitH = origH * scale
                let originX = (CGFloat(size) - fitW) / 2.0
                let originY = (CGFloat(size) - fitH) / 2.0
                context.draw(preparedImage, in: CGRect(x: originX, y: originY, width: fitW, height: fitH))
                
                if let representation = context.makeImage() {
                    CGImageDestinationAddImage(destination, representation, nil)
                }
            }
            
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError.engineExecutionFailed("Failed to finalize ICNS compression.", underlyingError: nil)
            }
            return mutableData as Data
        }
        
        // ImageIO Path
        let destinationIdentifier = typeIdentifier(for: format)
        let mutableData = NSMutableData()
        
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            destinationIdentifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.engineExecutionFailed(
                "Could not create image destination for \(format.displayName).",
                underlyingError: nil
            )
        }
        
        var destProperties: [String: Any] = [:]
        
        if [FileFormat.jpg, .heic, .avif].contains(format) && !lossless {
            destProperties[kCGImageDestinationLossyCompressionQuality as String] = max(0.01, min(1.0, quality))
        }
        
        if preserveMetadata, let sourceProperties {
            for (key, value) in sourceProperties {
                destProperties[key] = value
            }
            // Normalize orientation tag
            destProperties[kCGImagePropertyOrientation as String] = 1
            if var tiffDict = destProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiffDict[kCGImagePropertyTIFFOrientation as String] = 1
                destProperties[kCGImagePropertyTIFFDictionary as String] = tiffDict
            }
            destProperties[kCGImagePropertyPixelWidth as String] = preparedImage.width
            destProperties[kCGImagePropertyPixelHeight as String] = preparedImage.height
        }
        
        CGImageDestinationAddImage(destination, preparedImage, destProperties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to finalize image compression.",
                underlyingError: nil
            )
        }
        
        return mutableData as Data
    }
    
    // MARK: - Target File Size Optimization Algorithm
    
    /// Overload that extracts parameters from ConversionOptions
    static func optimizeForTargetSize(
        cgImage: CGImage,
        targetFormat: FileFormat,
        targetSizeBytes: Int64,
        options: ConversionOptions,
        sourceProperties: [String: Any]?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> TargetSizeOptimizationResult {
        let jxlLossless = options.customOptions["jxl_lossless"] == "true"
        let jxlEffort = options.customOptions["jxl_effort"].flatMap(Int.init) ?? 7
        let jxlBitDepth = options.customOptions["jxl_bit_depth"].flatMap(Int.init) ?? 8
        let isLossless = (targetFormat == .webp && options.webpLossless)
            || (targetFormat == .jxl && jxlLossless)
            || options.imageOptimizationMode == .lossless
        return try optimizeForTargetSize(
            cgImage: cgImage,
            format: targetFormat,
            targetBytes: targetSizeBytes,
            sourceProperties: sourceProperties,
            preserveMetadata: options.preserveMetadata,
            lossless: isLossless,
            jxlEffort: jxlEffort,
            jxlBitDepth: jxlBitDepth,
            progress: progress
        )
    }
    
    /// Optimizes encoding quality via bounded binary search to produce a file <= targetBytes
    static func optimizeForTargetSize(
        cgImage: CGImage,
        format: FileFormat,
        targetBytes: Int64,
        sourceProperties: [String: Any]?,
        preserveMetadata: Bool,
        lossless: Bool = false,
        jxlEffort: Int = 7,
        jxlBitDepth: Int = 8,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> TargetSizeOptimizationResult {
        guard targetBytes > 0 else {
            let data = try encodeToMemory(
                cgImage: cgImage,
                format: format,
                quality: 0.90,
                lossless: false,
                sourceProperties: sourceProperties,
                preserveMetadata: preserveMetadata,
                jxlEffort: jxlEffort,
                jxlBitDepth: jxlBitDepth
            )
            return TargetSizeOptimizationResult(data: data, finalQuality: 0.90, targetReached: true, note: nil)
        }
        
        // For lossless formats (PNG, lossless WebP, lossless JXL, etc.), lossless encoding produces a fixed size
        if format == .png || format == .tiff || format == .bmp || format == .tga || lossless {
            let data = try encodeToMemory(
                cgImage: cgImage,
                format: format,
                quality: 1.0,
                lossless: true,
                sourceProperties: sourceProperties,
                preserveMetadata: preserveMetadata,
                jxlEffort: jxlEffort,
                jxlBitDepth: jxlBitDepth
            )
            let reached = Int64(data.count) <= targetBytes
            let note = reached ? nil : "Target size cannot be reached with lossless compression."
            return TargetSizeOptimizationResult(data: data, finalQuality: 1.0, targetReached: reached, note: note)
        }
        
        // For lossy formats (JPEG, WebP, HEIC, AVIF, JXL), perform bounded binary search on quality
        var lowQuality = 0.05
        var highQuality = 0.98
        var bestData: Data? = nil
        var bestQuality = lowQuality
        
        // 1. Initial check at high quality (0.95)
        let initialData = try encodeToMemory(
            cgImage: cgImage,
            format: format,
            quality: 0.95,
            lossless: false,
            sourceProperties: sourceProperties,
            preserveMetadata: preserveMetadata,
            jxlEffort: jxlEffort,
            jxlBitDepth: jxlBitDepth
        )
        
        if Int64(initialData.count) <= targetBytes {
            // Already fits under target size at high quality! Try max quality (1.0)
            if let maxData = try? encodeToMemory(
                cgImage: cgImage,
                format: format,
                quality: 1.0,
                lossless: false,
                sourceProperties: sourceProperties,
                preserveMetadata: preserveMetadata,
                jxlEffort: jxlEffort,
                jxlBitDepth: jxlBitDepth
            ), Int64(maxData.count) <= targetBytes {
                return TargetSizeOptimizationResult(data: maxData, finalQuality: 1.0, targetReached: true, note: nil)
            }
            return TargetSizeOptimizationResult(data: initialData, finalQuality: 0.95, targetReached: true, note: nil)
        }
        
        // 2. Bounded iterative binary search (max 6 iterations for high speed and precision)
        let maxIterations = 6
        for iteration in 0..<maxIterations {
            try Task.checkCancellation()
            progress?(Double(iteration) / Double(maxIterations))
            
            let midQuality = (lowQuality + highQuality) / 2.0
            let testData = try encodeToMemory(
                cgImage: cgImage,
                format: format,
                quality: midQuality,
                lossless: false,
                sourceProperties: sourceProperties,
                preserveMetadata: preserveMetadata,
                jxlEffort: jxlEffort,
                jxlBitDepth: jxlBitDepth
            )
            
            let currentSize = Int64(testData.count)
            
            if currentSize <= targetBytes {
                // Meets target: record as candidate, try higher quality
                bestData = testData
                bestQuality = midQuality
                lowQuality = midQuality + 0.02
            } else {
                // Too large: reduce quality upper bound
                highQuality = midQuality - 0.02
            }
            
            if highQuality < lowQuality {
                break
            }
        }
        
        if let result = bestData {
            return TargetSizeOptimizationResult(data: result, finalQuality: bestQuality, targetReached: true, note: nil)
        }
        
        // 3. Fallback: even lowest quality was larger than targetBytes.
        // Return encoding at lowest quality (honest reporting without padding or corruption)
        let fallbackData = try encodeToMemory(
            cgImage: cgImage,
            format: format,
            quality: 0.05,
            lossless: false,
            sourceProperties: sourceProperties,
            preserveMetadata: preserveMetadata,
            jxlEffort: jxlEffort,
            jxlBitDepth: jxlBitDepth
        )
        return TargetSizeOptimizationResult(
            data: fallbackData,
            finalQuality: 0.05,
            targetReached: false,
            note: "Target size could not be reached without exceeding the minimum quality."
        )
    }
    
    // MARK: - Estimation Helper
    
    /// Honest, realistic estimation of output dimensions and file size based on image parameters
    static func computeEstimatedSize(
        originalSizeBytes: Int64,
        originalDimensions: CGSize,
        targetFormat: FileFormat,
        options: ConversionOptions
    ) -> (estimatedBytes: Int64, estimatedDimensions: CGSize) {
        var width = originalDimensions.width
        var height = originalDimensions.height
        
        // Account for crop
        if options.cropMode == .centerCrop, let ratio = options.cropAspectRatio.ratioValue, ratio > 0 {
            let currentRatio = width / max(1.0, height)
            if currentRatio > ratio {
                width = height * ratio
            } else {
                height = width / ratio
            }
        } else if options.cropMode == .customRect, let cropRect = options.cropRect {
            width = width * CGFloat(cropRect.width)
            height = height * CGFloat(cropRect.height)
        }
        
        // Account for resize
        if options.resizeMode != .none {
            let curRatio = width / max(1.0, height)
            switch options.resizeMode {
            case .none:
                break
            case .exactWidth:
                if let w = options.resizeWidth, w > 0 {
                    width = CGFloat(w)
                    if options.preserveAspectRatio { height = width / curRatio }
                }
            case .exactHeight:
                if let h = options.resizeHeight, h > 0 {
                    height = CGFloat(h)
                    if options.preserveAspectRatio { width = height * curRatio }
                }
            case .exactDimensions:
                let w = CGFloat(options.resizeWidth ?? Int(width))
                let h = CGFloat(options.resizeHeight ?? Int(height))
                if options.preserveAspectRatio {
                    let scale = min(w / width, h / height)
                    width = width * scale
                    height = height * scale
                } else {
                    width = w
                    height = h
                }
            case .percentage:
                let pct = CGFloat(options.resizePercentage ?? 1.0)
                width = width * pct
                height = height * pct
            case .longestEdge:
                let maxE = CGFloat(options.resizeWidth ?? 1920)
                if width >= height {
                    width = maxE
                    height = width / curRatio
                } else {
                    height = maxE
                    width = height * curRatio
                }
            case .shortestEdge:
                let minE = CGFloat(options.resizeWidth ?? 1080)
                if width <= height {
                    width = minE
                    height = width / curRatio
                } else {
                    height = minE
                    width = height * curRatio
                }
            }
        }
        
        let outDimensions = CGSize(width: max(1.0, round(width)), height: max(1.0, round(height)))
        
        // Target file size override
        if let targetBytes = options.effectiveTargetFileSizeBytes, targetBytes > 0 {
            return (targetBytes, outDimensions)
        }
        
        // Estimate size from pixel count ratio & quality
        let origPixelCount = max(1.0, originalDimensions.width * originalDimensions.height)
        let outPixelCount = outDimensions.width * outDimensions.height
        let pixelRatio = outPixelCount / origPixelCount
        
        let formatMultiplier: Double
        switch targetFormat {
        case .webp: formatMultiplier = options.webpLossless ? 0.75 : 0.60
        case .jxl: formatMultiplier = (options.customOptions["jxl_lossless"] == "true") ? 0.70 : 0.48
        case .avif: formatMultiplier = 0.50
        case .heic: formatMultiplier = 0.55
        case .jpg: formatMultiplier = 0.85
        case .png: formatMultiplier = 1.10
        default: formatMultiplier = 1.00
        }
        
        let qualityFactor = options.effectiveImageQuality
        let estimated = Double(originalSizeBytes) * pixelRatio * formatMultiplier * (0.4 + 0.6 * qualityFactor)
        
        return (max(1024, Int64(estimated)), outDimensions)
    }
    
    // MARK: - UTType Helper
    
    private static func typeIdentifier(for format: FileFormat) -> String {
        switch format {
        case .jpg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .avif: return "public.avif"
        case .jp2: return "public.jpeg-2000"
        case .psd: return "com.adobe.photoshop-image"
        case .exr: return "com.ilm.openexr-image"
        case .ppm: return "public.pbm"
        case .hdr: return "public.radiance"
        case .jxl: return "public.jpeg-xl"
        case .sgi: return "com.sgi.sgi-image"
        case .ico: return "com.microsoft.ico"
        case .icns: return "com.apple.icns"
        case .tga: return "com.truevision.tga-image"
        default: return format.utType?.identifier ?? "public.png"
        }
    }
}

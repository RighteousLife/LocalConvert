import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import os.log

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
        options: ConversionOptions
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
        
        // High-quality bitmap context rendering
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var bitmapInfo = cgImage.bitmapInfo
        if bitmapInfo.contains(.alphaInfoMask) && (cgImage.alphaInfo == .none || cgImage.alphaInfo == .noneSkipLast || cgImage.alphaInfo == .noneSkipFirst) {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        } else {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        
        guard let context = CGContext(
            data: nil,
            width: finalW,
            height: finalH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to allocate bitmap context for resizing to \(finalW)x\(finalH).",
                underlyingError: nil
            )
        }
        
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))
        
        guard let resized = context.makeImage() else {
            throw ConversionError.engineExecutionFailed(
                "Failed to render resized image.",
                underlyingError: nil
            )
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
        preserveMetadata: Bool
    ) throws -> Data {
        if format == .webp {
            let encoder = WebPEncoder()
            let mode: WebPEncodingMode = lossless
                ? .lossless
                : .lossy(quality: Float(max(0.0, min(1.0, quality)) * 100.0))
            
            return try encoder.encode(image: cgImage, mode: mode)
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
            let origW = CGFloat(cgImage.width)
            let origH = CGFloat(cgImage.height)
            
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
                context.draw(cgImage, in: CGRect(x: originX, y: originY, width: fitW, height: fitH))
                
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
            destProperties[kCGImagePropertyPixelWidth as String] = cgImage.width
            destProperties[kCGImagePropertyPixelHeight as String] = cgImage.height
        }
        
        CGImageDestinationAddImage(destination, cgImage, destProperties as CFDictionary)
        
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
        return try optimizeForTargetSize(
            cgImage: cgImage,
            format: targetFormat,
            targetBytes: targetSizeBytes,
            sourceProperties: sourceProperties,
            preserveMetadata: options.preserveMetadata,
            lossless: options.webpLossless || options.imageOptimizationMode == .lossless,
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
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> TargetSizeOptimizationResult {
        guard targetBytes > 0 else {
            let data = try encodeToMemory(
                cgImage: cgImage,
                format: format,
                quality: 0.90,
                lossless: false,
                sourceProperties: sourceProperties,
                preserveMetadata: preserveMetadata
            )
            return TargetSizeOptimizationResult(data: data, finalQuality: 0.90, targetReached: true, note: nil)
        }
        
        // For lossless formats (PNG, lossless WebP, etc.), lossless encoding produces a fixed size
        if format == .png || lossless {
            let data = try encodeToMemory(
                cgImage: cgImage,
                format: format,
                quality: 1.0,
                lossless: true,
                sourceProperties: sourceProperties,
                preserveMetadata: preserveMetadata
            )
            let reached = Int64(data.count) <= targetBytes
            let note = reached ? nil : "Target size cannot be reached with lossless compression."
            return TargetSizeOptimizationResult(data: data, finalQuality: 1.0, targetReached: reached, note: note)
        }
        
        // For lossy formats (JPEG, WebP, HEIC, AVIF), perform bounded binary search on quality
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
            preserveMetadata: preserveMetadata
        )
        
        if Int64(initialData.count) <= targetBytes {
            // Already fits under target size at high quality! Try max quality (1.0)
            if let maxData = try? encodeToMemory(
                cgImage: cgImage,
                format: format,
                quality: 1.0,
                lossless: false,
                sourceProperties: sourceProperties,
                preserveMetadata: preserveMetadata
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
                preserveMetadata: preserveMetadata
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
            preserveMetadata: preserveMetadata
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
        case .ico: return "com.microsoft.ico"
        case .icns: return "com.apple.icns"
        case .tga: return "com.truevision.tga-image"
        default: return format.utType?.identifier ?? "public.png"
        }
    }
}

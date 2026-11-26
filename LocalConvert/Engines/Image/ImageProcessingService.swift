import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit
import os.log

// MARK: - Image Processing Service (Unified Image Toolbox Pro Pipeline)

enum ImageProcessingService {

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "ImageProcessingService")

    struct InMemoryPipelineOutput: Sendable {
        let previewCGImage: CGImage
        let encodedData: Data
        let telemetry: ImageProcessingTelemetry
        var usedRAWFallback: Bool = false
    }

    static let cameraRAWFormats: Set<FileFormat> = [
        .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw
    ]

    struct DecodedImageResult: Sendable {
        let cgImage: CGImage
        let properties: SendableImageProperties?
        let format: FileFormat?
        let fileSizeBytes: Int64
        let rawNativeWidth: Int?
        let rawNativeHeight: Int?
        let usedCIRAWFilter: Bool
        let usedRAWFallback: Bool
        let rawWarningNote: String?

        var rawPropertiesDict: [String: Any]? { properties?.raw }
    }

    // MARK: - Decode Any Supported Image Input

    static func inspectSourceDimensions(url: URL) -> (width: Int, height: Int)? {
        let isRAWHint = FileDetector.detectFormat(url: url)?.isRawImage == true
        guard let inspected = ImageSourcePipeline.inspectProperties(url: url, isRAWHint: isRAWHint) else {
            return nil
        }
        return ImageSourcePipeline.orientedDimensions(from: inspected.properties)
    }

    static func decodeInputImage(
        url: URL,
        maxPixelDimension: Int? = nil
    ) async throws -> (cgImage: CGImage, properties: [String: Any]?, format: FileFormat?, fileSizeBytes: Int64) {
        let res = try await decodeInputImageWithRAW(url: url, maxPixelDimension: maxPixelDimension, rawConfig: nil, useProxyCache: false)
        return (res.cgImage, res.rawPropertiesDict, res.format, res.fileSizeBytes)
    }

    static func decodeInputImageWithRAW(
        url: URL,
        maxPixelDimension: Int? = nil,
        rawConfig: ImageRAWDevelopConfig? = nil,
        useProxyCache: Bool = true
    ) async throws -> DecodedImageResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }
        let identity = ImagePreviewProxyCache.fileIdentity(for: url)
        let fileSize = identity.fileSize
        let format = FileDetector.detectFormat(url: url)
        let isRAWInput = format.map { cameraRAWFormats.contains($0) } ?? false

        let rawSignature: String? = {
            guard isRAWInput, let rc = rawConfig, rc.enabled, rc.useRAWFilter else { return nil }
            if let data = try? JSONEncoder().encode(rc), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "raw"
        }()

        let proxyKey: ImagePreviewProxyCache.ProxyKey? = maxPixelDimension.map { dim in
            ImagePreviewProxyCache.ProxyKey(
                path: identity.path,
                fileSize: identity.fileSize,
                mtimeInterval: identity.mtime,
                maxPixelDimension: dim,
                rawSignature: rawSignature
            )
        }

        if useProxyCache, let pk = proxyKey, let cached = await ImagePreviewProxyCache.shared.proxy(for: pk) {
            return DecodedImageResult(
                cgImage: cached.cgImage,
                properties: cached.properties,
                format: cached.format,
                fileSizeBytes: cached.fileSizeBytes,
                rawNativeWidth: cached.fullWidth > 0 ? cached.fullWidth : nil,
                rawNativeHeight: cached.fullHeight > 0 ? cached.fullHeight : nil,
                usedCIRAWFilter: isRAWInput && !cached.isRAWFallbackUsed && (rawConfig?.useRAWFilter ?? false),
                usedRAWFallback: cached.isRAWFallbackUsed,
                rawWarningNote: cached.rawStatusNote
            )
        }

        // Camera RAW path via native CIRAWFilter (macOS Camera RAW) with explicit fallback if unsupported
        if isRAWInput {
            let effRaw = rawConfig ?? ImageRAWDevelopConfig()
            if effRaw.enabled && effRaw.useRAWFilter {
                let headerDims = inspectSourceDimensions(url: url)
                let scaleFactor: Double = {
                    guard let maxDim = maxPixelDimension, let dims = headerDims else { return 1.0 }
                    let longest = max(1, max(dims.width, dims.height))
                    return max(0.08, min(1.0, Double(maxDim) / Double(longest)))
                }()
                if let rawRendered = ImageSourcePipeline.renderWithCIRAWFilter(
                    url: url,
                    config: effRaw,
                    scaleFactor: scaleFactor,
                    prefer16Bit: (maxPixelDimension == nil)
                ) {
                    let cg = rawRendered.cgImage
                    let sendProps = rawRendered.properties.map { SendableImageProperties(raw: $0) }
                    if useProxyCache, let pk = proxyKey {
                        let cached = ImagePreviewProxyCache.CachedProxy(
                            cgImage: cg,
                            properties: sendProps,
                            format: format,
                            fileSizeBytes: fileSize,
                            fullWidth: rawRendered.nativeWidth ?? headerDims?.width ?? cg.width,
                            fullHeight: rawRendered.nativeHeight ?? headerDims?.height ?? cg.height,
                            isRAWFallbackUsed: false,
                            rawStatusNote: nil,
                            byteCost: ImagePreviewProxyCache.estimateByteCost(of: cg)
                        )
                        await ImagePreviewProxyCache.shared.storeProxy(cached, for: pk)
                    }
                    return DecodedImageResult(
                        cgImage: cg,
                        properties: sendProps,
                        format: format,
                        fileSizeBytes: fileSize,
                        rawNativeWidth: rawRendered.nativeWidth ?? headerDims?.width,
                        rawNativeHeight: rawRendered.nativeHeight ?? headerDims?.height,
                        usedCIRAWFilter: true,
                        usedRAWFallback: false,
                        rawWarningNote: nil
                    )
                }
            }
        }

        if format == .svg || url.pathExtension.lowercased() == "svg" {
            guard let nsImage = NSImage(contentsOf: url), nsImage.size.width > 0, nsImage.size.height > 0 else {
                throw ConversionError.invalidInput("The SVG file could not be read.")
            }
            var rect = CGRect(origin: .zero, size: nsImage.size)
            if let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return DecodedImageResult(cgImage: cg, properties: nil, format: format, fileSizeBytes: fileSize, rawNativeWidth: nil, rawNativeHeight: nil, usedCIRAWFilter: false, usedRAWFallback: false, rawWarningNote: nil)
            }
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(nsImage.size.width)),
                pixelsHigh: max(1, Int(nsImage.size.height)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                throw ConversionError.engineExecutionFailed("Failed to rasterize SVG.", underlyingError: nil)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            nsImage.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = rep.cgImage else {
                throw ConversionError.engineExecutionFailed("Failed to extract SVG bitmap.", underlyingError: nil)
            }
            return DecodedImageResult(cgImage: cg, properties: nil, format: format, fileSizeBytes: fileSize, rawNativeWidth: nil, rawNativeHeight: nil, usedCIRAWFilter: false, usedRAWFallback: false, rawWarningNote: nil)
        }

        if format == .jxl || url.pathExtension.lowercased() == "jxl" {
            let decoded = try JPEGXLCodec.decode(url: url, prefer16Bit: maxPixelDimension == nil, decodeAllFrames: false)
            guard var primary = decoded.primaryImage else {
                throw ConversionError.invalidInput("Could not decode JPEG XL frame.")
            }
            if let maxDim = maxPixelDimension, max(primary.width, primary.height) > maxDim {
                let scale = Double(maxDim) / Double(max(primary.width, primary.height))
                let pw = max(1, Int((Double(primary.width) * scale).rounded()))
                let ph = max(1, Int((Double(primary.height) * scale).rounded()))
                primary = (try? ImageProcessor.resampleCGImage(primary, width: pw, height: ph, method: .bilinear)) ?? primary
            }
            let boxProps = JPEGXLCodec.parseMetadataBoxes(exifTIFF: decoded.info.exifData, xmp: decoded.info.xmpData)
            var sendProps: SendableImageProperties? = nil
            if !boxProps.isEmpty {
                var dict: [String: Any] = [:]
                for (k, v) in boxProps { dict[k as String] = v }
                sendProps = SendableImageProperties(raw: dict)
            }
            if useProxyCache, let pk = proxyKey {
                await ImagePreviewProxyCache.shared.storeProxy(
                    ImagePreviewProxyCache.CachedProxy(
                        cgImage: primary, properties: sendProps, format: format, fileSizeBytes: fileSize,
                        fullWidth: decoded.info.width, fullHeight: decoded.info.height,
                        isRAWFallbackUsed: false, rawStatusNote: nil,
                        byteCost: ImagePreviewProxyCache.estimateByteCost(of: primary)
                    ),
                    for: pk
                )
            }
            return DecodedImageResult(cgImage: primary, properties: sendProps, format: format, fileSizeBytes: fileSize, rawNativeWidth: decoded.info.width, rawNativeHeight: decoded.info.height, usedCIRAWFilter: false, usedRAWFallback: false, rawWarningNote: nil)
        }

        if let format, [.qoi, .pcx, .wbmp, .xpm].contains(format),
           let ffmpegPath = await BundledFFmpegProvider().findFFmpegPath() {
            let tempPNG = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalConvert-ToolboxDec-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tempPNG) }
            try await runFFmpeg(ffmpegPath: ffmpegPath, args: ["-y", "-i", url.path, "-frames:v", "1", tempPNG.path])
            if let src = CGImageSourceCreateWithURL(tempPNG as CFURL, nil),
               var cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                if let maxDim = maxPixelDimension, max(cg.width, cg.height) > maxDim {
                    let scale = Double(maxDim) / Double(max(cg.width, cg.height))
                    cg = (try? ImageProcessor.resampleCGImage(cg, width: max(1, Int((Double(cg.width) * scale).rounded())), height: max(1, Int((Double(cg.height) * scale).rounded())), method: .bilinear)) ?? cg
                }
                return DecodedImageResult(cgImage: cg, properties: nil, format: format, fileSizeBytes: fileSize, rawNativeWidth: nil, rawNativeHeight: nil, usedCIRAWFilter: false, usedRAWFallback: false, rawWarningNote: nil)
            }
        }

        let initialSrc = CGImageSourceCreateWithURL(url as CFURL, nil)
        let resolvedSrcAndImage: (CGImageSource, [String: Any]?, CGImage?) = {
            if let s = initialSrc, CGImageSourceGetCount(s) > 0,
               let img = CGImageSourceCreateImageAtIndex(s, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
                let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any]
                return (s, p, img)
            }
            // Some TIFF-wrapped DNGs fail the RA02 RAW plugin; retry ImageIO with explicit TIFF hint ONLY if header is TIFF.
            if isRAWInput,
               ImageSourcePipeline.hasTIFFHeader(url: url),
               let tiffSrc = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary),
               CGImageSourceGetCount(tiffSrc) > 0,
               let tiffImg = CGImageSourceCreateImageAtIndex(tiffSrc, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
                let p = CGImageSourceCopyPropertiesAtIndex(tiffSrc, 0, nil) as? [String: Any]
                return (tiffSrc, p, tiffImg)
            }
            if let s = initialSrc, CGImageSourceGetCount(s) > 0 {
                let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any]
                return (s, p, nil)
            }
            return (CGImageSourceCreateIncremental(nil), nil, nil)
        }()

        let src = resolvedSrcAndImage.0
        guard CGImageSourceGetCount(src) > 0 else {
            throw ConversionError.invalidInput("Could not decode image: \(url.lastPathComponent)")
        }

        let props = resolvedSrcAndImage.1
        let sendProps = props.map { SendableImageProperties(raw: $0) }
        let fullDims = ImageSourcePipeline.orientedDimensions(from: props) ?? inspectSourceDimensions(url: url)
        let rawFallbackNote: String? = isRAWInput
            ? "Native CIRAWFilter unavailable for this camera file; decoded via standard ImageIO fallback."
            : nil

        // Bounded proxy decode via ImageIO when previewing huge photos (avoids full-res allocation in UI)
        if let maxDim = maxPixelDimension,
           let fullDims,
           max(fullDims.width, fullDims.height) > maxDim,
           let thumb = ImageSourcePipeline.extractThumbnail(from: src, index: 0, maxPixelSize: CGFloat(maxDim)) {
            if useProxyCache, let pk = proxyKey {
                await ImagePreviewProxyCache.shared.storeProxy(
                    ImagePreviewProxyCache.CachedProxy(
                        cgImage: thumb, properties: sendProps, format: format, fileSizeBytes: fileSize,
                        fullWidth: fullDims.width, fullHeight: fullDims.height,
                        isRAWFallbackUsed: isRAWInput, rawStatusNote: rawFallbackNote,
                        byteCost: ImagePreviewProxyCache.estimateByteCost(of: thumb)
                    ),
                    for: pk
                )
            }
            return DecodedImageResult(cgImage: thumb, properties: sendProps, format: format, fileSizeBytes: fileSize, rawNativeWidth: fullDims.width, rawNativeHeight: fullDims.height, usedCIRAWFilter: false, usedRAWFallback: isRAWInput, rawWarningNote: rawFallbackNote)
        }

        guard var cgImage = resolvedSrcAndImage.2 ?? CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConversionError.invalidInput("Could not decode image: \(url.lastPathComponent)")
        }

        let orientation = ImageSourcePipeline.orientation(from: props)
        if orientation != .up {
            cgImage = ImageProcessor.orientCGImage(cgImage, orientation: orientation)
        }

        if let maxDim = maxPixelDimension, max(cgImage.width, cgImage.height) > maxDim {
            let scale = Double(maxDim) / Double(max(1, max(cgImage.width, cgImage.height)))
            let pw = max(1, Int((Double(cgImage.width) * scale).rounded()))
            let ph = max(1, Int((Double(cgImage.height) * scale).rounded()))
            cgImage = (try? ImageProcessor.resampleCGImage(cgImage, width: pw, height: ph, method: .bilinear)) ?? cgImage
        }

        if useProxyCache, let pk = proxyKey {
            await ImagePreviewProxyCache.shared.storeProxy(
                ImagePreviewProxyCache.CachedProxy(
                    cgImage: cgImage, properties: sendProps, format: format, fileSizeBytes: fileSize,
                    fullWidth: fullDims?.width ?? cgImage.width, fullHeight: fullDims?.height ?? cgImage.height,
                    isRAWFallbackUsed: isRAWInput, rawStatusNote: rawFallbackNote,
                    byteCost: ImagePreviewProxyCache.estimateByteCost(of: cgImage)
                ),
                for: pk
            )
        }
        return DecodedImageResult(cgImage: cgImage, properties: sendProps, format: format, fileSizeBytes: fileSize, rawNativeWidth: fullDims?.width, rawNativeHeight: fullDims?.height, usedCIRAWFilter: false, usedRAWFallback: isRAWInput, rawWarningNote: rawFallbackNote)
    }

    // MARK: - Non-Destructive In-Memory Pipeline (Powers Previews, Compare & File Export)

    static func processInMemory(
        url: URL,
        outputFormat: FileFormat,
        config: ImageToolboxConfig,
        previewMaxDimension: Int? = nil,
        encodeOutput: Bool = true,
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> InMemoryPipelineOutput {
        progress(0.1, "Decoding source image...")
        let decoded = try await decodeInputImageWithRAW(
            url: url,
            maxPixelDimension: previewMaxDimension,
            rawConfig: config.rawDevelop,
            useProxyCache: previewMaxDimension != nil
        )
        var working = decoded.cgImage
        let decodedHeaderDims = (decoded.rawNativeWidth == nil || decoded.rawNativeHeight == nil)
            ? (ImageSourcePipeline.orientedDimensions(from: decoded.rawPropertiesDict) ?? inspectSourceDimensions(url: url))
            : nil
        let origW = decoded.rawNativeWidth ?? decodedHeaderDims?.width ?? working.width
        let origH = decoded.rawNativeHeight ?? decodedHeaderDims?.height ?? working.height
        let expectedOut = ImageDimensionCalculator.expectedOutputDimensions(
            sourceWidth: origW,
            sourceHeight: origH,
            config: config
        )
        var warnings: [String] = []
        if let rawWarn = decoded.rawWarningNote {
            warnings.append(rawWarn)
        }
        let sourceFrameCount = inspectAnimationFrameCount(url: url, format: decoded.format)
        if let animWarn = animationFlatteningWarning(
            frameCount: sourceFrameCount,
            inputFormat: decoded.format,
            outputFormat: outputFormat,
            config: config
        ) {
            warnings.append(animWarn)
        }

        try Task.checkCancellation()

        // Fast-path check: lossless JPEG -> JXL transcode or JXL -> JPEG reconstruct when no pixel edits
        let hasPixelEdits = config.hasPixelEdits

        if previewMaxDimension == nil, !hasPixelEdits, encodeOutput {
            if decoded.format == .jpg, outputFormat == .jxl, config.jxlTranscodeJPEG {
                progress(0.45, "Transcoding JPEG bitstream to JPEG XL...")
                let rawJPEG = try Data(contentsOf: url, options: .mappedIfSafe)
                let transcoded = try JPEGXLCodec.transcodeJPEG(jpegData: rawJPEG, effort: config.jxlEffort, storeJPEGMetadata: true)
                let telemetry = ImageProcessingTelemetry(
                    originalBytes: decoded.fileSizeBytes,
                    processedBytes: Int64(transcoded.count),
                    originalWidth: origW,
                    originalHeight: origH,
                    outputWidth: origW,
                    outputHeight: origH,
                    outputFormat: .jxl,
                    targetReached: true,
                    finalQuality: 1.0,
                    warnings: warnings,
                    note: "Lossless JPEG bitstream transcode (byte-exact JPEG reconstruction embedded)."
                )
                return InMemoryPipelineOutput(previewCGImage: working, encodedData: transcoded, telemetry: telemetry, usedRAWFallback: decoded.usedRAWFallback)
            }

            if decoded.format == .jxl, outputFormat == .jpg, config.jxlReconstructJPEG {
                progress(0.45, "Reconstructing original JPEG bitstream...")
                let rawJXL = try Data(contentsOf: url, options: .mappedIfSafe)
                let reconstructed = try JPEGXLCodec.reconstructJPEG(jxlData: rawJXL)
                let telemetry = ImageProcessingTelemetry(
                    originalBytes: decoded.fileSizeBytes,
                    processedBytes: Int64(reconstructed.count),
                    originalWidth: origW,
                    originalHeight: origH,
                    outputWidth: origW,
                    outputHeight: origH,
                    outputFormat: .jpg,
                    targetReached: true,
                    finalQuality: 1.0,
                    warnings: warnings,
                    note: "Lossless JPEG reconstruction restored original JPEG bytes."
                )
                return InMemoryPipelineOutput(previewCGImage: working, encodedData: reconstructed, telemetry: telemetry, usedRAWFallback: decoded.usedRAWFallback)
            }
        }

        // 1. Orientation (16-bit preserving) + Continuous Straighten + Stage A Rectangular Crop
        if config.cropTransform.isActive {
            progress(0.2, "Applying geometry & crop...")
            let normRot = ((config.cropTransform.rotationDegrees % 360) + 360) % 360
            if normRot != 0 || config.cropTransform.flipHorizontal || config.cropTransform.flipVertical {
                working = try ImageCropService.transformOrientation(
                    cgImage: working,
                    rotationDegrees: normRot,
                    flipHorizontal: config.cropTransform.flipHorizontal,
                    flipVertical: config.cropTransform.flipVertical
                )
            }
            if abs(config.cropTransform.straightenDegrees) > 0.01 {
                working = try ImageCropService.straighten(
                    cgImage: working,
                    degrees: config.cropTransform.straightenDegrees,
                    autoCropInscribed: config.cropTransform.autoCropOnStraighten
                )
            }
            if config.cropTransform.cropMode != .none {
                working = try ImageCropService.performRectangularCrop(cgImage: working, config: config.cropTransform)
            }
        }
        try Task.checkCancellation()

        // 1B. Projective Perspective Correction
        if config.perspective.enabled {
            progress(0.28, "Applying perspective homography...")
            working = try ImagePerspectiveService.apply(cgImage: working, config: config.perspective, outputFormat: outputFormat)
            let capOut = FormatCapabilityRegistry.shared.capability(for: outputFormat)
            if config.perspective.fillMode == .transparent && !capOut.supportsTransparency {
                warnings.append("\(outputFormat.shortExtensionLabel) does not support alpha transparency; perspective corners were flattened.")
            }
        }
        try Task.checkCancellation()

        // 2. Background Removal (Apple Vision with bounded mask cache for smooth color/filter scrubbing)
        if config.backgroundRemoval.enabled {
            progress(0.35, "Segmenting foreground subject...")
            if let maxPrev = previewMaxDimension {
                let id = ImagePreviewProxyCache.fileIdentity(for: url)
                let geomSig = "\(config.cropTransform.rotationDegrees)|\(config.cropTransform.flipHorizontal)|\(config.cropTransform.flipVertical)|\(String(format: "%.2f", config.cropTransform.straightenDegrees))|\(config.cropTransform.cropMode.rawValue)|\(config.cropTransform.normalizedRect?.x ?? -1)|\(config.cropTransform.normalizedRect?.width ?? -1)|\(config.perspective.enabled)"
                let mk = ImagePreviewProxyCache.MaskKey(
                    path: id.path,
                    fileSize: id.fileSize,
                    mtimeInterval: id.mtime,
                    maxPixelDimension: maxPrev,
                    geometrySignature: geomSig
                )
                let rawMask: CGImage
                if let cachedMask = await ImagePreviewProxyCache.shared.mask(for: mk) {
                    rawMask = cachedMask
                } else {
                    rawMask = try ImageBackgroundRemovalService.computeRawMaskCGImage(cgImage: working)
                    await ImagePreviewProxyCache.shared.storeMask(rawMask, for: mk)
                }
                working = try ImageBackgroundRemovalService.compositeWithMask(cgImage: working, rawMaskCGImage: rawMask, config: config.backgroundRemoval)
            } else {
                working = try ImageBackgroundRemovalService.removeBackground(cgImage: working, config: config.backgroundRemoval)
            }
            let capOut = FormatCapabilityRegistry.shared.capability(for: outputFormat)
            if config.backgroundRemoval.fillMode == .transparent && !capOut.supportsTransparency {
                warnings.append("\(outputFormat.shortExtensionLabel) does not support transparency; transparent areas will be flattened on export. Use PNG, WebP, or JXL to preserve alpha.")
            }
        }
        try Task.checkCancellation()

        // 2B. Fused Lazy Core Image DAG: Color Adjustments (Light, WB, Levels, Curves, Color Balance) + Ordered Effect Stack
        let hasColorOrEffects = config.colorAdjustments.hasActiveAdjustments || config.effectStack.contains(where: \.isEnabled)
        if hasColorOrEffects {
            progress(0.42, "Applying non-destructive color & effects...")
            let workCS = (working.colorSpace?.model == .rgb ? working.colorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let renderFmt = ImageProcessor.ciRenderFormat(for: working)
            var ciGraph = CIImage(cgImage: working)
            let originalExtent = ciGraph.extent

            if config.colorAdjustments.hasActiveAdjustments {
                ciGraph = ImageAdjustmentsEngine.applyColorAdjustments(
                    ciGraph,
                    config: config.colorAdjustments,
                    workingColorSpace: workCS
                )
            }
            try Task.checkCancellation()
            if config.effectStack.contains(where: \.isEnabled) {
                ciGraph = ImageAdjustmentsEngine.applyEffectsChain(
                    ciGraph,
                    slots: config.effectStack,
                    workingColorSpace: workCS
                )
            }
            try Task.checkCancellation()

            let renderedCG = autoreleasepool { () -> CGImage? in
                let ctx = ImageProcessor.sharedCIContext(for: workCS)
                let cg = ctx.createCGImage(ciGraph, from: originalExtent, format: renderFmt, colorSpace: workCS)
                if Int(originalExtent.width) * Int(originalExtent.height) >= 16_000_000 {
                    ctx.clearCaches()
                }
                return cg
            }
            guard let renderedCG else {
                throw ConversionError.engineExecutionFailed("Failed to render Core Image adjustments graph.", underlyingError: nil)
            }
            working = renderedCG
        }
        try Task.checkCancellation()

        // 2C. Stage B Geometric Shape Mask (applied after color/effects so outer fill remains clean)
        if config.cropTransform.shape.isGeometricMask {
            let capOut = FormatCapabilityRegistry.shared.capability(for: outputFormat)
            let preserveTransp = (config.cropTransform.shapeBackgroundFill == .transparent) && capOut.supportsTransparency
            working = try ImageCropService.applyShapeMask(
                cgImage: working,
                config: config.cropTransform,
                preserveTransparency: preserveTransp
            )
            if config.cropTransform.shapeBackgroundFill == .transparent && !capOut.supportsTransparency {
                warnings.append("\(outputFormat.shortExtensionLabel) does not support alpha transparency; outer crop shape areas were filled with the selected background color.")
            }
        }
        try Task.checkCancellation()

        // 3. Color Management
        if config.colorTarget != .preserve {
            progress(0.48, "Converting color profile to \(config.colorTarget.rawValue)...")
            working = try ImageColorManagementService.convertColorProfile(cgImage: working, target: config.colorTarget)
        }
        try Task.checkCancellation()

        // 4. Resize & Post-Sharpen (bounded when in preview proxy mode so resize preview matches full aspect/sharpness cleanly)
        if config.resizeStrategy != .none {
            progress(0.58, "Resizing (\(config.resamplingMethod.rawValue))...")
            if let maxPrev = previewMaxDimension {
                let resizeTarget = ImageDimensionCalculator.resizedDimensions(
                    currentWidth: ImageDimensionCalculator.croppedDimensions(sourceWidth: origW, sourceHeight: origH, crop: config.cropTransform).width,
                    currentHeight: ImageDimensionCalculator.croppedDimensions(sourceWidth: origW, sourceHeight: origH, crop: config.cropTransform).height,
                    strategy: config.resizeStrategy,
                    width: config.resizeWidth,
                    height: config.resizeHeight,
                    percentage: config.resizePercentage,
                    preserveAspectRatio: config.preserveAspectRatio
                )
                let boundScale = min(1.0, Double(maxPrev) / Double(max(1, max(resizeTarget.width, resizeTarget.height))))
                let prevW = max(1, Int((Double(resizeTarget.width) * boundScale).rounded()))
                let prevH = max(1, Int((Double(resizeTarget.height) * boundScale).rounded()))
                working = try ImageProcessor.resampleCGImage(
                    working,
                    width: prevW,
                    height: prevH,
                    method: config.resamplingMethod,
                    sharpenAmount: config.postResizeSharpen
                )
            } else {
                working = try ImageResizeService.resize(
                    cgImage: working,
                    strategy: config.resizeStrategy,
                    width: config.resizeWidth,
                    height: config.resizeHeight,
                    percentage: config.resizePercentage,
                    preserveAspectRatio: config.preserveAspectRatio,
                    method: config.resamplingMethod,
                    sharpenAmount: config.postResizeSharpen
                )
            }
        }
        try Task.checkCancellation()

        // 4B. Conventional High-Quality Upscale (2x-4x, Custom Scale, Target Size)
        if config.upscale.enabled {
            progress(0.64, "Upscaling (\(config.upscale.method.rawValue))...")
            if let maxPrev = previewMaxDimension {
                var proxyUpCfg = config.upscale
                let capScale = min(1.0, Double(maxPrev) / Double(max(1, max(expectedOut.width, expectedOut.height))))
                proxyUpCfg.preset = .targetDimensions
                proxyUpCfg.targetWidth = max(1, Int((Double(expectedOut.width) * capScale).rounded()))
                proxyUpCfg.targetHeight = max(1, Int((Double(expectedOut.height) * capScale).rounded()))
                proxyUpCfg.preserveAspectRatio = false
                let upRes = try ImageUpscaleService.upscale(cgImage: working, config: proxyUpCfg)
                working = upRes.cgImage
            } else {
                let upRes = try ImageUpscaleService.upscale(cgImage: working, config: config.upscale)
                working = upRes.cgImage
                if upRes.wasMemoryClamped {
                    warnings.append("Upscale output exceeded safety bounds (16,384 px edge / 100 MP limit) and was clamped to \(working.width)×\(working.height).")
                }
            }
        }
        try Task.checkCancellation()

        // 4C. DPI Resampling (only when resamplePixels == true; otherwise DPI stays metadata-only)
        if config.dpiConfig.enabled && config.dpiConfig.resamplePixels {
            progress(0.68, "Resampling pixels for \(Int(config.dpiConfig.targetDPI.rounded())) DPI...")
            let dpiTarget = ImageDimensionCalculator.dpiAdjustedDimensions(
                currentWidth: working.width,
                currentHeight: working.height,
                dpi: config.dpiConfig
            )
            let boundedTarget: (width: Int, height: Int) = {
                guard let maxPrev = previewMaxDimension else { return dpiTarget }
                let scale = min(1.0, Double(maxPrev) / Double(max(1, max(dpiTarget.width, dpiTarget.height))))
                return (max(1, Int((Double(dpiTarget.width) * scale).rounded())), max(1, Int((Double(dpiTarget.height) * scale).rounded())))
            }()
            working = try ImageProcessor.resampleCGImage(
                working,
                width: boundedTarget.width,
                height: boundedTarget.height,
                method: config.resamplingMethod,
                sharpenAmount: 0.0
            )
        }
        try Task.checkCancellation()

        // 4D. Canvas Extension & Padding (does not scale source pixels)
        if config.canvasExtension.enabled {
            progress(0.70, "Extending canvas...")
            var effCanvas = config.canvasExtension
            if previewMaxDimension != nil, working.width > 0, origW > 0 {
                let ratio = Double(working.width) / Double(origW)
                if effCanvas.mode == .padding {
                    effCanvas.padTop = Int((Double(effCanvas.padTop) * ratio).rounded())
                    effCanvas.padBottom = Int((Double(effCanvas.padBottom) * ratio).rounded())
                    effCanvas.padLeft = Int((Double(effCanvas.padLeft) * ratio).rounded())
                    effCanvas.padRight = Int((Double(effCanvas.padRight) * ratio).rounded())
                } else {
                    effCanvas.targetWidth = effCanvas.targetWidth.map { max(1, Int((Double($0) * ratio).rounded())) }
                    effCanvas.targetHeight = effCanvas.targetHeight.map { max(1, Int((Double($0) * ratio).rounded())) }
                }
            }
            working = try ImageCanvasBorderService.extendCanvas(cgImage: working, config: effCanvas, outputFormat: outputFormat)
            let capOut = FormatCapabilityRegistry.shared.capability(for: outputFormat)
            if config.canvasExtension.fillMode == .transparent && !capOut.supportsTransparency {
                warnings.append("\(outputFormat.shortExtensionLabel) does not support transparency; canvas extension background was flattened.")
            }
        }
        try Task.checkCancellation()

        // 4E. Border & Frame
        if config.borderFrame.enabled {
            progress(0.72, "Applying border & frame...")
            var effBorder = config.borderFrame
            if previewMaxDimension != nil, working.width > 0, origW > 0 {
                let ratio = Double(working.width) / Double(origW)
                effBorder.uniformWidth = max(1, Int((Double(effBorder.uniformWidth) * ratio).rounded()))
                effBorder.topWidth = max(1, Int((Double(effBorder.topWidth) * ratio).rounded()))
                effBorder.rightWidth = max(1, Int((Double(effBorder.rightWidth) * ratio).rounded()))
                effBorder.bottomWidth = max(1, Int((Double(effBorder.bottomWidth) * ratio).rounded()))
                effBorder.leftWidth = max(1, Int((Double(effBorder.leftWidth) * ratio).rounded()))
                effBorder.cornerRadius *= ratio
                effBorder.shadowRadius *= ratio
            }
            working = try ImageCanvasBorderService.applyBorder(cgImage: working, config: effBorder, outputFormat: outputFormat)
        }
        try Task.checkCancellation()

        // 5. Watermark
        if config.watermark.enabled {
            progress(0.72, "Applying watermark...")
            working = try ImageWatermarkService.apply(cgImage: working, config: config.watermark)
        }
        try Task.checkCancellation()

        // 6. Flatten alpha explicitly if preserveAlpha == false and not already flattened
        if !config.preserveAlpha {
            working = flattenAlphaToWhite(working)
        }

        // 7. Apply Metadata, DPI & Privacy Policy
        var effectiveProps = ImageMetadataService.applyPolicyToProperties(
            existing: decoded.rawPropertiesDict,
            payload: config.metadataEdit
        )
        if config.dpiConfig.enabled && config.dpiConfig.targetDPI > 0 {
            var propsDict = effectiveProps ?? [:]
            propsDict[kCGImagePropertyDPIWidth as String] = config.dpiConfig.targetDPI
            propsDict[kCGImagePropertyDPIHeight as String] = config.dpiConfig.targetDPI
            var tiffDict = (propsDict[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
            tiffDict[kCGImagePropertyTIFFXResolution as String] = config.dpiConfig.targetDPI
            tiffDict[kCGImagePropertyTIFFYResolution as String] = config.dpiConfig.targetDPI
            tiffDict[kCGImagePropertyTIFFResolutionUnit as String] = 2
            propsDict[kCGImagePropertyTIFFDictionary as String] = tiffDict
            effectiveProps = propsDict
        }
        let preserveMeta = (config.metadataEdit.policy != .stripAll) || config.dpiConfig.enabled

        if !encodeOutput {
            let reportedWidth = (previewMaxDimension == nil) ? working.width : expectedOut.width
            let reportedHeight = (previewMaxDimension == nil) ? working.height : expectedOut.height
            let visualTelemetry = ImageProcessingTelemetry(
                originalBytes: decoded.fileSizeBytes,
                processedBytes: decoded.fileSizeBytes,
                originalWidth: origW,
                originalHeight: origH,
                outputWidth: reportedWidth,
                outputHeight: reportedHeight,
                outputFormat: outputFormat,
                targetReached: true,
                finalQuality: nil,
                warnings: warnings,
                note: "Interactive GPU visual preview (codec compression skipped during edit)"
            )
            progress(1.0, "Complete")
            return InMemoryPipelineOutput(
                previewCGImage: working,
                encodedData: Data(),
                telemetry: visualTelemetry,
                usedRAWFallback: decoded.usedRAWFallback
            )
        }

        // 8. Encode Output
        progress(0.85, "Encoding \(outputFormat.shortExtensionLabel)...")
        let encodedData: Data
        var finalQuality: Double? = config.quality
        var targetReached = true
        var note: String? = nil

        let isLossless: Bool = {
            if outputFormat == .png || outputFormat == .tiff || outputFormat == .bmp || outputFormat == .tga {
                return true
            }
            if outputFormat == .webp { return config.webpLossless || config.compressionProfile.prefersLossless }
            if outputFormat == .jxl { return config.jxlLossless || config.compressionProfile.prefersLossless }
            return false
        }()

        if config.targetFileSizeEnabled && config.targetFileSizeBytes > 0 {
            let opt = try ImageProcessor.optimizeForTargetSize(
                cgImage: working,
                format: outputFormat,
                targetBytes: config.targetFileSizeBytes,
                sourceProperties: effectiveProps,
                preserveMetadata: preserveMeta,
                lossless: isLossless,
                jxlEffort: config.jxlEffort,
                jxlBitDepth: config.jxlBitDepth
            )
            encodedData = opt.data
            finalQuality = opt.finalQuality
            targetReached = opt.targetReached
            let actualLen = Int64(opt.data.count)
            let diff = actualLen - config.targetFileSizeBytes
            if opt.targetReached {
                let qPct = Int((opt.finalQuality * 100.0).rounded())
                let baseDrop = Int(((config.quality - opt.finalQuality) * 100.0).rounded())
                let dropText = baseDrop > 0 ? " (quality lowered by \(baseDrop)% from \(Int((config.quality * 100).rounded()))%)" : ""
                note = "Achieved under target (\(ByteCountFormatter.string(fromByteCount: actualLen, countStyle: .file))) at Q=\(qPct)%\(dropText)."
            } else {
                let deltaStr = ByteCountFormatter.string(fromByteCount: max(0, diff), countStyle: .file)
                let fallbackMsg = isLossless
                    ? "Target cannot be guaranteed in lossless mode (\(ByteCountFormatter.string(fromByteCount: actualLen, countStyle: .file)), +\(deltaStr) over target). Disable lossless or switch to JPEG/WebP/JXL lossy."
                    : "Closest achievable size at Q=\(Int((opt.finalQuality * 100).rounded()))%: \(ByteCountFormatter.string(fromByteCount: actualLen, countStyle: .file)) (+\(deltaStr) above target)."
                note = fallbackMsg
                warnings.append(fallbackMsg)
            }
        } else if FormatCapabilityRegistry.shared.capability(for: outputFormat).canWrite &&
                    [FileFormat.qoi, .pcx, .wbmp, .hdr].contains(outputFormat) {
            encodedData = try await encodeViaFFmpegToData(cgImage: working, format: outputFormat)
        } else if outputFormat == .pdf {
            encodedData = try encodeCGImageToPDFData(cgImage: working)
        } else {
            encodedData = try ImageProcessor.encodeToMemory(
                cgImage: working,
                format: outputFormat,
                quality: config.quality,
                lossless: isLossless,
                sourceProperties: effectiveProps,
                preserveMetadata: preserveMeta,
                jxlEffort: config.jxlEffort,
                jxlBitDepth: config.jxlBitDepth,
                jxlDistance: config.jxlDistance
            )
            if isLossless { finalQuality = 1.0 }
        }

        // Decode preview image directly from the encoded output bytes so Before/After shows true compression artifacts/alpha!
        let actualOutputCGImage: CGImage = {
            if outputFormat == .jxl, let dec = try? JPEGXLCodec.decode(data: encodedData, prefer16Bit: false, decodeAllFrames: false).primaryImage {
                return dec
            }
            if let src = CGImageSourceCreateWithData(encodedData as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return img
            }
            return working
        }()

        let reportedWidth = (previewMaxDimension == nil) ? working.width : expectedOut.width
        let reportedHeight = (previewMaxDimension == nil) ? working.height : expectedOut.height

        let reportedBytes: Int64 = {
            guard previewMaxDimension != nil, working.width > 0, working.height > 0 else {
                return Int64(encodedData.count)
            }
            let previewArea = Double(working.width * working.height)
            let targetArea = Double(max(1, reportedWidth * reportedHeight))
            let areaRatio = targetArea / max(1.0, previewArea)
            if abs(areaRatio - 1.0) < 0.05 {
                return Int64(encodedData.count)
            }
            return max(Int64(encodedData.count), Int64((Double(encodedData.count) * areaRatio).rounded()))
        }()

        let telemetry = ImageProcessingTelemetry(
            originalBytes: decoded.fileSizeBytes,
            processedBytes: reportedBytes,
            originalWidth: origW,
            originalHeight: origH,
            outputWidth: reportedWidth,
            outputHeight: reportedHeight,
            outputFormat: outputFormat,
            targetReached: targetReached,
            finalQuality: finalQuality,
            warnings: warnings,
            note: note
        )

        progress(1.0, "Complete")
        return InMemoryPipelineOutput(
            previewCGImage: actualOutputCGImage,
            encodedData: encodedData,
            telemetry: telemetry,
            usedRAWFallback: decoded.usedRAWFallback
        )
    }

    // MARK: - Full File Export (Single & Multi-Size Batch)

    static func processToFile(
        inputURL: URL,
        outputFormat: FileFormat,
        outputDirectory: URL,
        config: ImageToolboxConfig,
        overwriteExisting: Bool = false,
        existingFileHandling: ExistingFileHandling? = nil,
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> ConversionResult {
        let start = CFAbsoluteTimeGetCurrent()
        try Task.checkCancellation()

        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }

        let effectiveHandling: ExistingFileHandling = existingFileHandling ?? (overwriteExisting ? .overwrite : .createUnique)
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let ext = outputFormat.fileExtension

        // Handle Multi-Size Batch Export if enabled
        if config.exportMultipleSizes && !config.multiSizePresets.isEmpty {
            var writtenURLs: [URL] = []
            var totalBytes: Int64 = 0

            for (idx, preset) in config.multiSizePresets.enumerated() {
                try Task.checkCancellation()
                var perSize = config
                perSize.exportMultipleSizes = false
                perSize.resizeStrategy = .fitInside
                perSize.resizeWidth = preset.width
                perSize.resizeHeight = preset.height
                perSize.preserveAspectRatio = true

                let baseProgress = Double(idx) / Double(config.multiSizePresets.count)
                let sliceProgress = 1.0 / Double(config.multiSizePresets.count)
                let result = try await processInMemory(url: inputURL, outputFormat: outputFormat, config: perSize) { frac, msg in
                    progress(.determinate(baseProgress + frac * sliceProgress, message: "\(preset.label): \(msg)"))
                }

                let safeSuffix = preset.label.replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "/", with: "-")
                let targetURL = try reserveSafeOutputURL(
                    directory: outputDirectory,
                    baseName: "\(baseName)_\(safeSuffix)",
                    ext: ext,
                    sourceURL: inputURL,
                    policy: effectiveHandling
                )
                defer { ConversionManager.releaseReservedOutputURL(targetURL) }
                try result.encodedData.write(to: targetURL, options: .atomic)
                writtenURLs.append(targetURL)
                totalBytes += Int64(result.encodedData.count)
            }

            guard let primary = writtenURLs.first else {
                throw ConversionError.engineExecutionFailed("No resize presets produced output.", underlyingError: nil)
            }
            let duration = CFAbsoluteTimeGetCurrent() - start
            progress(.determinate(1.0, message: "Complete (\(writtenURLs.count) sizes)"))
            return ConversionResult(
                outputURL: primary,
                additionalOutputURLs: Array(writtenURLs.dropFirst()),
                outputFormat: outputFormat,
                fileSize: totalBytes,
                duration: duration,
                engineName: "ImageEngine"
            )
        }

        let hasPixelEdits = config.hasPixelEdits

        let hasMetadataOrDPIEdits = config.metadataEdit.policy != .preserveAll
            || config.metadataEdit.stripGPS
            || config.metadataEdit.stripCamera
            || config.metadataEdit.stripRights
            || config.metadataEdit.stripEXIF
            || config.metadataEdit.stripIPTC
            || config.metadataEdit.stripXMP
            || config.metadataEdit.stripSoftware
            || (config.dpiConfig.enabled && !config.dpiConfig.resamplePixels)

        if !hasPixelEdits,
           !config.exportMultipleSizes,
           hasMetadataOrDPIEdits,
           FileDetector.detectFormat(url: inputURL) == outputFormat,
           ImageMetadataInspectorService.supportsLosslessMetadataCopy(format: outputFormat) {
            progress(.determinate(0.35, message: "Updating metadata/DPI non-destructively (0 pixel re-encode)..."))
            let candidateName = (effectiveHandling == .createUnique) ? "\(baseName)_processed" : baseName
            let outputURL = try reserveSafeOutputURL(
                directory: outputDirectory,
                baseName: candidateName,
                ext: ext,
                sourceURL: inputURL,
                policy: effectiveHandling
            )
            defer { ConversionManager.releaseReservedOutputURL(outputURL) }
            let res = try await ImageMetadataInspectorService.writeMetadataAndDPINonDestructively(
                from: inputURL,
                to: outputURL,
                payload: config.metadataEdit,
                dpi: config.dpiConfig
            )
            if res.wasLosslessPixelCopy {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                let duration = CFAbsoluteTimeGetCurrent() - start
                progress(.determinate(1.0, message: "Complete (Lossless metadata copy)"))
                return ConversionResult(
                    outputURL: outputURL,
                    additionalOutputURLs: [],
                    outputFormat: outputFormat,
                    fileSize: bytes,
                    duration: duration,
                    engineName: "ImageEngine"
                )
            }
        }

        // Preserve multi-frame animation when converting between animated containers without frame-flattening edits
        let detectedInputFormat = FileDetector.detectFormat(url: inputURL)
        let animFrameCount = inspectAnimationFrameCount(url: inputURL, format: detectedInputFormat)
        if animFrameCount > 1,
           let inFmt = detectedInputFormat,
           canPreserveAnimation(inputFormat: inFmt, outputFormat: outputFormat, config: config) {
            let candidateName = (inFmt == outputFormat && effectiveHandling == .createUnique)
                ? "\(baseName)_processed"
                : baseName
            let outputURL = try reserveSafeOutputURL(
                directory: outputDirectory,
                baseName: candidateName,
                ext: ext,
                sourceURL: inputURL,
                policy: effectiveHandling
            )
            defer { ConversionManager.releaseReservedOutputURL(outputURL) }

            var animOptions = ConversionOptions.default
            animOptions.imageQuality = config.quality
            animOptions.imageOptimizationMode = config.jxlLossless ? .lossless : .balanced
            animOptions.customOptions["jxl_lossless"] = config.jxlLossless ? "true" : "false"
            animOptions.customOptions["jxl_effort"] = String(config.jxlEffort)
            animOptions.customOptions["jxl_bit_depth"] = String(config.jxlBitDepth)

            if try await ImageConversionEngine.convertAnimatedIfApplicable(
                input: inputURL,
                inputFormat: inFmt,
                outputFormat: outputFormat,
                outputURL: outputURL,
                options: animOptions,
                progress: progress
            ) {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                let duration = CFAbsoluteTimeGetCurrent() - start
                progress(.determinate(1.0, message: "Complete (\(animFrameCount) animated frames preserved)"))
                logger.info("Image Toolbox preserved \(animFrameCount) animated frames: \(inputURL.lastPathComponent) -> \(outputURL.lastPathComponent)")
                return ConversionResult(
                    outputURL: outputURL,
                    additionalOutputURLs: [],
                    outputFormat: outputFormat,
                    fileSize: bytes,
                    duration: duration,
                    engineName: "ImageEngine"
                )
            }
        }

        let out = try await processInMemory(url: inputURL, outputFormat: outputFormat, config: config) { frac, msg in
            progress(.determinate(frac, message: msg))
        }

        let candidateName = (FileDetector.detectFormat(url: inputURL) == outputFormat && effectiveHandling == .createUnique)
            ? "\(baseName)_processed"
            : baseName
        let outputURL = try reserveSafeOutputURL(
            directory: outputDirectory,
            baseName: candidateName,
            ext: ext,
            sourceURL: inputURL,
            policy: effectiveHandling
        )
        defer { ConversionManager.releaseReservedOutputURL(outputURL) }

        try out.encodedData.write(to: outputURL, options: .atomic)
        let duration = CFAbsoluteTimeGetCurrent() - start
        logger.info("Image Toolbox processed \(inputURL.lastPathComponent) -> \(outputURL.lastPathComponent) (\(out.encodedData.count) bytes)")

        return ConversionResult(
            outputURL: outputURL,
            additionalOutputURLs: [],
            outputFormat: outputFormat,
            fileSize: Int64(out.encodedData.count),
            duration: duration,
            engineName: "ImageEngine"
        )
    }

    // MARK: - Animation Preservation & Flattening Inspection

    static func inspectAnimationFrameCount(url: URL, format: FileFormat? = nil) -> Int {
        let detected = format ?? FileDetector.detectFormat(url: url)
        if detected == .jxl || url.pathExtension.lowercased() == "jxl" {
            if let info = try? JPEGXLCodec.inspect(url: url) {
                return max(1, info.frameCount)
            }
            return 1
        }
        guard detected == .gif || detected == .apng || detected == .webp || detected == .png else {
            return 1
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return 1
        }
        return max(1, CGImageSourceGetCount(source))
    }

    static func canPreserveAnimation(
        inputFormat: FileFormat?,
        outputFormat: FileFormat,
        config: ImageToolboxConfig
    ) -> Bool {
        guard config.preserveAnimation, let inFmt = inputFormat else { return false }
        let isAnimatedInput = (inFmt == .gif || inFmt == .apng || inFmt == .webp || inFmt == .jxl)
        let isAnimatedOutput = (outputFormat == .gif || outputFormat == .apng || outputFormat == .jxl)
        guard isAnimatedInput && isAnimatedOutput else { return false }
        guard !config.hasPixelEdits,
              !config.exportMultipleSizes,
              !config.targetFileSizeEnabled else {
            return false
        }
        return true
    }

    static func animationFlatteningWarning(
        frameCount: Int,
        inputFormat: FileFormat?,
        outputFormat: FileFormat,
        config: ImageToolboxConfig
    ) -> String? {
        guard frameCount > 1 else { return nil }
        guard !canPreserveAnimation(inputFormat: inputFormat, outputFormat: outputFormat, config: config) else {
            return nil
        }
        let isAnimatedOutput = (outputFormat == .gif || outputFormat == .apng || outputFormat == .jxl)
        if !isAnimatedOutput {
            return "Animated input (\(frameCount) frames) will be flattened to frame 1 because \(outputFormat.displayName) does not preserve multi-frame animation in Image Toolbox (use GIF, APNG, or JPEG XL without pixel edits to keep all frames)."
        }
        return "Animated input (\(frameCount) frames) will be flattened to frame 1 because active pixel/geometry edits, multi-size export, or target file-size optimization apply to a single still frame."
    }

    // MARK: - Private Helpers

    private static func reserveSafeOutputURL(
        directory: URL,
        baseName: String,
        ext: String,
        sourceURL: URL,
        policy: ExistingFileHandling
    ) throws -> URL {
        let candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        if candidate.standardizedFileURL == sourceURL.standardizedFileURL && policy != .overwrite {
            let fallbackBase = baseName.hasSuffix("_processed") ? baseName : "\(baseName)_processed"
            return try ConversionManager.reserveUniqueOutputURL(
                directory: directory,
                baseName: fallbackBase,
                extension: ext,
                sourceURL: sourceURL,
                policy: .createUnique
            )
        }
        return try ConversionManager.reserveUniqueOutputURL(
            directory: directory,
            baseName: baseName,
            extension: ext,
            sourceURL: sourceURL,
            policy: policy
        )
    }

    private static func flattenAlphaToWhite(_ image: CGImage) -> CGImage {
        ImageProcessor.flattenAlphaOntoWhiteIfNeeded(image, for: .jpg)
    }

    private static func encodeCGImageToPDFData(cgImage: CGImage) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Failed to create PDF data context.", underlyingError: nil)
        }
        ctx.beginPDFPage(nil)
        ctx.draw(cgImage, in: mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func encodeViaFFmpegToData(cgImage: CGImage, format: FileFormat) async throws -> Data {
        guard let ffmpegPath = await BundledFFmpegProvider().findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("FFmpeg is required for \(format.displayName).")
        }
        let prepared = ImageProcessor.prepareImageForEncoding(cgImage, format: format)
        let use16BitTIFF = (format == .hdr) || prepared.bitsPerComponent > 8

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-FFImg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempExt = use16BitTIFF ? "tiff" : "png"
        let intermediate = tempDir.appendingPathComponent("in.\(tempExt)")
        let outURL = tempDir.appendingPathComponent("out.\(format.rawValue)")

        if use16BitTIFF {
            guard let d = CGImageDestinationCreateWithURL(intermediate as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
                throw ConversionError.engineExecutionFailed("Failed to stage temporary 16-bit TIFF.", underlyingError: nil)
            }
            let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]]
            CGImageDestinationAddImage(d, prepared, props as CFDictionary)
            guard CGImageDestinationFinalize(d) else {
                throw ConversionError.engineExecutionFailed("Failed to write temporary 16-bit TIFF.", underlyingError: nil)
            }
        } else {
            guard let d = CGImageDestinationCreateWithURL(intermediate as CFURL, "public.png" as CFString, 1, nil) else {
                throw ConversionError.engineExecutionFailed("Failed to stage temporary PNG.", underlyingError: nil)
            }
            CGImageDestinationAddImage(d, prepared, nil)
            guard CGImageDestinationFinalize(d) else {
                throw ConversionError.engineExecutionFailed("Failed to write temporary PNG.", underlyingError: nil)
            }
        }
        var args = ["-y", "-i", intermediate.path]
        if format == .hdr { args += ["-pix_fmt", "rgb96le"] }
        else if format == .wbmp { args += ["-pix_fmt", "monob"] }
        args.append(outURL.path)
        try await runFFmpeg(ffmpegPath: ffmpegPath, args: args)
        return try Data(contentsOf: outURL)
    }

    private static func runFFmpeg(ffmpegPath: String, args: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args

        let output = try await AsyncProcessRunner.run(process)
        guard output.terminationStatus == 0 else {
            let msg = String(data: output.stderr, encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed("FFmpeg image error: \(msg.suffix(240))", underlyingError: nil)
        }
    }
}

import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
import AppKit
import os.log

final class ImageConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "ImageEngine"
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ImageEngine")
    
    private static let ffmpegRasterInputs: Set<FileFormat> = [.qoi, .pcx, .wbmp, .xpm]
    private static let ffmpegRasterOutputs: Set<FileFormat> = [.apng, .qoi, .pcx, .wbmp, .hdr]
    
    var supportedInputFormats: Set<FileFormat> {
        [
            .jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .apng, .avif,
            .jp2, .psd, .exr, .ppm, .hdr, .jxl, .qoi, .pcx, .wbmp, .sgi, .xpm,
            .svg, .ico, .icns, .tga,
            .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw
        ]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [
            .jpg, .png, .heic, .webp, .jxl, .tiff, .bmp, .gif, .apng, .avif,
            .jp2, .psd, .exr, .ppm, .hdr, .qoi, .pcx, .wbmp,
            .pdf, .ico, .icns, .tga
        ]
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        guard supportedInputFormats.contains(input) else { return false }
        return supportedOutputFormats.contains(output) && input != output
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        var formats = supportedOutputFormats
        formats.remove(input)
        return formats
    }
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        guard canConvert(from: input, to: output) else { return [] }
        var descriptors: [ConversionOptionDescriptor] = []
        
        // Smart Presets
        let validPresets: [ConversionPreset] = [.custom, .web, .maximumQuality, .smallFile, .appleDevice]
        descriptors.append(
            ConversionOptionDescriptor(
                id: "preset",
                title: "Smart Preset",
                description: "Auto-configure settings for common use cases",
                kind: .preset(validPresets)
            )
        )
        
        // Quality preset applies to lossy image targets
        if [FileFormat.jpg, .heic, .avif].contains(output) {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "imageQuality",
                    title: "Image Quality",
                    description: "Select compression quality preset",
                    kind: .qualityPreset([.low, .medium, .high, .maximum])
                )
            )
        }
        
        // WebP and JPEG XL offer lossy quality and a lossless toggle
        if output == .webp {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "imageQuality",
                    title: "WebP Lossy Quality",
                    description: "Compression quality when encoding lossy WebP",
                    kind: .qualityPreset([.low, .medium, .high, .maximum])
                )
            )
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "webpLossless",
                    title: "Lossless WebP",
                    description: "Encode as lossless WebP (larger file, no quality loss)",
                    kind: .toggle(title: "Lossless", defaultValue: false)
                )
            )
        } else if output == .jxl {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "imageQuality",
                    title: "JPEG XL Quality",
                    description: "Visual quality for lossy JPEG XL encoding (mapped to Butteraugli distance)",
                    kind: .qualityPreset([.low, .medium, .high, .maximum])
                )
            )
        }
        
        if output != .pdf {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "preserveMetadata",
                    title: "Preserve Metadata",
                    description: "Keep EXIF and camera metadata",
                    kind: .toggle(title: "Preserve Metadata", defaultValue: true)
                )
            )
        }
        
        return descriptors
    }
    
    func isAvailable() async -> Bool {
        true // Native macOS APIs are always available
    }
    
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let input = inputs.first else { throw ConversionError.invalidInput("No inputs") }
        let startTime = CFAbsoluteTimeGetCurrent()
        
        try Task.checkCancellation()
        
        // Validate input file exists
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        
        // Validate output directory is writable
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }
        
        progress(.determinate(0.1, message: "Reading image..."))
        
        // Delegate full Image Toolbox Pro pipelines (crop/rotate/flip/Vision bg removal/color mgmt/resize/watermark/multi-size)
        if options.customOptions["image_toolbox"] == "true",
           let toolboxConfig = ImageToolboxConfig.from(options: options) {
            return try await ImageProcessingService.processToFile(
                inputURL: input,
                outputFormat: outputFormat,
                outputDirectory: outputDirectory,
                config: toolboxConfig,
                overwriteExisting: options.overwriteExisting,
                existingFileHandling: options.resolvedExistingFileHandling,
                progress: progress
            )
        }

        let detectedInputFormat = FileDetector.detectFormat(url: input)
        let outputURL: URL = try {
            let suffix = options.customOptions["output_suffix"] ?? ""
            let prefix = options.customOptions["output_prefix"] ?? ""
            let sameFormat = detectedInputFormat == outputFormat
            if sameFormat && options.resolvedExistingFileHandling == .createUnique && suffix.isEmpty && prefix.isEmpty {
                return try ConversionManager.reserveUniqueOutputURL(
                    directory: outputDirectory,
                    baseName: input.deletingPathExtension().lastPathComponent + "_edited",
                    extension: outputFormat.fileExtension,
                    sourceURL: input,
                    policy: .createUnique
                )
            }
            return try ConversionManager.reserveOutputURL(for: input, format: outputFormat, in: outputDirectory, options: options)
        }()
        defer { ConversionManager.releaseReservedOutputURL(outputURL) }

        let existingPolicy = options.resolvedExistingFileHandling
        let hasGeometryTransforms = options.resizeMode != .none || options.cropMode != .none || options.effectiveTargetFileSizeBytes != nil

        // Lossless JPEG <-> JPEG XL bitstream transcode / reconstruction (zero generational pixel loss)
        if !hasGeometryTransforms,
           detectedInputFormat == .jpg,
           outputFormat == .jxl,
           (options.customOptions["jxl_transcode_jpeg"] == "true" ||
            (options.customOptions["jxl_lossless"] == "true" && options.preserveMetadata && options.customOptions["jxl_transcode_jpeg"] != "false")) {
            let strictTranscode = options.customOptions["jxl_transcode_jpeg"] == "true"
            let effort = options.customOptions["jxl_effort"].flatMap(Int.init) ?? 7
            let jpegData = try Data(contentsOf: input, options: .mappedIfSafe)
            do {
                progress(.determinate(0.4, message: "Losslessly transcoding JPEG to JPEG XL..."))
                let jxlData = try JPEGXLCodec.transcodeJPEG(jpegData: jpegData, effort: effort, storeJPEGMetadata: true)
                let tempOut = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LocalConvert-JXLTranscode-\(UUID().uuidString).jxl")
                defer { try? FileManager.default.removeItem(at: tempOut) }
                try jxlData.write(to: tempOut, options: .atomic)
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: existingPolicy)
                let fileSize = Int64(jxlData.count)
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                progress(.determinate(1.0, message: "Complete"))
                return ConversionResult(
                    outputURL: outputURL,
                    additionalOutputURLs: [],
                    outputFormat: .jxl,
                    fileSize: fileSize,
                    duration: duration,
                    engineName: name
                )
            } catch {
                if strictTranscode {
                    throw error
                }
                logger.notice("Direct lossless JPEG->JXL transcode unavailable (\(error.localizedDescription, privacy: .public)); encoding lossless pixels.")
            }
        }

        if !hasGeometryTransforms,
           detectedInputFormat == .jxl,
           outputFormat == .jpg,
           options.customOptions["jxl_reconstruct_jpeg"] == "true" {
            progress(.determinate(0.4, message: "Reconstructing original JPEG bitstream..."))
            let jxlData = try Data(contentsOf: input, options: .mappedIfSafe)
            let reconstructed = try JPEGXLCodec.reconstructJPEG(jxlData: jxlData)
            let finalData = try Self.finalizeReconstructedJPEGData(
                reconstructed,
                preserveMetadata: options.preserveMetadata,
                quality: options.effectiveImageQuality
            )
            let tempOut = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalConvert-JXLReconstruct-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: tempOut) }
            try finalData.write(to: tempOut, options: .atomic)
            try Task.checkCancellation()
            _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: existingPolicy)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            progress(.determinate(1.0, message: "Complete"))
            return ConversionResult(
                outputURL: outputURL,
                additionalOutputURLs: [],
                outputFormat: .jpg,
                fileSize: fileSize,
                duration: duration,
                engineName: name
            )
        }

        // Animated GIF / APNG / WEBP / JXL <-> Animated JXL / GIF / APNG (when no resize/crop/target-size)
        if !hasGeometryTransforms, let inFmt = detectedInputFormat {
            let isAnimatedContainerPair =
                ((inFmt == .gif || inFmt == .apng || inFmt == .webp) && outputFormat == .jxl) ||
                (inFmt == .webp && (outputFormat == .gif || outputFormat == .apng)) ||
                (inFmt == .jxl && (outputFormat == .gif || outputFormat == .apng || outputFormat == .jxl))

            if isAnimatedContainerPair {
                let tempAnimOut = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LocalConvert-AnimStage-\(UUID().uuidString).\(outputFormat.fileExtension)")
                defer { try? FileManager.default.removeItem(at: tempAnimOut) }
                if try await Self.convertAnimatedIfApplicable(
                    input: input,
                    inputFormat: inFmt,
                    outputFormat: outputFormat,
                    outputURL: tempAnimOut,
                    options: options,
                    progress: progress
                ) {
                    try Task.checkCancellation()
                    _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempAnimOut, to: outputURL, policy: existingPolicy)
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    progress(.determinate(1.0, message: "Complete"))
                    return ConversionResult(
                        outputURL: outputURL,
                        additionalOutputURLs: [],
                        outputFormat: outputFormat,
                        fileSize: fileSize,
                        duration: duration,
                        engineName: name
                    )
                }
            }
        }

        // Multi-page TIFF -> Multi-page TIFF / PDF preservation
        if (detectedInputFormat == .tiff || input.pathExtension.lowercased() == "tif" || input.pathExtension.lowercased() == "tiff"),
           (outputFormat == .tiff || outputFormat == .pdf),
           options.effectiveTargetFileSizeBytes == nil {
            let tempMultiOut = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalConvert-TIFFMulti-\(UUID().uuidString).\(outputFormat.fileExtension)")
            defer { try? FileManager.default.removeItem(at: tempMultiOut) }
            if try convertMultiPageTIFFIfApplicable(
                input: input,
                outputFormat: outputFormat,
                outputURL: tempMultiOut,
                options: options,
                progress: progress
            ) {
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempMultiOut, to: outputURL, policy: existingPolicy)
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                progress(.determinate(1.0, message: "Complete"))
                return ConversionResult(
                    outputURL: outputURL,
                    additionalOutputURLs: [],
                    outputFormat: outputFormat,
                    fileSize: fileSize,
                    duration: duration,
                    engineName: name
                )
            }
        }
        
        // Direct animated route via bundled FFmpeg when converting animated GIF <-> APNG without geometry edits
        if let inFmt = detectedInputFormat,
           (inFmt == .gif || inFmt == .apng),
           (outputFormat == .apng || outputFormat == .gif),
           options.resizeMode == .none,
           options.cropMode == .none,
           options.effectiveTargetFileSizeBytes == nil,
           let ffmpegPath = await BundledFFmpegProvider().findFFmpegPath() {
            progress(.determinate(0.4, message: "Converting animated image..."))
            let tempFFAnimOut = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalConvert-ImgAnim-\(UUID().uuidString).\(outputFormat.fileExtension)")
            defer { try? FileManager.default.removeItem(at: tempFFAnimOut) }
            var args = ["-y", "-i", input.path]
            if outputFormat == .apng {
                args += ["-plays", "0", "-f", "apng"]
            } else {
                args += ["-filter_complex", "[0:v] split [a][b];[a] palettegen [p];[b][p] paletteuse"]
            }
            args.append(tempFFAnimOut.path)
            try await runFFmpegImageCommand(ffmpegPath: ffmpegPath, arguments: args)
            try Task.checkCancellation()
            _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempFFAnimOut, to: outputURL, policy: existingPolicy)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            progress(.determinate(1.0, message: "Complete"))
            return ConversionResult(
                outputURL: outputURL,
                additionalOutputURLs: [],
                outputFormat: outputFormat,
                fileSize: fileSize,
                duration: duration,
                engineName: name
            )
        }
        
        var cgImage: CGImage
        var sourceProperties: [String: Any]? = nil
        
        // SVG Vector Handling
        if detectedInputFormat == .svg || input.pathExtension.lowercased() == "svg" {
            guard let nsImage = NSImage(contentsOf: input), nsImage.size.width > 0, nsImage.size.height > 0 else {
                throw ConversionError.invalidInput("The SVG file could not be read or is invalid.")
            }
            var rect = CGRect(origin: .zero, size: nsImage.size)
            if let extracted = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                cgImage = extracted
            } else {
                // Fallback to drawing into a bitmap context if cgImage fails
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(nsImage.size.width), pixelsHigh: Int(nsImage.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                guard let rep = rep else {
                    throw ConversionError.engineExecutionFailed("Could not create bitmap for SVG rendering.", underlyingError: nil)
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                nsImage.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                
                guard let rendered = rep.cgImage else {
                    throw ConversionError.engineExecutionFailed("Failed to render SVG to bitmap.", underlyingError: nil)
                }
                cgImage = rendered
            }
        } else if let inFmt = detectedInputFormat, Self.ffmpegRasterInputs.contains(inFmt) {
            // Decode specialized raster formats (QOI, PCX, WBMP, XPM) via bundled FFmpeg to lossless PNG
            guard let ffmpegPath = await BundledFFmpegProvider().findFFmpegPath() else {
                throw ConversionError.engineNotAvailable("FFmpeg is required to decode \(inFmt.displayName).")
            }
            let tempPNG = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalConvert-ImgDec-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tempPNG) }
            try await runFFmpegImageCommand(ffmpegPath: ffmpegPath, arguments: ["-y", "-i", input.path, "-frames:v", "1", tempPNG.path])
            guard let imageSource = CGImageSourceCreateWithURL(tempPNG as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(
                    imageSource,
                    0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  ) else {
                throw ConversionError.invalidInput("The \(inFmt.displayName) image could not be decoded.")
            }
            cgImage = decoded
        } else if detectedInputFormat == .jxl || input.pathExtension.lowercased() == "jxl" {
            // Decode JPEG XL natively via bundled libjxl v0.13.0 (preserves bit depth, ICC, straight->premultiplied alpha, EXIF/XMP boxes)
            let decoded = try JPEGXLCodec.decode(url: input, prefer16Bit: true, decodeAllFrames: false)
            guard let primary = decoded.primaryImage else {
                throw ConversionError.invalidInput("The JPEG XL image did not contain a valid frame.")
            }
            cgImage = primary
            let boxProps = JPEGXLCodec.parseMetadataBoxes(exifTIFF: decoded.info.exifData, xmp: decoded.info.xmpData)
            if !boxProps.isEmpty {
                var strDict: [String: Any] = [:]
                for (k, v) in boxProps {
                    strDict[k as String] = v
                }
                sourceProperties = strDict
            } else if let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil) {
                sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
            }
        } else {
            // Standard ImageIO & Apple-native Camera RAW Handling
            try Task.checkCancellation()
            let (decodedImage, props) = try ImageSourcePipeline.decodeStandardOrRAW(url: input, detectedFormat: detectedInputFormat)
            cgImage = decodedImage
            sourceProperties = props
        }
        
        try Task.checkCancellation()
        
        progress(.determinate(0.4, message: "Converting..."))
        
        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-ImgOut-\(UUID().uuidString).\(outputFormat.fileExtension)")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        // Apply Image Transformations (Crop, Resize)
        let transformedImage = try ImageProcessor.applyTransformations(cgImage: cgImage, options: options)

        if outputFormat == .pdf {
            try convertImageToPDF(cgImage: transformedImage, outputURL: tempOut)
        } else if Self.ffmpegRasterOutputs.contains(outputFormat) {
            try await convertImageViaFFmpeg(cgImage: transformedImage, to: outputFormat, outputURL: tempOut)
        } else if let targetSizeBytes = options.effectiveTargetFileSizeBytes {
            // Target File Size Bounded Optimization
            let optResult = try ImageProcessor.optimizeForTargetSize(
                cgImage: transformedImage,
                targetFormat: outputFormat,
                targetSizeBytes: targetSizeBytes,
                options: options,
                sourceProperties: sourceProperties
            )
            try optResult.data.write(to: tempOut, options: .atomic)
            if !optResult.targetReached, let note = optResult.note {
                logger.notice("\(note, privacy: .public)")
            }
        } else if outputFormat == .webp {
            // libwebp path — ImageIO cannot encode WebP natively
            try await convertImageToWebP(
                cgImage: transformedImage,
                sourceProperties: sourceProperties,
                outputURL: tempOut,
                options: options
            )
        } else if outputFormat == .jxl {
            // Bundled libjxl v0.13.0 path
            try convertImageToJXL(
                cgImage: transformedImage,
                sourceProperties: sourceProperties,
                outputURL: tempOut,
                options: options
            )
        } else if outputFormat == .icns {
            // Standard Apple Icon representations (16, 32, 64, 128, 256, 512, 1024)
            try convertImageToICNS(
                cgImage: transformedImage,
                outputURL: tempOut
            )
        } else {
            try convertImage(
                cgImage: transformedImage,
                sourceProperties: sourceProperties,
                to: outputFormat,
                outputURL: tempOut,
                options: options
            )
        }

        try Task.checkCancellation()
        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempOut,
            to: outputURL,
            policy: existingPolicy
        )
        
        progress(.determinate(1.0, message: "Complete"))
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        logger.info("Image conversion succeeded: \(input.lastPathComponent) -> \(outputURL.lastPathComponent) (\(fileSize) bytes, \(duration)s)")
        
        return ConversionResult(
            outputURL: outputURL,
            outputFormat: outputFormat,
            fileSize: fileSize,
            duration: duration,
            engineName: name
        )
    }
    
    // MARK: - Image to Image Conversion (ImageIO)

    private func convertImage(
        cgImage: CGImage,
        sourceProperties: [String: Any]?,
        to format: FileFormat,
        outputURL: URL,
        options: ConversionOptions
    ) throws {
        let preparedImage = ImageProcessor.prepareImageForEncoding(cgImage, format: format)
        let destinationIdentifier = typeIdentifier(for: format)
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            destinationIdentifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.engineExecutionFailed(
                "Could not create output image for \(format.displayName).",
                underlyingError: nil
            )
        }
        
        var destProperties: [String: Any] = [:]
        
        // Set lossy compression quality (default 0.90)
        if [FileFormat.jpg, .heic, .avif].contains(format) {
            destProperties[kCGImageDestinationLossyCompressionQuality as String] = options.effectiveImageQuality
        }
        
        // Preserve metadata if requested, correcting orientation tag since pixels were rendered upright
        if options.preserveMetadata, let sourceProperties {
            let normalized = ImageSourcePipeline.normalizedPropertiesAfterOrientation(
                from: sourceProperties,
                pixelWidth: preparedImage.width,
                pixelHeight: preparedImage.height
            )
            for (key, value) in normalized {
                destProperties[key] = value
            }
        }
        
        CGImageDestinationAddImage(destination, preparedImage, destProperties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to write converted image data to \(outputURL.lastPathComponent).",
                underlyingError: nil
            )
        }
    }
    
    // MARK: - Image to JPEG XL Conversion (libjxl v0.13.0)

    private func convertImageToJXL(
        cgImage: CGImage,
        sourceProperties: [String: Any]?,
        outputURL: URL,
        options: ConversionOptions
    ) throws {
        let isLossless = (options.customOptions["jxl_lossless"] == "true") || options.imageOptimizationMode == .lossless
        let effort = options.customOptions["jxl_effort"].flatMap(Int.init) ?? 7
        let bitDepth = options.customOptions["jxl_bit_depth"].flatMap(Int.init) ?? 8
        let distance = options.customOptions["jxl_distance"].flatMap(Double.init)

        let jxlData = try ImageProcessor.encodeToMemory(
            cgImage: cgImage,
            format: .jxl,
            quality: options.effectiveImageQuality,
            lossless: isLossless,
            sourceProperties: sourceProperties,
            preserveMetadata: options.preserveMetadata,
            jxlEffort: effort,
            jxlBitDepth: bitDepth,
            jxlDistance: distance
        )
        try jxlData.write(to: outputURL, options: .atomic)
        logger.debug("JXL encode: \(cgImage.width)x\(cgImage.height) -> \(jxlData.count) bytes [\(isLossless ? "lossless" : "q=\(options.effectiveImageQuality)")]")
    }

    // MARK: - JXL JPEG Reconstruction Metadata Enforcement (LC-009)

    static func finalizeReconstructedJPEGData(
        _ reconstructed: Data,
        preserveMetadata: Bool,
        quality: Double
    ) throws -> Data {
        if preserveMetadata {
            return reconstructed
        }
        guard let src = CGImageSourceCreateWithData(reconstructed as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConversionError.engineExecutionFailed(
                "Could not re-decode reconstructed JPEG to strip metadata.",
                underlyingError: "CGImageSource failed to decode reconstructed JPEG payload while preserveMetadata is disabled."
            )
        }
        return try ImageProcessor.encodeToMemory(
            cgImage: img,
            format: .jpg,
            quality: quality,
            lossless: false,
            sourceProperties: nil,
            preserveMetadata: false
        )
    }

    // MARK: - Animated GIF / APNG / WEBP / JXL Route Helper

    /// Maximum total uncompressed RGBA pixel buffer budget across all frames in an animated conversion (512 MiB).
    static let maxAnimatedUncompressedBytes: Int64 = 512 * 1024 * 1024
    /// Maximum pixel count for any single frame in an animated conversion (100 MP).
    static let maxAnimatedFramePixels: Int64 = 100_000_000

    /// Overflow-safe budget check for animated image conversions (`width * height * bytesPerPixel * frameCount`).
    static func validateAnimatedMemoryBudget(
        width: Int,
        height: Int,
        frameCount: Int,
        bytesPerPixel: Int = 4,
        maxTotalBytes: Int64 = maxAnimatedUncompressedBytes
    ) throws {
        guard width > 0, height > 0, frameCount > 0, bytesPerPixel > 0, maxTotalBytes > 0 else {
            throw ConversionError.invalidInput(
                "Invalid animated image dimensions (\(width)×\(height), \(frameCount) frames)."
            )
        }

        let (pixelsPerFrame, pxOverflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !pxOverflow, pixelsPerFrame <= maxAnimatedFramePixels else {
            throw ConversionError.invalidInput(
                "Animated image frame dimensions \(width)×\(height) exceed the \(maxAnimatedFramePixels / 1_000_000) MP per-frame memory limit."
            )
        }

        let (bytesPerFrame, bpfOverflow) = pixelsPerFrame.multipliedReportingOverflow(by: Int64(bytesPerPixel))
        guard !bpfOverflow else {
            throw ConversionError.invalidInput(
                "Animated image frame memory (\(width)×\(height) @ \(bytesPerPixel) Bpp) overflows safe bounds."
            )
        }

        let (totalBytes, totalOverflow) = bytesPerFrame.multipliedReportingOverflow(by: Int64(frameCount))
        guard !totalOverflow, totalBytes <= maxTotalBytes else {
            let limitDescription = maxTotalBytes >= 1024 * 1024
                ? "\(maxTotalBytes / (1024 * 1024)) MB"
                : "\(maxTotalBytes) bytes"
            throw ConversionError.invalidInput(
                "Animated image (\(width)×\(height), \(frameCount) frames) exceeds the \(limitDescription) uncompressed frame memory budget."
            )
        }
    }

    private static func extractAnimatedImageIOFrames(
        input: URL,
        inputFormat: FileFormat,
        outputFormat: FileFormat,
        bitDepth: Int,
        maxUncompressedMemoryBytes: Int64,
        onFrameDecoded: (@Sendable (Int) -> Void)?,
        progress: @Sendable (ConversionProgress) -> Void
    ) throws -> (frames: [JXLEncodeFrame], loopCount: Int)? {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }

        // Read container & frame-0 metadata BEFORE decoding any pixel buffers.
        let containerProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let frame0Props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        let gifDict = containerProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let webpDict = containerProps?[kCGImagePropertyWebPDictionary] as? [CFString: Any]

        let canvasWidth = (gifDict?[kCGImagePropertyGIFCanvasPixelWidth] as? NSNumber)?.intValue
            ?? (webpDict?[kCGImagePropertyWebPCanvasPixelWidth] as? NSNumber)?.intValue
            ?? 0
        let canvasHeight = (gifDict?[kCGImagePropertyGIFCanvasPixelHeight] as? NSNumber)?.intValue
            ?? (webpDict?[kCGImagePropertyWebPCanvasPixelHeight] as? NSNumber)?.intValue
            ?? 0

        let prop0Width = (frame0Props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let prop0Height = (frame0Props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let prop0Depth = (frame0Props?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8

        var targetWidth = max(canvasWidth, prop0Width)
        var targetHeight = max(canvasHeight, prop0Height)
        let estimatedBytesPerPixel = (prop0Depth > 8 || (outputFormat == .jxl && bitDepth >= 16)) ? 8 : 4

        var cachedFrame0: CGImage? = nil
        if targetWidth > 0 && targetHeight > 0 {
            try validateAnimatedMemoryBudget(
                width: targetWidth,
                height: targetHeight,
                frameCount: count,
                bytesPerPixel: estimatedBytesPerPixel,
                maxTotalBytes: maxUncompressedMemoryBytes
            )
        } else {
            // Fallback when container/index-0 metadata lacks dimensions: decode frame 0 ONCE and reuse it at i == 0.
            guard let decoded0 = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ) else {
                return nil
            }
            onFrameDecoded?(0)
            cachedFrame0 = decoded0
            targetWidth = decoded0.width
            targetHeight = decoded0.height
            let frame0Bpp = (decoded0.bitsPerComponent > 8 || (outputFormat == .jxl && bitDepth >= 16)) ? 8 : 4
            try validateAnimatedMemoryBudget(
                width: targetWidth,
                height: targetHeight,
                frameCount: count,
                bytesPerPixel: frame0Bpp,
                maxTotalBytes: maxUncompressedMemoryBytes
            )
        }

        progress(.determinate(0.35, message: "Processing animated \(inputFormat.displayName) (\(count) frames)..."))
        var frames: [JXLEncodeFrame] = []
        frames.reserveCapacity(count)

        let loopCount: Int = {
            if let loops = gifDict?[kCGImagePropertyGIFLoopCount] as? Int {
                return loops
            }
            if let loops = webpDict?[kCGImagePropertyWebPLoopCount] as? Int {
                return loops
            }
            return 0
        }()

        for i in 0..<count {
            try Task.checkCancellation()
            let props: [CFString: Any]? = (i == 0)
                ? frame0Props
                : (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])

            if i > 0,
               let fw = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
               let fh = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
               fw > 0, fh > 0 {
                let (framePixels, framePxOverflow) = Int64(fw).multipliedReportingOverflow(by: Int64(fh))
                guard !framePxOverflow, framePixels <= maxAnimatedFramePixels else {
                    throw ConversionError.invalidInput(
                        "Animated image frame \(i + 1) dimensions \(fw)×\(fh) exceed the \(maxAnimatedFramePixels / 1_000_000) MP per-frame memory limit."
                    )
                }
            }

            let frameImg: CGImage
            if i == 0, let predecoded0 = cachedFrame0 {
                frameImg = predecoded0
                cachedFrame0 = nil
            } else {
                guard let decoded = CGImageSourceCreateImageAtIndex(
                    source,
                    i,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                ) else {
                    continue
                }
                onFrameDecoded?(i)
                frameImg = decoded
            }

            let normalizedImg: CGImage = (frameImg.width == targetWidth && frameImg.height == targetHeight)
                ? frameImg
                : (try? ImageProcessor.resampleCGImage(frameImg, width: targetWidth, height: targetHeight, method: .bilinear)) ?? frameImg

            let animDict: [CFString: Any]? = {
                switch inputFormat {
                case .gif: return props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                case .apng: return props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                case .webp: return props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                default: return nil
                }
            }()
            let delay = (animDict?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (animDict?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (animDict?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                ?? (animDict?[kCGImagePropertyAPNGDelayTime] as? Double)
                ?? (animDict?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                ?? (animDict?[kCGImagePropertyWebPDelayTime] as? Double)
                ?? 0.1
            frames.append(JXLEncodeFrame(image: normalizedImg, duration: max(0.02, delay)))
        }

        guard frames.count > 1 else { return nil }
        return (frames, loopCount)
    }

    static func convertAnimatedIfApplicable(
        input: URL,
        inputFormat: FileFormat,
        outputFormat: FileFormat,
        outputURL: URL,
        options: ConversionOptions,
        maxUncompressedMemoryBytes: Int64 = maxAnimatedUncompressedBytes,
        onFrameDecoded: (@Sendable (Int) -> Void)? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> Bool {
        let isLossless = (options.customOptions["jxl_lossless"] == "true") || options.imageOptimizationMode == .lossless
        let effort = options.customOptions["jxl_effort"].flatMap(Int.init) ?? 7
        let bitDepth = options.customOptions["jxl_bit_depth"].flatMap(Int.init) ?? 8
        let stagedOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-AnimCommit-\(UUID().uuidString).\(outputFormat.fileExtension)")
        defer { try? FileManager.default.removeItem(at: stagedOutputURL) }

        if inputFormat == .gif || inputFormat == .apng || inputFormat == .webp {
            guard let extracted = try extractAnimatedImageIOFrames(
                input: input,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                bitDepth: bitDepth,
                maxUncompressedMemoryBytes: maxUncompressedMemoryBytes,
                onFrameDecoded: onFrameDecoded,
                progress: progress
            ) else {
                return false
            }
            let frames = extracted.frames
            let loopCount = extracted.loopCount

            switch outputFormat {
            case .jxl:
                let jxlData = try JPEGXLCodec.encode(
                    frames: frames,
                    options: JXLEncodeOptions(
                        lossless: isLossless,
                        quality: options.effectiveImageQuality,
                        effort: effort,
                        bitDepth: bitDepth,
                        preserveAlpha: true,
                        useContainer: true
                    )
                )
                try jxlData.write(to: stagedOutputURL, options: .atomic)
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(stagedOutputURL, to: outputURL, policy: .overwrite)
                return true

            case .gif:
                try encodeAnimatedGIF(
                    frames: frames.map { ($0.image, $0.duration) },
                    loopCount: loopCount,
                    outputURL: stagedOutputURL
                )
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(stagedOutputURL, to: outputURL, policy: .overwrite)
                return true

            case .apng:
                try await encodeAnimatedAPNG(
                    frames: frames.map { ($0.image, $0.duration) },
                    outputURL: stagedOutputURL
                )
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(stagedOutputURL, to: outputURL, policy: .overwrite)
                return true

            default:
                return false
            }
        }

        if inputFormat == .jxl {
            let info = try JPEGXLCodec.inspect(url: input)
            guard info.isAnimated && info.frameCount > 1 else { return false }
            let jxlBytesPerPixel = (outputFormat == .jxl && bitDepth >= 16) ? 8 : 4
            try validateAnimatedMemoryBudget(
                width: info.width,
                height: info.height,
                frameCount: info.frameCount,
                bytesPerPixel: jxlBytesPerPixel,
                maxTotalBytes: maxUncompressedMemoryBytes
            )
            let decoded = try JPEGXLCodec.decode(url: input, prefer16Bit: false, decodeAllFrames: true)
            guard decoded.frames.count > 1 else { return false }

            if outputFormat == .gif {
                progress(.determinate(0.45, message: "Writing animated GIF (\(decoded.frames.count) frames)..."))
                try encodeAnimatedGIF(
                    frames: decoded.frames.map { ($0.image, $0.duration) },
                    loopCount: info.numLoops,
                    outputURL: stagedOutputURL
                )
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(stagedOutputURL, to: outputURL, policy: .overwrite)
                return true
            } else if outputFormat == .apng {
                progress(.determinate(0.45, message: "Writing animated APNG (\(decoded.frames.count) frames)..."))
                try await encodeAnimatedAPNG(
                    frames: decoded.frames.map { ($0.image, $0.duration) },
                    outputURL: stagedOutputURL
                )
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(stagedOutputURL, to: outputURL, policy: .overwrite)
                return true
            } else if outputFormat == .jxl {
                let encoded = try JPEGXLCodec.encode(
                    frames: decoded.frames.map { JXLEncodeFrame(image: $0.image, duration: max(0.02, $0.duration)) },
                    options: JXLEncodeOptions(
                        lossless: isLossless,
                        quality: options.effectiveImageQuality,
                        effort: effort,
                        bitDepth: bitDepth,
                        preserveAlpha: true,
                        useContainer: true,
                        iccProfileData: decoded.info.iccData,
                        exifData: decoded.info.exifData,
                        xmpData: decoded.info.xmpData
                    )
                )
                try encoded.write(to: stagedOutputURL, options: .atomic)
                try Task.checkCancellation()
                _ = try OutputReservationCoordinator.moveOrReplaceTempFile(stagedOutputURL, to: outputURL, policy: .overwrite)
                return true
            }
        }

        return false
    }

    private static func encodeAnimatedGIF(
        frames: [(image: CGImage, duration: Double)],
        loopCount: Int,
        outputURL: URL
    ) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw ConversionError.engineExecutionFailed("Could not create animated GIF destination.", underlyingError: nil)
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        for frame in frames {
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(0.02, frame.duration)]
            ]
            CGImageDestinationAddImage(dest, frame.image, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize animated GIF.", underlyingError: nil)
        }
    }

    private static func encodeAnimatedAPNG(
        frames: [(image: CGImage, duration: Double)],
        outputURL: URL
    ) async throws {
        guard let ffmpegPath = await BundledFFmpegProvider().findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("FFmpeg is required to encode animated APNG.")
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Anim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var concatManifest = ""
        var lastPath = ""
        for (idx, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let frameURL = tempDir.appendingPathComponent(String(format: "frame_%04d.png", idx))
            guard let d = CGImageDestinationCreateWithURL(frameURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ConversionError.engineExecutionFailed("Failed to write temporary animation frame.", underlyingError: nil)
            }
            CGImageDestinationAddImage(d, frame.image, nil)
            CGImageDestinationFinalize(d)
            let escaped = frameURL.path.replacingOccurrences(of: "'", with: "'\\''")
            concatManifest += "file '\(escaped)'\nduration \(String(format: "%.4f", max(0.02, frame.duration)))\n"
            lastPath = escaped
        }
        if !lastPath.isEmpty {
            concatManifest += "file '\(lastPath)'\n"
        }
        let manifestURL = tempDir.appendingPathComponent("frames.txt")
        try concatManifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        try await runFFmpegImageCommandStatic(
            ffmpegPath: ffmpegPath,
            arguments: ["-y", "-f", "concat", "-safe", "0", "-i", manifestURL.path, "-plays", "0", "-f", "apng", outputURL.path]
        )
    }

    private func convertMultiPageTIFFIfApplicable(
        input: URL,
        outputFormat: FileFormat,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return false }
        let pageCount = CGImageSourceGetCount(source)
        guard pageCount > 1 else { return false }

        progress(.determinate(0.35, message: "Processing \(pageCount) TIFF pages..."))

        var processedPages: [(image: CGImage, properties: [String: Any]?)] = []
        processedPages.reserveCapacity(pageCount)

        for idx in 0..<pageCount {
            try Task.checkCancellation()
            guard let pageImg = CGImageSourceCreateImageAtIndex(source, idx, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                continue
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, idx, nil) as? [String: Any]
            let orientation = ImageSourcePipeline.orientation(from: props)
            let oriented = (orientation != .up) ? ImageProcessor.orientCGImage(pageImg, orientation: orientation) : pageImg
            let transformed = try ImageProcessor.applyTransformations(cgImage: oriented, options: options)
            processedPages.append((transformed, props))
        }

        guard processedPages.count > 1 else { return false }

        if outputFormat == .tiff {
            guard let dest = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                typeIdentifier(for: .tiff) as CFString,
                processedPages.count,
                nil
            ) else {
                throw ConversionError.engineExecutionFailed("Could not create multi-page TIFF destination.", underlyingError: nil)
            }
            for page in processedPages {
                let destProps: [String: Any] = options.preserveMetadata
                    ? ImageSourcePipeline.normalizedPropertiesAfterOrientation(
                        from: page.properties,
                        pixelWidth: page.image.width,
                        pixelHeight: page.image.height
                    )
                    : [:]
                CGImageDestinationAddImage(dest, page.image, destProps as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else {
                throw ConversionError.engineExecutionFailed("Failed to finalize multi-page TIFF.", underlyingError: nil)
            }
            return true
        } else if outputFormat == .pdf {
            var firstBox = CGRect(x: 0, y: 0, width: processedPages[0].image.width, height: processedPages[0].image.height)
            guard let pdfContext = CGContext(outputURL as CFURL, mediaBox: &firstBox, nil) else {
                throw ConversionError.engineExecutionFailed("Could not create multi-page PDF context.", underlyingError: nil)
            }
            for page in processedPages {
                var box = CGRect(x: 0, y: 0, width: page.image.width, height: page.image.height)
                pdfContext.beginPDFPage([kCGPDFContextMediaBox: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary)
                pdfContext.draw(page.image, in: box)
                pdfContext.endPDFPage()
            }
            pdfContext.closePDF()
            return true
        }

        return false
    }

    // MARK: - Image to WebP Conversion (libwebp)
    
    /// Encodes a CGImage to WebP using the libwebp C bridge with ICC/EXIF/XMP container metadata preservation
    /// and cooperative libwebp progress-hook task cancellation.
    private func convertImageToWebP(
        cgImage: CGImage,
        sourceProperties: [String: Any]?,
        outputURL: URL,
        options: ConversionOptions
    ) async throws {
        let isLossless = options.webpLossless || options.imageOptimizationMode == .lossless
        let quality = options.effectiveImageQuality
        let preserveMetadata = options.preserveMetadata
        // Flatten any NSObject values into Sendable primitives? ImageIO property dictionaries come from CFPropertyList
        // and encodeToMemory reads only Foundation metadata objects synchronously inside the detached encode step.
        nonisolated(unsafe) let unsafeSourceProperties = sourceProperties
        let token = WebPCancellationToken()

        let webpData: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try ImageProcessor.encodeToMemory(
                    cgImage: cgImage,
                    format: .webp,
                    quality: quality,
                    lossless: isLossless,
                    sourceProperties: unsafeSourceProperties,
                    preserveMetadata: preserveMetadata,
                    cancelFlag: token.pointer
                )
            }.value
        } onCancel: {
            token.cancel()
        }

        try Task.checkCancellation()
        
        // Validate the encoded output before writing
        guard WebPEncoder.validate(webpData) else {
            throw ConversionError.engineExecutionFailed(
                "WebP encoding produced an invalid bitstream.",
                underlyingError: "RIFF/WEBP signature check failed on encoder output"
            )
        }
        
        try webpData.write(to: outputURL, options: .atomic)
        
        logger.debug("WebP encode: \(cgImage.width)x\(cgImage.height) → \(webpData.count) bytes [\(isLossless ? "lossless" : "lossy q=\(quality * 100.0)")]")
    }
    
    // MARK: - Image to PDF Conversion
    
    private func convertImageToPDF(cgImage: CGImage, outputURL: URL) throws {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        
        guard let pdfContext = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed(
                "Could not create PDF rendering context for \(outputURL.lastPathComponent).",
                underlyingError: nil
            )
        }
        
        pdfContext.beginPDFPage(nil)
        pdfContext.draw(cgImage, in: mediaBox)
        pdfContext.endPDFPage()
        pdfContext.closePDF()
    }
    
    // MARK: - Image to ICNS Conversion (Standard Apple Icon Representations)
    
    private func convertImageToICNS(cgImage: CGImage, outputURL: URL) throws {
        let standardSizes = [16, 32, 128, 256, 512]
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "com.apple.icns" as CFString,
            standardSizes.count,
            nil
        ) else {
            throw ConversionError.engineExecutionFailed(
                "Could not create ICNS image destination for \(outputURL.lastPathComponent).",
                underlyingError: nil
            )
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
            
            // Aspect-fit into square canvas
            let scale = min(CGFloat(size) / origW, CGFloat(size) / origH)
            let fitW = origW * scale
            let fitH = origH * scale
            let originX = (CGFloat(size) - fitW) / 2.0
            let originY = (CGFloat(size) - fitH) / 2.0
            let drawRect = CGRect(x: originX, y: originY, width: fitW, height: fitH)
            
            context.draw(cgImage, in: drawRect)
            
            if let representation = context.makeImage() {
                CGImageDestinationAddImage(destination, representation, nil)
            }
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to finalize ICNS icon creation.",
                underlyingError: nil
            )
        }
    }
    
    // MARK: - FFmpeg Raster Image Helpers
    
    private func convertImageViaFFmpeg(cgImage: CGImage, to format: FileFormat, outputURL: URL) async throws {
        guard let ffmpegPath = await BundledFFmpegProvider().findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("FFmpeg is required to encode \(format.displayName).")
        }
        let prepared = ImageProcessor.prepareImageForEncoding(cgImage, format: format)
        let use16BitTIFF = (format == .hdr) || prepared.bitsPerComponent > 8
        let tempExt = use16BitTIFF ? "tiff" : "png"
        let tempIntermediate = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-ImgEnc-\(UUID().uuidString).\(tempExt)")
        defer { try? FileManager.default.removeItem(at: tempIntermediate) }

        if use16BitTIFF {
            guard let dest = CGImageDestinationCreateWithURL(tempIntermediate as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
                throw ConversionError.engineExecutionFailed("Failed to create 16-bit TIFF staging file.", underlyingError: nil)
            }
            let tiffProps: [CFString: Any] = [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]
            ]
            CGImageDestinationAddImage(dest, prepared, tiffProps as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw ConversionError.engineExecutionFailed("Failed to write 16-bit TIFF staging file.", underlyingError: nil)
            }
        } else {
            try convertImage(cgImage: prepared, sourceProperties: nil, to: .png, outputURL: tempIntermediate, options: .default)
        }

        var args = ["-y", "-i", tempIntermediate.path]
        switch format {
        case .apng:
            args += ["-plays", "0", "-f", "apng"]
        case .hdr:
            args += ["-pix_fmt", "rgb96le"]
        case .wbmp:
            args += ["-pix_fmt", "monob"]
        default:
            break
        }
        args.append(outputURL.path)
        try await runFFmpegImageCommand(ffmpegPath: ffmpegPath, arguments: args)
    }
    
    private func runFFmpegImageCommand(ffmpegPath: String, arguments: [String]) async throws {
        try await Self.runFFmpegImageCommandStatic(ffmpegPath: ffmpegPath, arguments: arguments)
    }

    private static func runFFmpegImageCommandStatic(ffmpegPath: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        let output = try await AsyncProcessRunner.run(process)
        guard output.terminationStatus == 0 else {
            let err = String(data: output.stderr, encoding: .utf8) ?? "FFmpeg image conversion failed"
            throw ConversionError.engineExecutionFailed("Image conversion failed.", underlyingError: err)
        }
    }
    
    // MARK: - Type Identifier Mapping
    
    private func typeIdentifier(for format: FileFormat) -> String {
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


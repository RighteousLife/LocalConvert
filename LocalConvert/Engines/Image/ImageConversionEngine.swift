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
    
    var supportedInputFormats: Set<FileFormat> {
        [.jpg, .png, .heic, .webp, .tiff, .bmp, .gif]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [.jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .pdf]
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
        
        // Quality preset applies to lossy image targets
        if [FileFormat.jpg, .heic].contains(output) {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "imageQuality",
                    title: "Image Quality",
                    description: "Select compression quality preset",
                    kind: .qualityPreset([.low, .medium, .high, .maximum])
                )
            )
        }
        
        // WebP offers lossy quality and a lossless toggle
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
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
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
        
        // Create image source
        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ConversionError.invalidInput("The file could not be read as an image.")
        }
        
        guard CGImageSourceGetCount(imageSource) > 0 else {
            throw ConversionError.invalidInput("The image file does not contain any image data.")
        }
        
        try Task.checkCancellation()
        
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        
        guard var cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions as CFDictionary) else {
            throw ConversionError.invalidInput("The image file could not be decoded. It may be corrupted or unsupported.")
        }
        
        // Read orientation from metadata and transform pixels if needed so image is upright
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        let orientationRaw = (sourceProperties?[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        
        if orientation != .up {
            let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
            let ciContext = CIContext()
            if let orientedImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                cgImage = orientedImage
            }
        }
        
        try Task.checkCancellation()
        
        progress(.determinate(0.4, message: "Converting..."))
        
        let outputURL = ConversionManager.outputURL(for: input, format: outputFormat, in: outputDirectory)
        
        do {
            if outputFormat == .pdf {
                try convertImageToPDF(cgImage: cgImage, outputURL: outputURL)
            } else if outputFormat == .webp {
                // libwebp path — ImageIO cannot encode WebP natively
                try convertImageToWebP(
                    cgImage: cgImage,
                    outputURL: outputURL,
                    options: options
                )
            } else {
                try convertImage(
                    cgImage: cgImage,
                    sourceProperties: sourceProperties,
                    to: outputFormat,
                    outputURL: outputURL,
                    options: options
                )
            }
            
            try Task.checkCancellation()
        } catch {
            // Clean up partially written output file on cancellation or error
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        
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
        if [FileFormat.jpg, .heic].contains(format) {
            destProperties[kCGImageDestinationLossyCompressionQuality as String] = options.effectiveImageQuality
        }
        
        // Preserve metadata if requested, correcting orientation tag since pixels were rendered upright
        if options.preserveMetadata, let sourceProperties {
            for (key, value) in sourceProperties {
                destProperties[key] = value
            }
            // Set orientation to 1 (normal / upright) to prevent double-rotation in viewers
            destProperties[kCGImagePropertyOrientation as String] = 1
            if var tiffDict = destProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiffDict[kCGImagePropertyTIFFOrientation as String] = 1
                destProperties[kCGImagePropertyTIFFDictionary as String] = tiffDict
            }
        }
        
        CGImageDestinationAddImage(destination, cgImage, destProperties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to write converted image data to \(outputURL.lastPathComponent).",
                underlyingError: nil
            )
        }
    }
    
    // MARK: - Image to WebP Conversion (libwebp)
    
    /// Encodes a CGImage to WebP using the libwebp C bridge.
    /// Quality is mapped from ConversionOptions (0.0–1.0) to libwebp scale (0–100).
    private func convertImageToWebP(
        cgImage: CGImage,
        outputURL: URL,
        options: ConversionOptions
    ) throws {
        let encoder = WebPEncoder()
        
        // Map quality: ConversionOptions 0.0-1.0 → libwebp 0-100
        let libwebpQuality = Float(options.effectiveImageQuality * 100.0)
        let mode: WebPEncodingMode = options.webpLossless
            ? .lossless
            : .lossy(quality: libwebpQuality)
        
        let webpData = try encoder.encode(image: cgImage, mode: mode)
        
        // Validate the encoded output before writing
        guard WebPEncoder.validate(webpData) else {
            throw ConversionError.engineExecutionFailed(
                "WebP encoding produced an invalid bitstream.",
                underlyingError: "RIFF/WEBP signature check failed on encoder output"
            )
        }
        
        try webpData.write(to: outputURL, options: .atomic)
        
        logger.debug("WebP encode: \(cgImage.width)x\(cgImage.height) → \(webpData.count) bytes [\(options.webpLossless ? "lossless" : "lossy q=\(libwebpQuality)")]")
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
    
    // MARK: - Type Identifier Mapping
    
    private func typeIdentifier(for format: FileFormat) -> String {
        switch format {
        case .jpg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        default: return format.utType?.identifier ?? "public.png"
        }
    }
}


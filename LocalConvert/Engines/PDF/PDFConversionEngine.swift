import Foundation
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import os.log

final class PDFConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "PDFEngine"
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "PDFEngine")
    
    var supportedInputFormats: Set<FileFormat> {
        [.pdf]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [.png, .jpg, .tiff]
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        supportedInputFormats.contains(input) && supportedOutputFormats.contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        return supportedOutputFormats
    }
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        guard canConvert(from: input, to: output) else { return [] }
        var descriptors: [ConversionOptionDescriptor] = [
            ConversionOptionDescriptor(
                id: "pdfDPI",
                title: "Rendering Resolution (DPI)",
                description: "Select rendering resolution for PDF pages",
                kind: .dpiPreset([72.0, 96.0, 150.0, 200.0, 300.0, 600.0])
            )
        ]
        
        if output == .jpg {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "imageQuality",
                    title: "Image Quality",
                    description: "Select JPEG compression quality preset",
                    kind: .qualityPreset([.low, .medium, .high, .maximum])
                )
            )
        }
        
        return descriptors
    }
    
    func isAvailable() async -> Bool {
        true // PDFKit & CoreGraphics are always available on macOS
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
        
        // Validate input exists
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        
        // Validate output directory writable
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }
        
        progress(.determinate(0.05, message: "Opening PDF document..."))
        
        guard let pdfDocument = PDFDocument(url: input) else {
            throw ConversionError.invalidInput("The PDF file could not be opened. It may be corrupted or invalid.")
        }
        
        let pageCount = pdfDocument.pageCount
        guard pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file does not contain any pages.")
        }
        
        let dpi = options.effectivePDFDPI
        let scale: CGFloat = CGFloat(dpi / 72.0)
        
        var generatedURLs: [URL] = []
        var totalBytes: Int64 = 0
        
        do {
            for pageIndex in 0..<pageCount {
                try Task.checkCancellation()
                
                let progressFraction = Double(pageIndex) / Double(pageCount)
                progress(.determinate(
                    progressFraction,
                    message: "Rendering page \(pageIndex + 1) of \(pageCount)..."
                ))
                
                guard let page = pdfDocument.page(at: pageIndex) else {
                    throw ConversionError.engineExecutionFailed(
                        "Could not read page \(pageIndex + 1) of the PDF.",
                        underlyingError: nil
                    )
                }
                
                // Determine output URL with collision handling
                let pageURL = ConversionManager.multiPageOutputURL(
                    for: input,
                    pageIndex: pageIndex,
                    totalPages: pageCount,
                    format: outputFormat,
                    in: outputDirectory
                )
                
                // Render page to image
                try renderPage(
                    page,
                    to: pageURL,
                    format: outputFormat,
                    scale: scale,
                    options: options
                )
                
                generatedURLs.append(pageURL)
                
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: pageURL.path)[.size] as? Int64) ?? 0
                totalBytes += fileSize
            }
            
            try Task.checkCancellation()
        } catch {
            // Clean up any files that were already written if cancellation or error occurred
            for url in generatedURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        
        progress(.determinate(1.0, message: "Complete"))
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        guard let firstURL = generatedURLs.first else {
            throw ConversionError.engineExecutionFailed("No output files were created.", underlyingError: nil)
        }
        
        let remainingURLs = Array(generatedURLs.dropFirst())
        
        logger.info("PDF conversion succeeded: \(input.lastPathComponent) -> \(generatedURLs.count) page(s) (\(totalBytes) bytes, \(duration)s)")
        
        return ConversionResult(
            outputURL: firstURL,
            additionalOutputURLs: remainingURLs,
            outputFormat: outputFormat,
            fileSize: totalBytes,
            duration: duration,
            engineName: name
        )
    }
    
    // MARK: - Page Rendering
    
    private func renderPage(
        _ page: PDFPage,
        to outputURL: URL,
        format: FileFormat,
        scale: CGFloat,
        options: ConversionOptions
    ) throws {
        let pageRect = page.bounds(for: .mediaBox)
        let pixelWidth = max(Int(pageRect.width * scale), 1)
        let pixelHeight = max(Int(pageRect.height * scale), 1)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ConversionError.engineExecutionFailed("Could not create graphics rendering context.", underlyingError: nil)
        }
        
        // Fill white background for all formats (standard document background, required for JPEG)
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        
        // Scale context according to target DPI
        context.scaleBy(x: scale, y: scale)
        
        // Draw PDF page into context using AppKit graphics context
        let nsGraphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = nsGraphicsContext
        page.draw(with: .mediaBox, to: context)
        NSGraphicsContext.current = previousContext
        
        guard let cgImage = context.makeImage() else {
            throw ConversionError.engineExecutionFailed("Could not create image from rendered PDF page.", underlyingError: nil)
        }
        
        // Write to destination
        let destinationType: String
        switch format {
        case .jpg: destinationType = "public.jpeg"
        case .png: destinationType = "public.png"
        case .tiff: destinationType = "public.tiff"
        default: destinationType = format.utType?.identifier ?? "public.png"
        }
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            destinationType as CFString,
            1,
            nil
        ) else {
            throw ConversionError.engineExecutionFailed("Could not create image destination for \(outputURL.lastPathComponent).", underlyingError: nil)
        }
        
        var properties: [String: Any] = [:]
        if format == .jpg {
            properties[kCGImageDestinationLossyCompressionQuality as String] = options.effectiveImageQuality
        }
        
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize image for \(outputURL.lastPathComponent).", underlyingError: nil)
        }
    }
}

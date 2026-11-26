import Foundation
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import os.log

final class PDFConversionEngine: ConversionEngine, @unchecked Sendable {

    /// Maximum rendered pixel budget per PDF page (100 MP, ~400 MB RGBA8) to prevent OOM on
    /// oversized architectural/poster sheets or malformed PDFs at high DPI.
    static let maxPagePixels: Int64 = 100_000_000

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
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let input = inputs.first else { throw ConversionError.invalidInput("No inputs") }
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
        
        if pdfDocument.isLocked {
            if let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
                guard pdfDocument.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF document '\(input.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF file '\(input.lastPathComponent)' is password-protected. Please provide a password.")
            }
        }
        
        let pageCount = pdfDocument.pageCount
        guard pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file does not contain any pages.")
        }
        
        let dpi = options.effectivePDFDPI
        guard dpi.isFinite, dpi > 0 else {
            throw ConversionError.invalidInput("Invalid PDF rendering DPI (\(dpi)).")
        }
        let scale: CGFloat = CGFloat(dpi / 72.0)

        // Validate all page pixel budgets before creating staging directories or reserving outputs
        for pageIndex in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = pdfDocument.page(at: pageIndex) else {
                throw ConversionError.engineExecutionFailed(
                    "Could not read page \(pageIndex + 1) of the PDF.",
                    underlyingError: nil
                )
            }
            _ = try Self.validatedRenderPixelSize(
                for: page,
                dpi: dpi,
                pageNumber: pageIndex + 1
            )
        }
        
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PDFRender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        var reservedURLs: [URL] = []
        defer {
            for url in reservedURLs {
                ConversionManager.releaseReservedOutputURL(url)
            }
        }

        var stagedPages: [(tempURL: URL, finalURL: URL)] = []
        var totalBytes: Int64 = 0

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

            // Determine output URL with atomic reservation and collision handling
            let pageURL = try ConversionManager.reserveMultiPageOutputURL(
                for: input,
                pageIndex: pageIndex,
                totalPages: pageCount,
                format: outputFormat,
                in: outputDirectory,
                options: options
            )
            reservedURLs.append(pageURL)

            let tempPageURL = stagingDir.appendingPathComponent("page-\(pageIndex).\(outputFormat.fileExtension)")

            // Render page to staged temporary image inside an autoreleasepool to bound per-page memory
            try autoreleasepool {
                try renderPage(
                    page,
                    pageNumber: pageIndex + 1,
                    to: tempPageURL,
                    format: outputFormat,
                    dpi: dpi,
                    scale: scale,
                    options: options
                )
            }

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempPageURL.path)[.size] as? Int64) ?? 0
            totalBytes += fileSize
            stagedPages.append((tempURL: tempPageURL, finalURL: pageURL))
        }

        try Task.checkCancellation()

        let policy = options.resolvedExistingFileHandling
        var generatedURLs: [URL] = []
        do {
            for staged in stagedPages {
                try Task.checkCancellation()
                let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
                    staged.tempURL,
                    to: staged.finalURL,
                    policy: policy
                )
                generatedURLs.append(committedURL)
            }
        } catch {
            if policy != .overwrite {
                for createdURL in generatedURLs {
                    try? FileManager.default.removeItem(at: createdURL)
                }
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

    /// Validates and computes safe pixel dimensions for a PDF page at the requested DPI,
    /// guarding against floating-point non-finiteness, integer overflow, and per-page OOM.
    static func validatedRenderPixelSize(
        for page: PDFPage,
        dpi: Double,
        pageNumber: Int = 1,
        maxPagePixels: Int64 = maxPagePixels
    ) throws -> (width: Int, height: Int) {
        guard maxPagePixels > 0 else {
            throw ConversionError.invalidInput("Invalid maximum PDF page pixel budget.")
        }
        guard dpi.isFinite, dpi > 0 else {
            throw ConversionError.invalidInput("Invalid PDF rendering DPI (\(dpi)).")
        }
        let scale = dpi / 72.0
        guard scale.isFinite, scale > 0 else {
            throw ConversionError.invalidInput("Invalid PDF rendering scale for DPI \(dpi).")
        }

        let uprightSize = PDFRedactionService.uprightSize(for: page)
        let rawWidth = Double(uprightSize.width) * scale
        let rawHeight = Double(uprightSize.height) * scale
        guard rawWidth.isFinite, rawHeight.isFinite, rawWidth > 0, rawHeight > 0 else {
            throw ConversionError.invalidInput("PDF page \(pageNumber) has invalid non-finite dimensions.")
        }

        let limitDescription = maxPagePixels >= 1_000_000
            ? "\(maxPagePixels / 1_000_000) MP"
            : "\(maxPagePixels) pixels"
        let maxDouble = Double(maxPagePixels)
        guard rawWidth <= maxDouble, rawHeight <= maxDouble else {
            throw ConversionError.invalidInput(
                "PDF page \(pageNumber) dimensions exceed the \(limitDescription) per-page rendering limit at \(String(format: "%.0f", dpi)) DPI. Reduce rendering DPI."
            )
        }

        let pixelWidth = max(Int(rawWidth), 1)
        let pixelHeight = max(Int(rawHeight), 1)
        let (totalPixels, overflow) = Int64(pixelWidth).multipliedReportingOverflow(by: Int64(pixelHeight))
        guard !overflow, totalPixels <= maxPagePixels else {
            throw ConversionError.invalidInput(
                "PDF page \(pageNumber) requires \(pixelWidth)×\(pixelHeight) pixels, exceeding the \(limitDescription) per-page memory limit. Reduce rendering DPI."
            )
        }

        return (pixelWidth, pixelHeight)
    }

    private func renderPage(
        _ page: PDFPage,
        pageNumber: Int,
        to outputURL: URL,
        format: FileFormat,
        dpi: Double,
        scale: CGFloat,
        options: ConversionOptions
    ) throws {
        let pageRect = page.bounds(for: .mediaBox)
        let (pixelWidth, pixelHeight) = try Self.validatedRenderPixelSize(
            for: page,
            dpi: dpi,
            pageNumber: pageNumber
        )
        
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
        
        let targetRect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        // Fill white background for all formats (standard document background, required for JPEG)
        context.setFillColor(CGColor.white)
        context.fill(targetRect)
        
        if let cgPage = page.pageRef {
            let transform = cgPage.getDrawingTransform(.mediaBox, rect: targetRect, rotate: 0, preserveAspectRatio: true)
            context.concatenate(transform)
            context.drawPDFPage(cgPage)
        } else {
            // Scale and translate for non-zero mediaBox origin
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            let nsGraphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            let previousContext = NSGraphicsContext.current
            NSGraphicsContext.current = nsGraphicsContext
            page.draw(with: .mediaBox, to: context)
            NSGraphicsContext.current = previousContext
        }
        
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

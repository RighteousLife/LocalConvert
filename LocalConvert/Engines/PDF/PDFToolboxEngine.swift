import Foundation
import PDFKit
import CoreGraphics
import AppKit

final class PDFToolboxEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "PDFToolboxEngine"
    
    var supportedInputFormats: Set<FileFormat> {
        [.pdf, .jpg, .png, .heic, .tiff]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [.pdf, .png, .jpg, .tiff]
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        guard supportedInputFormats.contains(input) && supportedOutputFormats.contains(output) else {
            return false
        }
        if input == .pdf {
            return output == .pdf || output.category == .image
        } else if input.category == .image {
            return output == .pdf
        }
        return false
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        if input == .pdf {
            return [.pdf, .png, .jpg, .tiff]
        } else if input.category == .image {
            return [.pdf]
        }
        return []
    }
    
    func isAvailable() async -> Bool {
        return true
    }
    
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        
        let operation = options.customOptions["pdf_operation"] ?? "unknown"
        
        try Task.checkCancellation()
        
        if operation == "imagesToPDF" {
            return try await performImagesToPDF(inputs: inputs, outputDirectory: outputDirectory, progress: progress)
        } else if operation == "pdfToImages" {
            // Check if we use PDFConversionEngine or do it here. We'll do it here.
            return try await performPDFToImages(input: inputs.first!, to: outputFormat, outputDirectory: outputDirectory, options: options, progress: progress)
        }
        
        // All other operations are PDF -> PDF
        let input = inputs.first!
        let outputExt = outputFormat.fileExtension
        var outputName = input.deletingPathExtension().lastPathComponent
        
        if operation == "merge" {
            outputName += "_merged"
        } else if operation == "splitEveryPage" || operation == "splitRanges" {
            outputName += "_split"
        } else if operation == "separatePages" {
            outputName += "_separated"
        } else {
            outputName += "_\(operation)"
        }
        
        let outputURL = OutputManager.safeOutputURL(for: URL(fileURLWithPath: outputName), format: outputFormat, in: outputDirectory)
        
        if operation == "merge" {
            return try await performMerge(inputs: inputs, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "splitEveryPage" {
            return try await performSplitEveryPage(input: input, outputDirectory: outputDirectory, baseName: input.deletingPathExtension().lastPathComponent, options: options, progress: progress)
        } else if operation == "splitRanges" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performSplitRanges(input: input, rangesString: rangesString, outputDirectory: outputDirectory, baseName: input.deletingPathExtension().lastPathComponent, options: options, progress: progress)
        } else if operation == "extract" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performExtract(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "delete" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performDelete(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "reorder" {
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performReorder(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "rotate" {
            let rotationStr = options.customOptions["pdf_rotation"] ?? "90"
            let rotation = Int(rotationStr) ?? 90
            let rangesString = options.customOptions["pdf_pages"] ?? ""
            return try await performRotate(input: input, rotation: rotation, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "compress" {
            return try await performCompress(input: input, outputURL: outputURL, options: options, progress: progress)
        } else if operation == "separatePages" {
            return try await performSeparatePages(input: input, outputURL: outputURL, options: options, progress: progress)
        }
        
        throw ConversionError.invalidInput("Unknown operation \(operation)")
    }
    
    // MARK: - Document Loading with Password Decryption
    
    private func loadPDFDocument(from url: URL, options: ConversionOptions) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw ConversionError.invalidInput("The PDF file could not be opened. It may be corrupted or invalid.")
        }
        if doc.isLocked {
            if let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
                guard doc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF document '\(url.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF file '\(url.lastPathComponent)' is password-protected. Please provide a password.")
            }
        }
        guard doc.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file does not contain any pages.")
        }
        return doc
    }
    
    // MARK: - Implementations
    
    private func performMerge(inputs: [URL], outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let outDoc = PDFDocument()
        var pageCount = 0
        for (i, url) in inputs.enumerated() {
            progress(.determinate(Double(i) / Double(inputs.count), message: "Merging \(url.lastPathComponent)..."))
            let doc = try loadPDFDocument(from: url, options: options)
            for p in 0..<doc.pageCount {
                if let page = doc.page(at: p) {
                    // Copy page to avoid document sharing issues
                    let copiedPage = page.copy() as! PDFPage
                    outDoc.insert(copiedPage, at: pageCount)
                    pageCount += 1
                }
            }
            try Task.checkCancellation()
        }
        
        guard outDoc.write(to: outputURL) else {
            throw ConversionError.engineExecutionFailed("Failed to save merged PDF", underlyingError: nil)
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: outputURL, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performSplitEveryPage(input: URL, outputDirectory: URL, baseName: String, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let doc = try loadPDFDocument(from: input, options: options)
        var generated = [URL]()
        
        for i in 0..<doc.pageCount {
            progress(.determinate(Double(i) / Double(doc.pageCount), message: "Splitting page \(i+1)..."))
            try Task.checkCancellation()
            
            let singleDoc = PDFDocument()
            if let page = doc.page(at: i) {
                singleDoc.insert(page.copy() as! PDFPage, at: 0)
                let url = OutputManager.safeOutputURL(for: URL(fileURLWithPath: "\(baseName)_page_\(i+1)"), format: .pdf, in: outputDirectory)
                if singleDoc.write(to: url) {
                    generated.append(url)
                }
            }
        }
        
        guard let first = generated.first else {
            throw ConversionError.engineExecutionFailed("Failed to split", underlyingError: nil)
        }
        
        var additional = generated
        additional.removeFirst()
        
        let size = (try? FileManager.default.attributesOfItem(atPath: first.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: first, additionalOutputURLs: additional, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performSplitRanges(input: URL, rangesString: String, outputDirectory: URL, baseName: String, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let doc = try loadPDFDocument(from: input, options: options)
        var generated = [URL]()
        let components = rangesString.split(separator: ",")
        
        for (i, comp) in components.enumerated() {
            try Task.checkCancellation()
            let subPages = PageRangeParser.parse(String(comp), maxPages: doc.pageCount)
            let subDoc = PDFDocument()
            for (j, p) in subPages.enumerated() {
                if let page = doc.page(at: p - 1) {
                    subDoc.insert(page.copy() as! PDFPage, at: j)
                }
            }
            if subDoc.pageCount > 0 {
                let url = OutputManager.safeOutputURL(for: URL(fileURLWithPath: "\(baseName)_part\(i+1)"), format: .pdf, in: outputDirectory)
                if subDoc.write(to: url) {
                    generated.append(url)
                }
            }
        }
        
        guard let first = generated.first else {
            throw ConversionError.engineExecutionFailed("Failed to split ranges", underlyingError: nil)
        }
        
        var additional = generated
        additional.removeFirst()
        
        let size = (try? FileManager.default.attributesOfItem(atPath: first.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: first, additionalOutputURLs: additional, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performExtract(input: URL, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let doc = try loadPDFDocument(from: input, options: options)
        let pages = PageRangeParser.parse(rangesString, maxPages: doc.pageCount)
        
        let subDoc = PDFDocument()
        for (j, p) in pages.enumerated() {
            if let page = doc.page(at: p - 1) {
                subDoc.insert(page.copy() as! PDFPage, at: j)
            }
        }
        
        guard subDoc.pageCount > 0, subDoc.write(to: outputURL) else {
            throw ConversionError.engineExecutionFailed("Failed to save extracted pages", underlyingError: nil)
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: outputURL, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performDelete(input: URL, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let doc = try loadPDFDocument(from: input, options: options)
        let toDelete = Set(PageRangeParser.parse(rangesString, maxPages: doc.pageCount))
        
        let subDoc = PDFDocument()
        var inserted = 0
        for i in 0..<doc.pageCount {
            if !toDelete.contains(i + 1) {
                if let page = doc.page(at: i) {
                    subDoc.insert(page.copy() as! PDFPage, at: inserted)
                    inserted += 1
                }
            }
        }
        
        guard subDoc.pageCount > 0 else {
            throw ConversionError.invalidInput("Cannot delete all pages of a PDF")
        }
        
        guard subDoc.write(to: outputURL) else {
            throw ConversionError.engineExecutionFailed("Failed to save deleted PDF", underlyingError: nil)
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: outputURL, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performReorder(input: URL, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        return try await performExtract(input: input, rangesString: rangesString, outputURL: outputURL, options: options, progress: progress)
    }
    
    private func performRotate(input: URL, rotation: Int, rangesString: String, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let doc = try loadPDFDocument(from: input, options: options)
        let toRotate = rangesString.isEmpty ? Set(1...doc.pageCount) : Set(PageRangeParser.parse(rangesString, maxPages: doc.pageCount))
        
        let subDoc = PDFDocument()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) {
                let copied = page.copy() as! PDFPage
                if toRotate.contains(i + 1) {
                    copied.rotation = (copied.rotation + rotation) % 360
                }
                subDoc.insert(copied, at: i)
            }
        }
        
        guard subDoc.write(to: outputURL) else {
            throw ConversionError.engineExecutionFailed("Failed to save rotated PDF", underlyingError: nil)
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: outputURL, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performCompress(input: URL, outputURL: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let doc = try loadPDFDocument(from: input, options: options)
        
        let subDoc = PDFDocument()
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            if let page = doc.page(at: i) {
                let rect = page.bounds(for: .mediaBox)
                let image = page.thumbnail(of: rect.size, for: .mediaBox)
                if let newPage = PDFPage(image: image) {
                    subDoc.insert(newPage, at: i)
                } else {
                    subDoc.insert(page.copy() as! PDFPage, at: i)
                }
            }
        }
        
        guard subDoc.write(to: outputURL) else {
            throw ConversionError.engineExecutionFailed("Failed to save compressed PDF", underlyingError: nil)
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: outputURL, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performImagesToPDF(inputs: [URL], outputDirectory: URL, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let subDoc = PDFDocument()
        var inserted = 0
        
        let outputName = inputs.first!.deletingPathExtension().lastPathComponent + "_images"
        let outputURL = OutputManager.safeOutputURL(for: URL(fileURLWithPath: outputName), format: .pdf, in: outputDirectory)
        
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                subDoc.insert(page, at: inserted)
                inserted += 1
            }
        }
        
        guard subDoc.pageCount > 0, subDoc.write(to: outputURL) else {
            throw ConversionError.engineExecutionFailed("Failed to save Images to PDF", underlyingError: nil)
        }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: outputURL, outputFormat: .pdf, fileSize: size, duration: 0, engineName: name)
    }
    
    private func performPDFToImages(input: URL, to outputFormat: FileFormat, outputDirectory: URL, options: ConversionOptions, progress: @Sendable (ConversionProgress) -> Void) async throws -> ConversionResult {
        let doc = try loadPDFDocument(from: input, options: options)
        let dpi = options.effectivePDFDPI
        var generated = [URL]()
        let baseName = input.deletingPathExtension().lastPathComponent
        
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            progress(.determinate(Double(i) / Double(doc.pageCount), message: "Rendering page \(i+1)..."))
            
            if let page = doc.page(at: i) {
                let cgPDFPage = page.pageRef!
                let rect = cgPDFPage.getBoxRect(.mediaBox)
                let scale = dpi / 72.0
                let width = Int(rect.width * scale)
                let height = Int(rect.height * scale)
                
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { continue }
                
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: scale, y: -scale)
                context.drawPDFPage(cgPDFPage)
                
                if let cgImage = context.makeImage() {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
                    guard let tiffData = nsImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiffData) else { continue }
                    
                    let data: Data?
                    if outputFormat == .jpg {
                        data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: options.effectiveImageQuality])
                    } else if outputFormat == .tiff {
                        data = bitmap.representation(using: .tiff, properties: [:])
                    } else {
                        data = bitmap.representation(using: .png, properties: [:])
                    }
                    
                    if let d = data {
                        let url = OutputManager.safeOutputURL(for: URL(fileURLWithPath: "\(baseName)_page_\(i+1)"), format: outputFormat, in: outputDirectory)
                        if (try? d.write(to: url)) != nil {
                            generated.append(url)
                        }
                    }
                }
            }
        }
        
        guard let first = generated.first else {
            throw ConversionError.engineExecutionFailed("Failed to render PDF pages to images", underlyingError: nil)
        }
        
        var additional = generated
        additional.removeFirst()
        
        let size = (try? FileManager.default.attributesOfItem(atPath: first.path)[.size] as? Int64) ?? 0
        return ConversionResult(outputURL: first, additionalOutputURLs: additional, outputFormat: outputFormat, fileSize: size, duration: 0, engineName: name)
    }
    
    // MARK: - PDF Grid Split (Separate Pages)
    
    private func performSeparatePages(
        input: URL,
        outputURL: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let splitResult = try await PDFGridPageSplitter.split(
            input: input,
            outputURL: outputURL,
            layout: .twoByTwo,
            password: options.customOptions["pdf_password"],
            progress: progress
        )
        
        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        return ConversionResult(
            outputURL: splitResult.outputURL,
            outputFormat: .pdf,
            fileSize: size,
            duration: duration,
            engineName: name
        )
    }
}

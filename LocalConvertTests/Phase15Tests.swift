import Foundation
import Testing
import PDFKit
import AppKit
@testable import LocalConvert

@Suite("Phase 15 PDF Toolbox Tests")
struct Phase15Tests {
    
    // MARK: - Test Fixture Helpers
    
    private func createTestPDF(pages: Int, pageSize: CGSize = CGSize(width: 300, height: 400), in directory: URL, name: String = UUID().uuidString + ".pdf") -> URL {
        let pdfURL = directory.appendingPathComponent(name)
        let pdfDoc = PDFDocument()
        
        for i in 1...pages {
            let image = NSImage(size: NSSize(width: pageSize.width, height: pageSize.height))
            image.lockFocus()
            
            // Fill background
            let color = NSColor(hue: CGFloat(i) / CGFloat(pages + 1), saturation: 0.6, brightness: 0.9, alpha: 1.0)
            color.setFill()
            NSRect(origin: .zero, size: pageSize).fill()
            
            // Draw text
            let text = "Page \(i)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 28),
                .foregroundColor: NSColor.black
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            str.draw(at: NSPoint(x: 20, y: pageSize.height - 50))
            
            image.unlockFocus()
            
            if let page = PDFPage(image: image) {
                pdfDoc.insert(page, at: i - 1)
            }
        }
        
        pdfDoc.write(to: pdfURL)
        return pdfURL
    }
    
    private func createTestImage(size: CGSize = CGSize(width: 200, height: 200), color: NSColor = .blue, in directory: URL, name: String = UUID().uuidString + ".png") throws -> URL {
        let imageURL = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: size.width, height: size.height))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ConversionError.engineExecutionFailed("Failed to create test image", underlyingError: nil)
        }
        
        try pngData.write(to: imageURL)
        return imageURL
    }
    
    // MARK: - Page Range Parser Tests
    
    @Test("PageRangeParser: Valid Single & Range Inputs")
    func testPageRangeParserValid() {
        #expect(PageRangeParser.parse("1", maxPages: 5) == [1])
        #expect(PageRangeParser.parse("1-5", maxPages: 5) == [1, 2, 3, 4, 5])
        #expect(PageRangeParser.parse("1,3,5", maxPages: 5) == [1, 3, 5])
        #expect(PageRangeParser.parse("1-3,7,9-11", maxPages: 15) == [1, 2, 3, 7, 9, 10, 11])
        #expect(PageRangeParser.parse("  1 - 3 , 5 , 8 - 10  ", maxPages: 12) == [1, 2, 3, 5, 8, 9, 10])
    }
    
    @Test("PageRangeParser: Invalid & Edge Case Inputs")
    func testPageRangeParserInvalid() {
        #expect(PageRangeParser.parse("0", maxPages: 5) == [])
        #expect(PageRangeParser.parse("-1", maxPages: 5) == [])
        #expect(PageRangeParser.parse("abc", maxPages: 5) == [])
        #expect(PageRangeParser.parse("1--", maxPages: 5) == [])
        #expect(PageRangeParser.parse("", maxPages: 5) == [])
        #expect(PageRangeParser.parse("   ", maxPages: 5) == [])
        #expect(PageRangeParser.parse("10-20", maxPages: 5) == [])
    }
    
    @Test("PageRangeParser: Reversed Ranges, Duplicates & Order Preservation")
    func testPageRangeParserReversedAndDuplicates() {
        // Reversed range "5-2" is safely handled as 2...5
        #expect(PageRangeParser.parse("5-2", maxPages: 5) == [2, 3, 4, 5])
        // Duplicate removal
        #expect(PageRangeParser.parse("1-3,2,5", maxPages: 5) == [1, 2, 3, 5])
        // Custom order preservation for reordering/extracting
        #expect(PageRangeParser.parse("5, 2, 4", maxPages: 5) == [5, 2, 4])
        #expect(PageRangeParser.parse("3, 1, 2", maxPages: 3) == [3, 1, 2])
    }
    
    // MARK: - PDFToolboxEngine Operations Tests
    
    @Test("PDF Toolbox: Merge PDFs")
    func testPDFMerge() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf1 = createTestPDF(pages: 3, in: tempDir, name: "doc1.pdf")
        let pdf2 = createTestPDF(pages: 2, in: tempDir, name: "doc2.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "merge"
        
        let result = try await engine.convert(
            inputs: [pdf1, pdf2],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let mergedDoc = PDFDocument(url: result.outputURL)
        #expect(mergedDoc != nil)
        #expect(mergedDoc?.pageCount == 5)
    }
    
    @Test("PDF Toolbox: Split Every Page")
    func testPDFSplitEveryPage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 5, in: tempDir, name: "split5.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "splitEveryPage"
        
        let result = try await engine.convert(
            inputs: [pdf],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let allURLs = result.allOutputURLs
        #expect(allURLs.count == 5)
        for url in allURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
            let doc = PDFDocument(url: url)
            #expect(doc?.pageCount == 1)
        }
    }
    
    @Test("PDF Toolbox: Split by Ranges")
    func testPDFSplitRanges() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 5, in: tempDir, name: "ranges5.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "splitRanges"
        options.customOptions["pdf_pages"] = "1-2, 3-5"
        
        let result = try await engine.convert(
            inputs: [pdf],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let allURLs = result.allOutputURLs
        #expect(allURLs.count == 2)
        
        let docPart1 = PDFDocument(url: allURLs[0])
        #expect(docPart1?.pageCount == 2)
        
        let docPart2 = PDFDocument(url: allURLs[1])
        #expect(docPart2?.pageCount == 3)
    }
    
    @Test("PDF Toolbox: Extract Pages")
    func testPDFExtract() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 5, in: tempDir, name: "extract5.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "extract"
        options.customOptions["pdf_pages"] = "5, 2, 4"
        
        let result = try await engine.convert(
            inputs: [pdf],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let extractedDoc = PDFDocument(url: result.outputURL)
        #expect(extractedDoc?.pageCount == 3)
    }
    
    @Test("PDF Toolbox: Delete Pages")
    func testPDFDelete() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 5, in: tempDir, name: "delete5.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "delete"
        options.customOptions["pdf_pages"] = "2, 4"
        
        let result = try await engine.convert(
            inputs: [pdf],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let remainingDoc = PDFDocument(url: result.outputURL)
        #expect(remainingDoc?.pageCount == 3)
    }
    
    @Test("PDF Toolbox: Reorder Pages")
    func testPDFReorder() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 5, in: tempDir, name: "reorder5.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "reorder"
        options.customOptions["pdf_pages"] = "5, 1, 3, 2, 4"
        
        let result = try await engine.convert(
            inputs: [pdf],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let reorderedDoc = PDFDocument(url: result.outputURL)
        #expect(reorderedDoc?.pageCount == 5)
    }
    
    @Test("PDF Toolbox: Rotate Pages (90, 180, 270)")
    func testPDFRotate() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 3, in: tempDir, name: "rotate3.pdf")
        let engine = PDFToolboxEngine()
        
        for deg in [90, 180, 270] {
            var options = ConversionOptions.default
            options.customOptions["pdf_operation"] = "rotate"
            options.customOptions["pdf_rotation"] = "\(deg)"
            
            let result = try await engine.convert(
                inputs: [pdf],
                to: .pdf,
                outputDirectory: tempDir,
                options: options,
                progress: { _ in }
            )
            
            #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
            let rotatedDoc = PDFDocument(url: result.outputURL)
            #expect(rotatedDoc != nil)
            #expect(rotatedDoc?.pageCount == 3)
            #expect(rotatedDoc?.page(at: 0)?.rotation == deg)
        }
    }
    
    @Test("PDF Toolbox: Compress PDF")
    func testPDFCompress() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 3, pageSize: CGSize(width: 800, height: 1000), in: tempDir, name: "compress3.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "compress"
        
        let result = try await engine.convert(
            inputs: [pdf],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let compressedDoc = PDFDocument(url: result.outputURL)
        #expect(compressedDoc != nil)
        #expect(compressedDoc?.pageCount == 3)
    }
    
    @Test("PDF Toolbox: PDF to Images (PNG & JPG)")
    func testPDFToImages() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf = createTestPDF(pages: 3, in: tempDir, name: "pdfToImg3.pdf")
        let engine = PDFToolboxEngine()
        
        // PDF to PNG
        var pngOpts = ConversionOptions.default
        pngOpts.customOptions["pdf_operation"] = "pdfToImages"
        let pngResult = try await engine.convert(
            inputs: [pdf],
            to: .png,
            outputDirectory: tempDir,
            options: pngOpts,
            progress: { _ in }
        )
        #expect(pngResult.allOutputURLs.count == 3)
        for u in pngResult.allOutputURLs {
            #expect(FileManager.default.fileExists(atPath: u.path))
            #expect(u.pathExtension.lowercased() == "png")
        }
        
        // PDF to JPG
        var jpgOpts = ConversionOptions.default
        jpgOpts.customOptions["pdf_operation"] = "pdfToImages"
        let jpgResult = try await engine.convert(
            inputs: [pdf],
            to: .jpg,
            outputDirectory: tempDir,
            options: jpgOpts,
            progress: { _ in }
        )
        #expect(jpgResult.allOutputURLs.count == 3)
        for u in jpgResult.allOutputURLs {
            #expect(FileManager.default.fileExists(atPath: u.path))
            #expect(u.pathExtension.lowercased() == "jpg")
        }
    }
    
    @Test("PDF Toolbox: Images to PDF")
    func testImagesToPDF() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let img1 = try createTestImage(color: .red, in: tempDir, name: "img1.png")
        let img2 = try createTestImage(color: .green, in: tempDir, name: "img2.png")
        let img3 = try createTestImage(color: .blue, in: tempDir, name: "img3.png")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "imagesToPDF"
        
        let result = try await engine.convert(
            inputs: [img1, img2, img3],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let doc = PDFDocument(url: result.outputURL)
        #expect(doc != nil)
        #expect(doc?.pageCount == 3)
    }
    
    @Test("PDF Toolbox: Engine Resolution & Queue Execution")
    @MainActor
    func testPDFToolboxQueueIntegration() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let pdf1 = createTestPDF(pages: 2, in: tempDir, name: "q1.pdf")
        let pdf2 = createTestPDF(pages: 3, in: tempDir, name: "q2.pdf")
        
        let registry = ConversionRegistry.shared
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(conversionManager: manager)
        
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "merge"
        
        let job = ConversionJob(
            inputURLs: [pdf1, pdf2],
            inputFormat: .pdf,
            outputFormat: .pdf,
            outputDirectory: tempDir,
            options: options
        )
        
        queue.enqueue(job: job)
        
        var attempts = 0
        while queue.isProcessing && attempts < 100 {
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        
        #expect(queue.completedCount == 1)
        #expect(queue.failedCount == 0)
    }
}

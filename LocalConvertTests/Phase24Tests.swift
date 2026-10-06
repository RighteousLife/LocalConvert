import Foundation
import Testing
import PDFKit
import CoreGraphics
import CoreText
import AppKit
@testable import LocalConvert

@Suite("Phase 24 — PDF 4-Up / Separate Pages Tests")
struct Phase24Tests {
    
    // MARK: - Test Fixture Generator
    
    private func createMultiUpPDF(
        pagesConfiguration: [Int], // e.g. [4, 4, 3]
        pageSize: CGSize = CGSize(width: 800, height: 600),
        in directory: URL,
        name: String = "multiup.pdf"
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create test PDF context", underlyingError: nil)
        }
        
        var globalSlideNumber = 1
        let layout = PDFGridLayout.twoByTwo
        
        for count in pagesConfiguration {
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            
            // White background
            context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            context.fill(mediaBox)
            
            let cellRects = layout.cellRects(for: mediaBox)
            for (cellIndex, cellRect) in cellRects.enumerated() {
                if cellIndex < count {
                    // Draw card container
                    let insetRect = cellRect.insetBy(dx: 15, dy: 15)
                    context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 0.15))
                    context.fill(insetRect)
                    
                    // Draw text string
                    let str = "Slide \(globalSlideNumber)"
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.boldSystemFont(ofSize: 22),
                        .foregroundColor: NSColor.black
                    ]
                    let attrStr = NSAttributedString(string: str, attributes: attrs)
                    
                    let line = CTLineCreateWithAttributedString(attrStr)
                    context.saveGState()
                    context.textPosition = CGPoint(x: cellRect.minX + 30, y: cellRect.minY + cellRect.height / 2)
                    CTLineDraw(line, context)
                    context.restoreGState()
                    
                    globalSlideNumber += 1
                }
                // When cellIndex >= count, leave quadrant completely blank/white
            }
            
            context.endPDFPage()
        }
        
        context.closePDF()
        return url
    }
    
    // MARK: - 1. Grid Geometry & Layout Tests
    
    @Test("PDFGridLayout: Generates correct 2x2 cell geometry in reading order")
    func testGridLayoutGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let layout = PDFGridLayout.twoByTwo
        let cells = layout.cellRects(for: bounds)
        
        #expect(cells.count == 4)
        
        // 1. Top-Left: x=0, y=300, w=400, h=300
        #expect(cells[0] == CGRect(x: 0, y: 300, width: 400, height: 300))
        
        // 2. Top-Right: x=400, y=300, w=400, h=300
        #expect(cells[1] == CGRect(x: 400, y: 300, width: 400, height: 300))
        
        // 3. Bottom-Left: x=0, y=0, w=400, h=300
        #expect(cells[2] == CGRect(x: 0, y: 0, width: 400, height: 300))
        
        // 4. Bottom-Right: x=400, y=0, w=400, h=300
        #expect(cells[3] == CGRect(x: 400, y: 0, width: 400, height: 300))
    }
    
    // MARK: - 2. 4+4+3 Separation Tests
    
    @Test("Separate Pages: 4+4+3 layout correctly produces 11 individual pages skipping 12th empty cell")
    func testSeparatePages4plus4plus3() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4, 4, 3], in: tempDir, name: "lecture_443.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 11)
        
        // Verify dimensions of extracted pages (400 x 300 pt)
        if let firstPage = outputDoc.page(at: 0) {
            let bounds = firstPage.bounds(for: .mediaBox)
            #expect(bounds.width == 400)
            #expect(bounds.height == 300)
        }
    }
    
    // MARK: - 3. 4+4+4 Separation Tests
    
    @Test("Separate Pages: 4+4+4 layout produces 12 pages")
    func testSeparatePages4plus4plus4() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4, 4, 4], in: tempDir, name: "lecture_444.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 12)
    }
    
    // MARK: - 4. 4+3 Separation Tests
    
    @Test("Separate Pages: 4+3 layout produces 7 pages")
    func testSeparatePages4plus3() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4, 3], in: tempDir, name: "lecture_43.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 7)
    }
    
    // MARK: - 5. Empty Cell Detection on Single Page
    
    @Test("Separate Pages: Single page with 3 filled cells and 1 empty cell produces 3 pages")
    func testEmptyCellDetectionSinglePage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [3], in: tempDir, name: "single_page_3.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 3)
    }
    
    // MARK: - 6. Portrait vs Landscape Page Geometry
    
    @Test("Separate Pages: Portrait page produces proportional portrait pages")
    func testPortraitPageGeometry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Portrait page: 600 width x 800 height -> each cell 300 x 400
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4], pageSize: CGSize(width: 600, height: 800), in: tempDir, name: "portrait.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL), let page = outputDoc.page(at: 0) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 4)
        let bounds = page.bounds(for: .mediaBox)
        #expect(bounds.width == 300)
        #expect(bounds.height == 400)
    }
    
    @Test("Separate Pages: Landscape page produces proportional landscape pages")
    func testLandscapePageGeometry() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Landscape page: 1000 width x 600 height -> each cell 500 x 300
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4], pageSize: CGSize(width: 1000, height: 600), in: tempDir, name: "landscape.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL), let page = outputDoc.page(at: 0) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 4)
        let bounds = page.bounds(for: .mediaBox)
        #expect(bounds.width == 500)
        #expect(bounds.height == 300)
    }
    
    // MARK: - 7. Text Selectability & Searchability
    
    @Test("Separate Pages: Text is selectable and searchable in output PDF")
    func testTextSelectability() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4, 4, 3], in: tempDir, name: "text_lecture.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 11)
        
        // Check text selection on extracted pages
        if let page1 = outputDoc.page(at: 0) {
            let text = page1.string ?? ""
            #expect(text.contains("Slide 1"))
        }
        
        if let page11 = outputDoc.page(at: 10) {
            let text = page11.string ?? ""
            #expect(text.contains("Slide 11"))
        }
    }
    
    // MARK: - 8. Filename Collision Safety
    
    @Test("Separate Pages: Filename collision creates unique sequential filename")
    func testCollisionSafety() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4], in: tempDir, name: "Notes.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result1 = try await engine.convert(inputs: [inputURL], to: .pdf, outputDirectory: tempDir, options: options, progress: { _ in })
        let result2 = try await engine.convert(inputs: [inputURL], to: .pdf, outputDirectory: tempDir, options: options, progress: { _ in })
        
        #expect(result1.outputURL.lastPathComponent == "Notes_separated.pdf")
        #expect(result2.outputURL.lastPathComponent == "Notes_separated (1).pdf")
        #expect(FileManager.default.fileExists(atPath: result1.outputURL.path))
        #expect(FileManager.default.fileExists(atPath: result2.outputURL.path))
    }
    
    // MARK: - 9. All-Empty PDF Error Handling
    
    @Test("Separate Pages: All-empty PDF throws descriptive error")
    func testAllEmptyPDFThrowsError() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Blank PDF with 2 pages and 0 filled cells
        let inputURL = try createMultiUpPDF(pagesConfiguration: [0, 0], in: tempDir, name: "blank.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        await #expect(throws: ConversionError.self) {
            try await engine.convert(inputs: [inputURL], to: .pdf, outputDirectory: tempDir, options: options, progress: { _ in })
        }
    }
    
    // MARK: - 10. Cancellation Handling
    
    @Test("Separate Pages: Task cancellation terminates process early")
    func testCancellationHandling() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4, 4, 4, 4, 4], in: tempDir, name: "large_lecture.pdf")
        let engine = PDFToolboxEngine()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let task = Task {
            try await engine.convert(
                inputs: [inputURL],
                to: .pdf,
                outputDirectory: tempDir,
                options: options,
                progress: { _ in }
            )
        }
        
        task.cancel()
        
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
    
    // MARK: - 11. Raster Image Slide PDF Tests
    
    @Test("Separate Pages: Raster image slide PDF separates into distinct pages")
    func testSeparatePagesWithRasterSlideImages() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let url = tempDir.appendingPathComponent("raster_multiup.pdf")
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: 800, height: 600))
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create test PDF context", underlyingError: nil)
        }
        
        // Create a 4+3 (7 slides) PDF using raster image drawing in quadrants
        let layout = PDFGridLayout.twoByTwo
        
        for (pageIdx, slideCount) in [4, 3].enumerated() {
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            context.fill(mediaBox)
            
            let cellRects = layout.cellRects(for: mediaBox)
            for (cellIdx, cellRect) in cellRects.enumerated() {
                if cellIdx < slideCount {
                    // Draw a sample raster bitmap inside the cell
                    let bmpWidth = 100
                    let bmpHeight = 75
                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    if let bmpCtx = CGContext(data: nil, width: bmpWidth, height: bmpHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        bmpCtx.setFillColor(CGColor(red: CGFloat(pageIdx) * 0.4 + 0.2, green: CGFloat(cellIdx) * 0.2 + 0.1, blue: 0.8, alpha: 1.0))
                        bmpCtx.fill(CGRect(x: 0, y: 0, width: bmpWidth, height: bmpHeight))
                        if let img = bmpCtx.makeImage() {
                            context.draw(img, in: cellRect.insetBy(dx: 20, dy: 20))
                        }
                    }
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let result = try await engine.convert(
            inputs: [url],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let outputDoc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load output PDF")
            return
        }
        
        #expect(outputDoc.pageCount == 7)
    }
    
    // MARK: - 12. ConversionManager Integration Tests
    
    @Test("Separate Pages: ConversionManager executes separatePages job successfully")
    @MainActor
    func testConversionManagerSeparatePagesExecution() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createMultiUpPDF(pagesConfiguration: [4, 4, 3], in: tempDir, name: "lecture_mgr.pdf")
        let manager = ConversionManager()
        
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "separatePages"
        
        let job = ConversionJob(
            inputURLs: [inputURL],
            inputFormat: .pdf,
            outputFormat: .pdf,
            outputDirectory: tempDir,
            options: options
        )
        
        let result: ConversionResult = try await withCheckedThrowingContinuation { continuation in
            manager.submit(job: job) { status in
                switch status {
                case .completed(let res):
                    continuation.resume(returning: res)
                case .failed(let err):
                    continuation.resume(throwing: err)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .waiting, .converting:
                    break
                }
            }
        }
        
        guard let doc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load PDF generated through ConversionManager")
            return
        }
        
        #expect(doc.pageCount == 11)
        #expect(result.outputURL.lastPathComponent == "lecture_mgr_separated.pdf")
    }
}

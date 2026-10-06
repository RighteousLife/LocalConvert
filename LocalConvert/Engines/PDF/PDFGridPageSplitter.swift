import Foundation
import PDFKit
import CoreGraphics
import AppKit
import os.log

// MARK: - PDF Grid Layout

struct PDFGridLayout: Sendable, Equatable {
    let rows: Int
    let columns: Int
    
    static let twoByTwo = PDFGridLayout(rows: 2, columns: 2)
    
    init(rows: Int = 2, columns: Int = 2) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
    }
    
    /// Returns cell rectangles for a given page bounds in standard reading order:
    /// Top-Left -> Top-Right -> Bottom-Left -> Bottom-Right.
    /// In PDF page coordinates: Y=0 is at bottom, Y=max is at top.
    func cellRects(for pageBounds: CGRect) -> [CGRect] {
        let cellWidth = pageBounds.width / CGFloat(columns)
        let cellHeight = pageBounds.height / CGFloat(rows)
        
        var rects: [CGRect] = []
        rects.reserveCapacity(rows * columns)
        
        // Reading order: from top row down to bottom row
        for r in 0..<rows {
            let y = pageBounds.minY + CGFloat(rows - 1 - r) * cellHeight
            for c in 0..<columns {
                let x = pageBounds.minX + CGFloat(c) * cellWidth
                rects.append(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
            }
        }
        return rects
    }
}

// MARK: - PDF Grid Split Result

struct PDFGridSplitResult: Sendable {
    let totalPhysicalPages: Int
    let extractedPagesCount: Int
    let skippedEmptyCellsCount: Int
    let outputURL: URL
    let isVectorPreserved: Bool
}

// MARK: - PDF Grid Page Splitter

enum PDFGridPageSplitter {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "PDFGridPageSplitter")
    
    /// Splits multi-up PDF pages (e.g. 2x2 grid) into individual sequential PDF pages, automatically detecting and skipping empty cells.
    static func split(
        input: URL,
        outputURL: URL,
        layout: PDFGridLayout = .twoByTwo,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFGridSplitResult {
        
        try Task.checkCancellation()
        
        var isSuccess = false
        defer {
            if !isSuccess {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        
        guard let doc = PDFDocument(url: input) else {
            throw ConversionError.invalidInput("The PDF file could not be opened.")
        }
        
        if doc.isLocked {
            if let pwd = password, !pwd.isEmpty {
                guard doc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF document '\(input.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF file '\(input.lastPathComponent)' is password-protected. Please provide a password.")
            }
        }
        
        let physicalPageCount = doc.pageCount
        guard physicalPageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file contains no pages.")
        }
        
        progress(.determinate(0.05, message: "Analyzing PDF page layout..."))
        
        var cellsToExtract: [ExtractedCell] = []
        var totalEmptySkipped = 0
        
        for pageIndex in 0..<physicalPageCount {
            try Task.checkCancellation()
            
            let progressFraction = 0.05 + 0.45 * (Double(pageIndex) / Double(physicalPageCount))
            progress(.determinate(progressFraction, message: "Detecting content (Page \(pageIndex + 1) of \(physicalPageCount))..."))
            
            guard let page = doc.page(at: pageIndex) else { continue }
            let pageBounds = page.bounds(for: .cropBox)
            guard pageBounds.width > 0, pageBounds.height > 0 else { continue }
            
            let cellRects = layout.cellRects(for: pageBounds)
            
            for cellRect in cellRects {
                let empty = isCellEmpty(page: page, cellRect: cellRect, pageBounds: pageBounds)
                if empty {
                    totalEmptySkipped += 1
                } else {
                    cellsToExtract.append(ExtractedCell(pageIndex: pageIndex, cellRect: cellRect, originalPage: page))
                }
            }
        }
        
        guard !cellsToExtract.isEmpty else {
            throw ConversionError.invalidInput("No separable slide content found in the PDF document.")
        }
        
        logger.info("Found \(cellsToExtract.count) non-empty cells across \(physicalPageCount) physical pages (skipped \(totalEmptySkipped) empty cells).")
        
        try Task.checkCancellation()
        progress(.determinate(0.55, message: "Creating separate pages PDF..."))
        
        // 1. Primary Vector PDF Creation
        var isVectorPreserved = true
        var writeSuccess = false
        
        do {
            try createVectorPDF(cells: cellsToExtract, outputURL: outputURL, progress: progress)
            
            // Validate generated output
            if let verifyDoc = PDFDocument(url: outputURL), verifyDoc.pageCount == cellsToExtract.count {
                writeSuccess = true
            } else {
                isVectorPreserved = false
            }
        } catch {
            isVectorPreserved = false
        }
        
        // 2. High-Quality 300 DPI Raster Fallback (if vector generation failed)
        if !writeSuccess {
            logger.warning("Vector PDF generation did not succeed. Using high-resolution raster fallback...")
            try Task.checkCancellation()
            try createRasterFallbackPDF(cells: cellsToExtract, outputURL: outputURL, progress: progress)
            isVectorPreserved = false
        }
        
        try Task.checkCancellation()
        progress(.determinate(1.0, message: "Complete"))
        
        isSuccess = true
        
        return PDFGridSplitResult(
            totalPhysicalPages: physicalPageCount,
            extractedPagesCount: cellsToExtract.count,
            skippedEmptyCellsCount: totalEmptySkipped,
            outputURL: outputURL,
            isVectorPreserved: isVectorPreserved
        )
    }
    
    // MARK: - Extracted Cell Model
    
    struct ExtractedCell: @unchecked Sendable {
        let pageIndex: Int
        let cellRect: CGRect
        let originalPage: PDFPage
    }
    
    // MARK: - Vector PDF Generation
    
    private static func createVectorPDF(
        cells: [ExtractedCell],
        outputURL: URL,
        progress: @Sendable (ConversionProgress) -> Void
    ) throws {
        guard let firstCell = cells.first else {
            throw ConversionError.invalidInput("No cells to write")
        }
        
        let cellRect = firstCell.cellRect
        var initialMediaBox = CGRect(x: 0, y: 0, width: cellRect.width, height: cellRect.height)
        guard let pdfContext = CGContext(outputURL as CFURL, mediaBox: &initialMediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create PDF rendering context for \(outputURL.lastPathComponent).", underlyingError: nil)
        }
        
        let totalCells = cells.count
        
        for (index, cell) in cells.enumerated() {
            try Task.checkCancellation()
            
            let prog = 0.55 + 0.40 * (Double(index) / Double(totalCells))
            progress(.determinate(prog, message: "Extracting page \(index + 1) of \(totalCells)..."))
            
            let rect = cell.cellRect
            let page = cell.originalPage
            
            var pageMediaBox = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: NSData(bytes: &pageMediaBox, length: MemoryLayout<CGRect>.size)
            ]
            
            pdfContext.beginPDFPage(pageInfo as CFDictionary)
            pdfContext.saveGState()
            
            // Clip to target cell size
            pdfContext.clip(to: pageMediaBox)
            
            // Translate origin so cellRect is drawn at (0, 0)
            pdfContext.translateBy(x: -rect.origin.x, y: -rect.origin.y)
            
            // Draw original PDF page vectors and text
            page.draw(with: .cropBox, to: pdfContext)
            
            pdfContext.restoreGState()
            pdfContext.endPDFPage()
        }
        
        pdfContext.closePDF()
    }
    
    // MARK: - High-Resolution Raster Fallback Generation (300 DPI)
    
    private static func createRasterFallbackPDF(
        cells: [ExtractedCell],
        outputURL: URL,
        progress: @Sendable (ConversionProgress) -> Void
    ) throws {
        let outDoc = PDFDocument()
        let dpi: CGFloat = 300.0
        let scale: CGFloat = dpi / 72.0
        let totalCells = cells.count
        
        for (index, cell) in cells.enumerated() {
            try Task.checkCancellation()
            
            let prog = 0.55 + 0.40 * (Double(index) / Double(totalCells))
            progress(.determinate(prog, message: "Rendering crisp page \(index + 1) of \(totalCells)..."))
            
            let rect = cell.cellRect
            let page = cell.originalPage
            
            let pixelWidth = max(1, Int(rect.width * scale))
            let pixelHeight = max(1, Int(rect.height * scale))
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let bitmapCtx = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            
            bitmapCtx.setFillColor(.white)
            bitmapCtx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            
            bitmapCtx.scaleBy(x: scale, y: scale)
            bitmapCtx.translateBy(x: -rect.origin.x, y: -rect.origin.y)
            
            page.draw(with: .cropBox, to: bitmapCtx)
            
            if let image = bitmapCtx.makeImage() {
                let nsImage = NSImage(cgImage: image, size: NSSize(width: rect.width, height: rect.height))
                if let newPage = PDFPage(image: nsImage) {
                    outDoc.insert(newPage, at: outDoc.pageCount)
                }
            }
        }
        
        guard outDoc.pageCount > 0, outDoc.write(to: outputURL) else {
            throw ConversionError.engineExecutionFailed("Failed to write raster fallback PDF.", underlyingError: nil)
        }
    }
    
    // MARK: - Content Detection Algorithm
    
    /// Tests if a cell contains meaningful visual content vs empty/blank background.
    static func isCellEmpty(
        page: PDFPage,
        cellRect: CGRect,
        pageBounds: CGRect
    ) -> Bool {
        // Inset test region by 7-8% so global page headers/footers and border lines outside slide area do not cause false positives
        let contentTestRect = cellRect.insetBy(
            dx: max(8, cellRect.width * 0.07),
            dy: max(10, cellRect.height * 0.08)
        )
        
        // Fast path 1: If there's extractable text in this content-tested cell rectangle, it is definitely not empty
        if let pageText = page.selection(for: contentTestRect)?.string,
           !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        
        // Fast path 2: Pixel-level raster analysis at 72 DPI (fast, accurate, universal for images/vectors/text)
        let testScale: CGFloat = 1.0
        let testWidth = max(8, Int(cellRect.width * testScale))
        let testHeight = max(8, Int(cellRect.height * testScale))
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = testWidth * 4
        
        guard let ctx = CGContext(
            data: nil,
            width: testWidth,
            height: testHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // Conservative fallback: if context creation fails, don't drop the cell
            return false
        }
        
        // Fill canvas with pure white
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: testWidth, height: testHeight))
        
        // Render cell region
        ctx.scaleBy(x: testScale, y: testScale)
        ctx.translateBy(x: -cellRect.origin.x, y: -cellRect.origin.y)
        page.draw(with: .cropBox, to: ctx)
        
        guard let pixelData = ctx.data else {
            return false
        }
        
        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: testWidth * testHeight * 4)
        
        // Sample corners to determine the dominant background color (supports white, light gray, dark slides)
        let sampleCorners = [
            0, // top-left
            (testWidth - 1) * 4, // top-right
            ((testHeight - 1) * testWidth) * 4, // bottom-left
            ((testHeight - 1) * testWidth + testWidth - 1) * 4 // bottom-right
        ]
        
        var bgR: Double = 0
        var bgG: Double = 0
        var bgB: Double = 0
        var bgCount = 0
        
        for offset in sampleCorners {
            if offset + 3 < testWidth * testHeight * 4 {
                bgR += Double(buffer[offset])
                bgG += Double(buffer[offset + 1])
                bgB += Double(buffer[offset + 2])
                bgCount += 1
            }
        }
        
        if bgCount > 0 {
            bgR /= Double(bgCount)
            bgG /= Double(bgCount)
            bgB /= Double(bgCount)
        } else {
            bgR = 255; bgG = 255; bgB = 255
        }
        
        // Inset test area by 7-8% to ignore outer border lines, crop marks, and grid divider bleeds
        let minX = Int(Double(testWidth) * 0.07)
        let maxX = Int(Double(testWidth) * 0.93)
        let minY = Int(Double(testHeight) * 0.08)
        let maxY = Int(Double(testHeight) * 0.92)
        
        var contentPixelCount = 0
        var testedPixelCount = 0
        
        for y in minY..<maxY {
            let rowOffset = y * bytesPerRow
            for x in minX..<maxX {
                let pixelOffset = rowOffset + x * 4
                let r = Double(buffer[pixelOffset])
                let g = Double(buffer[pixelOffset + 1])
                let b = Double(buffer[pixelOffset + 2])
                let a = Double(buffer[pixelOffset + 3])
                
                testedPixelCount += 1
                
                if a < 20 {
                    continue // Transparent
                }
                
                // Euclidean distance from background
                let deltaR = r - bgR
                let deltaG = g - bgG
                let deltaB = b - bgB
                let distance = sqrt(deltaR * deltaR + deltaG * deltaG + deltaB * deltaB)
                
                if distance > 28.0 {
                    contentPixelCount += 1
                }
            }
        }
        
        guard testedPixelCount > 0 else { return false }
        
        let ratio = Double(contentPixelCount) / Double(testedPixelCount)
        
        // If content pixel count is >= 15 and at least 0.04% of tested pixels, it has meaningful content
        let hasContent = contentPixelCount >= 15 && ratio >= 0.0004
        
        return !hasContent
    }
}

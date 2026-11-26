import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - Office Engine Provider Protocol

protocol OfficeEngineProvider: Sendable {
    var providerName: String { get }
    func isAvailable() async -> Bool
    func findExecutablePath() async -> String?
    func version() async -> String?
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL
}

// MARK: - Bounded LibreOffice Process Limiter

actor LibreOfficeProcessLimiter {
    static let shared = LibreOfficeProcessLimiter(limit: 2)

    private let limit: Int
    private var activeCount: Int = 0
    private(set) var peakObservedConcurrency: Int = 0

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(limit: Int = 2) {
        self.limit = max(1, limit)
    }

    var currentActiveCount: Int {
        activeCount
    }

    func resetMetrics() {
        peakObservedConcurrency = activeCount
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            if activeCount > peakObservedConcurrency {
                peakObservedConcurrency = activeCount
            }
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if activeCount < limit {
                    activeCount += 1
                    if activeCount > peakObservedConcurrency {
                        peakObservedConcurrency = activeCount
                    }
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }
}

// MARK: - Base LibreOffice Provider

class BaseLibreOfficeProvider: OfficeEngineProvider, @unchecked Sendable {
    
    var providerName: String { "Base LibreOffice" }
    
    let logger = Logger(subsystem: "com.localconvert.app", category: "LibreOfficeProvider")
    
    // MARK: - Executable Resolution (Subclasses must override)
    
    func findExecutablePath() async -> String? {
        nil
    }
    
    func isAvailable() async -> Bool {
        await findExecutablePath() != nil
    }
    
    /// Retrieves LibreOffice version string for diagnostics
    func version() async -> String? {
        guard let path = await findExecutablePath() else { return nil }
        
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            var env = ProcessInfo.processInfo.environment
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            process.environment = env
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.components(separatedBy: .newlines).first
        } catch {
            logger.error("Failed to query LibreOffice version: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    static func userInstallationArgument(for profileDirectoryURL: URL) -> String {
        "-env:UserInstallation=\(profileDirectoryURL.absoluteString)"
    }

    struct PreparedEditablePDFSource: Sendable {
        let sourceURL: URL
        let cleanupDirectory: URL?
    }

    /// Writes an unencrypted temporary PDF inside `tempRoot` when the input PDF was locked or encrypted,
    /// stripping PDFKit `/Encrypt` trailer state by copying unlocked pages into a fresh `PDFDocument`.
    static func prepareUnlockedPDFForLibreOffice(
        input: URL,
        pdfDoc: PDFDocument,
        wasEncrypted: Bool,
        baseName: String,
        in tempRoot: URL
    ) throws -> PreparedEditablePDFSource {
        guard wasEncrypted else {
            return PreparedEditablePDFSource(sourceURL: input, cleanupDirectory: nil)
        }

        let unlockedDir = tempRoot.appendingPathComponent("unlocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unlockedDir, withIntermediateDirectories: true)
        let unlockedURL = unlockedDir.appendingPathComponent("\(baseName).pdf")

        let freshDoc = PDFDocument()
        for pageIndex in 0..<pdfDoc.pageCount {
            if let page = pdfDoc.page(at: pageIndex) {
                freshDoc.insert(page, at: freshDoc.pageCount)
            }
        }
        if let attrs = pdfDoc.documentAttributes {
            freshDoc.documentAttributes = attrs
        }

        guard freshDoc.write(to: unlockedURL) else {
            try? FileManager.default.removeItem(at: unlockedDir)
            throw ConversionError.engineExecutionFailed(
                "Failed to prepare unlocked temporary PDF for Office conversion.",
                underlyingError: nil
            )
        }

        guard let verifiedDoc = PDFDocument(url: unlockedURL),
              !verifiedDoc.isLocked,
              !verifiedDoc.isEncrypted,
              verifiedDoc.pageCount == pdfDoc.pageCount else {
            try? FileManager.default.removeItem(at: unlockedDir)
            throw ConversionError.engineExecutionFailed(
                "Prepared temporary PDF remained locked or unreadable.",
                underlyingError: nil
            )
        }

        return PreparedEditablePDFSource(sourceURL: unlockedURL, cleanupDirectory: unlockedDir)
    }

    /// Opens, unlocks, and prepares an unencrypted temporary PDF inside `tempRoot` when needed.
    static func prepareUnlockedEditablePDF(
        at input: URL,
        options: ConversionOptions,
        in tempRoot: URL
    ) throws -> PreparedEditablePDFSource {
        guard let pdfDoc = PDFDocument(url: input) else {
            throw ConversionError.invalidInput("The PDF file could not be opened. It may be corrupted or invalid.")
        }

        let wasEncryptedOrLocked = pdfDoc.isLocked || pdfDoc.isEncrypted
        if pdfDoc.isLocked {
            if let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
                guard pdfDoc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF document.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF file is password-protected. Please unlock or decrypt the document before converting.")
            }
        } else if wasEncryptedOrLocked, let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
            _ = pdfDoc.unlock(withPassword: pwd)
        }

        guard pdfDoc.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file does not contain any pages.")
        }

        let baseName = input.deletingPathExtension().lastPathComponent
        return try prepareUnlockedPDFForLibreOffice(
            input: input,
            pdfDoc: pdfDoc,
            wasEncrypted: wasEncryptedOrLocked,
            baseName: baseName,
            in: tempRoot
        )
    }

    // MARK: - Conversion Execution
    
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions = .default,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL {
        guard let sofficePath = await findExecutablePath() else {
            throw ConversionError.engineNotAvailable(
                "LibreOffice is required for Office document conversion. Please install LibreOffice or verify the bundled runtime."
            )
        }
        
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }
        
        progress(.determinate(0.1, message: "Preparing conversion environment..."))
        
        // Create an isolated temporary directory containing a sandbox user profile and scratch output dir
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Office-\(UUID().uuidString)")
        let tempProfile = tempRoot.appendingPathComponent("profile")
        let tempOut = tempRoot.appendingPathComponent("out")
        
        try FileManager.default.createDirectory(at: tempProfile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempOut, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        
        try Task.checkCancellation()
        
        // Determine if this is a PDF input requiring special handling
        let isPDFInput = input.pathExtension.lowercased() == "pdf"
        
        if isPDFInput {
            return try await convertPDF(
                input: input,
                to: outputFormat,
                outputDirectory: outputDirectory,
                options: options,
                progress: progress,
                sofficePath: sofficePath,
                tempRoot: tempRoot,
                tempOut: tempOut,
                tempProfile: tempProfile
            )
        }
        
        // Non-PDF: standard Office/Document conversion via LibreOffice
        let libreOfficeFormat = libreOfficeFormatName(for: outputFormat)
        let inputExt = input.pathExtension.lowercased()
        
        var args: [String] = [
            Self.userInstallationArgument(for: tempProfile),
            "--headless",
            "--norestore",
            "--nolockcheck"
        ]
        // HTML requires Writer import filter to unlock DOCX/DOC/RTF/EPUB/MD exports
        if (inputExt == "html" || inputExt == "htm" || inputExt == "xhtml"),
           [FileFormat.docx, .doc, .dotx, .rtf, .epub, .md, .txt].contains(outputFormat) {
            args.append("--infilter=HTML (StarWriter)")
        }
        args += [
            "--convert-to", libreOfficeFormat,
            "--outdir", tempOut.path,
            input.path
        ]
        
        progress(.determinate(0.3, message: "Converting document with LibreOffice..."))
        
        _ = try await executeProcessWithWatchdog(
            executablePath: sofficePath,
            arguments: args
        )
        
        progress(.determinate(0.8, message: "Verifying output document..."))
        
        let baseName = input.deletingPathExtension().lastPathComponent
        let outputExt = outputFormat.fileExtension
        let generatedTempURL = tempOut.appendingPathComponent("\(baseName).\(outputExt)")
        
        guard FileManager.default.fileExists(atPath: generatedTempURL.path) else {
            throw ConversionError.engineExecutionFailed(
                "Conversion finished, but output file was not created by LibreOffice.",
                underlyingError: nil
            )
        }
        
        // Validate generated output integrity before overwriting or finalizing the destination
        try await validateGeneratedDocument(at: generatedTempURL, format: outputFormat)
        
        let finalOutput = try ConversionManager.finalizeOutputFile(
            from: generatedTempURL,
            for: input,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )
        
        progress(.determinate(1.0, message: "Complete"))
        logger.info("Office conversion succeeded: \(input.lastPathComponent) -> \(finalOutput.lastPathComponent)")
        
        return finalOutput
    }
    
    /// Handles PDF → Office conversions using appropriate LibreOffice import filters
    private func convertPDF(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions = .default,
        progress: @Sendable (ConversionProgress) -> Void,
        sofficePath: String,
        tempRoot: URL,
        tempOut: URL,
        tempProfile: URL
    ) async throws -> URL {
        // Validate PDF document before process execution
        guard let pdfDoc = PDFDocument(url: input) else {
            throw ConversionError.invalidInput("The PDF file could not be opened. It may be corrupted or invalid.")
        }
        
        let wasEncryptedOrLocked = pdfDoc.isLocked || pdfDoc.isEncrypted
        if pdfDoc.isLocked {
            if let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
                guard pdfDoc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF document.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF file is password-protected. Please unlock or decrypt the document before converting.")
            }
        } else if wasEncryptedOrLocked, let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
            _ = pdfDoc.unlock(withPassword: pwd)
        }
        
        guard pdfDoc.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file does not contain any pages.")
        }
        
        let baseName = input.deletingPathExtension().lastPathComponent
        let effectivePDFMode = options.effectivePDFOfficeMode
        var unlockedCleanupDir: URL?
        defer {
            if let unlockedCleanupDir {
                try? FileManager.default.removeItem(at: unlockedCleanupDir)
            }
        }
        
        switch outputFormat {
        case .docx:
            if effectivePDFMode == .visual {
                progress(.determinate(0.25, message: "Rendering PDF pages for visual Word layout..."))
                let visualHTML = try renderPDFAsVisualHTML(
                    pdfDoc: pdfDoc,
                    baseName: baseName,
                    dpi: options.effectivePDFDPI,
                    in: tempRoot
                )
                progress(.determinate(0.55, message: "Packaging Word document..."))
                try await runLibreOffice(
                    sofficePath: sofficePath,
                    arguments: [
                        Self.userInstallationArgument(for: tempProfile),
                        "--headless",
                        "--convert-to", "docx:MS Word 2007 XML",
                        "--outdir", tempOut.path,
                        visualHTML.path
                    ]
                )
            } else {
                // PDF → DOCX (.automatic / .editable): Editable flow via writer_pdf_import filter
                let preparedSource = try Self.prepareUnlockedPDFForLibreOffice(
                    input: input,
                    pdfDoc: pdfDoc,
                    wasEncrypted: wasEncryptedOrLocked,
                    baseName: baseName,
                    in: tempRoot
                )
                unlockedCleanupDir = preparedSource.cleanupDirectory
                progress(.determinate(0.3, message: "Converting PDF to editable Word document..."))
                try await runLibreOffice(
                    sofficePath: sofficePath,
                    arguments: [
                        Self.userInstallationArgument(for: tempProfile),
                        "--headless",
                        "--infilter=writer_pdf_import",
                        "--convert-to", "docx",
                        "--outdir", tempOut.path,
                        preparedSource.sourceURL.path
                    ]
                )
            }
            
        case .pptx:
            let pptxSourcePDF: URL
            if effectivePDFMode == .visual {
                progress(.determinate(0.25, message: "Rasterizing PDF pages for visual slide fidelity..."))
                pptxSourcePDF = try renderPDFAsRasterizedPDF(
                    pdfDoc: pdfDoc,
                    baseName: baseName,
                    dpi: options.effectivePDFDPI,
                    in: tempRoot
                )
            } else {
                let preparedSource = try Self.prepareUnlockedPDFForLibreOffice(
                    input: input,
                    pdfDoc: pdfDoc,
                    wasEncrypted: wasEncryptedOrLocked,
                    baseName: baseName,
                    in: tempRoot
                )
                unlockedCleanupDir = preparedSource.cleanupDirectory
                pptxSourcePDF = preparedSource.sourceURL
            }
            // PDF → PPTX: Use impress_pdf_import filter
            progress(.determinate(0.45, message: "Converting PDF to PowerPoint presentation..."))
            try await runLibreOffice(
                sofficePath: sofficePath,
                arguments: [
                    Self.userInstallationArgument(for: tempProfile),
                    "--headless",
                    "--infilter=impress_pdf_import",
                    "--convert-to", "pptx",
                    "--outdir", tempOut.path,
                    pptxSourcePDF.path
                ]
            )
            
        case .xlsx:
            // PDF → XLSX: Extract tabular data/text structure to CSV, then convert via LibreOffice Calc
            progress(.determinate(0.2, message: "Extracting tabular data from PDF..."))
            let csvContent = try extractCSV(from: input, options: options)
            let tempCSV = tempRoot.appendingPathComponent("\(baseName).csv")
            try csvContent.write(to: tempCSV, atomically: true, encoding: .utf8)
            
            progress(.determinate(0.5, message: "Converting to Excel spreadsheet..."))
            try await runLibreOffice(
                sofficePath: sofficePath,
                arguments: [
                    Self.userInstallationArgument(for: tempProfile),
                    "--headless",
                    "--convert-to", "xlsx",
                    "--outdir", tempOut.path,
                    tempCSV.path
                ]
            )
            
        default:
            throw ConversionError.unsupportedConversion(from: .pdf, to: outputFormat)
        }
        
        progress(.determinate(0.8, message: "Verifying output document..."))
        
        // Find the generated output
        let outputExt = outputFormat.fileExtension
        let generatedTempURL = tempOut.appendingPathComponent("\(baseName).\(outputExt)")
        
        guard FileManager.default.fileExists(atPath: generatedTempURL.path) else {
            throw ConversionError.engineExecutionFailed(
                "PDF conversion finished, but the \(outputFormat.displayName) file was not created.",
                underlyingError: nil
            )
        }
        
        // Validate OpenXML structure (ZIP with expected entry)
        try await validateOpenXML(at: generatedTempURL, format: outputFormat)
        
        let finalOutput = try ConversionManager.finalizeOutputFile(
            from: generatedTempURL,
            for: input,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )
        
        progress(.determinate(1.0, message: "Complete"))
        logger.info("PDF → \(outputFormat.rawValue) conversion succeeded: \(input.lastPathComponent) -> \(finalOutput.lastPathComponent)")
        
        return finalOutput
    }

    private func renderPDFAsVisualHTML(
        pdfDoc: PDFDocument,
        baseName: String,
        dpi: Double,
        in directory: URL
    ) throws -> URL {
        let scale = CGFloat(max(dpi, 150.0) / 72.0)
        var imageTags: [String] = []

        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let pixelW = max(1, Int(ceil(bounds.width * scale)))
            let pixelH = max(1, Int(ceil(bounds.height * scale)))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                      data: nil,
                      width: pixelW,
                      height: pixelH,
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                continue
            }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()

            guard let cgImage = ctx.makeImage() else { continue }
            let pngData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(pngData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            guard CGImageDestinationFinalize(dest) else { continue }

            let base64 = (pngData as Data).base64EncodedString()
            let isLast = (pageIndex == pdfDoc.pageCount - 1)
            let style = isLast ? "display:block;width:100%;height:auto;" : "display:block;width:100%;height:auto;page-break-after:always;"
            imageTags.append("<p style=\"margin:0;padding:0;\"><img src=\"data:image/png;base64,\(base64)\" style=\"\(style)\"/></p>")
        }

        let html = """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8"><title>\(baseName)</title></head>
        <body style="margin:0;padding:0;">
        \(imageTags.joined(separator: "\n"))
        </body>
        </html>
        """
        let htmlURL = directory.appendingPathComponent("\(baseName).html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        return htmlURL
    }

    private func renderPDFAsRasterizedPDF(
        pdfDoc: PDFDocument,
        baseName: String,
        dpi: Double,
        in directory: URL
    ) throws -> URL {
        let scale = CGFloat(max(dpi, 150.0) / 72.0)
        let rasterPDFURL = directory.appendingPathComponent("\(baseName).pdf")
        var defaultBox = pdfDoc.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 792, height: 612)
        guard let pdfConsumer = CGDataConsumer(url: rasterPDFURL as CFURL),
              let pdfContext = CGContext(consumer: pdfConsumer, mediaBox: &defaultBox, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ConversionError.engineExecutionFailed("Failed to create rasterized PDF context.", underlyingError: nil)
        }

        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex) else { continue }
            var pageBox = page.bounds(for: .mediaBox)
            let pixelW = max(1, Int(ceil(pageBox.width * scale)))
            let pixelH = max(1, Int(ceil(pageBox.height * scale)))
            guard let imgCtx = CGContext(
                data: nil,
                width: pixelW,
                height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            imgCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            imgCtx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            imgCtx.saveGState()
            imgCtx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: imgCtx)
            imgCtx.restoreGState()
            guard let rendered = imgCtx.makeImage() else { continue }

            pdfContext.beginPDFPage([kCGPDFContextMediaBox: NSData(bytes: &pageBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            pdfContext.draw(rendered, in: CGRect(origin: .zero, size: pageBox.size))
            pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        return rasterPDFURL
    }
    
    /// Extracts text/tabular data from a PDF document into CSV format for spreadsheet conversion
    func extractCSV(from pdfURL: URL, options: ConversionOptions = .default) throws -> String {
        guard let pdfDoc = PDFDocument(url: pdfURL) else {
            throw ConversionError.invalidInput("The PDF file could not be opened. It may be corrupted or invalid.")
        }
        
        if pdfDoc.isLocked {
            if let pwd = options.customOptions["pdf_password"], !pwd.isEmpty {
                guard pdfDoc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF document.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF file is password-protected. Please unlock or decrypt the document before converting.")
            }
        }
        
        guard pdfDoc.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF file does not contain any pages.")
        }
        
        var tableRows: [[String]] = []
        
        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            guard !pageText.isEmpty else { continue }

            let pageRows = Self.extractTabularRows(from: page, text: pageText)
            tableRows.append(contentsOf: pageRows)
        }
        
        if tableRows.isEmpty {
            tableRows.append(["Document Content"])
        }

        let maxColumns = tableRows.map(\.count).max() ?? 1
        let csvLines = tableRows.map { row -> String in
            var padded = row
            if padded.count < maxColumns {
                padded.append(contentsOf: repeatElement("", count: maxColumns - padded.count))
            }
            return padded.map { cell in
                let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }.joined(separator: ",")
        }

        return csvLines.joined(separator: "\n") + "\n"
    }

    private static func extractTabularRows(from page: PDFPage, text: String) -> [[String]] {
        let nsText = text as NSString
        var rows: [[String]] = []
        var location = 0
        let totalLength = nsText.length

        while location < totalLength {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let lineRange = NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
            location = max(location + 1, lineEnd)

            let rawLine = nsText.substring(with: lineRange)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.contains("\t") {
                let cells = splitDelimitedTabs(trimmed)
                rows.append(cells)
                continue
            }

            if hasWideWhitespaceColumns(trimmed) {
                let cells = splitWideWhitespace(trimmed)
                rows.append(cells)
                continue
            }

            if let gapCells = splitUsingSelectionBounds(page: page, nsText: nsText, lineRange: lineRange),
               gapCells.count > 1 {
                rows.append(gapCells)
                continue
            }

            rows.append(splitMixedWordsAndNumbers(trimmed))
        }

        return rows
    }

    private static func splitDelimitedTabs(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func hasWideWhitespaceColumns(_ line: String) -> Bool {
        var spaceRun = 0
        for ch in line {
            if ch == " " {
                spaceRun += 1
                if spaceRun >= 2 { return true }
            } else {
                spaceRun = 0
            }
        }
        return false
    }

    private static func splitWideWhitespace(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var spaceRun = 0

        for ch in line {
            if ch == " " {
                spaceRun += 1
            } else {
                if spaceRun == 1 && !current.isEmpty {
                    current.append(" ")
                } else if spaceRun >= 2 && !current.isEmpty {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
                spaceRun = 0
                current.append(ch)
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty {
            cells.append(trailing)
        }
        return cells.isEmpty ? [line] : cells
    }

    private static func splitUsingSelectionBounds(page: PDFPage, nsText: NSString, lineRange: NSRange) -> [String]? {
        guard lineRange.length >= 2, nsText.length <= 250_000 else { return nil }

        // Tokenize contiguous non-whitespace word runs along this line with their UTF-16 NSRanges
        var tokens: [(text: String, bounds: CGRect)] = []
        let end = lineRange.location + lineRange.length
        var idx = lineRange.location
        while idx < end {
            while idx < end {
                let c = nsText.character(at: idx)
                if c != 0x20 && c != 0x09 { break }
                idx += 1
            }
            let tokStart = idx
            while idx < end {
                let c = nsText.character(at: idx)
                if c == 0x20 || c == 0x09 { break }
                idx += 1
            }
            let tokLen = idx - tokStart
            guard tokLen > 0 else { continue }
            let tokRange = NSRange(location: tokStart, length: tokLen)
            let tokStr = nsText.substring(with: tokRange)
            guard let sel = page.selection(for: tokRange) else { return nil }
            let bounds = sel.bounds(for: page)
            guard bounds.width > 0 && bounds.height > 0 else { return nil }
            tokens.append((tokStr, bounds))
        }

        guard tokens.count > 1 else { return nil }

        var cells: [String] = [tokens[0].text]
        var prevBounds = tokens[0].bounds

        for tok in tokens.dropFirst() {
            let lineHeight = max(prevBounds.height, tok.bounds.height)
            let columnThreshold = max(12.0, lineHeight * 1.1)
            let gap = tok.bounds.minX - prevBounds.maxX
            let sameLine = abs(tok.bounds.midY - prevBounds.midY) <= max(10.0, lineHeight)

            if sameLine && gap > columnThreshold {
                cells.append(tok.text)
            } else if gap < -columnThreshold {
                // Reverse/RTL or wrapped visual segment on the same extracted string line
                cells.append(tok.text)
            } else if let last = cells.last {
                cells[cells.count - 1] = "\(last) \(tok.text)"
            }
            prevBounds = tok.bounds
        }

        return cells
    }

    private static func splitMixedWordsAndNumbers(_ line: String) -> [String] {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return [line] }

        func isNumericToken(_ token: String) -> Bool {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
            guard !trimmed.isEmpty else { return false }
            let hasDigit = trimmed.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
            guard hasDigit else { return false }
            let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "$€£¥₺%+-,./:"))
            return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        let hasNumeric = tokens.contains(where: isNumericToken)
        guard hasNumeric else {
            return [line]
        }

        var cells: [String] = []
        var textRun: [String] = []
        for token in tokens {
            if isNumericToken(token) {
                if !textRun.isEmpty {
                    cells.append(textRun.joined(separator: " "))
                    textRun.removeAll()
                }
                cells.append(token)
            } else {
                textRun.append(token)
            }
        }
        if !textRun.isEmpty {
            cells.append(textRun.joined(separator: " "))
        }
        return cells.isEmpty ? [line] : cells
    }
    
    // MARK: - Subprocess Watchdog & Execution
    
    static let defaultWatchdogTimeout: TimeInterval = 120.0
    
    private struct WatchdogTimeoutError: Error {}
    
    /// Runs a process with an active watchdog timeout and structured task cancellation
    func executeProcessWithWatchdog(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = defaultWatchdogTimeout
    ) async throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        try await LibreOfficeProcessLimiter.shared.acquire()
        let result: ProcessExecutionOutput
        do {
            try Task.checkCancellation()
            result = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: timeout)
            await LibreOfficeProcessLimiter.shared.release()
        } catch let timeoutErr as ProcessTimeoutError {
            await LibreOfficeProcessLimiter.shared.release()
            throw ConversionError.engineExecutionFailed(
                "Office conversion timed out after \(Int(timeoutErr.timeoutSeconds)) seconds. The document may be corrupted or contain hanging macros.",
                underlyingError: "Watchdog timeout exceeded (\(Int(timeout))s)"
            )
        } catch {
            await LibreOfficeProcessLimiter.shared.release()
            throw error
        }

        let outputData = result.stdout
        let errorData = result.stderr

        guard result.terminationStatus == 0 else {
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if outputString.contains("Error:") && outputString.contains("no export filter") {
                throw ConversionError.engineExecutionFailed(
                    "LibreOffice does not support this conversion format combination.",
                    underlyingError: outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            let safeError = errorString ?? "none"
            logger.error("LibreOffice process failed (exit code \(result.terminationStatus)): \(safeError, privacy: .public)")

            throw ConversionError.engineExecutionFailed(
                "The document could not be converted. The file may be corrupted or password-protected.",
                underlyingError: errorString
            )
        }

        return (outputData, errorData)
    }
    
    /// Runs a LibreOffice process with given arguments, watchdog timeout, and waits for completion
    private func runLibreOffice(
        sofficePath: String,
        arguments: [String],
        timeout: TimeInterval = defaultWatchdogTimeout
    ) async throws {
        _ = try await executeProcessWithWatchdog(
            executablePath: sofficePath,
            arguments: arguments,
            timeout: timeout
        )
    }
    
    /// Validates generated Office/PDF/EPUB/text documents for structural integrity.
    private func validateGeneratedDocument(at url: URL, format: FileFormat) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else {
            throw ConversionError.engineExecutionFailed(
                "The converted \(format.displayName) file is empty.",
                underlyingError: nil
            )
        }
        
        if format == .pdf {
            guard let pdfDoc = PDFDocument(url: url), pdfDoc.pageCount > 0 else {
                throw ConversionError.engineExecutionFailed(
                    "The document was converted, but the generated PDF is invalid or unreadable.",
                    underlyingError: nil
                )
            }
            return
        }
        
        if [.doc, .xls, .ppt].contains(format) {
            if let fh = try? FileHandle(forReadingFrom: url),
               let header = try? fh.read(upToCount: 8) {
                try? fh.close()
                let olePrefix: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
                // Legacy RTF-wrapped DOC is occasionally emitted only if empty/weird, normal LO writes OLE2
                if Array(header).starts(with: olePrefix) {
                    return
                }
            }
            // Fallback: verify non-trivial binary payload
            guard size >= 512 else {
                throw ConversionError.engineExecutionFailed(
                    "The generated \(format.displayName) file does not match the legacy binary Office structure.",
                    underlyingError: nil
                )
            }
            return
        }
        
        try await validateOpenXML(at: url, format: format)
    }
    
    /// Validates that a generated file is a valid ZIP archive containing the expected OpenXML/ODF/EPUB entry
    private func validateOpenXML(at url: URL, format: FileFormat) async throws {
        let expectedEntries: [String]
        switch format {
        case .docx, .dotx:
            expectedEntries = ["word/document.xml"]
        case .xlsx, .xltx:
            expectedEntries = ["xl/workbook.xml", "xl/worksheets/sheet"]
        case .pptx, .potx:
            expectedEntries = ["ppt/presentation.xml", "ppt/slides/slide"]
        case .odt, .ods, .odp:
            expectedEntries = ["content.xml", "mimetype"]
        case .epub:
            expectedEntries = ["META-INF/container.xml"]
        default:
            return // No ZIP structure validation needed for non-packaged formats (txt, rtf, html, md, csv, tsv)
        }
        
        // Use /usr/bin/unzip to check for expected entry without pipe buffer deadlock
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", url.path]

        let output = try await AsyncProcessRunner.run(process)
        guard output.terminationStatus == 0 else {
            throw ConversionError.engineExecutionFailed(
                "The generated \(format.displayName) file is not a valid archive.",
                underlyingError: nil
            )
        }
        
        let listing = String(data: output.stdout, encoding: .utf8) ?? ""
        
        for entry in expectedEntries {
            guard listing.contains(entry) else {
                throw ConversionError.engineExecutionFailed(
                    "The generated \(format.displayName) file does not contain the expected content structure.",
                    underlyingError: "Missing entry: \(entry)"
                )
            }
        }
    }
    
    private func libreOfficeFormatName(for format: FileFormat) -> String {
        switch format {
        case .pdf: return "pdf"
        default: return format.fileExtension
        }
    }
}

// MARK: - System LibreOffice Provider

final class SystemLibreOfficeProvider: BaseLibreOfficeProvider, @unchecked Sendable {
    
    override var providerName: String { "System LibreOffice" }
    
    /// Known candidate locations for LibreOffice on macOS
    private var candidatePaths: [String] {
        [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice").path,
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice"
        ]
    }
    
    override func findExecutablePath() async -> String? {
        for path in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // Fallback: check `which soffice`
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = ["soffice"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            logger.debug("soffice not found via which: \(error.localizedDescription, privacy: .public)")
        }
        
        return nil
    }
}

// MARK: - Bundled LibreOffice Provider

final class BundledLibreOfficeProvider: BaseLibreOfficeProvider, @unchecked Sendable {

    let fallbackToSystem: Bool
    let enforceBundledOnly: Bool
    private let systemProvider = SystemLibreOfficeProvider()
    private let environment: [String: String]
    private let bundleCandidatesOverride: [URL]?
    private let isExecutableCheck: @Sendable (String) -> Bool

    convenience init(fallbackToSystem: Bool = false) {
        self.init(
            fallbackToSystem: fallbackToSystem,
            enforceBundledOnly: BundledBinarySecurityPolicy.isReleaseBundledOnly
        )
    }

    init(
        fallbackToSystem: Bool = false,
        enforceBundledOnly: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleCandidatesOverride: [URL]? = nil,
        isExecutableCheck: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.enforceBundledOnly = enforceBundledOnly
        self.fallbackToSystem = enforceBundledOnly ? false : fallbackToSystem
        self.environment = environment
        self.bundleCandidatesOverride = bundleCandidatesOverride
        self.isExecutableCheck = isExecutableCheck
    }

    override var providerName: String {
        "Bundled LibreOffice"
    }

    override func findExecutablePath() async -> String? {
        if let bundledPath = resolveBundledExecutable() {
            return bundledPath
        }
        if !enforceBundledOnly, fallbackToSystem {
            return await systemProvider.findExecutablePath()
        }
        return nil
    }

    /// Resolves the bundled soffice executable path. Release builds strictly inspect bundled app resources only.
    private func resolveBundledExecutable() -> String? {
        let relativeSoffice = "LibreOffice/Contents/MacOS/soffice"

        // 1. ProcessInfo environment override (Debug / test only)
        if !enforceBundledOnly,
           let env = environment["LOCALCONVERT_SOFFICE_PATH"],
           isExecutableCheck(env) {
            return env
        }

        var candidates: [URL] = []
        if let bundleCandidatesOverride {
            candidates = bundleCandidatesOverride
        } else {
            // 2. Standard Bundle.main resources directory
            if let resourceURL = Bundle.main.resourceURL {
                candidates.append(resourceURL.appendingPathComponent(relativeSoffice))
            }

            // 3. Bundle.main.bundleURL Contents/Resources
            candidates.append(
                Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Resources/\(relativeSoffice)")
            )

            // 4. Bundle for this class (useful when executing unit tests)
            let thisBundle = Bundle(for: BundledLibreOfficeProvider.self)
            if let resourceURL = thisBundle.resourceURL {
                candidates.append(resourceURL.appendingPathComponent(relativeSoffice))
                candidates.append(resourceURL.deletingLastPathComponent().appendingPathComponent("Resources/\(relativeSoffice)"))
            }

            // 5. Near executable in app bundle
            if let execURL = Bundle.main.executableURL {
                let appBundleURL = execURL.deletingLastPathComponent().deletingLastPathComponent()
                candidates.append(appBundleURL.appendingPathComponent("Resources/\(relativeSoffice)"))
            }

            // 6-7. Developer/test host fallbacks (Debug / test only)
            if !enforceBundledOnly {
                if let testHost = environment["TEST_HOST"] {
                    let hostURL = URL(fileURLWithPath: testHost)
                    let hostAppURL = hostURL.deletingLastPathComponent().deletingLastPathComponent()
                    candidates.append(hostAppURL.appendingPathComponent("Resources/\(relativeSoffice)"))
                }

                if let srcroot = environment["SRCROOT"] {
                    candidates.append(URL(fileURLWithPath: srcroot).appendingPathComponent("LocalConvert/Resources/\(relativeSoffice)"))
                }
                let sourceDirFallback = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent() // Office
                    .deletingLastPathComponent() // Engines
                    .deletingLastPathComponent() // LocalConvert
                    .appendingPathComponent("Resources/\(relativeSoffice)")
                candidates.append(sourceDirFallback)
            }
        }

        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if isExecutableCheck(path) {
                return path
            }
        }

        return nil
    }
}

// MARK: - Office Conversion Engine

final class OfficeConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "OfficeEngine"
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "OfficeEngine")
    let provider: OfficeEngineProvider
    
    init(provider: OfficeEngineProvider = BundledLibreOfficeProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)) {
        self.provider = provider
    }
    
    private static let writerInputs: Set<FileFormat> = [
        .docx, .doc, .dotx, .docm, .odt, .rtf, .txt, .md, .html
    ]
    private static let writerOutputs: Set<FileFormat> = [
        .pdf, .docx, .doc, .dotx, .odt, .rtf, .txt, .html, .md, .epub
    ]
    
    private static let spreadsheetInputs: Set<FileFormat> = [
        .xlsx, .xls, .xltx, .xlsm, .xlsb, .ods, .csv, .tsv
    ]
    private static let spreadsheetOutputs: Set<FileFormat> = [
        .pdf, .xlsx, .xls, .xltx, .ods, .csv, .tsv, .html
    ]
    
    private static let presentationInputs: Set<FileFormat> = [
        .pptx, .ppt, .potx, .pptm, .ppsx, .pps, .odp
    ]
    private static let presentationOutputs: Set<FileFormat> = [
        .pdf, .pptx, .ppt, .potx, .odp, .html
    ]
    
    var supportedInputFormats: Set<FileFormat> {
        Self.writerInputs
            .union(Self.spreadsheetInputs)
            .union(Self.presentationInputs)
            .union([.pdf])
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        Self.writerOutputs
            .union(Self.spreadsheetOutputs)
            .union(Self.presentationOutputs)
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        availableOutputFormats(for: input).contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        if input == .pdf {
            return [.docx, .xlsx, .pptx]
        }
        
        var outputs = Set<FileFormat>()
        if Self.writerInputs.contains(input) {
            outputs.formUnion(Self.writerOutputs)
        }
        if Self.spreadsheetInputs.contains(input) {
            outputs.formUnion(Self.spreadsheetOutputs)
            // Native CSV <-> TSV conversions are handled directly by TextConversionEngine
            if input == .csv { outputs.remove(.tsv) }
            if input == .tsv { outputs.remove(.csv) }
        }
        if Self.presentationInputs.contains(input) {
            outputs.formUnion(Self.presentationOutputs)
        }
        outputs.remove(input)
        return outputs
    }
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        guard canConvert(from: input, to: output) else { return [] }
        var descriptors: [ConversionOptionDescriptor] = []
        
        let validPresets: [ConversionPreset] = [.custom, .documentPDF, .documentEditable, .documentPrintArchive]
        descriptors.append(
            ConversionOptionDescriptor(
                id: "preset",
                title: "Smart Preset",
                description: "Auto-configure settings for common use cases",
                kind: .preset(validPresets)
            )
        )
        
        if input == .pdf && [FileFormat.docx, .xlsx, .pptx].contains(output) {
            descriptors.append(
                ConversionOptionDescriptor(
                    id: "pdfOfficeMode",
                    title: "Conversion Mode",
                    description: "Select PDF to Office conversion approach",
                    kind: .pdfOfficeMode([.automatic, .editable, .visual])
                )
            )
        }
        
        return descriptors
    }
    
    func isAvailable() async -> Bool {
        await provider.isAvailable()
    }
    
    /// Diagnostics method returning the active provider version if available
    func diagnostics() async -> String {
        let isAvail = await provider.isAvailable()
        let ver = await provider.version() ?? "unknown"
        return "Provider: \(provider.providerName), Available: \(isAvail), Version: \(ver)"
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
        
        let outputURL = try await provider.convert(
            input: input,
            to: outputFormat,
            outputDirectory: outputDirectory,
            options: options,
            progress: progress
        )
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        
        return ConversionResult(
            outputURL: outputURL,
            additionalOutputURLs: [],
            outputFormat: outputFormat,
            fileSize: fileSize,
            duration: duration,
            engineName: "\(name) (\(provider.providerName))"
        )
    }
}

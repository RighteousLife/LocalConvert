import Foundation
import PDFKit
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
        
        // Non-PDF: standard Office → PDF (or other) conversion
        let libreOfficeFormat = libreOfficeFormatName(for: outputFormat)
        
        progress(.determinate(0.3, message: "Converting document with LibreOffice..."))
        
        _ = try await executeProcessWithWatchdog(
            executablePath: sofficePath,
            arguments: [
                "-env:UserInstallation=file://\(tempProfile.path)",
                "--headless",
                "--convert-to", libreOfficeFormat,
                "--outdir", tempOut.path,
                input.path
            ]
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
        
        let finalOutput = ConversionManager.outputURL(for: input, format: outputFormat, in: outputDirectory)
        try FileManager.default.moveItem(at: generatedTempURL, to: finalOutput)
        
        // Validate PDF output
        if outputFormat == .pdf {
            guard let pdfDoc = PDFDocument(url: finalOutput), pdfDoc.pageCount > 0 else {
                try? FileManager.default.removeItem(at: finalOutput)
                throw ConversionError.engineExecutionFailed(
                    "The document was converted, but the generated PDF is invalid or unreadable.",
                    underlyingError: nil
                )
            }
        }
        
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
        
        let baseName = input.deletingPathExtension().lastPathComponent
        
        switch outputFormat {
        case .docx:
            // PDF → DOCX: Use writer_pdf_import filter
            progress(.determinate(0.3, message: "Converting PDF to Word document..."))
            try await runLibreOffice(
                sofficePath: sofficePath,
                arguments: [
                    "-env:UserInstallation=file://\(tempProfile.path)",
                    "--headless",
                    "--infilter=writer_pdf_import",
                    "--convert-to", "docx",
                    "--outdir", tempOut.path,
                    input.path
                ]
            )
            
        case .pptx:
            // PDF → PPTX: Use impress_pdf_import filter
            progress(.determinate(0.3, message: "Converting PDF to PowerPoint presentation..."))
            try await runLibreOffice(
                sofficePath: sofficePath,
                arguments: [
                    "-env:UserInstallation=file://\(tempProfile.path)",
                    "--headless",
                    "--infilter=impress_pdf_import",
                    "--convert-to", "pptx",
                    "--outdir", tempOut.path,
                    input.path
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
                    "-env:UserInstallation=file://\(tempProfile.path)",
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
        try validateOpenXML(at: generatedTempURL, format: outputFormat)
        
        let finalOutput = ConversionManager.outputURL(for: input, format: outputFormat, in: outputDirectory)
        try FileManager.default.moveItem(at: generatedTempURL, to: finalOutput)
        
        progress(.determinate(1.0, message: "Complete"))
        logger.info("PDF → \(outputFormat.rawValue) conversion succeeded: \(input.lastPathComponent) -> \(finalOutput.lastPathComponent)")
        
        return finalOutput
    }
    
    /// Extracts text/tabular data from a PDF document into CSV format for spreadsheet conversion
    private func extractCSV(from pdfURL: URL, options: ConversionOptions = .default) throws -> String {
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
        
        var rows: [String] = []
        
        for pageIndex in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIndex) else { continue }
            let text = page.string ?? ""
            let lines = text.components(separatedBy: .newlines)
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                
                let cells: [String]
                if trimmed.contains("\t") {
                    cells = trimmed.components(separatedBy: "\t")
                } else if trimmed.contains(",") {
                    cells = trimmed.components(separatedBy: ",")
                } else {
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    cells = parts.isEmpty ? [trimmed] : parts
                }
                
                let csvRow = cells.map { cell in
                    let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\""
                }.joined(separator: ",")
                
                rows.append(csvRow)
            }
        }
        
        if rows.isEmpty {
            rows.append("\"Document Content\"")
        }
        
        return rows.joined(separator: "\n") + "\n"
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
        
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        
        let outputTask = Task { () -> Data in
            return outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task { () -> Data in
            return errorPipe.fileHandleForReading.readDataToEndOfFile()
        }
        
        try process.run()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        
        return try await withTaskCancellationHandler {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            process.terminationHandler = { _ in
                                continuation.resume()
                            }
                        }
                    }
                    
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            process.terminate()
                            throw WatchdogTimeoutError()
                        } catch is CancellationError {
                            // Cancelled because process finished before watchdog timeout
                        }
                    }
                    
                    // Whichever completes first
                    try await group.next()
                    group.cancelAll()
                }
            } catch is WatchdogTimeoutError {
                process.terminate()
                _ = await outputTask.value
                _ = await errorTask.value
                throw ConversionError.engineExecutionFailed(
                    "Office conversion timed out after \(Int(timeout)) seconds. The document may be corrupted or contain hanging macros.",
                    underlyingError: "Watchdog timeout exceeded (\(Int(timeout))s)"
                )
            } catch {
                process.terminate()
                _ = await outputTask.value
                _ = await errorTask.value
                throw error
            }
            
            let outputData = await outputTask.value
            let errorData = await errorTask.value
            
            guard process.terminationStatus == 0 else {
                let outputString = String(data: outputData, encoding: .utf8) ?? ""
                let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if outputString.contains("Error:") && outputString.contains("no export filter") {
                    throw ConversionError.engineExecutionFailed(
                        "LibreOffice does not support this conversion format combination.",
                        underlyingError: outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                
                let safeError = errorString ?? "none"
                logger.error("LibreOffice process failed (exit code \(process.terminationStatus)): \(safeError, privacy: .public)")
                
                throw ConversionError.engineExecutionFailed(
                    "The document could not be converted. The file may be corrupted or password-protected.",
                    underlyingError: errorString
                )
            }
            
            return (outputData, errorData)
        } onCancel: {
            process.terminate()
        }
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
    
    /// Validates that a generated file is a valid ZIP archive containing the expected OpenXML entry
    private func validateOpenXML(at url: URL, format: FileFormat) throws {
        let expectedEntries: [String]
        switch format {
        case .docx:
            expectedEntries = ["word/document.xml"]
        case .xlsx:
            expectedEntries = ["xl/workbook.xml", "xl/worksheets/sheet"]
        case .pptx:
            expectedEntries = ["ppt/presentation.xml", "ppt/slides/slide"]
        default:
            return // No validation needed for non-OpenXML formats
        }
        
        // Use /usr/bin/unzip to check for expected entry
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", url.path]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw ConversionError.engineExecutionFailed(
                "The generated \(format.displayName) file is not a valid archive.",
                underlyingError: nil
            )
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let listing = String(data: data, encoding: .utf8) ?? ""
        
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
    private let systemProvider = SystemLibreOfficeProvider()
    
    init(fallbackToSystem: Bool = false) {
        self.fallbackToSystem = fallbackToSystem
    }
    
    override var providerName: String {
        "Bundled LibreOffice"
    }
    
    override func findExecutablePath() async -> String? {
        if let bundledPath = resolveBundledExecutable() {
            return bundledPath
        }
        if fallbackToSystem {
            return await systemProvider.findExecutablePath()
        }
        return nil
    }
    
    /// Resolves the bundled soffice executable path with search candidates
    private func resolveBundledExecutable() -> String? {
        let relativeSoffice = "LibreOffice/Contents/MacOS/soffice"
        
        // 1. ProcessInfo environment override
        if let env = ProcessInfo.processInfo.environment["LOCALCONVERT_SOFFICE_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        
        var candidates: [URL] = []
        
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
        
        // 6. Test host app bundle from environment if available
        if let testHost = ProcessInfo.processInfo.environment["TEST_HOST"] {
            let hostURL = URL(fileURLWithPath: testHost)
            let hostAppURL = hostURL.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(hostAppURL.appendingPathComponent("Resources/\(relativeSoffice)"))
        }
        
        // 7. Project directory fallback for development/tests when running outside an app bundle
        if let srcroot = ProcessInfo.processInfo.environment["SRCROOT"] {
            candidates.append(URL(fileURLWithPath: srcroot).appendingPathComponent("LocalConvert/Resources/\(relativeSoffice)"))
        }
        let sourceDirFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Office
            .deletingLastPathComponent() // Engines
            .deletingLastPathComponent() // LocalConvert
            .appendingPathComponent("Resources/\(relativeSoffice)")
        candidates.append(sourceDirFallback)
        
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if FileManager.default.isExecutableFile(atPath: path) {
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
    
    init(provider: OfficeEngineProvider = BundledLibreOfficeProvider(fallbackToSystem: true)) {
        self.provider = provider
    }
    
    var supportedInputFormats: Set<FileFormat> {
        [.docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp, .rtf, .csv, .tsv, .html, .pdf]
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        [.pdf, .docx, .xlsx, .pptx, .rtf, .csv, .tsv, .odt, .txt]
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        if input == output { return false }
        
        // Office → PDF conversions
        let officeInputs: Set<FileFormat> = [.docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp, .rtf, .csv, .tsv, .html]
        if output == .pdf {
            return officeInputs.contains(input)
        }
        
        // PDF → Office conversions
        if input == .pdf {
            let pdfOutputs: Set<FileFormat> = [.docx, .xlsx, .pptx]
            return pdfOutputs.contains(output)
        }
        
        // ODT expansions
        if input == .odt && [.docx, .rtf].contains(output) { return true }
        
        // ODS expansions
        if input == .ods && [.xlsx, .csv].contains(output) { return true }
        
        // ODP expansions
        if input == .odp && output == .pptx { return true }
        
        // RTF expansions
        if input == .rtf && [.docx, .odt, .txt].contains(output) { return true }
        
        // CSV / TSV to XLSX
        if [.csv, .tsv].contains(input) && output == .xlsx { return true }
        
        // XLSX to CSV / TSV
        if input == .xlsx && [.csv, .tsv].contains(output) { return true }
        
        return false
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        var formats = Set<FileFormat>()
        let officeInputs: Set<FileFormat> = [.docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp, .rtf, .csv, .tsv, .html]
        
        if officeInputs.contains(input) {
            formats.insert(.pdf)
        }
        
        if input == .pdf {
            formats.formUnion([.docx, .xlsx, .pptx])
        } else if input == .odt {
            formats.formUnion([.docx, .rtf])
        } else if input == .ods {
            formats.formUnion([.xlsx, .csv])
        } else if input == .odp {
            formats.insert(.pptx)
        } else if input == .rtf {
            formats.formUnion([.docx, .odt, .txt])
        } else if input == .csv || input == .tsv {
            formats.insert(.xlsx)
        } else if input == .xlsx {
            formats.formUnion([.csv, .tsv])
        }
        
        return formats
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

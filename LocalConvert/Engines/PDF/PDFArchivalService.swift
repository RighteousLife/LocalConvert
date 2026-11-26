import Foundation
import PDFKit

// MARK: - PDF/A Archival Conversion Service

enum PDFArchivalService {

    struct ArchivalConversionResult: Sendable {
        let outputURL: URL
        let validationReport: PDFAValidationReport
    }

    /// Converts a PDF to a genuine archival PDF/A profile via bundled LibreOffice `draw_pdf_Export`,
    /// followed by independent structural/XMP/font/OutputIntent validation.
    static func convertToPDFA(
        inputURL: URL,
        outputURL: URL,
        profile: PDFAProfile,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ArchivalConversionResult {
        try Task.checkCancellation()

        guard profile.isGenerationSupported, let selectPdfVersion = profile.libreOfficeVersionValue else {
            throw ConversionError.invalidInput(
                profile.limitationNote ?? "\(profile.rawValue) generation is not supported by the bundled engines."
            )
        }

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }

        guard let doc = PDFDocument(url: inputURL) else {
            throw ConversionError.invalidInput("Unable to open PDF document at '\(inputURL.lastPathComponent)'.")
        }

        if doc.isLocked {
            if let pwd = password, !pwd.isEmpty {
                guard doc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF '\(inputURL.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF '\(inputURL.lastPathComponent)' is encrypted. PDF/A forbids encryption; please unlock first.")
            }
        }

        let provider = BundledLibreOfficeProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
        guard let sofficePath = await provider.findExecutablePath() else {
            throw ConversionError.engineNotAvailable("Bundled LibreOffice runtime is required for PDF/A conversion.")
        }

        progress(.determinate(0.1, message: "Preparing \(profile.rawValue) archival export..."))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PDFA-\(UUID().uuidString)", isDirectory: true)
        let tempProfile = tempRoot.appendingPathComponent("profile", isDirectory: true)
        let tempInDir = tempRoot.appendingPathComponent("in", isDirectory: true)
        let tempOutDir = tempRoot.appendingPathComponent("out", isDirectory: true)

        try FileManager.default.createDirectory(at: tempProfile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempInDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempOutDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // If source was unlocked from encryption (PDF/A cannot read locked PDFs in LibreOffice), stage unlocked temp copy
        let stagedInput = tempInDir.appendingPathComponent("source.pdf")
        if doc.isEncrypted {
            guard doc.write(to: stagedInput) else {
                throw ConversionError.engineExecutionFailed("Failed to stage unlocked PDF copy for PDF/A export.", underlyingError: nil)
            }
        } else {
            try FileManager.default.copyItem(at: inputURL, to: stagedInput)
        }

        try Task.checkCancellation()
        progress(.determinate(0.35, message: "Converting to \(profile.rawValue) via LibreOffice..."))

        let filterArg = "pdf:draw_pdf_Export:{\"SelectPdfVersion\":{\"type\":\"long\",\"value\":\"\(selectPdfVersion)\"}}"
        let args = [
            "-env:UserInstallation=file://\(tempProfile.path)",
            "--headless",
            "--norestore",
            "--nolockcheck",
            "--convert-to", filterArg,
            "--outdir", tempOutDir.path,
            stagedInput.path
        ]

        try await runLibreOfficeWithCancellation(executablePath: sofficePath, arguments: args)
        try Task.checkCancellation()

        let exportedTempPDF = tempOutDir.appendingPathComponent("source.pdf")
        guard FileManager.default.fileExists(atPath: exportedTempPDF.path),
              PDFDocument(url: exportedTempPDF) != nil else {
            throw ConversionError.engineExecutionFailed(
                "LibreOffice finished, but \(profile.rawValue) output file was not produced.",
                underlyingError: nil
            )
        }

        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(exportedTempPDF, to: outputURL, policy: .overwrite)

        progress(.determinate(0.85, message: "Validating \(profile.rawValue) compliance..."))
        let report = try PDFDocumentInspector.validatePDFA(url: outputURL, expectedProfile: profile)

        progress(.determinate(1.0, message: report.isCompliant ? "\(profile.rawValue) Validated" : "Completed with Validation Notes"))
        return ArchivalConversionResult(outputURL: outputURL, validationReport: report)
    }

    // MARK: - Subprocess Helper

    private static func runLibreOfficeWithCancellation(
        executablePath: String,
        arguments: [String]
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env

        try await LibreOfficeProcessLimiter.shared.acquire()
        let output: ProcessExecutionOutput
        do {
            try Task.checkCancellation()
            output = try await AsyncProcessRunner.run(
                process,
                stdin: .nullDevice,
                timeout: BaseLibreOfficeProvider.defaultWatchdogTimeout
            )
            await LibreOfficeProcessLimiter.shared.release()
        } catch is CancellationError {
            await LibreOfficeProcessLimiter.shared.release()
            throw ConversionError.cancelled
        } catch is ProcessTimeoutError {
            await LibreOfficeProcessLimiter.shared.release()
            throw ConversionError.engineExecutionFailed(
                "LibreOffice PDF/A export timed out.",
                underlyingError: "Watchdog timeout exceeded"
            )
        } catch let convErr as ConversionError {
            await LibreOfficeProcessLimiter.shared.release()
            throw convErr
        } catch {
            await LibreOfficeProcessLimiter.shared.release()
            throw ConversionError.engineExecutionFailed(
                "Failed to launch LibreOffice for PDF/A export.",
                underlyingError: error.localizedDescription
            )
        }

        if Task.isCancelled {
            throw ConversionError.cancelled
        }
        guard output.terminationStatus == 0 else {
            let errStr = String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError.engineExecutionFailed(
                "LibreOffice PDF/A export failed (exit \(output.terminationStatus)).",
                underlyingError: errStr
            )
        }
    }
}

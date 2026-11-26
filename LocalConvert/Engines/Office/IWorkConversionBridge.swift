import AppKit
import Foundation
import PDFKit
import os.log

// MARK: - iWork Application Definition

enum IWorkApplication: String, CaseIterable, Sendable {
    case pages
    case numbers
    case keynote

    var appName: String {
        switch self {
        case .pages: return "Pages"
        case .numbers: return "Numbers"
        case .keynote: return "Keynote"
        }
    }

    var appBundleFilename: String {
        "\(appName).app"
    }

    /// Known bundle identifiers across classic (`com.apple.iWork.*`) and newer macOS iWork releases.
    var bundleIdentifiers: [String] {
        switch self {
        case .pages:
            return ["com.apple.iWork.Pages", "com.apple.Pages"]
        case .numbers:
            return ["com.apple.iWork.Numbers", "com.apple.Numbers"]
        case .keynote:
            return ["com.apple.iWork.Keynote", "com.apple.Keynote"]
        }
    }

    var inputFormat: FileFormat {
        switch self {
        case .pages: return .pages
        case .numbers: return .numbers
        case .keynote: return .key
        }
    }

    var supportedOutputFormats: Set<FileFormat> {
        switch self {
        case .pages:
            return [.pdf, .docx, .rtf, .txt]
        case .numbers:
            return [.pdf, .xlsx, .csv]
        case .keynote:
            return [.pdf, .pptx]
        }
    }
}

// MARK: - Injectable Environment

struct IWorkBridgeEnvironment: Sendable {
    let locateApplication: @Sendable (IWorkApplication) -> URL?
    let readBundleIdentifier: @Sendable (URL) -> String?
    let runProcess: @Sendable (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> ProcessExecutionOutput
    let timeoutSeconds: TimeInterval

    init(
        locateApplication: @escaping @Sendable (IWorkApplication) -> URL?,
        readBundleIdentifier: @escaping @Sendable (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        runProcess: @escaping @Sendable (_ executablePath: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> ProcessExecutionOutput,
        timeoutSeconds: TimeInterval = IWorkConversionBridge.defaultTimeoutSeconds
    ) {
        self.locateApplication = locateApplication
        self.readBundleIdentifier = readBundleIdentifier
        self.runProcess = runProcess
        self.timeoutSeconds = timeoutSeconds
    }

    static let live = IWorkBridgeEnvironment(
        locateApplication: { app in
            IWorkConversionBridge.defaultLocateApplication(app)
        },
        readBundleIdentifier: { url in
            Bundle(url: url)?.bundleIdentifier
        },
        runProcess: { executablePath, arguments, timeout in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            return try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: timeout)
        },
        timeoutSeconds: IWorkConversionBridge.defaultTimeoutSeconds
    )
}

// MARK: - iWork AppleScript Bridge

struct IWorkConversionBridge: Sendable {

    static let osascriptExecutablePath = "/usr/bin/osascript"
    static let unzipExecutablePath = "/usr/bin/unzip"
    static let defaultTimeoutSeconds: TimeInterval = 120.0
    static let supportedInputFormats: Set<FileFormat> = [.pages, .numbers, .key]

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "IWorkConversionBridge")

    let environment: IWorkBridgeEnvironment

    init(environment: IWorkBridgeEnvironment = .live) {
        self.environment = environment
    }

    // MARK: - Format Capability Matrix

    static func application(for inputFormat: FileFormat) -> IWorkApplication? {
        switch inputFormat {
        case .pages: return .pages
        case .numbers: return .numbers
        case .key: return .keynote
        default: return nil
        }
    }

    static func availableOutputFormats(for inputFormat: FileFormat) -> Set<FileFormat> {
        application(for: inputFormat)?.supportedOutputFormats ?? []
    }

    static func canConvert(from inputFormat: FileFormat, to outputFormat: FileFormat) -> Bool {
        availableOutputFormats(for: inputFormat).contains(outputFormat)
    }

    /// Resolves whether `input` should be routed through the iWork bridge.
    /// Uses extension fast-path first (so invalid/dummy test files still route predictably)
    /// and falls back to `FileDetector` for extensionless iWork files/bundles.
    static func resolveInputFormat(for input: URL) -> FileFormat? {
        switch input.pathExtension.lowercased() {
        case "pages": return .pages
        case "numbers": return .numbers
        case "key": return .key
        default:
            if let detected = FileDetector.detectFormat(url: input),
               supportedInputFormats.contains(detected) {
                return detected
            }
            return nil
        }
    }

    static func appleScriptExportFormatName(for inputFormat: FileFormat, outputFormat: FileFormat) -> String? {
        switch (inputFormat, outputFormat) {
        case (.pages, .pdf): return "PDF"
        case (.pages, .docx): return "Microsoft Word"
        case (.pages, .rtf): return "RTF"
        case (.pages, .txt): return "unformatted text"
        case (.numbers, .pdf): return "PDF"
        case (.numbers, .xlsx): return "Microsoft Excel"
        case (.numbers, .csv): return "CSV"
        case (.key, .pdf): return "PDF"
        case (.key, .pptx): return "Microsoft PowerPoint"
        default: return nil
        }
    }

    // MARK: - App Availability Detection

    static func defaultCandidateApplicationDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    static func defaultLocateApplication(
        _ app: IWorkApplication,
        candidateDirectories: [URL] = defaultCandidateApplicationDirectories(),
        bundleIdentifierLookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        bundleExists: (URL) -> Bool = { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    ) -> URL? {
        for directory in candidateDirectories {
            let candidate = directory.appendingPathComponent(app.appBundleFilename, isDirectory: true)
            if bundleExists(candidate) {
                return candidate
            }
        }

        for bundleID in app.bundleIdentifiers {
            if let resolvedURL = bundleIdentifierLookup(bundleID), bundleExists(resolvedURL) {
                return resolvedURL
            }
        }

        return nil
    }

    func applicationURL(for app: IWorkApplication) -> URL? {
        environment.locateApplication(app)
    }

    func isApplicationInstalled(_ app: IWorkApplication) -> Bool {
        applicationURL(for: app) != nil
    }

    func isAvailable(for inputFormat: FileFormat) -> Bool {
        guard let app = Self.application(for: inputFormat) else { return false }
        return isApplicationInstalled(app)
    }

    func isAnyAppAvailable() -> Bool {
        IWorkApplication.allCases.contains { isApplicationInstalled($0) }
    }

    // MARK: - Static AppleScript Templates (Zero Path/User-String Interpolation)

    // Note: Paths and export format names are ALWAYS passed via `argv` (`item 1..3 of argv`)
    // and never interpolated into AppleScript source text.

    private static let pagesLegacyBundleScript = #"""
    on run argv
        set inputPath to item 1 of argv
        set outputPath to item 2 of argv
        set exportFormat to item 3 of argv
        set inputFile to (POSIX file inputPath) as alias
        set outputFile to POSIX file outputPath
        tell application id "com.apple.iWork.Pages"
            set targetDoc to open inputFile
            try
                if exportFormat is "PDF" then
                    export targetDoc to outputFile as PDF
                else if exportFormat is "Microsoft Word" then
                    export targetDoc to outputFile as Microsoft Word
                else if exportFormat is "RTF" then
                    export targetDoc to outputFile as RTF
                else if exportFormat is "unformatted text" then
                    export targetDoc to outputFile as unformatted text
                else
                    error "Unsupported Pages export format: " & exportFormat
                end if
            on error errMsg number errNum
                try
                    close targetDoc saving no
                end try
                error errMsg number errNum
            end try
            try
                close targetDoc saving no
            end try
        end tell
    end run
    """#

    private static let pagesModernBundleScript = #"""
    on run argv
        set inputPath to item 1 of argv
        set outputPath to item 2 of argv
        set exportFormat to item 3 of argv
        set inputFile to (POSIX file inputPath) as alias
        set outputFile to POSIX file outputPath
        tell application id "com.apple.Pages"
            set targetDoc to open inputFile
            try
                if exportFormat is "PDF" then
                    export targetDoc to outputFile as PDF
                else if exportFormat is "Microsoft Word" then
                    export targetDoc to outputFile as Microsoft Word
                else if exportFormat is "RTF" then
                    export targetDoc to outputFile as RTF
                else if exportFormat is "unformatted text" then
                    export targetDoc to outputFile as unformatted text
                else
                    error "Unsupported Pages export format: " & exportFormat
                end if
            on error errMsg number errNum
                try
                    close targetDoc saving no
                end try
                error errMsg number errNum
            end try
            try
                close targetDoc saving no
            end try
        end tell
    end run
    """#

    private static let numbersLegacyBundleScript = #"""
    on run argv
        set inputPath to item 1 of argv
        set outputPath to item 2 of argv
        set exportFormat to item 3 of argv
        set inputFile to (POSIX file inputPath) as alias
        set outputFile to POSIX file outputPath
        tell application id "com.apple.iWork.Numbers"
            set targetDoc to open inputFile
            try
                if exportFormat is "PDF" then
                    export targetDoc to outputFile as PDF
                else if exportFormat is "Microsoft Excel" then
                    export targetDoc to outputFile as Microsoft Excel
                else if exportFormat is "CSV" then
                    export targetDoc to outputFile as CSV
                else
                    error "Unsupported Numbers export format: " & exportFormat
                end if
            on error errMsg number errNum
                try
                    close targetDoc saving no
                end try
                error errMsg number errNum
            end try
            try
                close targetDoc saving no
            end try
        end tell
    end run
    """#

    private static let numbersModernBundleScript = #"""
    on run argv
        set inputPath to item 1 of argv
        set outputPath to item 2 of argv
        set exportFormat to item 3 of argv
        set inputFile to (POSIX file inputPath) as alias
        set outputFile to POSIX file outputPath
        tell application id "com.apple.Numbers"
            set targetDoc to open inputFile
            try
                if exportFormat is "PDF" then
                    export targetDoc to outputFile as PDF
                else if exportFormat is "Microsoft Excel" then
                    export targetDoc to outputFile as Microsoft Excel
                else if exportFormat is "CSV" then
                    export targetDoc to outputFile as CSV
                else
                    error "Unsupported Numbers export format: " & exportFormat
                end if
            on error errMsg number errNum
                try
                    close targetDoc saving no
                end try
                error errMsg number errNum
            end try
            try
                close targetDoc saving no
            end try
        end tell
    end run
    """#

    private static let keynoteLegacyBundleScript = #"""
    on run argv
        set inputPath to item 1 of argv
        set outputPath to item 2 of argv
        set exportFormat to item 3 of argv
        set inputFile to (POSIX file inputPath) as alias
        set outputFile to POSIX file outputPath
        tell application id "com.apple.iWork.Keynote"
            set targetDoc to open inputFile
            try
                if exportFormat is "PDF" then
                    export targetDoc to outputFile as PDF
                else if exportFormat is "Microsoft PowerPoint" then
                    export targetDoc to outputFile as Microsoft PowerPoint
                else
                    error "Unsupported Keynote export format: " & exportFormat
                end if
            on error errMsg number errNum
                try
                    close targetDoc saving no
                end try
                error errMsg number errNum
            end try
            try
                close targetDoc saving no
            end try
        end tell
    end run
    """#

    private static let keynoteModernBundleScript = #"""
    on run argv
        set inputPath to item 1 of argv
        set outputPath to item 2 of argv
        set exportFormat to item 3 of argv
        set inputFile to (POSIX file inputPath) as alias
        set outputFile to POSIX file outputPath
        tell application id "com.apple.Keynote"
            set targetDoc to open inputFile
            try
                if exportFormat is "PDF" then
                    export targetDoc to outputFile as PDF
                else if exportFormat is "Microsoft PowerPoint" then
                    export targetDoc to outputFile as Microsoft PowerPoint
                else
                    error "Unsupported Keynote export format: " & exportFormat
                end if
            on error errMsg number errNum
                try
                    close targetDoc saving no
                end try
                error errMsg number errNum
            end try
            try
                close targetDoc saving no
            end try
        end tell
    end run
    """#

    static func appleScriptSource(for app: IWorkApplication, resolvedBundleIdentifier: String? = nil) -> String {
        switch app {
        case .pages:
            return resolvedBundleIdentifier == "com.apple.Pages" ? pagesModernBundleScript : pagesLegacyBundleScript
        case .numbers:
            return resolvedBundleIdentifier == "com.apple.Numbers" ? numbersModernBundleScript : numbersLegacyBundleScript
        case .keynote:
            return resolvedBundleIdentifier == "com.apple.Keynote" ? keynoteModernBundleScript : keynoteLegacyBundleScript
        }
    }

    static func osascriptArguments(
        for inputFormat: FileFormat,
        outputFormat: FileFormat,
        inputURL: URL,
        outputURL: URL,
        resolvedBundleIdentifier: String? = nil
    ) throws -> [String] {
        guard let app = application(for: inputFormat),
              let exportFormatName = appleScriptExportFormatName(for: inputFormat, outputFormat: outputFormat) else {
            throw ConversionError.unsupportedConversion(from: inputFormat, to: outputFormat)
        }

        let script = appleScriptSource(for: app, resolvedBundleIdentifier: resolvedBundleIdentifier)
        return [
            "-e",
            script,
            inputURL.path,
            outputURL.path,
            exportFormatName
        ]
    }

    // MARK: - Error Classification

    static func mapOsascriptFailure(
        exitCode: Int32,
        stderr: String,
        stdout: String,
        app: IWorkApplication,
        outputFormat: FileFormat
    ) -> ConversionError {
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [trimmedStderr, trimmedStdout]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let lower = combined.lowercased()

        // -1743 (errAEEventNotPermitted) / -1744 (errAEEventWouldRequireUserConsent)
        if combined.contains("-1743")
            || combined.contains("-1744")
            || lower.contains("not authorized to send apple events")
            || lower.contains("erraeeventnotpermitted") {
            return ConversionError.engineExecutionFailed(
                "macOS Automation permission is required to control \(app.appName).app. Enable LocalConvert under System Settings > Privacy & Security > Automation, then retry.",
                underlyingError: combined.isEmpty ? "osascript exit \(exitCode) (-1743)" : combined
            )
        }

        // -10814 (kLSApplicationNotFoundErr) / missing app at runtime
        if combined.contains("-10814")
            || lower.contains("application can't be found")
            || lower.contains("unable to find application") {
            return ConversionError.engineNotAvailable(
                "\(app.appBundleFilename) could not be found or launched by macOS. Install \(app.appName) to convert .\(app.inputFormat.fileExtension) documents."
            )
        }

        if lower.contains("password") || lower.contains("encrypted") {
            return ConversionError.invalidInput(
                "The \(app.appName) document appears to be password-protected or locked. Unlock it in \(app.appName) before converting."
            )
        }

        return ConversionError.engineExecutionFailed(
            "\(app.appName) failed to export the document to \(outputFormat.displayName).",
            underlyingError: combined.isEmpty ? "osascript exited with status \(exitCode)" : combined
        )
    }

    // MARK: - Conversion Execution

    func convert(
        input: URL,
        inputFormat: FileFormat? = nil,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions = .default,
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        try Task.checkCancellation()

        guard let resolvedInputFormat = inputFormat ?? Self.resolveInputFormat(for: input),
              let app = Self.application(for: resolvedInputFormat) else {
            let fallbackFormat = inputFormat ?? FileFormat.from(extension: input.pathExtension) ?? .pages
            throw ConversionError.unsupportedConversion(from: fallbackFormat, to: outputFormat)
        }

        guard Self.canConvert(from: resolvedInputFormat, to: outputFormat) else {
            throw ConversionError.unsupportedConversion(from: resolvedInputFormat, to: outputFormat)
        }

        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }

        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        guard let installedAppURL = applicationURL(for: app) else {
            throw ConversionError.engineNotAvailable(
                "\(app.appBundleFilename) is required to convert .\(resolvedInputFormat.fileExtension) files, but it was not found in Applications. Install \(app.appName) to enable \(resolvedInputFormat.displayName) conversion."
            )
        }

        let resolvedBundleID = environment.readBundleIdentifier(installedAppURL)

        progress(.determinate(0.1, message: "Preparing \(app.appName) export..."))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-iWork-\(UUID().uuidString)", isDirectory: true)
        let tempExportDir = tempRoot.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: tempExportDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let safeBase = OutputReservationCoordinator.sanitizedOutputBaseName(for: input, options: options)
        let stagedFilename = OutputReservationCoordinator.makeOutputFilename(
            baseName: safeBase,
            extension: outputFormat.fileExtension
        )
        let stagedExportURL = tempExportDir.appendingPathComponent(stagedFilename)

        let args = try Self.osascriptArguments(
            for: resolvedInputFormat,
            outputFormat: outputFormat,
            inputURL: input,
            outputURL: stagedExportURL,
            resolvedBundleIdentifier: resolvedBundleID
        )

        try Task.checkCancellation()
        progress(.determinate(0.35, message: "Exporting with \(app.appName)..."))

        let processOutput: ProcessExecutionOutput
        do {
            processOutput = try await environment.runProcess(
                Self.osascriptExecutablePath,
                args,
                environment.timeoutSeconds
            )
        } catch let timeoutError as ProcessTimeoutError {
            throw ConversionError.engineExecutionFailed(
                "\(app.appName) export timed out after \(Int(timeoutError.timeoutSeconds)) seconds. Check whether \(app.appName) is waiting on a dialog and try again.",
                underlyingError: "osascript watchdog timeout (\(Int(timeoutError.timeoutSeconds))s)"
            )
        } catch is CancellationError {
            throw ConversionError.cancelled
        }

        try Task.checkCancellation()

        guard processOutput.terminationStatus == 0 else {
            let stderrText = String(data: processOutput.stderr, encoding: .utf8) ?? ""
            let stdoutText = String(data: processOutput.stdout, encoding: .utf8) ?? ""
            Self.logger.error("\(app.appName) osascript failed (exit \(processOutput.terminationStatus)): \(stderrText, privacy: .public)")
            throw Self.mapOsascriptFailure(
                exitCode: processOutput.terminationStatus,
                stderr: stderrText,
                stdout: stdoutText,
                app: app,
                outputFormat: outputFormat
            )
        }

        progress(.determinate(0.8, message: "Verifying exported document..."))

        let exportedFiles = try collectExportedFiles(
            expectedURL: stagedExportURL,
            exportDirectory: tempExportDir,
            outputFormat: outputFormat,
            app: app
        )

        for exportedURL in exportedFiles {
            try await validateExportedFile(at: exportedURL, format: outputFormat)
        }

        let publishedURLs = try publishExportedFiles(
            exportedFiles,
            for: input,
            safeBase: safeBase,
            outputFormat: outputFormat,
            in: outputDirectory,
            options: options
        )

        guard let primaryOutputURL = publishedURLs.first else {
            throw ConversionError.engineExecutionFailed(
                "\(app.appName) export completed, but no output file was produced.",
                underlyingError: nil
            )
        }

        let totalBytes = publishedURLs.reduce(Int64(0)) { partial, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return partial + size
        }

        progress(.determinate(1.0, message: "Complete"))
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        Self.logger.info("iWork conversion succeeded: \(input.lastPathComponent) -> \(publishedURLs.count) file(s) (\(totalBytes) bytes)")

        return ConversionResult(
            outputURL: primaryOutputURL,
            additionalOutputURLs: Array(publishedURLs.dropFirst()),
            outputFormat: outputFormat,
            fileSize: totalBytes,
            duration: duration,
            engineName: "OfficeEngine (\(app.appName) Bridge)"
        )
    }

    // MARK: - Output Collection, Validation & Atomic Publish

    private func collectExportedFiles(
        expectedURL: URL,
        exportDirectory: URL,
        outputFormat: FileFormat,
        app: IWorkApplication
    ) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: expectedURL.path, isDirectory: &isDir), !isDir.boolValue {
            return [expectedURL]
        }

        // Numbers exports multi-sheet / multi-table documents to CSV as a folder of per-table CSV files.
        if outputFormat == .csv {
            let csvFiles = enumerateRegularFiles(in: exportDirectory, matchingExtension: "csv")
            if !csvFiles.isEmpty {
                return csvFiles
            }
        } else {
            let matchingFiles = enumerateRegularFiles(in: exportDirectory, matchingExtension: outputFormat.fileExtension)
            if let singleMatch = matchingFiles.first, matchingFiles.count == 1 {
                return [singleMatch]
            }
        }

        throw ConversionError.engineExecutionFailed(
            "\(app.appName) export finished, but the \(outputFormat.displayName) output file was not created.",
            underlyingError: nil
        )
    }

    private func enumerateRegularFiles(in rootDirectory: URL, matchingExtension ext: String) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let targetExt = ext.lowercased()
        var matches: [URL] = []
        for case let candidateURL as URL in enumerator {
            guard let values = try? candidateURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  candidateURL.pathExtension.lowercased() == targetExt else {
                continue
            }
            matches.append(candidateURL)
        }
        return matches.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func validateExportedFile(at url: URL, format: FileFormat) async throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0

        if format == .txt || format == .csv {
            guard attrs != nil else {
                throw ConversionError.engineExecutionFailed(
                    "The exported \(format.displayName) file could not be read.",
                    underlyingError: nil
                )
            }
            return
        }

        guard size > 0 else {
            throw ConversionError.engineExecutionFailed(
                "The exported \(format.displayName) file is empty.",
                underlyingError: nil
            )
        }

        if format == .pdf {
            guard let pdfDoc = PDFDocument(url: url), pdfDoc.pageCount > 0 else {
                throw ConversionError.engineExecutionFailed(
                    "The document was exported, but the generated PDF is invalid or unreadable.",
                    underlyingError: nil
                )
            }
            return
        }

        let expectedEntries: [String]
        switch format {
        case .docx:
            expectedEntries = ["word/document.xml"]
        case .xlsx:
            expectedEntries = ["xl/workbook.xml", "xl/worksheets/sheet"]
        case .pptx:
            expectedEntries = ["ppt/presentation.xml", "ppt/slides/slide"]
        default:
            return
        }

        let output = try await environment.runProcess(
            Self.unzipExecutablePath,
            ["-l", url.path],
            min(environment.timeoutSeconds, 30.0)
        )
        guard output.terminationStatus == 0 else {
            throw ConversionError.engineExecutionFailed(
                "The exported \(format.displayName) file is not a valid archive.",
                underlyingError: nil
            )
        }

        let listing = String(data: output.stdout, encoding: .utf8) ?? ""
        for entry in expectedEntries {
            guard listing.contains(entry) else {
                throw ConversionError.engineExecutionFailed(
                    "The exported \(format.displayName) file does not contain the expected content structure.",
                    underlyingError: "Missing entry: \(entry)"
                )
            }
        }
    }

    private func publishExportedFiles(
        _ stagedFiles: [URL],
        for input: URL,
        safeBase: String,
        outputFormat: FileFormat,
        in outputDirectory: URL,
        options: ConversionOptions
    ) throws -> [URL] {
        let policy = options.resolvedExistingFileHandling

        if stagedFiles.count == 1, let singleFile = stagedFiles.first {
            let reservedURL = try OutputReservationCoordinator.reserveOutputURL(
                for: input,
                format: outputFormat,
                in: outputDirectory,
                options: options
            )
            defer { OutputReservationCoordinator.releaseReservedOutputURL(reservedURL) }
            let committed = try OutputReservationCoordinator.moveOrReplaceTempFile(
                singleFile,
                to: reservedURL,
                policy: policy
            )
            return [committed]
        }

        // Multi-file export (e.g., Numbers multi-sheet/multi-table CSV directory).
        var reservedURLs: [URL] = []
        defer {
            for reserved in reservedURLs {
                OutputReservationCoordinator.releaseReservedOutputURL(reserved)
            }
        }

        var stagedPairs: [(source: URL, destination: URL)] = []
        for (index, stagedFile) in stagedFiles.enumerated() {
            let sheetStem = sanitizeCSVComponent(stagedFile.deletingPathExtension().lastPathComponent)
            let candidateBase: String
            if sheetStem.isEmpty || sheetStem.caseInsensitiveCompare(safeBase) == .orderedSame {
                candidateBase = "\(safeBase)-\(index + 1)"
            } else {
                candidateBase = "\(safeBase)-\(sheetStem)"
            }

            let reserved = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: outputDirectory,
                baseName: candidateBase,
                extension: outputFormat.fileExtension,
                sourceURL: input,
                policy: policy
            )
            reservedURLs.append(reserved)
            stagedPairs.append((source: stagedFile, destination: reserved))
        }

        var committedURLs: [URL] = []
        do {
            for pair in stagedPairs {
                try Task.checkCancellation()
                let committed = try OutputReservationCoordinator.moveOrReplaceTempFile(
                    pair.source,
                    to: pair.destination,
                    policy: policy
                )
                committedURLs.append(committed)
            }
        } catch {
            if policy != .overwrite {
                for createdURL in committedURLs {
                    try? FileManager.default.removeItem(at: createdURL)
                }
            }
            throw error
        }

        return committedURLs
    }

    private func sanitizeCSVComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

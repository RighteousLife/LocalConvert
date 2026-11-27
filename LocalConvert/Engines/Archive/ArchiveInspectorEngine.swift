import Foundation
import Darwin
import os

// MARK: - Archive Inspection Models

struct ArchiveEntry: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let path: String
    let uncompressedSize: Int64
    let isDirectory: Bool
    let isEncrypted: Bool

    init(
        path: String,
        uncompressedSize: Int64,
        isDirectory: Bool,
        isEncrypted: Bool = false
    ) {
        self.id = path
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.isDirectory = isDirectory
        self.isEncrypted = isEncrypted
    }

    var displayName: String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty ? path : name
    }

    var formattedSize: String {
        if isDirectory {
            return String(localized: "Folder")
        }
        return ByteCountFormatter.string(fromByteCount: uncompressedSize, countStyle: .file)
    }
}

struct ArchiveInspectionResult: Equatable, Sendable {
    let archiveURL: URL
    let entries: [ArchiveEntry]
    let totalUncompressedBytes: Int64
    let hasEncryptedEntries: Bool

    var regularFileEntries: [ArchiveEntry] {
        entries.filter { !$0.isDirectory }
    }
}

// MARK: - Archive Inspector & Encrypted ZIP Engine

enum ArchiveInspectorEngine: Sendable {

    private static let bsdtarPath = "/usr/bin/bsdtar"
    private static let unzipPath = "/usr/bin/unzip"
    private static let scriptPath = "/usr/bin/script"
    private static let processTimeoutSeconds: TimeInterval = 60.0
    static let defaultMaxListingOutputBytes: Int = 8 * 1024 * 1024

    static let supportedExtensions: Set<String> = [
        "zip", "tar", "tgz", "tbz2", "txz", "7z"
    ]

    static func isSupportedArchiveURL(_ url: URL) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.hasSuffix(".tar.gz") || lowerName.hasSuffix(".tar.bz2") || lowerName.hasSuffix(".tar.xz") {
            return true
        }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Strict Zip-Slip Path Validation

    /// Validates an archive entry path against Zip-Slip traversal, NUL bytes, Windows backslashes,
    /// absolute paths, and destination boundary escape. Returns the resolved destination URL inside `destinationRoot`.
    static func validateEntryPath(_ entryPath: String, destinationRoot: URL) throws -> URL {
        guard !entryPath.isEmpty else {
            throw ConversionError.invalidInput("Archive contains an empty entry path.")
        }
        if entryPath.contains("\0") {
            throw ConversionError.invalidInput("Archive entry path contains invalid NUL characters.")
        }
        if entryPath.contains("\\") {
            throw ConversionError.invalidInput("Archive entry path contains unsupported Windows-style separators: \(entryPath)")
        }
        if entryPath.hasPrefix("/") {
            throw ConversionError.invalidInput("Archive contains an unsafe absolute path entry: \(entryPath)")
        }

        let trimmed = entryPath.hasSuffix("/") ? String(entryPath.dropLast()) : entryPath
        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else {
            throw ConversionError.invalidInput("Archive contains an empty entry path.")
        }

        var validatedComponents: [String] = []
        validatedComponents.reserveCapacity(rawComponents.count)

        for componentSub in rawComponents {
            let component = String(componentSub)
            if component.isEmpty || component == "." || component == ".." {
                throw ConversionError.invalidInput("Archive contains unsafe path traversal entry: \(entryPath)")
            }
            if component.contains(":") && validatedComponents.isEmpty && component.count == 2 {
                throw ConversionError.invalidInput("Archive contains unsupported drive prefix in entry: \(entryPath)")
            }
            validatedComponents.append(component)
        }

        let rootStd = destinationRoot.standardizedFileURL
        var candidate = rootStd
        for (idx, component) in validatedComponents.enumerated() {
            let isLastDir = entryPath.hasSuffix("/") && idx == validatedComponents.count - 1
            candidate = candidate.appendingPathComponent(component, isDirectory: isLastDir)
        }
        let resolvedCandidate = candidate.standardizedFileURL
        let rootPrefix = rootStd.path.hasSuffix("/") ? rootStd.path : rootStd.path + "/"

        guard resolvedCandidate.path.hasPrefix(rootPrefix) else {
            throw ConversionError.invalidInput("Archive entry path escapes destination directory: \(entryPath)")
        }

        return resolvedCandidate
    }

    // MARK: - Archive Entry Listing

    static func listEntries(
        in archiveURL: URL,
        maxEntries: Int = ArchiveConversionEngine.defaultMaxArchiveEntries,
        maxUncompressedBytes: Int64 = ArchiveConversionEngine.defaultMaxUncompressedBytes,
        maxListingBytes: Int = ArchiveInspectorEngine.defaultMaxListingOutputBytes
    ) async throws -> ArchiveInspectionResult {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ConversionError.inputFileNotFound(archiveURL)
        }
        guard FileManager.default.isExecutableFile(atPath: bsdtarPath) else {
            throw ConversionError.engineNotAvailable("macOS archive tool (/usr/bin/bsdtar) is unavailable.")
        }

        try Task.checkCancellation()

        let listProcess = Process()
        listProcess.executableURL = URL(fileURLWithPath: bsdtarPath)
        listProcess.arguments = ["--numeric-owner", "-tvf", archiveURL.path]
        listProcess.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        listProcess.standardOutput = stdoutPipe
        listProcess.standardError = stderrPipe

        let maxStderrBytes = 256 * 1024
        let stderrTask = Task.detached(priority: .utility) { () -> Data in
            let readHandle = stderrPipe.fileHandleForReading
            var captured = Data()
            while let chunk = try? readHandle.read(upToCount: 65_536), !chunk.isEmpty {
                if captured.count < maxStderrBytes {
                    let remaining = maxStderrBytes - captured.count
                    captured.append(chunk.prefix(remaining))
                }
            }
            return captured
        }

        let effectiveMaxListingBytes = max(0, maxListingBytes)
        let effectiveMaxEntries = max(0, maxEntries)
        let streamTask = Task.detached(priority: .utility) { () throws -> Data in
            let readHandle = stdoutPipe.fileHandleForReading
            var collected = Data()
            var totalStdoutBytes = 0
            var entryLineCount = 0
            var currentLineHasNonWhitespace = false

            while let chunk = try readHandle.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                let (nextTotal, overflow) = totalStdoutBytes.addingReportingOverflow(chunk.count)
                if overflow || nextTotal > effectiveMaxListingBytes {
                    try? readHandle.close()
                    throw ConversionError.invalidInput(
                        "Archive listing output exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(effectiveMaxListingBytes), countStyle: .binary)) safety limit."
                    )
                }

                for byte in chunk {
                    if byte == 0x0A || byte == 0x0D {
                        currentLineHasNonWhitespace = false
                    } else if byte != 0x20 && byte != 0x09 {
                        if !currentLineHasNonWhitespace {
                            currentLineHasNonWhitespace = true
                            entryLineCount += 1
                            if entryLineCount > effectiveMaxEntries {
                                try? readHandle.close()
                                throw ConversionError.invalidInput(
                                    "Archive exceeds the maximum supported entry count (\(effectiveMaxEntries) items)."
                                )
                            }
                        }
                    }
                }

                totalStdoutBytes = nextTotal
                collected.append(chunk)
            }
            return collected
        }

        let stdoutData: Data
        do {
            var capturedStdout = Data()
            try await AsyncProcessRunner.awaitExit(of: listProcess, timeout: processTimeoutSeconds) {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                capturedStdout = try await streamTask.value
            }
            stdoutData = capturedStdout
        } catch is ProcessTimeoutError {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = try? await streamTask.value
            _ = await stderrTask.value
            throw ConversionError.engineExecutionFailed(
                "Listing archive timed out after \(Int(processTimeoutSeconds)) seconds.",
                underlyingError: "Watchdog timeout exceeded"
            )
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = try? await streamTask.value
            _ = await stderrTask.value
            throw error
        }

        let stderrData = await stderrTask.value
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        guard listProcess.terminationStatus == 0 else {
            throw ConversionError.invalidInput(
                stderrStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Archive '\(archiveURL.lastPathComponent)' could not be inspected or appears corrupted."
                    : stderrStr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let isZipArchive = archiveURL.pathExtension.lowercased() == "zip"
        let encryptedPaths = isZipArchive ? await encryptedEntryPathsInZip(archiveURL) : []
        let fallbackZipEncrypted = isZipArchive && isZipHeaderEncrypted(url: archiveURL)

        let rawLines = stdoutStr
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard rawLines.count <= maxEntries else {
            throw ConversionError.invalidInput(
                "Archive exceeds the maximum supported entry count (\(maxEntries) items)."
            )
        }

        let virtualRoot = URL(fileURLWithPath: "/LocalConvertArchiveCheck", isDirectory: true)
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(rawLines.count)
        var totalBytes: Int64 = 0
        var anyEncrypted = fallbackZipEncrypted

        for rawLine in rawLines {
            let parsed = try parseBsdtarListingLine(rawLine)
            _ = try validateEntryPath(parsed.path, destinationRoot: virtualRoot)

            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(parsed.size)
            if overflow || nextTotal > maxUncompressedBytes {
                throw ConversionError.invalidInput(
                    "Archive unpacked size exceeds the \(ByteCountFormatter.string(fromByteCount: maxUncompressedBytes, countStyle: .binary)) safety limit."
                )
            }
            totalBytes = nextTotal

            let entryEncrypted = encryptedPaths.contains(parsed.path) || (fallbackZipEncrypted && !parsed.isDirectory)
            if entryEncrypted {
                anyEncrypted = true
            }

            entries.append(
                ArchiveEntry(
                    path: parsed.path,
                    uncompressedSize: parsed.size,
                    isDirectory: parsed.isDirectory,
                    isEncrypted: entryEncrypted
                )
            )
        }

        return ArchiveInspectionResult(
            archiveURL: archiveURL,
            entries: entries,
            totalUncompressedBytes: totalBytes,
            hasEncryptedEntries: anyEncrypted
        )
    }

    // MARK: - Single Entry Extraction (Atomic & Zip-Slip Safe)

    static func extractEntry(
        _ entryPath: String,
        from archiveURL: URL,
        to destinationDirectory: URL,
        password: String? = nil,
        policy: ExistingFileHandling = .createUnique,
        maxUncompressedBytes: Int64 = ArchiveConversionEngine.defaultMaxUncompressedBytes
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ConversionError.inputFileNotFound(archiveURL)
        }
        try OutputReservationCoordinator.validateWritableDirectory(destinationDirectory)
        _ = try validateEntryPath(entryPath, destinationRoot: destinationDirectory)

        let inspection = try await listEntries(
            in: archiveURL,
            maxUncompressedBytes: maxUncompressedBytes
        )

        guard let targetEntry = inspection.entries.first(where: { $0.path == entryPath }) else {
            throw ConversionError.invalidInput("Archive entry '\(entryPath)' was not found.")
        }
        guard !targetEntry.isDirectory else {
            throw ConversionError.invalidInput("Selected entry '\(entryPath)' is a folder. Select a file to extract.")
        }

        try Task.checkCancellation()

        let fileName = targetEntry.displayName
        let rawExtension = (fileName as NSString).pathExtension
        let baseName: String = {
            if rawExtension.isEmpty {
                return fileName
            }
            let stripped = String(fileName.dropLast(rawExtension.count + 1))
            return stripped.isEmpty ? "extracted" : stripped
        }()

        let tempFileURL = destinationDirectory.appendingPathComponent(
            ".LocalConvert-extract-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            try? FileManager.default.removeItem(at: tempFileURL)
        }

        let requiresPassword = targetEntry.isEncrypted || inspection.hasEncryptedEntries
        let hasGlobCharacters = entryPath.contains(where: { "*?[\\".contains($0) })

        if requiresPassword {
            guard let password, !password.isEmpty else {
                throw ConversionError.invalidInput("This archive entry is encrypted. Enter the archive password to extract it.")
            }
            try await extractEncryptedEntryToTempFile(
                entryPath: entryPath,
                from: archiveURL,
                password: password,
                tempFileURL: tempFileURL,
                maxUncompressedBytes: maxUncompressedBytes
            )
        } else if hasGlobCharacters {
            try await extractEntryViaStagingDirectory(
                entryPath: entryPath,
                from: archiveURL,
                tempFileURL: tempFileURL,
                maxUncompressedBytes: maxUncompressedBytes
            )
        } else {
            try await streamSingleEntryToTempFile(
                entryPath: entryPath,
                from: archiveURL,
                tempFileURL: tempFileURL,
                maxUncompressedBytes: maxUncompressedBytes
            )
        }

        try Task.checkCancellation()

        let reservedURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: destinationDirectory,
            baseName: baseName,
            extension: rawExtension,
            sourceURL: archiveURL,
            policy: policy
        )
        defer {
            OutputReservationCoordinator.releaseReservedOutputURL(reservedURL)
        }

        return try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempFileURL,
            to: reservedURL,
            policy: policy
        )
    }

    // MARK: - Encrypted ZIP Creation (No CLI Password Exposure)

    static func createEncryptedZip(
        inputs: [URL],
        outputDirectory: URL,
        archiveBaseName: String = "Archive",
        password: String,
        policy: ExistingFileHandling = .createUnique
    ) async throws -> URL {
        guard !inputs.isEmpty else {
            throw ConversionError.invalidInput("Select at least one file or folder to create an encrypted ZIP.")
        }
        guard !password.isEmpty else {
            throw ConversionError.invalidInput("Password cannot be empty for an encrypted ZIP archive.")
        }
        if password.contains("\n") || password.contains("\r") || password.contains("\0") {
            throw ConversionError.invalidInput("Password contains unsupported control characters.")
        }
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)
        guard FileManager.default.isExecutableFile(atPath: bsdtarPath),
              FileManager.default.isExecutableFile(atPath: scriptPath) else {
            throw ConversionError.engineNotAvailable("macOS archive tools (/usr/bin/bsdtar, /usr/bin/script) are unavailable.")
        }

        let fm = FileManager.default
        for url in inputs {
            try validateNoSymlinksRecursively(at: url)
        }

        try Task.checkCancellation()

        let stageDir = fm.temporaryDirectory.appendingPathComponent(
            "LocalConvert-ZipStage-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        var stagedNames: [String] = []
        var usedNames: Set<String> = []
        for url in inputs {
            let candidateName = uniqueStagedItemName(for: url.lastPathComponent, used: &usedNames)
            let stagedURL = stageDir.appendingPathComponent(candidateName)
            try fm.copyItem(at: url, to: stagedURL)
            stagedNames.append(candidateName)
        }

        let sanitizedBase = sanitizeArchiveBaseName(archiveBaseName)
        let tempZipURL = outputDirectory.appendingPathComponent(
            ".LocalConvert-enczip-\(UUID().uuidString).zip",
            isDirectory: false
        )
        defer { try? fm.removeItem(at: tempZipURL) }

        let tarArgs = [
            "-q", "/dev/null",
            bsdtarPath,
            "--format=zip",
            "--options", "zip:encryption=zipcrypt",
            "-cf", tempZipURL.path,
            "-C", stageDir.path,
            "--"
        ] + stagedNames

        let (status, outputText, rejectedPassphrase) = try await runInteractiveScriptProcess(
            executable: scriptPath,
            arguments: tarArgs,
            passphrase: password,
            confirmPassphrase: true
        )

        if rejectedPassphrase {
            throw ConversionError.invalidInput("Archive password confirmation was rejected.")
        }

        guard status == 0 else {
            throw ConversionError.engineExecutionFailed(
                "Failed to create encrypted ZIP archive.",
                underlyingError: outputText
            )
        }

        guard fm.fileExists(atPath: tempZipURL.path),
              let size = (try? fm.attributesOfItem(atPath: tempZipURL.path)[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            throw ConversionError.engineExecutionFailed(
                "Encrypted ZIP creation produced an empty file.",
                underlyingError: nil
            )
        }

        guard isZipHeaderEncrypted(url: tempZipURL) else {
            throw ConversionError.engineExecutionFailed(
                "Created ZIP archive failed encryption header verification.",
                underlyingError: nil
            )
        }

        let reservedURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: outputDirectory,
            baseName: sanitizedBase,
            extension: "zip",
            policy: policy
        )
        defer {
            OutputReservationCoordinator.releaseReservedOutputURL(reservedURL)
        }

        return try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempZipURL,
            to: reservedURL,
            policy: policy
        )
    }

    /// Recursively verifies via `lstat` that `url` and (if a directory) none of its descendants are symbolic links.
    static func validateNoSymlinksRecursively(at url: URL) throws {
        var rootStat = stat()
        guard lstat(url.path, &rootStat) == 0 else {
            throw ConversionError.inputFileNotFound(url)
        }
        let rootMode = rootStat.st_mode & S_IFMT
        if rootMode == S_IFLNK {
            throw ConversionError.invalidInput("Symbolic links cannot be added to encrypted archives: \(url.lastPathComponent)")
        }
        guard rootMode == S_IFDIR else {
            return
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return
        }

        for case let item as URL in enumerator {
            try Task.checkCancellation()
            var itemStat = stat()
            if lstat(item.path, &itemStat) == 0, (itemStat.st_mode & S_IFMT) == S_IFLNK {
                throw ConversionError.invalidInput("Symbolic links cannot be added to encrypted archives: \(item.lastPathComponent)")
            }
        }
    }

    // MARK: - Private Parsing & Extraction Helpers

    private struct ParsedTarLine {
        let isDirectory: Bool
        let size: Int64
        let path: String
    }

    private static func parseBsdtarListingLine(_ rawLine: String) throws -> ParsedTarLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConversionError.invalidInput("Encountered empty archive entry metadata.")
        }

        // Parse 8 whitespace-delimited columns and preserve everything from column 9 onward verbatim
        // (so consecutive spaces inside filenames are never collapsed).
        var fields: [Substring] = []
        fields.reserveCapacity(8)
        var idx = trimmed.startIndex

        while idx < trimmed.endIndex && fields.count < 8 {
            while idx < trimmed.endIndex && (trimmed[idx] == " " || trimmed[idx] == "\t") {
                idx = trimmed.index(after: idx)
            }
            guard idx < trimmed.endIndex else { break }
            let start = idx
            while idx < trimmed.endIndex && trimmed[idx] != " " && trimmed[idx] != "\t" {
                idx = trimmed.index(after: idx)
            }
            fields.append(trimmed[start..<idx])
        }

        while idx < trimmed.endIndex && (trimmed[idx] == " " || trimmed[idx] == "\t") {
            idx = trimmed.index(after: idx)
        }

        guard fields.count == 8, idx < trimmed.endIndex else {
            throw ConversionError.invalidInput("Archive entry contains malformed metadata: \(trimmed)")
        }

        let mode = fields[0]
        guard let modeChar = mode.first else {
            throw ConversionError.invalidInput("Archive entry contains missing mode metadata.")
        }

        let isDirectory: Bool
        switch modeChar {
        case "-":
            isDirectory = false
        case "d":
            isDirectory = true
        case "l", "h":
            throw ConversionError.invalidInput("Archive contains symbolic or hard links, which are blocked for security.")
        case "b", "c", "p", "s":
            throw ConversionError.invalidInput("Archive contains unsupported special file entry (device, FIFO, or socket), which is blocked for security.")
        default:
            throw ConversionError.invalidInput("Archive contains unsupported entry type '\(modeChar)', which is blocked for security.")
        }

        guard let size = Int64(fields[4]), size >= 0 else {
            throw ConversionError.invalidInput("Archive entry contains invalid size metadata.")
        }

        let path = String(trimmed[idx...])
        return ParsedTarLine(isDirectory: isDirectory, size: size, path: path)
    }

    private static func streamSingleEntryToTempFile(
        entryPath: String,
        from archiveURL: URL,
        tempFileURL: URL,
        maxUncompressedBytes: Int64
    ) async throws {
        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: tempFileURL)
        defer { try? writeHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bsdtarPath)
        process.arguments = [
            "--no-same-permissions",
            "--no-same-owner",
            "-xOf", archiveURL.path,
            "--", entryPath
        ]
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stderrTask = Task.detached(priority: .utility) { () -> Data in
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let streamTask = Task.detached(priority: .utility) { () throws -> Int64 in
            var total: Int64 = 0
            let readHandle = stdoutPipe.fileHandleForReading
            while true {
                let chunk = readHandle.readData(ofLength: 65_536)
                if chunk.isEmpty { break }
                total += Int64(chunk.count)
                if total > maxUncompressedBytes {
                    try? readHandle.close()
                    throw ConversionError.invalidInput("Extracted file exceeds the safety size limit.")
                }
                try writeHandle.write(contentsOf: chunk)
            }
            return total
        }

        do {
            try await AsyncProcessRunner.awaitExit(of: process, timeout: processTimeoutSeconds) {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                _ = try await streamTask.value
            }
        } catch let timeoutError as ProcessTimeoutError {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = try? await streamTask.value
            _ = await stderrTask.value
            throw ConversionError.engineExecutionFailed(
                "Archive extraction timed out: \(timeoutError.localizedDescription)",
                underlyingError: nil
            )
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = try? await streamTask.value
            _ = await stderrTask.value
            throw error
        }

        let errData = await stderrTask.value
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ConversionError.engineExecutionFailed(
                "Failed to extract '\(entryPath)'.",
                underlyingError: errStr
            )
        }
    }

    private static func extractEntryViaStagingDirectory(
        entryPath: String,
        from archiveURL: URL,
        tempFileURL: URL,
        maxUncompressedBytes: Int64
    ) async throws {
        let fm = FileManager.default
        let stageDir = fm.temporaryDirectory.appendingPathComponent(
            "LocalConvert-ExtractStage-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        let escapedPattern = escapeBsdtarGlobPattern(entryPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bsdtarPath)
        process.arguments = [
            "--no-same-permissions",
            "--no-same-owner",
            "-xf", archiveURL.path,
            "-C", stageDir.path,
            "--", escapedPattern
        ]

        let output = try await AsyncProcessRunner.run(
            process,
            stdin: .nullDevice,
            timeout: processTimeoutSeconds
        )
        guard output.terminationStatus == 0 else {
            let errStr = String(data: output.stderr, encoding: .utf8) ?? ""
            throw ConversionError.engineExecutionFailed(
                "Failed to extract '\(entryPath)'.",
                underlyingError: errStr
            )
        }

        let verifier = ArchiveConversionEngine(maxUncompressedBytes: maxUncompressedBytes)
        try verifier.validateExtractedTreeSafety(root: stageDir)

        let extractedURL = try validateEntryPath(entryPath, destinationRoot: stageDir)
        guard fm.fileExists(atPath: extractedURL.path) else {
            throw ConversionError.invalidInput("Extracted entry '\(entryPath)' was not found in staging directory.")
        }
        try fm.copyItem(at: extractedURL, to: tempFileURL)
    }

    private static func extractEncryptedEntryToTempFile(
        entryPath: String,
        from archiveURL: URL,
        password: String,
        tempFileURL: URL,
        maxUncompressedBytes: Int64
    ) async throws {
        let fm = FileManager.default
        let stageDir = fm.temporaryDirectory.appendingPathComponent(
            "LocalConvert-EncExtract-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stageDir) }

        let escapedPattern = escapeBsdtarGlobPattern(entryPath)
        let args = [
            "-q", "/dev/null",
            bsdtarPath,
            "--no-same-permissions",
            "--no-same-owner",
            "-xf", archiveURL.path,
            "-C", stageDir.path,
            "--", escapedPattern
        ]

        let (status, outputText, rejectedPassphrase) = try await runInteractiveScriptProcess(
            executable: scriptPath,
            arguments: args,
            passphrase: password,
            confirmPassphrase: false
        )

        if rejectedPassphrase {
            throw ConversionError.invalidInput("Incorrect password or unable to decrypt '\(entryPath)'.")
        }

        guard status == 0 else {
            let lowered = outputText.lowercased()
            if lowered.contains("incorrect") || lowered.contains("passphrase") || lowered.contains("password") || lowered.contains("failed") {
                throw ConversionError.invalidInput("Incorrect password or unable to decrypt '\(entryPath)'.")
            }
            throw ConversionError.engineExecutionFailed(
                "Failed to extract encrypted entry '\(entryPath)'.",
                underlyingError: outputText
            )
        }

        let verifier = ArchiveConversionEngine(maxUncompressedBytes: maxUncompressedBytes)
        try verifier.validateExtractedTreeSafety(root: stageDir)

        let extractedURL = try validateEntryPath(entryPath, destinationRoot: stageDir)
        guard fm.fileExists(atPath: extractedURL.path) else {
            throw ConversionError.invalidInput("Incorrect password or entry '\(entryPath)' could not be extracted.")
        }
        try fm.copyItem(at: extractedURL, to: tempFileURL)
    }

    private static func runInteractiveScriptProcess(
        executable: String,
        arguments: [String],
        passphrase: String,
        confirmPassphrase: Bool
    ) async throws -> (status: Int32, output: String, rejectedPassphrase: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        final class LockedProcessBox: @unchecked Sendable {
            private let lock = NSLock()
            private var process: Process?

            init(_ process: Process) {
                self.process = process
            }

            func terminate() {
                lock.lock()
                let proc = process
                lock.unlock()
                if let proc, proc.isRunning {
                    proc.terminate()
                }
            }

            func clear() {
                lock.lock()
                process = nil
                lock.unlock()
            }
        }

        final class PromptState: @unchecked Sendable {
            private let lock = NSLock()
            var buffer = ""
            var sentPrimary = false
            var sentConfirm = false
            var rejectedPassphrase = false
            let passphrase: String
            let confirmPassphrase: Bool

            init(passphrase: String, confirmPassphrase: Bool) {
                self.passphrase = passphrase
                self.confirmPassphrase = confirmPassphrase
            }

            func consume(_ text: String, writer: FileHandle, processBox: LockedProcessBox) {
                var payloadsToWrite: [Data] = []
                var shouldCloseWriter = false
                var shouldTerminate = false

                lock.lock()
                buffer.append(text)
                if buffer.count > 4096 {
                    buffer = String(buffer.suffix(2048))
                }
                let lowered = buffer.lowercased()
                if !sentPrimary && (lowered.contains("enter passphrase") || lowered.contains("password:")) {
                    sentPrimary = true
                    buffer = ""
                    payloadsToWrite.append(Data((passphrase + "\n").utf8))
                } else if confirmPassphrase && sentPrimary && !sentConfirm && (lowered.contains("verifying") || lowered.contains("verify")) {
                    sentConfirm = true
                    buffer = ""
                    payloadsToWrite.append(Data((passphrase + "\n").utf8))
                    shouldCloseWriter = true
                } else if !confirmPassphrase && sentPrimary && (lowered.contains("enter passphrase") || lowered.contains("incorrect")) {
                    rejectedPassphrase = true
                    shouldTerminate = true
                    shouldCloseWriter = true
                }
                lock.unlock()

                for data in payloadsToWrite {
                    try? writer.write(contentsOf: data)
                }
                if shouldCloseWriter {
                    try? writer.close()
                }
                if shouldTerminate {
                    processBox.terminate()
                }
            }

            var didRejectPassphrase: Bool {
                lock.lock()
                defer { lock.unlock() }
                return rejectedPassphrase
            }
        }

        let processBox = LockedProcessBox(process)
        defer { processBox.clear() }
        let promptState = PromptState(passphrase: passphrase, confirmPassphrase: confirmPassphrase)
        let outTask = Task.detached(priority: .utility) { () -> String in
            let readHandle = outputPipe.fileHandleForReading
            let fd = readHandle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 256)
            var collected = Data()
            while true {
                let bytesRead = Darwin.read(fd, &buffer, buffer.count)
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if bytesRead == 0 { break }
                let chunk = Data(buffer[0..<bytesRead])
                collected.append(chunk)
                let str = String(decoding: chunk, as: UTF8.self)
                promptState.consume(str, writer: stdinPipe.fileHandleForWriting, processBox: processBox)
            }
            _ = readHandle
            return String(decoding: collected, as: UTF8.self)
        }

        do {
            try await AsyncProcessRunner.awaitExit(of: process, timeout: processTimeoutSeconds) {
                try? outputPipe.fileHandleForWriting.close()
            }
            try? stdinPipe.fileHandleForWriting.close()
            let output = await outTask.value
            return (process.terminationStatus, output, promptState.didRejectPassphrase)
        } catch {
            try? stdinPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            _ = await outTask.value
            if promptState.didRejectPassphrase {
                return (1, "", true)
            }
            throw error
        }
    }

    private static func escapeBsdtarGlobPattern(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.count + 4)
        for ch in path {
            if ch == "\\" || ch == "*" || ch == "?" || ch == "[" || ch == "]" {
                escaped.append("\\")
            }
            escaped.append(ch)
        }
        return escaped
    }

    private static func sanitizeArchiveBaseName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        if trimmed.lowercased().hasSuffix(".zip") {
            let stripped = String(trimmed.dropLast(4))
            return stripped.isEmpty ? "Archive" : stripped
        }
        return trimmed.isEmpty ? "Archive" : trimmed
    }

    private static func uniqueStagedItemName(for rawName: String, used: inout Set<String>) -> String {
        let clean = rawName.isEmpty ? "item" : rawName
        if used.insert(clean).inserted {
            return clean
        }
        let ext = (clean as NSString).pathExtension
        let stem = ext.isEmpty ? clean : String(clean.dropLast(ext.count + 1))
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if used.insert(candidate).inserted {
                return candidate
            }
            counter += 1
        }
    }

    private static func encryptedEntryPathsInZip(_ archiveURL: URL) async -> Set<String> {
        guard FileManager.default.isExecutableFile(atPath: unzipPath) else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: unzipPath)
        proc.arguments = ["-Z", "-lT", archiveURL.path]
        guard let result = try? await AsyncProcessRunner.run(proc, stdin: .nullDevice, timeout: 15),
              result.terminationStatus == 0,
              let stdout = String(data: result.stdout, encoding: .utf8) else {
            return []
        }

        var encrypted: Set<String> = []
        for line in stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("d") else { continue }
            var fields: [Substring] = []
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex && fields.count < 8 {
                while idx < trimmed.endIndex && (trimmed[idx] == " " || trimmed[idx] == "\t") {
                    idx = trimmed.index(after: idx)
                }
                guard idx < trimmed.endIndex else { break }
                let start = idx
                while idx < trimmed.endIndex && trimmed[idx] != " " && trimmed[idx] != "\t" {
                    idx = trimmed.index(after: idx)
                }
                fields.append(trimmed[start..<idx])
            }
            while idx < trimmed.endIndex && (trimmed[idx] == " " || trimmed[idx] == "\t") {
                idx = trimmed.index(after: idx)
            }
            guard fields.count == 8, idx < trimmed.endIndex else { continue }
            // unzip -Z -lT column 4 is file type / encryption indicator (e.g. "TX", "BX", "tx", "bx"; uppercase T/B = encrypted)
            let typeToken = String(fields[4])
            if let first = typeToken.first, first.isUppercase {
                let path = String(trimmed[idx...])
                encrypted.insert(path)
            }
        }
        return encrypted
    }

    static func isZipHeaderEncrypted(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }

        func scan(_ bytes: [UInt8]) -> Bool {
            var i = 0
            while i + 8 < bytes.count {
                if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x03 && bytes[i + 3] == 0x04 {
                    if (bytes[i + 6] & 0x01) != 0 { return true }
                    i += 4
                    continue
                }
                if i + 10 < bytes.count && bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x01 && bytes[i + 3] == 0x02 {
                    if (bytes[i + 8] & 0x01) != 0 { return true }
                    i += 4
                    continue
                }
                i += 1
            }
            return false
        }

        if let headData = try? fh.read(upToCount: 65_536), scan(Array(headData)) {
            return true
        }
        guard let fileSize = try? fh.seekToEnd(), fileSize > 22 else { return false }
        let tailLength = min(fileSize, 65_557)
        try? fh.seek(toOffset: fileSize - tailLength)
        guard let tailData = try? fh.read(upToCount: Int(tailLength)) else { return false }
        return scan(Array(tailData))
    }
}

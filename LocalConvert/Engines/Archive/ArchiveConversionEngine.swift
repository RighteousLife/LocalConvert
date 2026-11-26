import Foundation
import Darwin
import os.log

// MARK: - Archive Conversion Engine

/// Converts and repacks consumer archive formats using macOS built-in libarchive (/usr/bin/bsdtar), gzip, and bzip2.
/// Zero external Homebrew dependencies.
final class ArchiveConversionEngine: ConversionEngine, @unchecked Sendable {
    
    let name = "ArchiveEngine"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ArchiveEngine")
    
    private static let bsdtarPath = "/usr/bin/bsdtar"
    private static let gzipPath = "/usr/bin/gzip"
    private static let bzip2Path = "/usr/bin/bzip2"
    
    static let defaultMaxArchiveEntries = 10_000
    static let defaultMaxUncompressedBytes: Int64 = 2 * 1024 * 1024 * 1024 // 2 GB archive bomb guard
    private static let processTimeoutSeconds: TimeInterval = 120.0
    
    private let maxArchiveEntries: Int
    private let maxUncompressedBytes: Int64
    private let diskSpaceGuard: DiskSpaceGuard
    private let stagingParentDirectory: URL
    
    init(
        maxArchiveEntries: Int = ArchiveConversionEngine.defaultMaxArchiveEntries,
        maxUncompressedBytes: Int64 = ArchiveConversionEngine.defaultMaxUncompressedBytes,
        diskSpaceGuard: DiskSpaceGuard = DiskSpaceGuard(),
        stagingParentDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.maxArchiveEntries = max(1, maxArchiveEntries)
        self.maxUncompressedBytes = max(1, maxUncompressedBytes)
        self.diskSpaceGuard = diskSpaceGuard
        self.stagingParentDirectory = stagingParentDirectory
    }
    
    private static let containerInputs: Set<FileFormat> = [.zip, .tar, .tgz, .tbz2, .txz, .sevenZ, .rar]
    private static let containerOutputs: Set<FileFormat> = [.zip, .tar, .tgz, .tbz2, .txz, .sevenZ]
    private static let streamFormats: Set<FileFormat> = [.gz, .bz2]
    
    var supportedInputFormats: Set<FileFormat> {
        Self.containerInputs.union(Self.streamFormats)
    }
    
    var supportedOutputFormats: Set<FileFormat> {
        Self.containerOutputs.union(Self.streamFormats)
    }
    
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        availableOutputFormats(for: input).contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        var outputs = supportedOutputFormats
        outputs.remove(input)
        return outputs
    }
    
    func isAvailable() async -> Bool {
        FileManager.default.isExecutableFile(atPath: Self.bsdtarPath)
            && FileManager.default.isExecutableFile(atPath: Self.gzipPath)
            && FileManager.default.isExecutableFile(atPath: Self.bzip2Path)
    }
    
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let input = inputs.first else {
            throw ConversionError.invalidInput("No input archive provided.")
        }
        guard await isAvailable() else {
            throw ConversionError.engineNotAvailable("macOS archive tools (/usr/bin/bsdtar) are unavailable.")
        }
        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ConversionError.inputFileNotFound(input)
        }
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }
        guard supportedOutputFormats.contains(outputFormat) else {
            throw ConversionError.unsupportedConversion(from: FileDetector.detectFormat(url: input) ?? .zip, to: outputFormat)
        }
        
        let inputFormat = FileDetector.detectFormat(url: input) ?? .zip
        let startTime = CFAbsoluteTimeGetCurrent()
        try Task.checkCancellation()
        
        // Pre-flight disk space guard before creating any temporary extraction workspace
        try diskSpaceGuard.validateSufficientSpace(
            stagingDirectory: stagingParentDirectory,
            outputDirectory: outputDirectory,
            inputURLs: [input],
            outputFormat: outputFormat
        )
        
        let scratchRoot = stagingParentDirectory
            .appendingPathComponent("LocalConvert-Archive-\(UUID().uuidString)")
        let extractDir = scratchRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }
        
        progress(.determinate(0.15, message: "Inspecting archive safety & entries..."))
        
        if Self.streamFormats.contains(inputFormat) {
            try await decompressSingleStream(input: input, format: inputFormat, into: extractDir)
            try validateExtractedTreeSafety(root: extractDir)
        } else {
            // Inspect ZIP central header for encryption bit before extracting
            if inputFormat == .zip && isZipEncrypted(url: input) {
                throw ConversionError.invalidInput("The ZIP archive '\(input.lastPathComponent)' is password-protected or encrypted and cannot be converted automatically.")
            }
            let inspectedBytes = try await inspectArchiveEntriesSafely(input: input)
            try validateDiskSpaceForUnpackedArchive(
                unpackedBytes: inspectedBytes,
                stagingDirectory: scratchRoot,
                outputDirectory: outputDirectory,
                outputFormat: outputFormat
            )
            try Task.checkCancellation()
            
            progress(.determinate(0.4, message: "Extracting archive safely..."))
            let (_, stderr) = try await runTool(
                executable: Self.bsdtarPath,
                arguments: extractionArguments(for: input, destinationDirectory: extractDir),
                failureContext: "Archive extraction failed"
            )
            if stderr.lowercased().contains("passphrase") || stderr.lowercased().contains("encrypted") {
                throw ConversionError.invalidInput("The archive '\(input.lastPathComponent)' is encrypted or requires a password.")
            }
            try validateExtractedTreeSafety(root: extractDir)
        }
        
        try Task.checkCancellation()
        
        let extractedItems = try FileManager.default.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        )
        guard !extractedItems.isEmpty else {
            throw ConversionError.invalidInput("The archive '\(input.lastPathComponent)' is empty.")
        }
        
        progress(.determinate(0.7, message: "Creating \(outputFormat.shortExtensionLabel) archive..."))
        
        let tempOut = scratchRoot.appendingPathComponent("output.\(outputFormat.fileExtension)")
        
        if Self.streamFormats.contains(outputFormat) {
            // .gz / .bz2 are single-file compressors
            guard extractedItems.count == 1,
                  let singleFile = extractedItems.first,
                  (try? singleFile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else {
                let suggested = outputFormat == .gz ? ".tar.gz" : ".tar.bz2"
                throw ConversionError.invalidInput("\(outputFormat.displayName) compresses a single file only. Use \(suggested) for multi-file or folder archives.")
            }
            try await compressSingleStream(file: singleFile, format: outputFormat, to: tempOut)
        } else {
            let entryNames = extractedItems.map(\.lastPathComponent)
            var tarArgs: [String] = []
            switch outputFormat {
            case .zip:
                tarArgs = ["--format=zip", "-cf", tempOut.path]
            case .sevenZ:
                tarArgs = ["--format=7zip", "-cf", tempOut.path]
            case .tar:
                tarArgs = ["-cf", tempOut.path]
            case .tgz:
                tarArgs = ["-czf", tempOut.path]
            case .tbz2:
                tarArgs = ["-cjf", tempOut.path]
            case .txz:
                tarArgs = ["-cJf", tempOut.path]
            default:
                throw ConversionError.unsupportedConversion(from: inputFormat, to: outputFormat)
            }
            tarArgs += ["-C", extractDir.path, "--"] + entryNames
            
            _ = try await runTool(
                executable: Self.bsdtarPath,
                arguments: tarArgs,
                failureContext: "Failed to build \(outputFormat.displayName) archive"
            )
            // Verify output archive can be listed
            _ = try await runTool(
                executable: Self.bsdtarPath,
                arguments: ["-tf", tempOut.path],
                failureContext: "Generated archive integrity check failed"
            )
        }
        
        guard FileManager.default.fileExists(atPath: tempOut.path),
              let outSize = (try? FileManager.default.attributesOfItem(atPath: tempOut.path)[.size] as? Int64),
              outSize > 0 else {
            throw ConversionError.engineExecutionFailed("Archive creation succeeded, but output file is empty.", underlyingError: nil)
        }
        
        let finalOutput = try ConversionManager.finalizeOutputFile(
            from: tempOut,
            for: input,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        progress(.determinate(1.0, message: "Complete"))
        logger.info("Archive conversion succeeded: \(input.lastPathComponent) -> \(finalOutput.lastPathComponent)")
        
        return ConversionResult(
            outputURL: finalOutput,
            additionalOutputURLs: [],
            outputFormat: outputFormat,
            fileSize: outSize,
            duration: duration,
            engineName: name
        )
    }
    
    // MARK: - Single Stream (.gz / .bz2)
    
    private func decompressSingleStream(input: URL, format: FileFormat, into directory: URL) async throws {
        let base = FileFormat.baseNameByStrippingExtension(from: input)
        let safeName = (base.isEmpty || base == "." || base == ".." || base.contains("/")) ? "payload.bin" : base
        let outFile = directory.appendingPathComponent(safeName)
        let tool = (format == .bz2) ? Self.bzip2Path : Self.gzipPath
        
        try await runToolStreamingToFile(
            executable: tool,
            arguments: ["-d", "-c", "--", input.path],
            outputURL: outFile,
            maxBytes: maxUncompressedBytes,
            failureContext: "Failed to decompress \(format.displayName)"
        )
    }
    
    private func compressSingleStream(file: URL, format: FileFormat, to destination: URL) async throws {
        let tool = (format == .bz2) ? Self.bzip2Path : Self.gzipPath
        try await runToolStreamingToFile(
            executable: tool,
            arguments: ["-c", "--", file.path],
            outputURL: destination,
            maxBytes: nil,
            failureContext: "Failed to compress with \(format.displayName)"
        )
    }
    
    // MARK: - Security Inspection & Guards

    func extractionArguments(for input: URL, destinationDirectory: URL) -> [String] {
        [
            "--no-same-permissions",
            "--no-same-owner",
            "-xf", input.path,
            "-C", destinationDirectory.path
        ]
    }

    private func validateDiskSpaceForUnpackedArchive(
        unpackedBytes: Int64,
        stagingDirectory: URL,
        outputDirectory: URL,
        outputFormat: FileFormat
    ) throws {
        guard unpackedBytes > 0 else { return }
        let requiredBytes = diskSpaceGuard.estimateRequiredBytes(
            inputSizes: [unpackedBytes],
            outputFormat: outputFormat
        )
        let standardizedStaging = stagingDirectory.standardizedFileURL
        let standardizedOutput = outputDirectory.standardizedFileURL
        if !diskSpaceGuard.checkSpace(at: standardizedStaging, requiredBytes: requiredBytes).isSufficient {
            throw ConversionError.insufficientDiskSpace
        }
        if standardizedOutput != standardizedStaging,
           !diskSpaceGuard.checkSpace(at: standardizedOutput, requiredBytes: requiredBytes).isSufficient {
            throw ConversionError.insufficientDiskSpace
        }
    }

    private static func formattedByteLimit(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
    
    private func containsEncryptedZipHeaders(in bytes: [UInt8]) -> Bool {
        var i = 0
        while i + 8 < bytes.count {
            // Local file header: 50 4B 03 04 (bit 0 at offset +6 is encryption flag)
            if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x03 && bytes[i + 3] == 0x04 {
                if (bytes[i + 6] & 0x01) != 0 {
                    return true
                }
                i += 4
                continue
            }
            // Central directory header: 50 4B 01 02 (bit 0 at offset +8 is encryption flag)
            if i + 10 < bytes.count && bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x01 && bytes[i + 3] == 0x02 {
                if (bytes[i + 8] & 0x01) != 0 {
                    return true
                }
                i += 4
                continue
            }
            i += 1
        }
        return false
    }

    private func isZipEncrypted(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }

        if let headData = try? fh.read(upToCount: 65_536),
           containsEncryptedZipHeaders(in: Array(headData)) {
            return true
        }

        guard let fileSize = try? fh.seekToEnd(), fileSize > 22 else {
            return false
        }

        // Locate End of Central Directory (50 4B 05 06) in the last 64 KB + EOCD header
        let tailLength = min(fileSize, 65_557)
        try? fh.seek(toOffset: fileSize - tailLength)
        guard let tailData = try? fh.read(upToCount: Int(tailLength)), tailData.count >= 22 else {
            return false
        }
        let tailBytes = Array(tailData)
        if containsEncryptedZipHeaders(in: tailBytes) {
            return true
        }

        var pos = tailBytes.count - 22
        while pos >= 0 {
            if tailBytes[pos] == 0x50 && tailBytes[pos + 1] == 0x4B && tailBytes[pos + 2] == 0x05 && tailBytes[pos + 3] == 0x06 {
                let cdSize = UInt64(tailBytes[pos + 12])
                    | (UInt64(tailBytes[pos + 13]) << 8)
                    | (UInt64(tailBytes[pos + 14]) << 16)
                    | (UInt64(tailBytes[pos + 15]) << 24)
                let cdOffset = UInt64(tailBytes[pos + 16])
                    | (UInt64(tailBytes[pos + 17]) << 8)
                    | (UInt64(tailBytes[pos + 18]) << 16)
                    | (UInt64(tailBytes[pos + 19]) << 24)
                if cdSize > 0, cdOffset < fileSize {
                    let maxScan: UInt64 = 16_777_216
                    let bytesToRead = Int(min(cdSize, min(fileSize - cdOffset, maxScan)))
                    try? fh.seek(toOffset: cdOffset)
                    if let cdData = try? fh.read(upToCount: bytesToRead),
                       containsEncryptedZipHeaders(in: Array(cdData)) {
                        return true
                    }
                }
                break
            }
            if pos == 0 { break }
            pos -= 1
        }
        return false
    }
    
    @discardableResult
    func inspectArchiveEntriesSafely(input: URL) async throws -> Int64 {
        let (stdout, stderr) = try await runTool(
            executable: Self.bsdtarPath,
            arguments: ["--numeric-owner", "-tvf", input.path],
            failureContext: "Archive could not be read or appears corrupted"
        )
        let combinedErr = stderr.lowercased()
        if combinedErr.contains("passphrase") || combinedErr.contains("encrypted") || combinedErr.contains("password") {
            throw ConversionError.invalidInput("The archive '\(input.lastPathComponent)' is encrypted or password-protected.")
        }
        
        let lines = stdout.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count <= maxArchiveEntries else {
            throw ConversionError.invalidInput("Archive exceeds the maximum supported entry count (\(maxArchiveEntries) items).")
        }
        
        var totalSize: Int64 = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Extract mode, size, and path to block non-regular/non-directory entries and traversal (Zip Slip)
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.count >= 9 {
                let mode = tokens[0]
                guard let modeChar = mode.first else {
                    throw ConversionError.invalidInput("Archive entry contains malformed mode metadata.")
                }
                switch modeChar {
                case "-", "d":
                    break
                case "l", "h":
                    throw ConversionError.invalidInput("Archive contains symbolic or hard links, which are blocked for security.")
                case "b", "c", "p", "s":
                    throw ConversionError.invalidInput("Archive contains unsupported special file entry (device, FIFO, or socket), which is blocked for security.")
                default:
                    throw ConversionError.invalidInput("Archive contains unsupported entry type '\(modeChar)', which is blocked for security.")
                }

                guard let sizeVal = Int64(tokens[4]) else {
                    throw ConversionError.invalidInput("Archive entry contains invalid size metadata.")
                }
                guard sizeVal >= 0 else {
                    throw ConversionError.invalidInput("Archive entry contains negative size.")
                }
                let (nextTotal, overflow) = totalSize.addingReportingOverflow(sizeVal)
                if overflow || nextTotal > maxUncompressedBytes {
                    throw ConversionError.invalidInput("Archive unpacked size exceeds the \(Self.formattedByteLimit(maxUncompressedBytes)) safety limit.")
                }
                totalSize = nextTotal

                let entryPath = tokens[8...].joined(separator: " ")
                let normalizedComponents = entryPath.split(separator: "/")
                if entryPath.hasPrefix("/") || normalizedComponents.contains("..") {
                    throw ConversionError.invalidInput("Archive contains unsafe path traversal entry: \(entryPath)")
                }
            } else {
                if let firstChar = trimmed.first {
                    switch firstChar {
                    case "l", "h":
                        throw ConversionError.invalidInput("Archive contains symbolic or hard links, which are blocked for security.")
                    case "b", "c", "p", "s":
                        throw ConversionError.invalidInput("Archive contains unsupported special file entry (device, FIFO, or socket), which is blocked for security.")
                    default:
                        if let firstTok = tokens.first, firstTok.count >= 10, firstChar != "-", firstChar != "d" {
                            throw ConversionError.invalidInput("Archive contains unsupported entry type '\(firstChar)', which is blocked for security.")
                        }
                    }
                }
                // Fallback direct traversal check
                let normalizedComponents = trimmed.split(separator: "/")
                if trimmed == ".." || trimmed.hasPrefix("../") || trimmed.hasPrefix("/") || trimmed.hasSuffix("/..") || normalizedComponents.contains("..") || line.contains(" ../") {
                    throw ConversionError.invalidInput("Archive contains unsafe path traversal entry.")
                }
            }
        }
        return totalSize
    }
    
    @discardableResult
    func validateExtractedTreeSafety(root: URL) throws -> Int64 {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var rootStat = stat()
        guard lstat(resolvedRoot, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ConversionError.invalidInput("Extraction root directory is missing or unsafe.")
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ConversionError.invalidInput("Unable to inspect extracted archive contents safely.")
        }

        var totalExtractedBytes: Int64 = 0
        var extractedEntryCount = 0

        for case let itemURL as URL in enumerator {
            extractedEntryCount += 1
            if extractedEntryCount > maxArchiveEntries {
                throw ConversionError.invalidInput("Extracted archive exceeds the maximum supported entry count (\(maxArchiveEntries) items).")
            }

            var st = stat()
            guard lstat(itemURL.path, &st) == 0 else {
                throw ConversionError.invalidInput("Extracted archive entry could not be verified safely.")
            }

            let modeType = st.st_mode & S_IFMT
            switch modeType {
            case S_IFLNK:
                throw ConversionError.invalidInput("Archive extracted a symbolic link, which is blocked for security.")
            case S_IFDIR:
                break
            case S_IFREG:
                if st.st_nlink > 1 {
                    throw ConversionError.invalidInput("Archive extracted a hard link or multi-linked file, which is blocked for security.")
                }
                let fileSize = Int64(st.st_size)
                guard fileSize >= 0 else {
                    throw ConversionError.invalidInput("Extracted archive entry reported invalid negative size.")
                }
                let (nextTotal, overflow) = totalExtractedBytes.addingReportingOverflow(fileSize)
                if overflow || nextTotal > maxUncompressedBytes {
                    throw ConversionError.invalidInput("Extracted archive size exceeds the \(Self.formattedByteLimit(maxUncompressedBytes)) safety limit.")
                }
                totalExtractedBytes = nextTotal
            case S_IFIFO, S_IFCHR, S_IFBLK, S_IFSOCK:
                throw ConversionError.invalidInput("Archive extracted an unsupported special file (device, FIFO, or socket), which is blocked for security.")
            default:
                throw ConversionError.invalidInput("Archive extracted an unsupported file system entry type, which is blocked for security.")
            }

            let resolvedItem = itemURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedItem == resolvedRoot || resolvedItem.hasPrefix(resolvedRoot + "/") else {
                throw ConversionError.invalidInput("Archive entry escaped extraction boundary.")
            }
        }

        if let enumerationError {
            throw ConversionError.invalidInput("Unable to inspect extracted archive contents safely: \(enumerationError.localizedDescription)")
        }

        return totalExtractedBytes
    }
    
    // MARK: - Subprocess Execution with Watchdog & Cancellation
    
    private func runTool(executable: String, arguments: [String], failureContext: String) async throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let result: ProcessExecutionOutput
        do {
            result = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: Self.processTimeoutSeconds)
        } catch is ProcessTimeoutError {
            throw ConversionError.engineExecutionFailed(
                "\(failureContext): timed out after \(Int(Self.processTimeoutSeconds)) seconds.",
                underlyingError: "Watchdog timeout exceeded"
            )
        }

        let outStr = String(data: result.stdout, encoding: .utf8) ?? ""
        let errStr = String(data: result.stderr, encoding: .utf8) ?? ""

        guard result.terminationStatus == 0 else {
            let loweredErr = errStr.lowercased()
            if loweredErr.contains("passphrase")
                || loweredErr.contains("encrypted")
                || loweredErr.contains("password required")
                || loweredErr.contains("incorrect password")
                || loweredErr.contains("wrong password") {
                throw ConversionError.invalidInput("The archive is encrypted or password-protected and cannot be converted automatically.")
            }
            throw ConversionError.engineExecutionFailed(
                "\(failureContext).",
                underlyingError: errStr.isEmpty ? outStr : errStr
            )
        }
        return (outStr, errStr)
    }

    private func runToolStreamingToFile(
        executable: String,
        arguments: [String],
        outputURL: URL,
        maxBytes: Int64?,
        failureContext: String
    ) async throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? writeHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
                if let maxBytes, total > maxBytes {
                    try? readHandle.close()
                    throw ConversionError.invalidInput("Decompressed payload exceeds the \(Self.formattedByteLimit(maxBytes)) safety limit.")
                }
                try writeHandle.write(contentsOf: chunk)
            }
            return total
        }

        do {
            try await AsyncProcessRunner.awaitExit(of: process, timeout: Self.processTimeoutSeconds) {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                _ = try await streamTask.value
            }
        } catch let timeoutErr as ProcessTimeoutError {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = try? await streamTask.value
            _ = await stderrTask.value
            throw ConversionError.engineExecutionFailed("\(failureContext): \(timeoutErr.localizedDescription)", underlyingError: nil)
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
            throw ConversionError.engineExecutionFailed("\(failureContext).", underlyingError: errStr)
        }
    }
}

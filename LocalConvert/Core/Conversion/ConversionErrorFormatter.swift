import Foundation

// MARK: - Conversion Size Comparison

struct ConversionSizeComparison: Sendable, Equatable {
    let inputBytes: Int64
    let outputBytes: Int64

    var formattedInput: String {
        ByteCountFormatter.string(fromByteCount: inputBytes, countStyle: .file)
    }

    var formattedOutput: String {
        ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
    }

    var differenceBytes: Int64 {
        outputBytes - inputBytes
    }

    var percentChange: Double {
        guard inputBytes > 0 else { return 0 }
        return (Double(outputBytes) - Double(inputBytes)) / Double(inputBytes) * 100.0
    }

    var isSmaller: Bool {
        outputBytes < inputBytes
    }

    var isLarger: Bool {
        outputBytes > inputBytes
    }

    var formattedSummary: String {
        guard inputBytes > 0 && outputBytes > 0 else { return "" }
        let pct = abs(Int(round(percentChange)))
        if isSmaller {
            return "\(pct)% smaller"
        } else if isLarger {
            return "\(pct)% larger"
        } else {
            return "Same size"
        }
    }

    var savedBytes: Int64 {
        inputBytes - outputBytes
    }

    var savedPercentage: Double {
        guard inputBytes > 0 else { return 0.0 }
        return (Double(inputBytes - outputBytes) / Double(inputBytes)) * 100.0
    }

    var displayString: String {
        formattedFullComparison
    }

    var formattedFullComparison: String {
        guard inputBytes > 0 && outputBytes > 0 else { return "" }
        return "\(formattedInput) → \(formattedOutput) (\(formattedSummary))"
    }
}

// MARK: - Batch Result Summary

struct BatchResultSummary: Sendable, Equatable {
    let totalFiles: Int
    let completedCount: Int
    let failedCount: Int
    let cancelledCount: Int
    let totalInputBytes: Int64
    let totalOutputBytes: Int64

    var formattedTotalInput: String {
        ByteCountFormatter.string(fromByteCount: totalInputBytes, countStyle: .file)
    }

    var formattedTotalOutput: String {
        ByteCountFormatter.string(fromByteCount: totalOutputBytes, countStyle: .file)
    }

    var totalSavedBytes: Int64 {
        max(0, totalInputBytes - totalOutputBytes)
    }

    var savedBytes: Int64 {
        totalInputBytes - totalOutputBytes
    }

    var savedPercentage: Double {
        guard totalInputBytes > 0 else { return 0.0 }
        return (Double(totalInputBytes - totalOutputBytes) / Double(totalInputBytes)) * 100.0
    }

    var formattedTotalSaved: String {
        ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)
    }

    var savingsPercentage: Int {
        guard totalInputBytes > 0, totalSavedBytes > 0 else { return 0 }
        return Int(round(Double(totalSavedBytes) / Double(totalInputBytes) * 100.0))
    }

    var formattedSavingsSummary: String {
        if totalSavedBytes > 0 {
            return "Saved: \(formattedTotalSaved) (\(savingsPercentage)%)"
        } else if totalOutputBytes > totalInputBytes {
            let diff = totalOutputBytes - totalInputBytes
            return "\(ByteCountFormatter.string(fromByteCount: diff, countStyle: .file)) larger"
        } else {
            return "Same size"
        }
    }

    var displayString: String {
        formattedSavingsSummary
    }
}

// MARK: - Error Details Formatter

struct ErrorDetailsFormatter: Sendable {
    static func title(for error: ConversionError) -> String {
        switch error {
        case .inputFileNotFound:
            return "Source File Not Found"
        case .outputDirectoryNotWritable:
            return "Destination Folder Not Writable"
        case .unsupportedConversion:
            return "Unsupported Conversion Format"
        case .engineNotAvailable:
            return "Conversion Engine Unavailable"
        case .invalidInput:
            return "Invalid or Protected Input File"
        case .cancelled:
            return "Conversion Cancelled"
        case .insufficientDiskSpace:
            return "Insufficient Disk Space"
        case .engineExecutionFailed:
            return "Conversion Failed"
        default:
            return "Conversion Error"
        }
    }

    static func suggestedAction(for error: ConversionError) -> String {
        switch error {
        case .inputFileNotFound:
            return "Verify that the source file still exists on disk and has not been moved, renamed, or disconnected."
        case .outputDirectoryNotWritable:
            return "Choose a writable output folder (such as Desktop or Documents) in the Output selector or Settings."
        case .unsupportedConversion:
            return "Select one of the recommended target formats from the format picker for this file type."
        case .engineNotAvailable:
            return "Reinstall or verify LocalConvert's bundled conversion engines and try again."
        case .invalidInput:
            return "Check whether the file is password-protected, corrupted, or truncated, and unlock or repair it before converting."
        case .cancelled:
            return "Click Retry if you want to run this conversion again."
        case .insufficientDiskSpace:
            return "Free up space on the destination or startup disk, or choose another output drive, then retry."
        case .engineExecutionFailed:
            return "Check that the source file is valid and that sufficient free disk space is available, then retry."
        default:
            return "Review the technical details below or try converting to an alternative target format."
        }
    }

    static func format(
        job: ConversionJob,
        error: ConversionError
    ) -> String {
        format(
            inputFilename: job.inputFilename,
            inputFormat: job.inputFormat.displayName,
            outputFormat: job.outputFormat.displayName,
            error: error,
            jobID: job.id
        )
    }

    static func format(
        inputFilename: String,
        inputFormat: String,
        outputFormat: String,
        error: ConversionError,
        jobID: UUID? = nil
    ) -> String {
        let userMessage = sanitize(error.errorDescription ?? error.localizedDescription)
        let suggestion = suggestedAction(for: error)
        let technicalDetails: String

        switch error {
        case .engineExecutionFailed(_, let underlyingError):
            technicalDetails = sanitize(underlyingError ?? "None")
        case .unsupportedConversion(let from, let to):
            technicalDetails = "No conversion engine registered for route \(from.rawValue) → \(to.rawValue)"
        case .engineNotAvailable(let engine):
            technicalDetails = "Engine '\(engine)' is not installed or available on this system."
        case .inputFileNotFound(let url):
            technicalDetails = sanitize("Input file path: \(url.path)")
        case .outputDirectoryNotWritable(let dir):
            technicalDetails = sanitize("Output directory not writable: \(dir.path)")
        case .insufficientDiskSpace:
            technicalDetails = "Available disk space on staging or destination volume is below the required safety threshold."
        default:
            technicalDetails = "None"
        }

        let lines = [
            "--- LocalConvert Error Report ---",
            jobID != nil ? "Job ID: \(jobID!.uuidString)" : nil,
            "Input: \(inputFilename)",
            "Conversion: \(inputFormat) → \(outputFormat)",
            "Status: Failed",
            "Error: \(userMessage)",
            "Suggested Action: \(suggestion)",
            "Technical Details: \(technicalDetails)",
            "----------------------------------"
        ].compactMap { $0 }

        return lines.joined(separator: "\n")
    }

    /// Sanitizes secret strings (passwords, tokens, bearer auth, keys), GPS coordinates, and
    /// local macOS username home paths (`/Users/<name>` -> `~`).
    static func sanitize(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            ("Bearer\\s+[A-Za-z0-9\\-._~+/]+=*", "Bearer [REDACTED]"),
            ("password=[^\\s&]+", "password=[REDACTED]"),
            ("pwd=[^\\s&]+", "pwd=[REDACTED]"),
            ("secret=[^\\s&]+", "secret=[REDACTED]"),
            ("token=[^\\s&]+", "token=[REDACTED]"),
            ("key=[^\\s&]+", "key=[REDACTED]"),
            ("(?:latitude|longitude|lat|lon)\\s*[:=]\\s*[-+]?\\d+(?:\\.\\d+)?", "[GPS_REDACTED]"),
            ("\\b\\d{1,3}\\.\\d{3,}°\\s*[NSEW]\\b", "[GPS_REDACTED]"),
            ("/Users/[^/\\s:]+", "~")
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(location: 0, length: result.utf16.count),
                    withTemplate: template
                )
            }
        }
        return result
    }
}

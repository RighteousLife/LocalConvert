import Foundation
import os

// MARK: - Structured Local Diagnostics

/// High-level subsystem categories for local structured diagnostic events.
/// Zero network or telemetry transmission — all events stay in-process and local log storage.
enum DiagnosticCategory: String, CaseIterable, Sendable {
    case conversion = "Conversion"
    case imageDecode = "ImageDecode"
    case rawProcessing = "RAWProcessing"
    case metadata = "Metadata"
    case videoProcessing = "VideoProcessing"
    case watchFolder = "WatchFolder"
    case bundledTool = "BundledTool"
    case fileAccess = "FileAccess"
    case uiLifecycle = "UILifecycle"
    case audioLibrary = "AudioLibrary"
    case audioPlayer = "AudioPlayer"
    case audioWaveform = "AudioWaveform"
    case audioEditor = "AudioEditor"

    var isAudioWorkspaceCategory: Bool {
        switch self {
        case .audioLibrary, .audioPlayer, .audioWaveform, .audioEditor:
            return true
        default:
            return false
        }
    }
}

/// Distinguishes informational milestones, expected user/input validation failures,
/// and unexpected internal/dependency execution failures.
enum DiagnosticSeverity: String, CaseIterable, Sendable {
    case info = "INFO"
    case validation = "VALIDATION"
    case internalError = "INTERNAL_ERROR"
}

struct DiagnosticEvent: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let severity: DiagnosticSeverity
    let stage: String
    let operationID: String?
    let sanitizedFilename: String?
    let message: String

    var formattedLine: String {
        let opPart = operationID.map { " [op:\($0)]" } ?? ""
        let filePart = sanitizedFilename.map { " [file:\($0)]" } ?? ""
        return "[\(category.rawValue)][\(severity.rawValue)][\(stage)]\(opPart)\(filePart) \(message)"
    }
}

/// Lightweight, thread-safe local diagnostics recorder.
/// Enforces privacy redaction via `ErrorDetailsFormatter.sanitize(_:)`, bounds retained
/// in-memory history (`maxEvents = 200`), and bridges to `DiagnosticLogManager` without
/// duplicating writes.
enum StructuredDiagnostics {

    private static let maxEvents = 200
    private static let bufferLock = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])

    /// Classifies a `ConversionError` into expected validation vs unexpected internal error.
    static func severity(for error: ConversionError) -> DiagnosticSeverity {
        switch error {
        case .inputFileNotFound,
             .outputDirectoryNotWritable,
             .outputFileAlreadyExists,
             .insufficientDiskSpace,
             .unsupportedConversion,
             .invalidInput,
             .cancelled:
            return .validation
        case .engineNotAvailable,
             .engineExecutionFailed,
             .unknown:
            return .internalError
        }
    }

    @discardableResult
    static func record(
        category: DiagnosticCategory,
        severity: DiagnosticSeverity,
        stage: String,
        operationID: String? = nil,
        filename: String? = nil,
        message: String,
        isVerboseEnabled: Bool? = nil,
        directoryOverride: URL? = nil
    ) -> DiagnosticEvent {
        let safeFilename = filename.flatMap { raw -> String? in
            if category.isAudioWorkspaceCategory {
                let ext = URL(fileURLWithPath: raw).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
                return ext.isEmpty ? "[REDACTED_AUDIO_FILE]" : "[REDACTED_AUDIO_FILE].\(ext)"
            }
            let last = URL(fileURLWithPath: raw).lastPathComponent
            return last.isEmpty ? nil : ErrorDetailsFormatter.sanitize(last)
        }
        let safeStage = ErrorDetailsFormatter.sanitize(stage)
        let rawSanitizedMessage = ErrorDetailsFormatter.sanitize(message)
        let safeMessage = category.isAudioWorkspaceCategory
            ? sanitizeAudioMetadataTokens(rawSanitizedMessage)
            : rawSanitizedMessage

        let event = DiagnosticEvent(
            id: UUID(),
            timestamp: Date(),
            category: category,
            severity: severity,
            stage: safeStage,
            operationID: operationID,
            sanitizedFilename: safeFilename,
            message: safeMessage
        )

        bufferLock.withLock { buffer in
            buffer.append(event)
            if buffer.count > maxEvents {
                buffer.removeFirst(buffer.count - maxEvents)
            }
        }

        switch severity {
        case .info:
            DiagnosticLogManager.logVerbose(
                category: category.rawValue,
                message: event.formattedLine,
                isVerboseEnabled: isVerboseEnabled,
                directoryOverride: directoryOverride
            )
        case .validation, .internalError:
            DiagnosticLogManager.logError(
                category: category.rawValue,
                message: event.formattedLine,
                isVerboseEnabled: isVerboseEnabled,
                directoryOverride: directoryOverride
            )
        }

        return event
    }

    static func recentEvents(
        category: DiagnosticCategory? = nil,
        severity: DiagnosticSeverity? = nil
    ) -> [DiagnosticEvent] {
        let snapshot = bufferLock.withLock { $0 }
        return snapshot.filter { event in
            (category == nil || event.category == category)
                && (severity == nil || event.severity == severity)
        }
    }

    static func clearRecentEvents() {
        bufferLock.withLock { $0.removeAll() }
    }

    static func exportSanitizedSummary(limit: Int = 50) -> String {
        let formatter = ISO8601DateFormatter()
        return recentEvents()
            .suffix(max(1, limit))
            .map { "[\(formatter.string(from: $0.timestamp))] \($0.formattedLine)" }
            .joined(separator: "\n")
    }

    @discardableResult
    static func recordAudioEvent(
        category: DiagnosticCategory,
        severity: DiagnosticSeverity,
        stage: String,
        assetID: UUID? = nil,
        fileExtension: String? = nil,
        message: String,
        isVerboseEnabled: Bool? = nil,
        directoryOverride: URL? = nil
    ) -> DiagnosticEvent {
        let extHint = fileExtension.flatMap { ext -> String? in
            let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "ext.\(trimmed)"
        }
        return record(
            category: category,
            severity: severity,
            stage: stage,
            operationID: assetID?.uuidString.prefix(8).description,
            filename: extHint,
            message: message,
            isVerboseEnabled: isVerboseEnabled,
            directoryOverride: directoryOverride
        )
    }

    /// Redacts track metadata fields and file paths beyond base secret/home-path sanitization
    /// for privacy-sensitive Audio Workspace categories.
    private static func sanitizeAudioMetadataTokens(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            ("\\b(title|artist|album|albumArtist|composer|lyrics|comment)\\s*[:=]\\s*(\"[^\"]*\"|'[^']*'|[^\\r\\n,;]+)", "$1=[REDACTED]"),
            ("/(?:Volumes|Users)/[^\\s'\"]+", "[PATH_REDACTED]")
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

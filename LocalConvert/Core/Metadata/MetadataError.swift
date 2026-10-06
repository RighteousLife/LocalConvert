import Foundation

enum MetadataError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(FileFormat)
    case unsupportedField(String)
    case readFailure(String)
    case writeFailure(String, underlying: String? = nil)
    case validationFailure(String)
    case invalidArtwork(String)
    case atomicReplacementFailure(String)
    case fileNotFound(URL)
    case permissionDenied(URL)
    case corruptInput(String)
    case cancelled
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Metadata operations are not supported for \(format.displayName) files."
        case .unsupportedField(let field):
            return "The field '\(field)' is not supported by this format's metadata provider."
        case .readFailure(let reason):
            return "Failed to read metadata: \(reason)"
        case .writeFailure(let reason, let underlying):
            if let underlying = underlying {
                return "Failed to write metadata: \(reason) (\(underlying))"
            }
            return "Failed to write metadata: \(reason)"
        case .validationFailure(let reason):
            return "Metadata validation failed: \(reason)"
        case .invalidArtwork(let reason):
            return "Invalid artwork: \(reason)"
        case .atomicReplacementFailure(let reason):
            return "Failed to safely replace original file: \(reason)"
        case .fileNotFound(let url):
            return "The file at '\(url.lastPathComponent)' was not found."
        case .permissionDenied(let url):
            return "Permission denied when accessing '\(url.lastPathComponent)'."
        case .corruptInput(let reason):
            return "The file is corrupt or unreadable: \(reason)"
        case .cancelled:
            return "The metadata operation was cancelled."
        case .unknown(let message):
            return "An unexpected metadata error occurred: \(message)"
        }
    }
}

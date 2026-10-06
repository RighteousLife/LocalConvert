import Foundation
import os.log

final class SafeMetadataWriter: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "SafeMetadataWriter")
    
    /// Executes a safe metadata write using a temporary sibling file and atomic replacement.
    /// Guarantees that the original file is NEVER corrupted or truncated if an error occurs.
    @discardableResult
    static func performSafeWrite(
        on targetURL: URL,
        outputExtension: String? = nil,
        writeBlock: @Sendable (URL) async throws -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw MetadataError.fileNotFound(targetURL)
        }
        
        let parentDir = targetURL.deletingLastPathComponent()
        let ext = outputExtension ?? targetURL.pathExtension
        let tempFileName = ".\(targetURL.deletingPathExtension().lastPathComponent).tmp-\(UUID().uuidString).\(ext)"
        let tempURL = parentDir.appendingPathComponent(tempFileName)
        
        // Ensure cleanup of temp file on failure or exit
        defer {
            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }
        
        // 1. Make a copy of the original file to the temporary scratch file
        do {
            try fileManager.copyItem(at: targetURL, to: tempURL)
        } catch {
            throw MetadataError.writeFailure("Could not create temporary working file: \(error.localizedDescription)")
        }
        
        // 2. Perform write block on the temp scratch file
        try await writeBlock(tempURL)
        
        // 2. Validate resulting temp file
        guard fileManager.fileExists(atPath: tempURL.path) else {
            throw MetadataError.writeFailure("Metadata write failed to produce an output file.")
        }
        
        let tempSize = (try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
        guard tempSize > 0 else {
            throw MetadataError.corruptInput("Metadata write produced a zero-byte file.")
        }
        
        // 3. Perform atomic replacement of the original
        do {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL, backupItemName: nil, options: .withoutDeletingBackupItem)
            logger.info("Successfully updated metadata atomically: \(targetURL.lastPathComponent, privacy: .public)")
            return targetURL
        } catch {
            // Fallback for filesystems where replaceItemAt might fail
            do {
                let backupURL = parentDir.appendingPathComponent(".\(targetURL.lastPathComponent).bak-\(UUID().uuidString)")
                try fileManager.moveItem(at: targetURL, to: backupURL)
                do {
                    try fileManager.moveItem(at: tempURL, to: targetURL)
                    try? fileManager.removeItem(at: backupURL)
                    return targetURL
                } catch {
                    // Restore original from backup
                    try? fileManager.moveItem(at: backupURL, to: targetURL)
                    throw error
                }
            } catch {
                throw MetadataError.atomicReplacementFailure("Could not replace original file: \(error.localizedDescription)")
            }
        }
    }
}

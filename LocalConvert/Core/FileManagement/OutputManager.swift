import Foundation
import os.log

// MARK: - Output Location

enum OutputLocation: String, Sendable, CaseIterable, Identifiable {
    case sameFolder = "Same folder as original"
    case askEveryTime = "Ask every time"
    case customFolder = "Choose output folder"
    
    var id: String { rawValue }
}

// MARK: - Output Manager

struct OutputManager: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "OutputManager")
    
    private static let outputLocationKey = "com.localconvert.outputLocation"
    private static let customOutputDirKey = "com.localconvert.customOutputDir"
    
    /// Resolves the output directory based on the user's preference
    static func resolveOutputDirectory(
        for inputURL: URL,
        preference: OutputLocation,
        customDirectory: URL? = nil
    ) -> URL {
        switch preference {
        case .sameFolder:
            return inputURL.deletingLastPathComponent()
        case .customFolder:
            if let custom = customDirectory, isOutputDirectoryValid(custom) {
                return custom
            }
            return inputURL.deletingLastPathComponent()
        case .askEveryTime:
            // UI layer handles interactive dialog; fallback to same folder
            return inputURL.deletingLastPathComponent()
        }
    }
    
    /// Checks if a directory exists and is writable
    static func isOutputDirectoryValid(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }
    
    /// Generates a safe output URL avoiding collisions
    static func safeOutputURL(for inputURL: URL, format: FileFormat, in directory: URL) -> URL {
        ConversionManager.outputURL(for: inputURL, format: format, in: directory)
    }
    
    /// Saves output location and custom directory to UserDefaults
    static func savePreferences(location: OutputLocation, customDirectory: URL?) {
        UserDefaults.standard.set(location.rawValue, forKey: outputLocationKey)
        if let customDirectory {
            UserDefaults.standard.set(customDirectory.path, forKey: customOutputDirKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customOutputDirKey)
        }
    }
    
    /// Loads saved output location and custom directory from UserDefaults
    static func loadSavedPreferences() -> (location: OutputLocation, customDirectory: URL?) {
        let savedRaw = UserDefaults.standard.string(forKey: outputLocationKey)
        let location = savedRaw.flatMap { OutputLocation(rawValue: $0) } ?? .sameFolder
        
        var customDir: URL? = nil
        if let path = UserDefaults.standard.string(forKey: customOutputDirKey) {
            let url = URL(fileURLWithPath: path)
            if isOutputDirectoryValid(url) {
                customDir = url
            }
        }
        return (location, customDir)
    }
    
    /// Cleans up temporary files created during conversion
    static func cleanupTemporaryFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        
        for file in contents {
            if file.lastPathComponent.hasPrefix("LocalConvert-") {
                try? fileManager.removeItem(at: file)
            }
        }
        
        logger.debug("Cleaned up temporary files")
    }
}

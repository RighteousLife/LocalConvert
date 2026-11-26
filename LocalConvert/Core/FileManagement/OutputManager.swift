import Foundation
import os.log

// MARK: - Output Location

enum OutputLocation: String, Sendable, CaseIterable, Identifiable {
    case sameFolder = "Same folder as original"
    case lastUsedFolder = "Last used folder"
    case askEveryTime = "Ask every time"
    case customFolder = "Choose output folder"
    
    var id: String { rawValue }
}

// MARK: - Output Manager

struct OutputManager: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "OutputManager")
    
    static let outputLocationKey = "com.localconvert.outputLocation"
    static let customOutputDirKey = "com.localconvert.customOutputDir"
    static let lastUsedOutputDirKey = "com.localconvert.lastUsedOutputDir"
    
    /// Resolves the output directory based on the user's preference
    static func resolveOutputDirectory(
        for inputURL: URL,
        preference: OutputLocation,
        customDirectory: URL? = nil,
        defaults: UserDefaults = AppStoragePaths.userDefaults
    ) -> URL {
        switch preference {
        case .sameFolder:
            return inputURL.deletingLastPathComponent()
        case .lastUsedFolder:
            if let lastUsed = lastUsedDirectory(defaults: defaults), isOutputDirectoryValid(lastUsed) {
                return lastUsed
            }
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
    
    /// Last used output directory saved from previous successful conversions
    static var lastUsedDirectory: URL? {
        get {
            lastUsedDirectory(defaults: AppStoragePaths.userDefaults)
        }
        set {
            setLastUsedDirectory(newValue, defaults: AppStoragePaths.userDefaults)
        }
    }

    static func lastUsedDirectory(defaults: UserDefaults = AppStoragePaths.userDefaults) -> URL? {
        guard let path = defaults.string(forKey: lastUsedOutputDirKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        return isOutputDirectoryValid(url) ? url : nil
    }

    static func setLastUsedDirectory(_ newValue: URL?, defaults: UserDefaults = AppStoragePaths.userDefaults) {
        if let newValue {
            defaults.set(newValue.path, forKey: lastUsedOutputDirKey)
        } else {
            defaults.removeObject(forKey: lastUsedOutputDirKey)
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
    static func savePreferences(
        location: OutputLocation,
        customDirectory: URL?,
        defaults: UserDefaults = AppStoragePaths.userDefaults
    ) {
        defaults.set(location.rawValue, forKey: outputLocationKey)
        if let customDirectory {
            defaults.set(customDirectory.path, forKey: customOutputDirKey)
        } else {
            defaults.removeObject(forKey: customOutputDirKey)
        }
    }
    
    /// Loads saved output location and custom directory from UserDefaults
    static func loadSavedPreferences(
        defaults: UserDefaults = AppStoragePaths.userDefaults
    ) -> (location: OutputLocation, customDirectory: URL?) {
        let savedRaw = defaults.string(forKey: outputLocationKey)
        let location = savedRaw.flatMap { OutputLocation(rawValue: $0) } ?? .sameFolder
        
        var customDir: URL? = nil
        if let path = defaults.string(forKey: customOutputDirKey) {
            let url = URL(fileURLWithPath: path)
            if isOutputDirectoryValid(url) {
                customDir = url
            }
        }
        return (location, customDir)
    }

    /// Resets all persisted output location keys in the specified `UserDefaults` domain.
    static func resetPreferences(defaults: UserDefaults = AppStoragePaths.userDefaults) {
        defaults.removeObject(forKey: outputLocationKey)
        defaults.removeObject(forKey: customOutputDirKey)
        defaults.removeObject(forKey: lastUsedOutputDirKey)
    }
    
    /// Cleans up temporary files created during conversion
    static func cleanupTemporaryFiles(in directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        
        for file in contents {
            let name = file.lastPathComponent
            if name.hasPrefix("LocalConvert-") || name.hasPrefix("LocalConvertAudio_") {
                try? fileManager.removeItem(at: file)
            }
        }
        
        logger.debug("Cleaned up temporary files")
    }
}

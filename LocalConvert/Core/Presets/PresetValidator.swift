import Foundation

// MARK: - Batch Validation Result

struct PresetBatchValidationResult: Sendable {
    let preset: SavedPreset
    let compatibleURLs: [URL]
    let incompatibleURLs: [(url: URL, reason: String)]
    
    var compatibleCount: Int { compatibleURLs.count }
    var incompatibleCount: Int { incompatibleURLs.count }
    var totalCount: Int { compatibleCount + incompatibleCount }
    
    var hasCompatibleFiles: Bool { !compatibleURLs.isEmpty }
    var isFullyCompatible: Bool { incompatibleURLs.isEmpty && !compatibleURLs.isEmpty }
    
    var summary: String {
        if totalCount == 0 {
            return "No files in queue"
        }
        if isFullyCompatible {
            return "Compatible with all \(compatibleCount) file\(compatibleCount == 1 ? "" : "s")"
        }
        if compatibleCount == 0 {
            return "Incompatible with all files (\(incompatibleCount) file\(incompatibleCount == 1 ? "" : "s"))"
        }
        return "Applies to \(compatibleCount) of \(totalCount) files (\(incompatibleCount) skipped)"
    }
}

// MARK: - Preset Validator

struct PresetValidator: Sendable {
    
    init() {}
    
    /// Validates whether the preset definition itself is valid in the system
    func isPresetValid(_ preset: SavedPreset, registry: ConversionRegistry = .shared) -> (isValid: Bool, reason: String?) {
        guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "Preset name cannot be empty.")
        }
        
        // Target format must be supported by at least one engine
        let hasAnySourceForTarget = FileFormat.allCases.contains { sourceFormat in
            registry.canConvert(from: sourceFormat, to: preset.targetFormat)
        }
        
        guard hasAnySourceForTarget else {
            return (false, "Target format \(preset.targetFormat.displayName) is not a supported output format.")
        }
        
        if let source = preset.sourceConstraint {
            guard registry.canConvert(from: source, to: preset.targetFormat) else {
                return (false, "Conversion from \(source.displayName) to \(preset.targetFormat.displayName) is not supported.")
            }
        }
        
        return (true, nil)
    }
    
    /// Checks if a specific file format is compatible with the given preset
    func isFileCompatible(
        preset: SavedPreset,
        fileFormat: FileFormat,
        registry: ConversionRegistry = .shared
    ) -> (isCompatible: Bool, reason: String?) {
        // 1. Source format constraint check
        if let sourceConstraint = preset.sourceConstraint, sourceConstraint != fileFormat {
            return (false, "Preset requires \(sourceConstraint.displayName) input (file is \(fileFormat.displayName)).")
        }
        
        // 2. Source category constraint check
        if let categoryConstraint = preset.sourceCategoryConstraint, categoryConstraint != fileFormat.category {
            return (false, "Preset requires \(categoryConstraint.rawValue.capitalized) input (file is \(fileFormat.category.rawValue.capitalized)).")
        }
        
        // 3. Same format check (avoid redundant same-to-same unless options like quality apply)
        if fileFormat == preset.targetFormat && preset.sourceConstraint == nil {
            return (false, "File is already in \(preset.targetFormat.displayName) format.")
        }
        
        // 4. Registry capability check (Single Source of Truth)
        guard registry.canConvert(from: fileFormat, to: preset.targetFormat) else {
            return (false, "Conversion from \(fileFormat.displayName) to \(preset.targetFormat.displayName) is not supported.")
        }
        
        return (true, nil)
    }
    
    /// Validates a batch of file URLs against the given preset
    func validateBatch(
        preset: SavedPreset,
        urls: [URL],
        fileDetector: FileDetector = FileDetector(),
        registry: ConversionRegistry = .shared
    ) -> PresetBatchValidationResult {
        var compatible: [URL] = []
        var incompatible: [(url: URL, reason: String)] = []
        
        for url in urls {
            // Check if directory
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue {
                incompatible.append((url: url, reason: "Folders are not supported."))
                continue
            }
            
            let detection = fileDetector.detect(url: url)
            guard let detectedFormat = detection.bestFormat else {
                incompatible.append((url: url, reason: "Unsupported or unrecognized file format."))
                continue
            }
            
            let compatibility = isFileCompatible(preset: preset, fileFormat: detectedFormat, registry: registry)
            if compatibility.isCompatible {
                compatible.append(url)
            } else {
                incompatible.append((url: url, reason: compatibility.reason ?? "Incompatible with preset."))
            }
        }
        
        return PresetBatchValidationResult(
            preset: preset,
            compatibleURLs: compatible,
            incompatibleURLs: incompatible
        )
    }
}

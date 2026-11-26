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

// MARK: - Filename Template Tokens

enum FilenameTemplateToken: String, CaseIterable, Identifiable, Sendable {
    case name = "{name}"
    case ext = "{ext}"
    case format = "{format}"
    case date = "{date}"
    case time = "{time}"
    case resolution = "{resolution}"
    case widthHeight = "{width}x{height}"
    case preset = "{preset}"
    case index = "{index}"

    var id: String { rawValue }

    var chipLabel: String {
        "+ \(rawValue)"
    }

    var accessibilityKey: String {
        switch self {
        case .name: return "name"
        case .ext: return "ext"
        case .format: return "format"
        case .date: return "date"
        case .time: return "time"
        case .resolution: return "resolution"
        case .widthHeight: return "width_x_height"
        case .preset: return "preset"
        case .index: return "index"
        }
    }

    var shortDescription: String {
        switch self {
        case .name: return String(localized: "Source name")
        case .ext: return String(localized: "Output extension")
        case .format: return String(localized: "Target format")
        case .date: return String(localized: "Date (YYYY-MM-DD)")
        case .time: return String(localized: "Time (HH-MM-SS)")
        case .resolution: return String(localized: "Resolution (WxH)")
        case .widthHeight: return String(localized: "Width x Height")
        case .preset: return String(localized: "Preset name")
        case .index: return String(localized: "Item index")
        }
    }
}

// MARK: - Output Manager

struct OutputManager: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "OutputManager")
    
    static let outputLocationKey = "com.localconvert.outputLocation"
    static let customOutputDirKey = "com.localconvert.customOutputDir"
    static let lastUsedOutputDirKey = "com.localconvert.lastUsedOutputDir"
    static let filenameTemplateKey = "com.localconvert.filenameTemplate"
    static let defaultFilenameTemplate = "{name}"
    static let maxFilenameUTF8Bytes = 240
    
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
        let template = filenameTemplate(defaults: AppStoragePaths.userDefaults)
        if template == defaultFilenameTemplate {
            return ConversionManager.outputURL(for: inputURL, format: format, in: directory)
        }
        return safeOutputURL(for: inputURL, format: format, in: directory, template: template)
    }

    /// Generates a collision-safe output URL by expanding a filename template with rich tokens,
    /// sanitizing path separators/traversal components, and clamping to 240 UTF-8 bytes.
    static func safeOutputURL(
        for inputURL: URL,
        format: FileFormat,
        in directory: URL,
        template: String,
        options: ConversionOptions = .default,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        width: Int? = nil,
        height: Int? = nil,
        presetName: String? = nil,
        index: Int? = 1
    ) -> URL {
        let stem = expandFilenameStem(
            template,
            inputURL: inputURL,
            outputFormat: format,
            options: options,
            date: date,
            timeZone: timeZone,
            width: width,
            height: height,
            presetName: presetName,
            index: index
        )
        return OutputReservationCoordinator.uniqueOutputURL(
            directory: directory,
            baseName: stem,
            extension: format.fileExtension
        )
    }

    // MARK: - Filename Template Persistence & Expansion

    static func filenameTemplate(defaults: UserDefaults = AppStoragePaths.userDefaults) -> String {
        guard let stored = defaults.string(forKey: filenameTemplateKey) else {
            return defaultFilenameTemplate
        }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFilenameTemplate : stored
    }

    static func setFilenameTemplate(_ template: String, defaults: UserDefaults = AppStoragePaths.userDefaults) {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.set(defaultFilenameTemplate, forKey: filenameTemplateKey)
        } else {
            defaults.set(template, forKey: filenameTemplateKey)
        }
    }

    static func appendingToken(_ token: FilenameTemplateToken, to template: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return token.rawValue
        }
        if let last = template.last, last == "_" || last == "-" || last == "." || last == " " {
            return "\(template)\(token.rawValue)"
        }
        return "\(template)_\(token.rawValue)"
    }

    static func previewFilename(
        for template: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        expandFilenameTemplate(
            template,
            inputURL: URL(fileURLWithPath: "/Sample/presentation.pptx"),
            outputFormat: .pdf,
            date: date,
            timeZone: timeZone,
            width: 1920,
            height: 1080,
            presetName: "Web Optimized",
            index: 1
        )
    }

    static func expandFilenameTemplate(
        _ template: String,
        inputURL: URL,
        outputFormat: FileFormat,
        options: ConversionOptions = .default,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        width: Int? = nil,
        height: Int? = nil,
        presetName: String? = nil,
        index: Int? = 1,
        maxUTF8Bytes: Int = maxFilenameUTF8Bytes
    ) -> String {
        let stem = expandFilenameStem(
            template,
            inputURL: inputURL,
            outputFormat: outputFormat,
            options: options,
            date: date,
            timeZone: timeZone,
            width: width,
            height: height,
            presetName: presetName,
            index: index
        )
        return clampFilename(
            stem: stem,
            extension: outputFormat.fileExtension,
            maxUTF8Bytes: maxUTF8Bytes
        )
    }

    static func expandFilenameStem(
        _ template: String,
        inputURL: URL,
        outputFormat: FileFormat,
        options: ConversionOptions = .default,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        width: Int? = nil,
        height: Int? = nil,
        presetName: String? = nil,
        index: Int? = 1
    ) -> String {
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        var effectiveTemplate = trimmedTemplate.isEmpty ? defaultFilenameTemplate : trimmedTemplate

        // If the template explicitly ends with ".{ext}", strip that suffix before expanding the stem
        // so the output extension is appended once rather than duplicated (e.g., ".pdf.pdf").
        if effectiveTemplate.lowercased().hasSuffix(".{ext}") {
            let stripped = String(effectiveTemplate.dropLast(".{ext}".count))
            effectiveTemplate = stripped.isEmpty ? defaultFilenameTemplate : stripped
        }

        // Strip any NUL characters from template so "\0" can safely serve as an empty-token sentinel.
        let safeScanTemplate = stripControlAndNullCharacters(effectiveTemplate)

        let rawBaseName = FileFormat.baseNameByStrippingExtension(from: inputURL)
        let sanitizedBaseName: String = {
            let cleaned = sanitizeFilenameComponent(rawBaseName)
            return cleaned.isEmpty ? "output" : cleaned
        }()

        let resolvedExt = sanitizeFilenameComponent(outputFormat.fileExtension)
        let resolvedFormat = sanitizeFilenameComponent(outputFormat.rawValue)

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateTokenValue = dateFormatter.string(from: date)

        dateFormatter.dateFormat = "HH-mm-ss"
        let timeTokenValue = dateFormatter.string(from: date)

        let optionWidth: Int?
        let optionHeight: Int?
        let modeResolutionFallback: String

        switch options.resizeMode {
        case .none:
            optionWidth = nil
            optionHeight = nil
            modeResolutionFallback = ""
        case .exactWidth:
            optionWidth = options.resizeWidth
            optionHeight = nil
            if let w = options.resizeWidth, w > 0 {
                modeResolutionFallback = "\(w)w"
            } else {
                modeResolutionFallback = ""
            }
        case .exactHeight:
            optionWidth = nil
            optionHeight = options.resizeHeight
            if let h = options.resizeHeight, h > 0 {
                modeResolutionFallback = "\(h)h"
            } else {
                modeResolutionFallback = ""
            }
        case .exactDimensions:
            optionWidth = options.resizeWidth
            optionHeight = options.resizeHeight
            modeResolutionFallback = ""
        case .percentage:
            optionWidth = nil
            optionHeight = nil
            if let pct = options.resizePercentage, pct > 0 {
                let percentInt = max(1, Int((pct * 100.0).rounded()))
                modeResolutionFallback = "\(percentInt)pct"
            } else {
                modeResolutionFallback = ""
            }
        case .longestEdge:
            optionWidth = nil
            optionHeight = nil
            let edge = options.resizeWidth ?? options.resizeHeight
            if let edge, edge > 0 {
                modeResolutionFallback = "\(edge)max"
            } else {
                modeResolutionFallback = ""
            }
        case .shortestEdge:
            optionWidth = nil
            optionHeight = nil
            let edge = options.resizeHeight ?? options.resizeWidth
            if let edge, edge > 0 {
                modeResolutionFallback = "\(edge)min"
            } else {
                modeResolutionFallback = ""
            }
        }

        let resolvedWidth = width ?? optionWidth
        let resolvedHeight = height ?? optionHeight
        let validWidth = resolvedWidth.flatMap { $0 > 0 ? $0 : nil }
        let validHeight = resolvedHeight.flatMap { $0 > 0 ? $0 : nil }

        let widthHeightTokenValue: String = {
            if let w = validWidth, let h = validHeight {
                return "\(w)x\(h)"
            }
            return ""
        }()

        let resolutionTokenValue: String = {
            if !widthHeightTokenValue.isEmpty {
                return widthHeightTokenValue
            }
            return modeResolutionFallback
        }()

        let rawPreset = [
            presetName,
            options.customOptions["preset_name"],
            options.effectivePreset?.rawValue
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let presetTokenValue = sanitizeFilenameComponent(rawPreset)

        let validIndex = index.flatMap { $0 > 0 ? $0 : nil }
        let indexTokenValue = validIndex.map(String.init) ?? ""
        let counterTokenValue = validIndex.map { String(format: "%03d", $0) } ?? ""

        let emptySentinel = "\u{0000}"

        // Ordered longest-first so compound tokens like {width}x{height} match before {width}.
        let tokenReplacements: [(token: String, value: String)] = [
            ("{width}x{height}", widthHeightTokenValue.isEmpty ? emptySentinel : widthHeightTokenValue),
            ("{resolution}", resolutionTokenValue.isEmpty ? emptySentinel : resolutionTokenValue),
            ("{format}", resolvedFormat.isEmpty ? emptySentinel : resolvedFormat),
            ("{preset}", presetTokenValue.isEmpty ? emptySentinel : presetTokenValue),
            ("{counter}", counterTokenValue.isEmpty ? emptySentinel : counterTokenValue),
            ("{index}", indexTokenValue.isEmpty ? emptySentinel : indexTokenValue),
            ("{width}", validWidth.map(String.init) ?? emptySentinel),
            ("{height}", validHeight.map(String.init) ?? emptySentinel),
            ("{name}", sanitizedBaseName),
            ("{date}", dateTokenValue),
            ("{time}", timeTokenValue),
            ("{ext}", resolvedExt.isEmpty ? emptySentinel : resolvedExt)
        ]

        var expanded = ""
        var cursor = safeScanTemplate.startIndex
        while cursor < safeScanTemplate.endIndex {
            let remainder = safeScanTemplate[cursor...]
            if let match = tokenReplacements.first(where: { remainder.hasPrefix($0.token) }) {
                expanded.append(match.value)
                cursor = safeScanTemplate.index(cursor, offsetBy: match.token.count)
            } else {
                let ch = safeScanTemplate[cursor]
                if ch == "/" || ch == ":" || ch == "\\" {
                    expanded.append("_")
                } else {
                    expanded.append(ch)
                }
                cursor = safeScanTemplate.index(after: cursor)
            }
        }

        expanded = collapseEmptyTokenSentinels(expanded)

        let prefix = sanitizeFilenameComponent(
            options.customOptions["output_prefix"] ?? "",
            trimLeadingTrailingDots: false
        )
        var suffix = sanitizeFilenameComponent(
            options.customOptions["output_suffix"] ?? "",
            trimLeadingTrailingDots: false
        )
        if suffix.isEmpty && options.hasVideoTrim {
            suffix = "_trimmed"
        }

        let combined = "\(prefix)\(expanded)\(suffix)"
        let finalStem = sanitizeFilenameComponent(combined)
        return finalStem.isEmpty ? sanitizedBaseName : finalStem
    }

    static func clampFilename(
        stem: String,
        extension ext: String,
        maxUTF8Bytes: Int = maxFilenameUTF8Bytes
    ) -> String {
        let cleanExt = sanitizeFilenameComponent(ext)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let extPart = cleanExt.isEmpty ? "" : ".\(cleanExt)"

        guard maxUTF8Bytes > 0 else { return "" }

        let budget = maxUTF8Bytes - extPart.utf8.count
        guard budget > 0 else {
            return truncateToUTF8ByteBudget(extPart, maxBytes: maxUTF8Bytes)
        }

        let safeStem = sanitizeFilenameComponent(stem)
        var clampedStem = truncateToUTF8ByteBudget(safeStem.isEmpty ? "output" : safeStem, maxBytes: budget)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if clampedStem.isEmpty {
            clampedStem = truncateToUTF8ByteBudget("output", maxBytes: budget)
        }
        return "\(clampedStem)\(extPart)"
    }

    static func sanitizeFilenameComponent(
        _ raw: String,
        trimLeadingTrailingDots: Bool = true
    ) -> String {
        let stripped = stripControlAndNullCharacters(raw)
        if trimLeadingTrailingDots {
            let trimmedCheck = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCheck == "." || trimmedCheck == ".." {
                return ""
            }
        }

        var cleaned = stripped
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: "_")
        }

        if trimLeadingTrailingDots {
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned == "." || cleaned == ".." {
                return ""
            }
        }
        return cleaned
    }

    private static func stripControlAndNullCharacters(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func collapseEmptyTokenSentinels(_ text: String) -> String {
        let sentinel: Character = "\u{0000}"
        let separators: Set<Character> = ["_", "-", " "]
        var chars = Array(text)

        while let idx = chars.firstIndex(of: sentinel) {
            let hasPrevSep = idx > 0 && separators.contains(chars[idx - 1])
            let hasNextSep = (idx + 1) < chars.count && separators.contains(chars[idx + 1])

            if hasPrevSep && hasNextSep {
                chars.removeSubrange((idx - 1)...idx)
            } else if hasPrevSep {
                chars.removeSubrange((idx - 1)...idx)
            } else if hasNextSep {
                chars.removeSubrange(idx...(idx + 1))
            } else {
                chars.remove(at: idx)
            }
        }

        return String(chars)
    }

    private static func truncateToUTF8ByteBudget(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if string.utf8.count <= maxBytes {
            return string
        }
        var result = ""
        var usedBytes = 0
        for char in string {
            let charBytes = char.utf8.count
            if usedBytes + charBytes > maxBytes {
                break
            }
            result.append(char)
            usedBytes += charBytes
        }
        return result
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
        defaults.removeObject(forKey: filenameTemplateKey)
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

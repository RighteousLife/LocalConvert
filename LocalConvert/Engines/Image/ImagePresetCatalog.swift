import Foundation

// MARK: - Image Editor Preset Catalog & Project Persistence (.lcimg)

struct ImageBatchPresetOutcome: Sendable, Equatable, Identifiable {
    let id: UUID = UUID()
    let url: URL
    let succeeded: Bool
    let message: String
}

struct ImageBatchPresetReport: Sendable, Equatable {
    let presetName: String
    let outcomes: [ImageBatchPresetOutcome]
    let wasCancelled: Bool

    var succeededCount: Int { outcomes.filter(\.succeeded).count }
    var failedCount: Int { outcomes.filter { !$0.succeeded }.count }
}

enum ImagePresetCatalog {

    static let projectFileExtension: String = ImageProjectDocument.fileExtension

    /// Built-in non-destructive Look Presets expressed via the standard `SavedPreset` schema (`isBuiltIn = true`)
    /// so they integrate directly with `PresetManager`, `PresetValidator`, and Undo/Redo without duplicating preset systems.
    static let builtInLookPresets: [SavedPreset] = [
        makeBuiltInLookPreset(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000001")!,
            name: "Crisp Editorial",
            description: "Clean micro-contrast boost, gentle shadow lift, and refined unsharp mask.",
            adjustments: {
                var c = ImageColorAdjustmentsConfig()
                c.contrast = 1.12
                c.shadows = 0.22
                c.highlights = -0.18
                c.vibrance = 0.18
                return c
            }(),
            effects: [
                ImageEffectSlot(kind: .unsharpMask, isEnabled: true, intensity: 0.45, radius: 1.6)
            ]
        ),
        makeBuiltInLookPreset(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000002")!,
            name: "Warm Film Grain",
            description: "Warm golden highlights, gentle lifted blacks, subtle vignette, and 35mm grain.",
            adjustments: {
                var c = ImageColorAdjustmentsConfig()
                c.temperatureOffset = 18.0
                c.contrast = 1.08
                c.blacks = 0.12
                c.saturation = 0.92
                c.colorBalance.highlights = ImageRGBBalanceOffset(cyanRed: 0.18, magentaGreen: 0.04, yellowBlue: -0.22)
                return c
            }(),
            effects: [
                ImageEffectSlot(kind: .vignette, isEnabled: true, intensity: 0.45, radius: 0.72, falloff: 0.65),
                ImageEffectSlot(kind: .filmGrain, isEnabled: true, intensity: 0.25, grainSize: 1.35)
            ]
        ),
        makeBuiltInLookPreset(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000003")!,
            name: "High-Contrast Noir",
            description: "Punchy silver-gelatin monochrome conversion with deep shadows and vignette.",
            adjustments: {
                var c = ImageColorAdjustmentsConfig()
                c.contrast = 1.28
                c.highlights = -0.15
                c.blacks = -0.20
                return c
            }(),
            effects: [
                ImageEffectSlot(kind: .monochrome, isEnabled: true, intensity: 1.0),
                ImageEffectSlot(kind: .vignette, isEnabled: true, intensity: 0.65, radius: 0.62, falloff: 0.55)
            ]
        ),
        makeBuiltInLookPreset(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000004")!,
            name: "Portrait Soft Glow",
            description: "Balanced skin warmth, soft shadow recovery, and subtle noise smoothing.",
            adjustments: {
                var c = ImageColorAdjustmentsConfig()
                c.exposureEV = 0.18
                c.shadows = 0.30
                c.highlights = -0.22
                c.vibrance = 0.15
                c.temperatureOffset = 10.0
                return c
            }(),
            effects: [
                ImageEffectSlot(kind: .noiseReduction, isEnabled: true, intensity: 0.22, sharpness: 0.45)
            ]
        ),
        makeBuiltInLookPreset(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000005")!,
            name: "Golden Landscape",
            description: "Vibrant sky/foliage separation with deep shadow detail and clarity.",
            adjustments: {
                var c = ImageColorAdjustmentsConfig()
                c.contrast = 1.14
                c.highlights = -0.35
                c.shadows = 0.35
                c.vibrance = 0.38
                c.temperatureOffset = 12.0
                return c
            }(),
            effects: [
                ImageEffectSlot(kind: .sharpen, isEnabled: true, intensity: 0.45, sharpness: 0.55)
            ]
        ),
        makeBuiltInLookPreset(
            id: UUID(uuidString: "A1000001-0000-4000-8000-000000000006")!,
            name: "Vintage Sepia Matte",
            description: "Faded sepia tone with lifted black floor and subtle warm vignette.",
            adjustments: {
                var c = ImageColorAdjustmentsConfig()
                c.blacks = 0.20
                c.contrast = 0.94
                return c
            }(),
            effects: [
                ImageEffectSlot(kind: .sepia, isEnabled: true, intensity: 0.72),
                ImageEffectSlot(kind: .vignette, isEnabled: true, intensity: 0.48, radius: 0.75, falloff: 0.65)
            ]
        )
    ]

    static func makeBuiltInLookPreset(
        id: UUID = UUID(),
        name: String,
        description: String?,
        targetFormat: FileFormat = .jxl,
        adjustments: ImageColorAdjustmentsConfig,
        effects: [ImageEffectSlot],
        isBuiltIn: Bool = true
    ) -> SavedPreset {
        var toolboxCfg = ImageToolboxConfig()
        toolboxCfg.colorAdjustments = adjustments
        toolboxCfg.effectStack = effects

        var opts = ConversionOptions.default
        opts = toolboxCfg.applying(to: opts, outputFormat: targetFormat)
        opts.customOptions["image_look_only"] = "true"

        return SavedPreset(
            id: id,
            name: name,
            description: description,
            targetFormat: targetFormat,
            sourceCategoryConstraint: .image,
            options: opts,
            isBuiltIn: isBuiltIn
        )
    }

    static func makeUserLookPreset(
        name: String,
        description: String? = nil,
        targetFormat: FileFormat,
        config: ImageToolboxConfig
    ) -> SavedPreset {
        makeBuiltInLookPreset(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            targetFormat: targetFormat,
            adjustments: config.colorAdjustments,
            effects: config.effectStack,
            isBuiltIn: false
        )
    }

    static func isImageToolboxPreset(_ preset: SavedPreset) -> Bool {
        preset.sourceCategoryConstraint == .image && preset.options.customOptions["image_toolbox"] == "true"
    }

    static func isLookOnlyPreset(_ preset: SavedPreset) -> Bool {
        preset.options.customOptions["image_look_only"] == "true"
    }

    /// Validates that a preset contains a decodable, structurally valid ImageToolboxConfig.
    static func validatePreset(_ preset: SavedPreset) -> (isValid: Bool, reason: String?) {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Preset name cannot be empty.")
        }
        guard let cfg = ImageToolboxConfig.from(options: preset.options) else {
            return (false, "Preset '\(preset.name)' is missing valid Image Toolbox configuration data.")
        }
        _ = cfg
        return (true, nil)
    }

    /// Applies `preset` cleanly onto `config`.
    /// When `lookOnly` is true (or preset is flagged `image_look_only`), only Color & Effect adjustments update,
    /// leaving format, crop, resize, watermark, and privacy metadata intact.
    /// Each effect slot gets a fresh `UUID()` so per-image configs never alias mutable IDs.
    @discardableResult
    static func apply(preset: SavedPreset, lookOnly: Bool? = nil, to config: inout ImageToolboxConfig) -> Bool {
        guard var decoded = ImageToolboxConfig.from(options: preset.options) else {
            return false
        }
        decoded.colorAdjustments.clamped()
        let isolatedEffects = decoded.effectStack.map { slot -> ImageEffectSlot in
            var copy = slot
            copy.id = UUID()
            copy.clamped()
            return copy
        }

        let applyLook = lookOnly ?? isLookOnlyPreset(preset)
        if applyLook {
            config.colorAdjustments = decoded.colorAdjustments
            config.effectStack = isolatedEffects
        } else {
            decoded.effectStack = isolatedEffects
            config = decoded
        }
        return true
    }

    // MARK: - .lcimg Project Document Serialization & Relinking

    static func saveProject(
        _ document: ImageProjectDocument,
        to destinationURL: URL,
        protectedSourceURLs: [URL] = []
    ) throws {
        let resolvedDest = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedDest.path.hasPrefix("/"), !resolvedDest.path.contains("\0") else {
            throw ConversionError.invalidInput("Invalid project destination path.")
        }
        for src in protectedSourceURLs {
            if src.standardizedFileURL.resolvingSymlinksInPath() == resolvedDest {
                throw ConversionError.invalidInput("Project file cannot overwrite a source image file.")
            }
        }
        let rawSrc = URL(fileURLWithPath: document.sourcePath).standardizedFileURL.resolvingSymlinksInPath()
        if rawSrc == resolvedDest {
            throw ConversionError.invalidInput("Project file cannot overwrite its linked source image.")
        }

        let parent = resolvedDest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        let tmpURL = parent.appendingPathComponent(".\(resolvedDest.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try data.write(to: tmpURL, options: .atomic)
        if FileManager.default.fileExists(atPath: resolvedDest.path) {
            _ = try FileManager.default.replaceItemAt(resolvedDest, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: resolvedDest)
        }
    }

    static func loadProject(from fileURL: URL) throws -> (document: ImageProjectDocument, resolvedSourceURL: URL?, isSourceMissing: Bool) {
        let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ConversionError.invalidInput("Project file not found: \(fileURL.lastPathComponent)")
        }
        let data = try Data(contentsOf: resolved)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(ImageProjectDocument.self, from: data)

        guard doc.schemaVersion >= 1 && doc.schemaVersion <= ImageProjectDocument.currentSchemaVersion else {
            throw ConversionError.invalidInput("Unsupported .lcimg project schema version (\(doc.schemaVersion)).")
        }

        // Reject relative/traversal paths or NUL injections embedded in untrusted project files
        guard doc.sourcePath.hasPrefix("/"),
              !doc.sourcePath.contains("\0"),
              !doc.sourcePath.split(separator: "/").contains("..") else {
            return (doc, nil, true)
        }

        let rawSourceURL = URL(fileURLWithPath: doc.sourcePath).standardizedFileURL
        var srcIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: rawSourceURL.path, isDirectory: &srcIsDir),
           !srcIsDir.boolValue {
            let resolvedSrc = rawSourceURL.resolvingSymlinksInPath()
            if FileDetector.detectFormat(url: resolvedSrc)?.category == .image {
                return (doc, resolvedSrc, false)
            }
        }

        // Attempt security-scoped bookmark resolution if available
        if let bookmark = doc.sourceBookmarkData {
            var stale = false
            if let bookmarked = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                var bmIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: bookmarked.path, isDirectory: &bmIsDir), !bmIsDir.boolValue {
                    let resolvedBookmark = bookmarked.standardizedFileURL.resolvingSymlinksInPath()
                    if FileDetector.detectFormat(url: resolvedBookmark)?.category == .image {
                        return (doc, resolvedBookmark, false)
                    }
                }
            }
        }
        return (doc, nil, true)
    }
}

extension ImageProjectDocument {
    var sourceDisplayPath: String {
        URL(fileURLWithPath: sourcePath).lastPathComponent.isEmpty ? sourcePath : "\(URL(fileURLWithPath: sourcePath).lastPathComponent) (\(sourcePath))"
    }

    static func create(
        sourceURL: URL,
        targetFormat: FileFormat,
        config: ImageToolboxConfig
    ) -> ImageProjectDocument {
        let standardized = sourceURL.standardizedFileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: standardized.path)
        let size = attrs?[.size] as? Int64
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970
        let bookmark = try? standardized.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return ImageProjectDocument(
            sourcePath: standardized.path,
            sourceBookmarkData: bookmark,
            sourceFileSize: size,
            sourceModificationTime: mtime,
            targetFormat: targetFormat,
            config: config
        )
    }
}

import Foundation
import AppIntents
import UniformTypeIdentifiers
import os.log

// MARK: - AppIntents Errors

enum LocalConvertIntentError: Error, LocalizedError, CustomLocalizedStringResourceConvertible, Equatable, Sendable {
    case noInputFiles
    case invalidInputFile(String)
    case unrecognizedFileFormat(String)
    case unsupportedConversion(from: FileFormat, to: FileFormat)
    case presetNotFound(String)
    case incompatiblePreset(presetName: String, details: String)
    case outputDirectoryNotWritable(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputFiles:
            return "No input files were provided."
        case .invalidInputFile(let reason):
            return reason
        case .unrecognizedFileFormat(let filename):
            return "Could not recognize file format for '\(filename)'."
        case .unsupportedConversion(let from, let to):
            return "Converting from \(from.displayName) to \(to.displayName) is not supported."
        case .presetNotFound(let name):
            return "Saved preset '\(name)' could not be found."
        case .incompatiblePreset(let presetName, let details):
            return "Preset '\(presetName)' cannot be applied: \(details)"
        case .outputDirectoryNotWritable(let path):
            return "Output directory is not writable: \(path)"
        case .conversionFailed(let message):
            return message
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "Conversion failed.")
    }
}

// MARK: - Target Format AppEnum

enum IntentTargetFormat: String, AppEnum, CaseIterable, Sendable {
    // Documents & Data
    case pdf
    case docx
    case doc
    case dotx
    case xlsx
    case xls
    case xltx
    case pptx
    case ppt
    case potx
    case odt
    case ods
    case odp
    case rtf
    case csv
    case tsv
    case txt
    case md
    case html
    case epub
    case plist
    case json
    case xml

    // Images
    case jpg
    case png
    case webp
    case heic
    case tiff
    case bmp
    case gif
    case apng
    case avif
    case jp2
    case psd
    case exr
    case ppm
    case hdr
    case jxl
    case qoi
    case pcx
    case wbmp
    case ico
    case icns
    case tga

    // Audio
    case mp3
    case wav
    case flac
    case m4a
    case m4b
    case m4r
    case aac
    case ogg
    case opus
    case aiff
    case caf
    case alac
    case ac3
    case eac3
    case dts
    case wma
    case au
    case wv
    case mka

    // Video
    case mp4
    case mov
    case mkv
    case webm
    case avi
    case wmv
    case asf
    case m4v
    case threeGP = "3gp"
    case threeG2 = "3g2"
    case mpg
    case ts
    case flv
    case f4v
    case vob
    case m2v

    // Subtitles
    case srt
    case vtt
    case ass
    case ssa

    // Archives
    case zip
    case tar
    case tgz
    case tbz2
    case txz
    case sevenZ = "7z"
    case gz
    case bz2

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Target Format"

    static let caseDisplayRepresentations: [IntentTargetFormat: DisplayRepresentation] = [
        .pdf: "PDF",
        .docx: "DOCX (Word)",
        .doc: "DOC (Legacy Word)",
        .dotx: "DOTX (Word Template)",
        .xlsx: "XLSX (Excel)",
        .xls: "XLS (Legacy Excel)",
        .xltx: "XLTX (Excel Template)",
        .pptx: "PPTX (PowerPoint)",
        .ppt: "PPT (Legacy PowerPoint)",
        .potx: "POTX (PowerPoint Template)",
        .odt: "ODT (OpenDocument Text)",
        .ods: "ODS (OpenDocument Sheet)",
        .odp: "ODP (OpenDocument Slides)",
        .rtf: "RTF (Rich Text)",
        .csv: "CSV",
        .tsv: "TSV",
        .txt: "TXT (Plain Text)",
        .md: "Markdown (MD)",
        .html: "HTML",
        .epub: "EPUB (eBook)",
        .plist: "PLIST (Property List)",
        .json: "JSON",
        .xml: "XML",
        .jpg: "JPEG",
        .png: "PNG",
        .webp: "WebP",
        .heic: "HEIC",
        .tiff: "TIFF",
        .bmp: "BMP",
        .gif: "GIF",
        .apng: "APNG (Animated PNG)",
        .avif: "AVIF",
        .jp2: "JPEG 2000 (JP2)",
        .psd: "PSD (Photoshop)",
        .exr: "OpenEXR (EXR)",
        .ppm: "PPM / Netpbm",
        .hdr: "Radiance HDR",
        .jxl: "JPEG XL (JXL)",
        .qoi: "QOI (Quite OK Image)",
        .pcx: "PCX",
        .wbmp: "WBMP",
        .ico: "ICO",
        .icns: "ICNS (macOS Icon)",
        .tga: "TGA (Targa)",
        .mp3: "MP3",
        .wav: "WAV",
        .flac: "FLAC",
        .m4a: "M4A (AAC)",
        .m4b: "M4B (Audiobook)",
        .m4r: "M4R (iPhone Ringtone)",
        .aac: "AAC",
        .ogg: "OGG",
        .opus: "Opus",
        .aiff: "AIFF",
        .caf: "CAF (Core Audio)",
        .alac: "ALAC (Apple Lossless)",
        .ac3: "AC-3 (Dolby Digital)",
        .eac3: "E-AC-3 (Dolby Digital+)",
        .dts: "DTS",
        .wma: "WMA (Windows Media)",
        .au: "AU (Sun Audio)",
        .wv: "WavPack (WV)",
        .mka: "MKA (Matroska Audio)",
        .mp4: "MP4",
        .mov: "MOV (QuickTime)",
        .mkv: "MKV (Matroska)",
        .webm: "WebM",
        .avi: "AVI",
        .wmv: "WMV",
        .asf: "ASF",
        .m4v: "M4V",
        .threeGP: "3GP",
        .threeG2: "3G2",
        .mpg: "MPG (MPEG-2)",
        .ts: "TS (MPEG-TS)",
        .flv: "FLV (Flash Video)",
        .f4v: "F4V",
        .vob: "VOB (DVD Video)",
        .m2v: "M2V (MPEG-2 Video)",
        .srt: "SRT (SubRip)",
        .vtt: "VTT (WebVTT)",
        .ass: "ASS (SubStation)",
        .ssa: "SSA (SubStation)",
        .zip: "ZIP",
        .tar: "TAR",
        .tgz: "TAR.GZ",
        .tbz2: "TAR.BZ2",
        .txz: "TAR.XZ",
        .sevenZ: "7Z",
        .gz: "GZ (Gzip)",
        .bz2: "BZ2 (Bzip2)"
    ]

    var fileFormat: FileFormat {
        // Every case rawValue matches FileFormat.rawValue 1-to-1.
        FileFormat(rawValue: rawValue) ?? .pdf
    }

    init?(fileFormat: FileFormat) {
        self.init(rawValue: fileFormat.rawValue)
    }
}

// MARK: - Quality Preset AppEnum

enum IntentQualityPreset: String, AppEnum, CaseIterable, Sendable {
    case low
    case medium
    case high
    case maximum

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quality"

    static let caseDisplayRepresentations: [IntentQualityPreset: DisplayRepresentation] = [
        .low: "Low",
        .medium: "Medium",
        .high: "High",
        .maximum: "Maximum"
    ]

    var qualityPreset: QualityPreset {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .maximum: return .maximum
        }
    }
}

// MARK: - Saved Preset AppEntity & EntityQuery

struct SavedPresetEntity: AppEntity, Sendable, Equatable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Preset"
    static let defaultQuery = SavedPresetEntityQuery()

    let id: UUID
    let name: String
    let targetFormatRawValue: String
    let targetFormatDisplayName: String
    let presetDescription: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle = presetDescription.map { LocalizedStringResource(stringLiteral: $0) }
            ?? LocalizedStringResource(stringLiteral: "Convert to \(targetFormatDisplayName)")
        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: subtitle
        )
    }

    init(preset: SavedPreset) {
        self.id = preset.id
        self.name = preset.name
        self.targetFormatRawValue = preset.targetFormat.rawValue
        self.targetFormatDisplayName = preset.targetFormat.displayName
        self.presetDescription = preset.description
    }
}

struct SavedPresetEntityQuery: EntityStringQuery {
    private let presetsProvider: @Sendable () async -> [SavedPreset]

    init() {
        self.presetsProvider = {
            await MainActor.run {
                PresetManager.shared.presets
            }
        }
    }

    init(presetsProvider: @escaping @Sendable () async -> [SavedPreset]) {
        self.presetsProvider = presetsProvider
    }

    func entities(for identifiers: [UUID]) async throws -> [SavedPresetEntity] {
        let presets = await presetsProvider()
        var byID: [UUID: SavedPreset] = [:]
        for preset in presets where byID[preset.id] == nil {
            byID[preset.id] = preset
        }
        return identifiers.compactMap { byID[$0].map(SavedPresetEntity.init(preset:)) }
    }

    func suggestedEntities() async throws -> [SavedPresetEntity] {
        let presets = await presetsProvider()
        return presets.map(SavedPresetEntity.init(preset:))
    }

    func entities(matching string: String) async throws -> [SavedPresetEntity] {
        let presets = await presetsProvider()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return presets.map(SavedPresetEntity.init(preset:))
        }
        return presets.filter { preset in
            preset.name.localizedCaseInsensitiveContains(query)
                || (preset.description?.localizedCaseInsensitiveContains(query) ?? false)
                || preset.targetFormat.displayName.localizedCaseInsensitiveContains(query)
        }.map(SavedPresetEntity.init(preset:))
    }
}

// MARK: - Shared AppIntents Execution Support

enum LocalConvertIntentSupport {
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "AppIntents")

    struct StagedInputFile: Sendable {
        let url: URL
        let isDataOnlyStaging: Bool
    }

    struct StagedIntentBatch: Sendable {
        let items: [StagedInputFile]
        let stagingDirectories: [URL]

        func cleanup() {
            for dir in stagingDirectories {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    static func ensureEnginesRegistered(in registry: ConversionRegistry = .shared) {
        guard registry.registeredEngines.isEmpty else { return }
        registry.register(engine: ImageConversionEngine())
        registry.register(engine: OfficeConversionEngine())
        registry.register(engine: PDFConversionEngine())
        registry.register(engine: MediaConversionEngine())
        registry.register(engine: SubtitleConversionEngine())
        registry.register(engine: ArchiveConversionEngine())
        registry.register(engine: TextConversionEngine())
        registry.register(engine: PDFToolboxEngine())
    }

    static func validateAndStageIntentFiles(_ files: [IntentFile]) throws -> StagedIntentBatch {
        guard !files.isEmpty else {
            throw LocalConvertIntentError.noInputFiles
        }

        var stagedItems: [StagedInputFile] = []
        var stagingDirs: [URL] = []
        var seenFilePaths = Set<String>()

        do {
            for file in files {
                if let fileURL = file.fileURL {
                    switch FinderHandoffHandler.validateInputFileURL(fileURL) {
                    case .success(let safeURL):
                        let dedupKey = safeURL.standardizedFileURL.path
                        if seenFilePaths.insert(dedupKey).inserted {
                            stagedItems.append(StagedInputFile(url: safeURL, isDataOnlyStaging: false))
                        }
                    case .failure(let error):
                        logger.warning("AppIntent rejected input file '\(fileURL.lastPathComponent, privacy: .private)': \(error.localizedDescription, privacy: .private)")
                        throw LocalConvertIntentError.invalidInputFile(error.localizedDescription)
                    }
                } else {
                    let stagingDir = AppStoragePaths.cachesDirectory
                        .appendingPathComponent("AppIntentsStaging", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                    stagingDirs.append(stagingDir)

                    let sanitizedFilename = sanitizeStagedFilename(file.filename, fallbackUTType: file.type)
                    let stagedURL = stagingDir.appendingPathComponent(sanitizedFilename, isDirectory: false)
                    try file.data.write(to: stagedURL, options: .atomic)

                    switch FinderHandoffHandler.validateInputFileURL(stagedURL) {
                    case .success(let safeStagedURL):
                        stagedItems.append(StagedInputFile(url: safeStagedURL, isDataOnlyStaging: true))
                    case .failure(let error):
                        throw LocalConvertIntentError.invalidInputFile(error.localizedDescription)
                    }
                }
            }
        } catch {
            for dir in stagingDirs {
                try? FileManager.default.removeItem(at: dir)
            }
            throw error
        }

        return StagedIntentBatch(items: stagedItems, stagingDirectories: stagingDirs)
    }

    private static func sanitizeStagedFilename(_ rawName: String, fallbackUTType: UTType?) -> String {
        let leaf = URL(fileURLWithPath: rawName).lastPathComponent
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let baseLeaf: String
        if leaf.isEmpty || leaf == "." || leaf == ".." {
            baseLeaf = "input"
        } else {
            baseLeaf = leaf
        }

        let currentExt = URL(fileURLWithPath: baseLeaf).pathExtension
        if currentExt.isEmpty, let preferredExt = fallbackUTType?.preferredFilenameExtension {
            return "\(baseLeaf).\(preferredExt)"
        }
        return baseLeaf
    }

    static func resolveOutputDirectory(
        for item: StagedInputFile,
        destinationOverride: URL?,
        policy: OutputDestinationPolicy = .defaultLocation
    ) async throws -> URL {
        let targetDir: URL
        if let destinationOverride {
            targetDir = destinationOverride
        } else if item.isDataOnlyStaging {
            targetDir = AppStoragePaths.cachesDirectory
                .appendingPathComponent("AppIntentsOutputs", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        } else {
            switch policy {
            case .customDirectory(let path):
                targetDir = URL(fileURLWithPath: path, isDirectory: true)
            case .sameAsInput:
                targetDir = item.url.deletingLastPathComponent()
            case .defaultLocation:
                targetDir = await MainActor.run {
                    OutputManager.resolveOutputDirectory(
                        for: item.url,
                        preference: AppSettings.shared.defaultOutputLocation.outputLocation,
                        customDirectory: AppSettings.shared.customOutputDirectory
                    )
                }
            }
        }

        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        guard OutputManager.isOutputDirectoryValid(targetDir) else {
            throw LocalConvertIntentError.outputDirectoryNotWritable(targetDir.path)
        }
        return targetDir
    }

    @MainActor
    static func runJob(
        _ job: ConversionJob,
        conversionManager: ConversionManager
    ) async throws -> ConversionResult {
        let status: ConversionJobStatus = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                conversionManager.submit(job: job) { finalStatus in
                    continuation.resume(returning: finalStatus)
                }
            }
        } onCancel: {
            Task { @MainActor in
                conversionManager.cancel(jobId: job.id)
            }
        }

        switch status {
        case .completed(let result):
            return result
        case .failed(let error):
            throw LocalConvertIntentError.conversionFailed(error.localizedDescription)
        case .cancelled:
            throw CancellationError()
        case .waiting, .converting:
            throw LocalConvertIntentError.conversionFailed("Conversion did not reach a terminal state.")
        }
    }
}

// MARK: - Convert Files AppIntent

struct ConvertFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Files"
    static let description = IntentDescription("Converts files locally to the selected format using LocalConvert.")

    @Parameter(title: "Files", description: "Files to convert.")
    var files: [IntentFile]

    @Parameter(title: "Target Format", description: "Target format to convert the files to.")
    var targetFormat: IntentTargetFormat

    @Parameter(title: "Quality", description: "Output quality preset for lossy conversions.", default: .high)
    var quality: IntentQualityPreset

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) to \(\.$targetFormat)") {
            \.$quality
        }
    }

    init() {}

    init(
        files: [IntentFile],
        targetFormat: IntentTargetFormat,
        quality: IntentQualityPreset = .high
    ) {
        self.init()
        self.files = files
        self.targetFormat = targetFormat
        self.quality = quality
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await execute()
        return .result(value: outputs)
    }

    func execute(
        destinationOverride: URL? = nil,
        conversionManager: ConversionManager? = nil,
        registry: ConversionRegistry = .shared
    ) async throws -> [IntentFile] {
        LocalConvertIntentSupport.ensureEnginesRegistered(in: registry)
        let batch = try LocalConvertIntentSupport.validateAndStageIntentFiles(files)
        defer { batch.cleanup() }

        let detector = FileDetector()
        let outputFormat = targetFormat.fileFormat
        let qualityPreset = quality.qualityPreset

        var preparedJobs: [(item: LocalConvertIntentSupport.StagedInputFile, inputFormat: FileFormat, options: ConversionOptions)] = []
        for item in batch.items {
            let detection = detector.detect(url: item.url)
            guard let inputFormat = detection.bestFormat else {
                throw LocalConvertIntentError.unrecognizedFileFormat(item.url.lastPathComponent)
            }

            var options = ConversionOptions.default
            options.overwriteExisting = false
            options.imageQuality = qualityPreset.value
            options.mediaQuality = qualityPreset

            guard registry.findEngine(from: inputFormat, to: outputFormat, options: options) != nil else {
                throw LocalConvertIntentError.unsupportedConversion(from: inputFormat, to: outputFormat)
            }
            preparedJobs.append((item: item, inputFormat: inputFormat, options: options))
        }

        let manager: ConversionManager
        if let conversionManager {
            manager = conversionManager
        } else {
            manager = await MainActor.run {
                ConversionManager(registry: registry, historyManager: .shared)
            }
        }

        let batchID = preparedJobs.count > 1 ? UUID() : nil
        var outputIntentFiles: [IntentFile] = []

        for entry in preparedJobs {
            try Task.checkCancellation()
            let outputDir = try await LocalConvertIntentSupport.resolveOutputDirectory(
                for: entry.item,
                destinationOverride: destinationOverride
            )

            let job = ConversionJob(
                inputURLs: [entry.item.url],
                inputFormat: entry.inputFormat,
                outputFormat: outputFormat,
                outputDirectory: outputDir,
                options: entry.options,
                batchID: batchID,
                source: .manual
            )

            let result = try await LocalConvertIntentSupport.runJob(job, conversionManager: manager)
            for outURL in result.allOutputURLs {
                outputIntentFiles.append(
                    IntentFile(
                        fileURL: outURL,
                        filename: outURL.lastPathComponent,
                        type: result.outputFormat.utType
                    )
                )
            }
        }

        return outputIntentFiles
    }
}

// MARK: - Run Saved Preset AppIntent

struct RunSavedPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Saved Preset"
    static let description = IntentDescription("Runs a saved LocalConvert preset on the provided files.")

    @Parameter(title: "Files", description: "Files to process using the saved preset.")
    var files: [IntentFile]

    @Parameter(title: "Preset", description: "Saved LocalConvert preset to apply.")
    var preset: SavedPresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$preset) on \(\.$files)")
    }

    init() {}

    init(files: [IntentFile], preset: SavedPresetEntity) {
        self.init()
        self.files = files
        self.preset = preset
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await execute()
        return .result(value: outputs)
    }

    func execute(
        presetsOverride: [SavedPreset]? = nil,
        destinationOverride: URL? = nil,
        conversionManager: ConversionManager? = nil,
        registry: ConversionRegistry = .shared
    ) async throws -> [IntentFile] {
        LocalConvertIntentSupport.ensureEnginesRegistered(in: registry)
        let batch = try LocalConvertIntentSupport.validateAndStageIntentFiles(files)
        defer { batch.cleanup() }

        let availablePresets: [SavedPreset]
        if let presetsOverride {
            availablePresets = presetsOverride
        } else {
            availablePresets = await MainActor.run {
                PresetManager.shared.presets
            }
        }

        guard let savedPreset = availablePresets.first(where: { $0.id == preset.id }) else {
            throw LocalConvertIntentError.presetNotFound(preset.name)
        }

        let validator = PresetValidator()
        let detector = FileDetector()
        let urls = batch.items.map(\.url)
        let validation = validator.validateBatch(
            preset: savedPreset,
            urls: urls,
            fileDetector: detector,
            registry: registry
        )

        guard !validation.compatibleURLs.isEmpty else {
            let reason = validation.incompatibleURLs.first?.reason ?? "No compatible input files were provided."
            throw LocalConvertIntentError.incompatiblePreset(presetName: savedPreset.name, details: reason)
        }

        let manager: ConversionManager
        if let conversionManager {
            manager = conversionManager
        } else {
            manager = await MainActor.run {
                ConversionManager(registry: registry, historyManager: .shared)
            }
        }

        let compatibleSet = Set(validation.compatibleURLs.map(\.standardizedFileURL))
        let compatibleItems = batch.items.filter { compatibleSet.contains($0.url.standardizedFileURL) }
        let batchID = compatibleItems.count > 1 ? UUID() : nil

        var outputIntentFiles: [IntentFile] = []

        for item in compatibleItems {
            try Task.checkCancellation()
            let detection = detector.detect(url: item.url)
            guard let inputFormat = detection.bestFormat else {
                throw LocalConvertIntentError.unrecognizedFileFormat(item.url.lastPathComponent)
            }

            let outputDir = try await LocalConvertIntentSupport.resolveOutputDirectory(
                for: item,
                destinationOverride: destinationOverride,
                policy: savedPreset.outputDestinationPolicy
            )

            var jobOptions = savedPreset.options
            // AppIntents must never overwrite source media or existing outputs unexpectedly by default.
            jobOptions.overwriteExisting = false
            jobOptions.customOptions["preset_name"] = savedPreset.name
            switch savedPreset.outputNamingPolicy {
            case .addSuffix(let suffix):
                jobOptions.customOptions["output_suffix"] = suffix
            case .addPrefix(let prefix):
                jobOptions.customOptions["output_prefix"] = prefix
            case .standard:
                break
            }

            let job = ConversionJob(
                inputURLs: [item.url],
                inputFormat: inputFormat,
                outputFormat: savedPreset.targetFormat,
                outputDirectory: outputDir,
                options: jobOptions,
                batchID: batchID,
                presetName: savedPreset.name,
                source: .manual
            )

            let result = try await LocalConvertIntentSupport.runJob(job, conversionManager: manager)
            for outURL in result.allOutputURLs {
                outputIntentFiles.append(
                    IntentFile(
                        fileURL: outURL,
                        filename: outURL.lastPathComponent,
                        type: result.outputFormat.utType
                    )
                )
            }
        }

        return outputIntentFiles
    }
}

// MARK: - App Shortcuts Provider

struct LocalConvertShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertFilesIntent(),
            phrases: [
                "Convert files with \(.applicationName)",
                "Batch convert files with \(.applicationName)"
            ],
            shortTitle: "Convert Files",
            systemImageName: "arrow.triangle.2.circlepath"
        )

        AppShortcut(
            intent: RunSavedPresetIntent(),
            phrases: [
                "Run saved preset in \(.applicationName)",
                "Apply preset with \(.applicationName)"
            ],
            shortTitle: "Run Saved Preset",
            systemImageName: "slider.horizontal.3"
        )
    }
}

import Foundation
import Darwin
import os

// MARK: - Quality Preset

enum QualityPreset: String, Sendable, CaseIterable, Codable, Equatable, Hashable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case maximum = "Maximum"
    
    var value: Double {
        switch self {
        case .low: return 0.50
        case .medium: return 0.75
        case .high: return 0.90
        case .maximum: return 1.00
        }
    }
}

// MARK: - PDF to Office Conversion Mode

enum PDFOfficeConversionMode: String, Sendable, CaseIterable, Codable, Equatable, Hashable {
    /// Automatically choose the best conversion approach
    case automatic = "Automatic"
    /// Attempt editable text extraction (LibreOffice writer_pdf_import)
    case editable = "Editable"
    /// Visual mode: render PDF pages as images embedded in the output
    case visual = "Visual"
}

// MARK: - Smart Presets

enum ConversionPreset: String, Sendable, CaseIterable, Codable, Equatable, Hashable {
    case custom = "Custom"
    case web = "Web Optimized"
    case maximumQuality = "Maximum Quality"
    case smallFile = "Small File"
    case appleDevice = "Apple Device"
    case videoMaximumCompatibility = "Maximum Compatibility"
    case audioOnly = "Audio Only"
    case documentPDF = "PDF"
    case documentEditable = "Editable"
    case documentPrintArchive = "Print / Archive"
    
    func targetOutputFormat(for inputCategory: FormatCategory) -> FileFormat? {
        switch self {
        case .audioOnly: return .mp3
        case .documentPDF, .documentPrintArchive: return .pdf
        case .documentEditable: return .docx
        case .videoMaximumCompatibility, .appleDevice:
            return inputCategory == .video ? .mp4 : nil
        default:
            return nil
        }
    }
}

// MARK: - Conversion Options

struct ConversionOptions: Sendable, Codable, Equatable, Hashable {
    var preset: ConversionPreset?
    var preserveMetadata: Bool
    var overwriteExisting: Bool
    var imageQuality: Double? // 0.0...1.0 for lossy formats (default 0.90)
    var pdfDPI: Double? // DPI for PDF rendering (default 150.0)
    var pdfOfficeMode: PDFOfficeConversionMode? // PDF → Office conversion mode
    var webpLossless: Bool // WebP lossless encoding (default false = lossy)
    var mediaQuality: QualityPreset? // Quality preset for audio/video (default .high)
    var targetFileSizeMB: Double? // For bounded file sizes (e.g. 25MB for Discord)
    var targetFileSizeBytes: Int64? // Target file size in bytes (e.g. 500_000 for 500 KB)
    
    // Image Optimization & Resize & Crop
    var imageOptimizationMode: ImageOptimizationMode
    var resizeMode: ImageResizeMode
    var resizeWidth: Int?
    var resizeHeight: Int?
    var resizePercentage: Double? // e.g. 0.50 for 50%
    var preserveAspectRatio: Bool
    var cropMode: ImageCropMode
    var cropAspectRatio: ImageCropAspectRatio
    var cropRect: NormalizedRect?
    var videoTrim: VideoTrimRange? = nil
    
    var customOptions: [String: String]
    
    init(
        preset: ConversionPreset? = nil,
        preserveMetadata: Bool = true,
        overwriteExisting: Bool = false,
        imageQuality: Double? = 0.90,
        pdfDPI: Double? = 150.0,
        pdfOfficeMode: PDFOfficeConversionMode? = .automatic,
        webpLossless: Bool = false,
        mediaQuality: QualityPreset? = .high,
        targetFileSizeMB: Double? = nil,
        targetFileSizeBytes: Int64? = nil,
        imageOptimizationMode: ImageOptimizationMode = .balanced,
        resizeMode: ImageResizeMode = .none,
        resizeWidth: Int? = nil,
        resizeHeight: Int? = nil,
        resizePercentage: Double? = nil,
        preserveAspectRatio: Bool = true,
        cropMode: ImageCropMode = .none,
        cropAspectRatio: ImageCropAspectRatio = .original,
        cropRect: NormalizedRect? = nil,
        videoTrim: VideoTrimRange? = nil,
        customOptions: [String: String] = [:]
    ) {
        self.preset = preset
        self.preserveMetadata = preserveMetadata
        self.overwriteExisting = overwriteExisting
        self.imageQuality = imageQuality
        self.pdfDPI = pdfDPI
        self.pdfOfficeMode = pdfOfficeMode
        self.webpLossless = webpLossless
        self.mediaQuality = mediaQuality
        self.targetFileSizeMB = targetFileSizeMB
        self.targetFileSizeBytes = targetFileSizeBytes
        self.imageOptimizationMode = imageOptimizationMode
        self.resizeMode = resizeMode
        self.resizeWidth = resizeWidth
        self.resizeHeight = resizeHeight
        self.resizePercentage = resizePercentage
        self.preserveAspectRatio = preserveAspectRatio
        self.cropMode = cropMode
        self.cropAspectRatio = cropAspectRatio
        self.cropRect = cropRect
        self.videoTrim = videoTrim
        self.customOptions = customOptions
    }

    /// Normalized preset: treats `.custom` and `nil` identically as `nil` (custom/manual configuration).
    var effectivePreset: ConversionPreset? {
        guard let preset, preset != .custom else { return nil }
        return preset
    }

    static let h264AACVideoContainers: Set<FileFormat> = [
        .mp4, .mov, .m4v, .mkv, .ts, .f4v, .threeGP, .threeG2
    ]

    private static let presetOwnedHiddenKeys: Set<String> = [
        "vcodec",
        "acodec",
        "pix_fmt",
        "profile:v",
        "audio_only",
        "pdf_archive",
        "preset_name"
    ]

    private static let presetOwnedCustomOptionKeys: Set<String> = presetOwnedHiddenKeys.union([
        "m4a_lossless",
        "audio_codec",
        "audio_sample_rate",
        "audio_channels"
    ])

    mutating func clearPresetOwnedHiddenOptions() {
        for key in Self.presetOwnedHiddenKeys {
            customOptions.removeValue(forKey: key)
        }
    }

    private mutating func resetPresetOwnedFields() {
        imageQuality = 0.90
        preserveMetadata = true
        pdfDPI = 150.0
        pdfOfficeMode = .automatic
        webpLossless = false
        mediaQuality = .high
        targetFileSizeMB = nil
        targetFileSizeBytes = nil
        imageOptimizationMode = .balanced
        for key in Self.presetOwnedCustomOptionKeys {
            customOptions.removeValue(forKey: key)
        }
    }

    mutating func applyPreset() {
        applyPreset(preset, inputFormat: nil, outputFormat: nil)
    }

    /// Atomically normalizes and applies `targetPreset` for an optional conversion route.
    /// Clears stale preset-owned fields from prior presets and avoids applying settings
    /// that do not apply to `outputFormat` when a format context is provided.
    mutating func applyPreset(
        _ targetPreset: ConversionPreset?,
        inputFormat: FileFormat? = nil,
        outputFormat: FileFormat? = nil
    ) {
        guard let targetPreset, targetPreset != .custom else {
            self.preset = nil
            self.customOptions.removeValue(forKey: "preset_name")
            return
        }

        self.preset = targetPreset
        resetPresetOwnedFields()

        let category = outputFormat?.category

        switch targetPreset {
        case .web:
            preserveMetadata = false
            switch category {
            case .audio:
                mediaQuality = .medium
            case .video:
                mediaQuality = .medium
            case .image:
                imageQuality = 0.75
                webpLossless = false
                imageOptimizationMode = .balanced
            case .document:
                imageQuality = 0.75
            case nil:
                imageQuality = 0.75
                webpLossless = false
                imageOptimizationMode = .balanced
                mediaQuality = .medium
            default:
                mediaQuality = .medium
            }

        case .maximumQuality:
            preserveMetadata = true
            switch category {
            case .audio:
                mediaQuality = .maximum
            case .video:
                mediaQuality = .maximum
            case .image:
                imageQuality = 1.0
                webpLossless = (outputFormat == .webp)
                imageOptimizationMode = .quality
            case .document:
                pdfDPI = 300.0
                imageQuality = 1.0
            case nil:
                imageQuality = 1.0
                webpLossless = true
                imageOptimizationMode = .quality
                mediaQuality = .maximum
                pdfDPI = 300.0
            default:
                mediaQuality = .maximum
            }

        case .smallFile:
            preserveMetadata = false
            switch category {
            case .audio:
                // Audio outputs do not enforce fixed MB target caps; optimize via quality + metadata stripping.
                mediaQuality = .low
            case .video:
                mediaQuality = .low
                targetFileSizeBytes = 1_000_000
                targetFileSizeMB = 1.0
            case .image:
                imageQuality = 0.50
                webpLossless = false
                imageOptimizationMode = .targetFileSize
                targetFileSizeBytes = 1_000_000 // 1 MB
                targetFileSizeMB = 1.0
            case .document:
                pdfDPI = 72.0
                imageQuality = 0.50
            case nil:
                imageQuality = 0.50
                webpLossless = false
                imageOptimizationMode = .targetFileSize
                targetFileSizeBytes = 1_000_000 // 1 MB
                targetFileSizeMB = 1.0
                mediaQuality = .low
                pdfDPI = 72.0
            default:
                mediaQuality = .low
            }

        case .appleDevice:
            preserveMetadata = true
            switch category {
            case .image:
                imageQuality = 0.85
                webpLossless = false
                imageOptimizationMode = .balanced
            case .video:
                mediaQuality = .high
                if let outputFormat, Self.h264AACVideoContainers.contains(outputFormat) {
                    customOptions["vcodec"] = "h264_videotoolbox"
                    customOptions["acodec"] = "aac_at"
                }
            case nil:
                imageQuality = 0.85
                mediaQuality = .high
                customOptions["vcodec"] = "h264_videotoolbox"
                customOptions["acodec"] = "aac_at"
            default:
                mediaQuality = .high
            }

        case .videoMaximumCompatibility:
            preserveMetadata = true
            mediaQuality = .medium
            if outputFormat == nil || (category == .video && Self.h264AACVideoContainers.contains(outputFormat!)) {
                customOptions["vcodec"] = "h264_videotoolbox"
                customOptions["acodec"] = "aac"
                customOptions["pix_fmt"] = "yuv420p"
                customOptions["profile:v"] = "main"
            }

        case .audioOnly:
            preserveMetadata = true
            mediaQuality = .high
            customOptions["audio_only"] = "true"

        case .documentPDF:
            pdfDPI = 150.0

        case .documentEditable:
            pdfOfficeMode = .editable

        case .documentPrintArchive:
            pdfDPI = 300.0
            preserveMetadata = true
            customOptions["pdf_archive"] = "true"

        case .custom:
            self.preset = nil
        }

        // Preserve inputFormat reference for future format-pair-specific adjustments
        _ = inputFormat
    }

    /// Returns a format-specific explanatory note when the active preset includes aspects
    /// that do not apply to `outputFormat` (e.g., lossless audio formats or audio MB caps).
    func unsupportedPresetNotice(for outputFormat: FileFormat?) -> String? {
        guard let activePreset = effectivePreset, let outputFormat else { return nil }
        let losslessAudioFormats: Set<FileFormat> = [.wav, .flac, .alac, .aiff, .caf, .au, .wv, .mka]
        if losslessAudioFormats.contains(outputFormat), activePreset == .smallFile || activePreset == .web {
            return "\(outputFormat.displayName) is lossless; bitrate compression does not reduce output size, though metadata stripping still applies."
        }
        if outputFormat == .png || outputFormat == .bmp || outputFormat == .tiff {
            if activePreset == .smallFile || activePreset == .web {
                return "\(outputFormat.displayName) uses lossless compression; lossy quality settings do not apply."
            }
        }
        return nil
    }

    /// Evaluates whether the current options match `candidate` for the active route descriptors.
    func matchesPreset(
        _ candidate: ConversionPreset,
        descriptors: [ConversionOptionDescriptor],
        inputFormat: FileFormat? = nil,
        outputFormat: FileFormat? = nil
    ) -> Bool {
        guard candidate != .custom else { return false }

        var expected = self
        expected.applyPreset(candidate, inputFormat: inputFormat, outputFormat: outputFormat)

        let isImageRoute = outputFormat?.category == .image
            || (descriptors.contains(where: { $0.id == "imageQuality" || $0.id == "webpLossless" })
                && !descriptors.contains(where: { $0.id == "pdfDPI" }))

        for descriptor in descriptors {
            switch descriptor.id {
            case "preset", "overwriteExisting":
                continue
            case "mediaQuality":
                if effectiveMediaQuality != expected.effectiveMediaQuality {
                    return false
                }
            case "preserveMetadata":
                if preserveMetadata != expected.preserveMetadata {
                    return false
                }
            case "imageQuality":
                if abs(effectiveImageQuality - expected.effectiveImageQuality) > 0.001 {
                    return false
                }
            case "webpLossless":
                if webpLossless != expected.webpLossless {
                    return false
                }
            case "targetFileSizeMB":
                if effectiveTargetFileSizeBytes != expected.effectiveTargetFileSizeBytes {
                    return false
                }
            case "pdfDPI":
                if abs(effectivePDFDPI - expected.effectivePDFDPI) > 0.1 {
                    return false
                }
            case "pdfOfficeMode":
                if effectivePDFOfficeMode != expected.effectivePDFOfficeMode {
                    return false
                }
            default:
                switch descriptor.kind {
                case .toggle(_, let defaultValue):
                    let actualBool = customOptions[descriptor.id].map { $0 == "true" } ?? defaultValue
                    let expectedBool = expected.customOptions[descriptor.id].map { $0 == "true" } ?? defaultValue
                    if actualBool != expectedBool {
                        return false
                    }
                case .picker(_, let defaultValue):
                    let actualVal = customOptions[descriptor.id] ?? defaultValue
                    let expectedVal = expected.customOptions[descriptor.id] ?? defaultValue
                    if actualVal != expectedVal {
                        return false
                    }
                default:
                    break
                }
            }
        }

        if isImageRoute {
            if imageOptimizationMode != expected.imageOptimizationMode {
                return false
            }
            if effectiveTargetFileSizeBytes != expected.effectiveTargetFileSizeBytes {
                return false
            }
            if abs(effectiveImageQuality - expected.effectiveImageQuality) > 0.001 {
                return false
            }
            if outputFormat == nil || outputFormat == .webp || descriptors.contains(where: { $0.id == "webpLossless" }) {
                if webpLossless != expected.webpLossless {
                    return false
                }
            }
            if preserveMetadata != expected.preserveMetadata {
                return false
            }
        }

        // Verify hidden preset-owned codec/mode flags for presets that define them
        switch candidate {
        case .appleDevice:
            if outputFormat == nil || outputFormat?.category == .video {
                if customOptions["vcodec"] != expected.customOptions["vcodec"]
                    || customOptions["acodec"] != expected.customOptions["acodec"] {
                    return false
                }
            }
        case .videoMaximumCompatibility:
            if outputFormat == nil || outputFormat?.category == .video {
                if customOptions["vcodec"] != expected.customOptions["vcodec"]
                    || customOptions["acodec"] != expected.customOptions["acodec"]
                    || customOptions["pix_fmt"] != expected.customOptions["pix_fmt"]
                    || customOptions["profile:v"] != expected.customOptions["profile:v"] {
                    return false
                }
            }
        case .audioOnly:
            if customOptions["audio_only"] != expected.customOptions["audio_only"] {
                return false
            }
        case .documentPrintArchive:
            if customOptions["pdf_archive"] != expected.customOptions["pdf_archive"] {
                return false
            }
        default:
            // If current options still carry hidden flags from another preset, it does not match a plain preset
            if customOptions["vcodec"] != nil
                || customOptions["acodec"] != nil
                || customOptions["pix_fmt"] != nil
                || customOptions["profile:v"] != nil
                || customOptions["audio_only"] != nil
                || customOptions["pdf_archive"] != nil {
                return false
            }
        }

        return true
    }

    /// Re-evaluates `preset` after a user edits an individual setting:
    /// - Keeps the active named preset if settings still match it.
    /// - Transitions to `nil` (`Custom`) if settings diverged.
    /// - Automatically restores a named preset when settings unambiguously match exactly one preset in `availablePresets`.
    mutating func reconcilePresetAfterManualEdit(
        availablePresets: [ConversionPreset],
        descriptors: [ConversionOptionDescriptor],
        inputFormat: FileFormat? = nil,
        outputFormat: FileFormat? = nil
    ) {
        let namedPresets = availablePresets.filter { $0 != .custom }
        guard !namedPresets.isEmpty else {
            preset = nil
            return
        }

        if let current = effectivePreset,
           namedPresets.contains(current),
           matchesPreset(current, descriptors: descriptors, inputFormat: inputFormat, outputFormat: outputFormat) {
            preset = current
            return
        }

        let matching = namedPresets.filter {
            matchesPreset($0, descriptors: descriptors, inputFormat: inputFormat, outputFormat: outputFormat)
        }
        if matching.count == 1, let unambiguous = matching.first {
            preset = unambiguous
        } else {
            preset = nil
        }
        if preset == nil {
            customOptions.removeValue(forKey: "preset_name")
        }
    }
    
    static let `default` = ConversionOptions()
    
    /// Effective JPEG/lossy quality (defaults to 0.90 if nil)
    var effectiveImageQuality: Double {
        imageQuality ?? 0.90
    }
    
    /// Effective target file size in bytes
    var effectiveTargetFileSizeBytes: Int64? {
        if let bytes = targetFileSizeBytes, bytes > 0 {
            return bytes
        }
        if let mb = targetFileSizeMB, mb > 0 {
            return Int64(mb * 1_000_000)
        }
        return nil
    }
    
    /// Returns true if any image optimization, resize, crop, or target size is active
    var hasImageOptimization: Bool {
        resizeMode != .none || cropMode != .none || effectiveTargetFileSizeBytes != nil || imageOptimizationMode != .balanced
    }

    /// Returns true when a single-range video trim is configured.
    var hasVideoTrim: Bool {
        videoTrim != nil
    }
    
    /// Effective PDF rendering DPI (defaults to 150.0 if nil)
    var effectivePDFDPI: Double {
        pdfDPI ?? 150.0
    }
    
    /// Effective PDF to Office conversion mode (defaults to .automatic if nil)
    var effectivePDFOfficeMode: PDFOfficeConversionMode {
        pdfOfficeMode ?? .automatic
    }
    
    /// Effective media (audio/video) quality preset (defaults to .high if nil)
    var effectiveMediaQuality: QualityPreset {
        mediaQuality ?? .high
    }

    /// Effective existing-file collision behavior honoring both `overwriteExisting` toggle and `customOptions["existing_file_handling"]`.
    var resolvedExistingFileHandling: ExistingFileHandling {
        if overwriteExisting {
            return .overwrite
        }
        if customOptions["existing_file_handling"] == ExistingFileHandling.skip.rawValue {
            return .skip
        }
        return .createUnique
    }
}



// MARK: - Conversion Progress

struct ConversionProgress: Sendable, Equatable {
    let fractionCompleted: Double? // nil = indeterminate
    let statusMessage: String
    
    static let indeterminate = ConversionProgress(fractionCompleted: nil, statusMessage: "Converting...")
    
    static func determinate(_ fraction: Double, message: String = "Converting...") -> ConversionProgress {
        ConversionProgress(fractionCompleted: min(max(fraction, 0), 1), statusMessage: message)
    }
}

// MARK: - Conversion Result

struct ConversionResult: Sendable, Equatable {
    let outputURL: URL
    let additionalOutputURLs: [URL]
    let outputFormat: FileFormat
    let fileSize: Int64
    let duration: TimeInterval
    let engineName: String
    
    var allOutputURLs: [URL] {
        [outputURL] + additionalOutputURLs
    }
    
    init(
        outputURL: URL,
        additionalOutputURLs: [URL] = [],
        outputFormat: FileFormat = .png,
        fileSize: Int64 = 0,
        duration: TimeInterval = 0,
        engineName: String = ""
    ) {
        self.outputURL = outputURL
        self.additionalOutputURLs = additionalOutputURLs
        self.outputFormat = outputFormat
        self.fileSize = fileSize
        self.duration = duration
        self.engineName = engineName
    }
}

// MARK: - Conversion Error

enum ConversionError: LocalizedError, Sendable, Equatable {
    case unsupportedConversion(from: FileFormat, to: FileFormat)
    case inputFileNotFound(URL)
    case outputDirectoryNotWritable(URL)
    case engineNotAvailable(String)
    case engineExecutionFailed(String, underlyingError: String?)
    case cancelled
    case invalidInput(String)
    case outputFileAlreadyExists(URL)
    case insufficientDiskSpace
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedConversion(let from, let to):
            return "Converting from \(from.displayName) to \(to.displayName) is not supported."
        case .inputFileNotFound(let url):
            return "The input file could not be found at: \(url.lastPathComponent)"
        case .outputDirectoryNotWritable(let url):
            return "Cannot write to the output directory: \(url.lastPathComponent)"
        case .engineNotAvailable(let name):
            return "The conversion engine '\(name)' is not available on this system."
        case .engineExecutionFailed(let message, _):
            return "Conversion failed: \(message)"
        case .cancelled:
            return "The conversion was cancelled."
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .outputFileAlreadyExists(let url):
            return "A file already exists at: \(url.lastPathComponent)"
        case .insufficientDiskSpace:
            return "There is not enough disk space for the conversion."
        case .unknown(let message):
            return "An unexpected error occurred: \(message)"
        }
    }
    
    var userFacingMessage: String {
        errorDescription ?? "Conversion failed"
    }
    
    var technicalDetails: String? {
        switch self {
        case .engineExecutionFailed(_, let underlying):
            return underlying
        default:
            return nil
        }
    }
}

// MARK: - Option Descriptors

struct OptionChoice: Identifiable, Sendable, Equatable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

enum OptionKind: Sendable, Equatable {
    case preset([ConversionPreset])
    case qualityPreset([QualityPreset])
    case targetSize([Double?])
    case dpiPreset([Double])
    case pdfOfficeMode([PDFOfficeConversionMode])
    case toggle(title: String, defaultValue: Bool)
    case picker(choices: [OptionChoice], defaultValue: String)
}

struct ConversionOptionDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let description: String
    let kind: OptionKind
}

// MARK: - Conversion Engine Protocol

protocol ConversionEngine: Sendable {
    /// Unique name for this engine
    var name: String { get }
    
    /// The set of input formats this engine can read
    var supportedInputFormats: Set<FileFormat> { get }
    
    /// The set of output formats this engine can write
    var supportedOutputFormats: Set<FileFormat> { get }
    
    /// Check if this engine can perform a specific conversion
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool
    
    /// Returns available output formats for a given input format
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat>
    
    /// Returns option descriptors applicable for a specific conversion route
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor]
    
    /// Check if the engine is available on this system
    func isAvailable() async -> Bool
    
    /// Perform the conversion
    func convert(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult
}

// MARK: - Default Implementation

extension ConversionEngine {
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        supportedInputFormats.contains(input) && supportedOutputFormats.contains(output)
    }
    
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat> {
        guard supportedInputFormats.contains(input) else { return [] }
        return supportedOutputFormats
    }
    
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        []
    }
}

// MARK: - Cancellation & Deadlock-Safe Subprocess Runner

struct ProcessTimeoutError: Error, LocalizedError, Sendable {
    let timeoutSeconds: TimeInterval
    var errorDescription: String? {
        "Process timed out after \(Int(timeoutSeconds)) seconds."
    }
}

struct ProcessExecutionOutput: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

@_silgen_name("proc_listchildpids")
private func lc_proc_listchildpids(_ ppid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

/// Executes Foundation `Process` instances without `terminationHandler` TOCTOU races,
/// pre-launch `terminate()` crashes, or 64 KB kernel pipe deadlocks, and escalates
/// `SIGTERM` to `SIGKILL` across the spawned child process tree after a bounded grace period.
enum AsyncProcessRunner {
    static let defaultTerminationGraceSeconds: TimeInterval = 2.0

    private static func directChildPIDs(of ppid: pid_t) -> [pid_t] {
        guard ppid > 0 else { return [] }
        let maxChildren = 128
        var buffer = [pid_t](repeating: 0, count: maxChildren)
        // proc_listchildpids returns the number of pid_t entries written (not byte count).
        let entryCount = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let ptr = raw.baseAddress else { return 0 }
            return lc_proc_listchildpids(ppid, ptr, Int32(raw.count))
        }
        guard entryCount > 0 else { return [] }
        let count = min(maxChildren, Int(entryCount))
        return buffer.prefix(count).filter { $0 > 0 }
    }

    private static func collectDescendantPIDs(of rootPID: pid_t) -> [pid_t] {
        guard rootPID > 0 else { return [] }
        var visited: Set<pid_t> = [rootPID, getpid()]
        var queue: [pid_t] = [rootPID]
        var descendants: [pid_t] = []

        while !queue.isEmpty && descendants.count < 256 {
            let current = queue.removeFirst()
            for child in directChildPIDs(of: current) where visited.insert(child).inserted {
                descendants.append(child)
                queue.append(child)
            }
        }
        return descendants
    }

    private static func signalProcessTree(rootPID: pid_t, ownProcessGroup: Bool, signal: Int32) {
        let selfPID = getpid()
        let selfPGID = getpgrp()
        let descendants = collectDescendantPIDs(of: rootPID)

        if ownProcessGroup && rootPID > 0 && rootPID != selfPID && rootPID != selfPGID && getpgid(rootPID) == rootPID {
            _ = killpg(rootPID, signal)
        }
        for child in descendants where child > 0 && child != selfPID {
            _ = kill(child, signal)
        }
        if rootPID > 0 && rootPID != selfPID {
            _ = kill(rootPID, signal)
        }
    }

    private final class State: @unchecked Sendable {
        private struct Box: Sendable {
            var launched = false
            var finished = false
            var timedOut = false
            var cancelled = false
            var terminationInitiated = false
            var pid: pid_t = 0
            var ownProcessGroup = false
            var escalationTask: Task<Void, Never>?
            var continuation: CheckedContinuation<Void, Never>?
        }
        private let lock = OSAllocatedUnfairLock(initialState: Box())

        func markLaunched(pid: pid_t, ownProcessGroup: Bool) -> (shouldTerminate: Bool, pid: pid_t, ownProcessGroup: Bool) {
            lock.withLock { box in
                box.launched = true
                box.pid = pid
                box.ownProcessGroup = ownProcessGroup
                let shouldTerminate = (box.cancelled || box.timedOut) && !box.finished
                return (shouldTerminate, pid, ownProcessGroup)
            }
        }

        func markFinished() {
            let (cont, escalation): (CheckedContinuation<Void, Never>?, Task<Void, Never>?) = lock.withLock { box in
                box.finished = true
                let esc = box.escalationTask
                box.escalationTask = nil
                let c = box.continuation
                box.continuation = nil
                return (c, esc)
            }
            escalation?.cancel()
            cont?.resume()
        }

        func terminate(_ process: Process, asTimeout: Bool, graceSeconds: TimeInterval) {
            enum Action {
                case none
                case terminateTree(pid: pid_t, ownProcessGroup: Bool, scheduleEscalation: Bool)
            }

            let action: Action = lock.withLock { box in
                if !box.finished {
                    if asTimeout {
                        box.timedOut = true
                    } else {
                        box.cancelled = true
                    }
                }
                guard box.launched && !box.finished else {
                    return .none
                }
                let firstTermination = !box.terminationInitiated
                box.terminationInitiated = true
                return .terminateTree(pid: box.pid, ownProcessGroup: box.ownProcessGroup, scheduleEscalation: firstTermination)
            }

            guard case .terminateTree(let pid, let ownProcessGroup, let scheduleEscalation) = action else {
                return
            }

            AsyncProcessRunner.signalProcessTree(rootPID: pid, ownProcessGroup: ownProcessGroup, signal: SIGTERM)
            if process.isRunning {
                process.terminate()
            }

            guard scheduleEscalation else { return }

            let clampedGrace = max(0.05, graceSeconds)
            let escalationTask = Task.detached(priority: .utility) { [weak self, pid, ownProcessGroup] in
                try? await Task.sleep(for: .seconds(clampedGrace))
                guard !Task.isCancelled, let self else { return }
                let stillRunning = self.lock.withLock { box -> Bool in
                    guard !box.finished else { return false }
                    box.escalationTask = nil
                    return true
                }
                guard stillRunning else { return }
                AsyncProcessRunner.signalProcessTree(rootPID: pid, ownProcessGroup: ownProcessGroup, signal: SIGKILL)
            }
            let stored = lock.withLock { box -> Bool in
                guard !box.finished else { return false }
                box.escalationTask = escalationTask
                return true
            }
            if !stored {
                escalationTask.cancel()
            }
        }

        var didTimeOut: Bool {
            lock.withLock { $0.timedOut }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeImmediately: Bool = lock.withLock { box in
                    if box.finished {
                        return true
                    }
                    box.continuation = continuation
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        }
    }

    /// Launches a pre-configured `Process` (after running `afterLaunch` e.g. to close write-side pipes or stream stdout),
    /// guarantees `terminationHandler` is installed prior to `process.run()`, and honors cancellation + optional timeout
    /// with `SIGTERM` -> `SIGKILL` escalation across the child process tree.
    static func awaitExit(
        of process: Process,
        timeout: TimeInterval? = nil,
        terminationGraceSeconds: TimeInterval = defaultTerminationGraceSeconds,
        afterLaunch: () async throws -> Void = {}
    ) async throws {
        let state = State()
        process.terminationHandler = { _ in
            state.markFinished()
        }

        var watchdogWorkItem: DispatchWorkItem?
        defer {
            watchdogWorkItem?.cancel()
            process.terminationHandler = nil
        }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            let pid = process.processIdentifier
            let ownPG = (pid > 0 && setpgid(pid, pid) == 0)
            let launchStatus = state.markLaunched(pid: pid, ownProcessGroup: ownPG)
            if launchStatus.shouldTerminate || Task.isCancelled {
                state.terminate(process, asTimeout: false, graceSeconds: terminationGraceSeconds)
            }

            if let timeout, timeout > 0 {
                let item = DispatchWorkItem {
                    state.terminate(process, asTimeout: true, graceSeconds: terminationGraceSeconds)
                }
                watchdogWorkItem = item
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
            }

            do {
                try await afterLaunch()
            } catch {
                state.terminate(process, asTimeout: false, graceSeconds: terminationGraceSeconds)
                await state.wait()
                throw error
            }

            await state.wait()
            if state.didTimeOut, let timeout {
                throw ProcessTimeoutError(timeoutSeconds: timeout)
            }
            try Task.checkCancellation()
        } onCancel: {
            state.terminate(process, asTimeout: false, graceSeconds: terminationGraceSeconds)
        }
    }

    /// Runs `process` capturing both `stdout` and `stderr` concurrently to avoid pipe deadlocks.
    static func run(
        _ process: Process,
        stdin: FileHandle? = .nullDevice,
        timeout: TimeInterval? = nil,
        terminationGraceSeconds: TimeInterval = defaultTerminationGraceSeconds
    ) async throws -> ProcessExecutionOutput {
        if let stdin {
            process.standardInput = stdin
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outTask = Task.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try await awaitExit(of: process, timeout: timeout, terminationGraceSeconds: terminationGraceSeconds) {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
            }
            let outData = await outTask.value
            let errData = await errTask.value
            return ProcessExecutionOutput(
                terminationStatus: process.terminationStatus,
                stdout: outData,
                stderr: errData
            )
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await outTask.value
            _ = await errTask.value
            throw error
        }
    }
}

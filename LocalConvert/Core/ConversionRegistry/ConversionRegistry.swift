import Foundation
import os.log

// MARK: - Conversion Route

struct ConversionRoute: Sendable {
    let engine: any ConversionEngine
    let inputFormat: FileFormat
    let outputFormat: FileFormat
    let priority: Int // Higher = preferred
}

// MARK: - Conversion Registry

final class ConversionRegistry: @unchecked Sendable {
    
    static let shared = ConversionRegistry()
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ConversionRegistry")
    private var engines: [any ConversionEngine] = []
    private let lock = NSLock()
    
    private init() {}
    
    // MARK: - Engine Registration
    
    func register(engine: any ConversionEngine) {
        lock.withLock {
            engines.append(engine)
            logger.info("Registered engine: \(engine.name, privacy: .public)")
        }
    }
    
    // MARK: - Query
    
    /// Returns all output formats supported for a given input format, strictly verified against FormatCapabilityRegistry.
    func supportedOutputFormats(for inputFormat: FileFormat) -> Set<FileFormat> {
        guard FormatCapabilityRegistry.shared.capability(for: inputFormat).canRead else {
            return []
        }
        return lock.withLock {
            var formats = Set<FileFormat>()
            for engine in engines {
                if engine.supportedInputFormats.contains(inputFormat) {
                    formats.formUnion(engine.availableOutputFormats(for: inputFormat))
                }
            }
            // Don't include converting to the same format or any read-only format
            formats.remove(inputFormat)
            return formats.filter { FormatCapabilityRegistry.shared.capability(for: $0).canWrite }
        }
    }
    
    /// Returns all currently supported input formats
    var supportedInputFormats: Set<FileFormat> {
        lock.withLock {
            var formats = Set<FileFormat>()
            for engine in engines {
                formats.formUnion(engine.supportedInputFormats)
            }
            return formats.filter { FormatCapabilityRegistry.shared.capability(for: $0).canRead }
        }
    }
    
    /// Find the best engine for a conversion
    func findEngine(from input: FileFormat, to output: FileFormat, options: ConversionOptions? = nil) -> (any ConversionEngine)? {
        let capIn = FormatCapabilityRegistry.shared.capability(for: input)
        let capOut = FormatCapabilityRegistry.shared.capability(for: output)
        guard capIn.canRead else { return nil }
        let isPDFToolbox = options?.customOptions["pdf_operation"] != nil
        let isAudioToolbox = options?.customOptions["audio_operation"] != nil
        let isImageToolbox = options?.customOptions["image_toolbox"] == "true"
        let isVideoTrim = options?.hasVideoTrim == true
        if !isPDFToolbox {
            guard capOut.canWrite else { return nil }
        }
        return lock.withLock {
            if isPDFToolbox {
                if let pdfToolbox = engines.first(where: { $0.name == "PDFToolboxEngine" && $0.canConvert(from: input, to: output) }) {
                    return pdfToolbox
                }
            }
            if isAudioToolbox {
                if let mediaEngine = engines.first(where: { $0.name == "MediaEngine" && $0.supportedInputFormats.contains(input) && $0.supportedOutputFormats.contains(output) }) {
                    return mediaEngine
                }
            }
            if isImageToolbox {
                if let imageEngine = engines.first(where: { $0.name == "ImageEngine" && $0.supportedInputFormats.contains(input) && $0.supportedOutputFormats.contains(output) }) {
                    return imageEngine
                }
            }
            if isVideoTrim && input.category == .video {
                if let mediaEngine = engines.first(where: { $0.name == "MediaEngine" && $0.supportedInputFormats.contains(input) && $0.supportedOutputFormats.contains(output) }) {
                    return mediaEngine
                }
            }
            return engines.first { $0.canConvert(from: input, to: output) }
        }
    }
    
    /// Check if a conversion is supported
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool {
        findEngine(from: input, to: output) != nil
    }
    
    /// Returns option descriptors applicable for a specific conversion route
    func optionDescriptors(from input: FileFormat, to output: FileFormat, options: ConversionOptions? = nil) -> [ConversionOptionDescriptor] {
        lock.withLock {
            if options?.hasVideoTrim == true,
               input.category == .video,
               let mediaEngine = engines.first(where: {
                   $0.name == "MediaEngine"
                       && $0.supportedInputFormats.contains(input)
                       && $0.supportedOutputFormats.contains(output)
               }) as? MediaConversionEngine {
                return mediaEngine.optionDescriptors(from: input, to: output, allowSameFormat: true)
            }
            guard let engine = engines.first(where: { $0.canConvert(from: input, to: output) }) else { return [] }
            return engine.optionDescriptors(from: input, to: output)
        }
    }
    
    /// Returns all registered engines
    var registeredEngines: [any ConversionEngine] {
        lock.withLock { engines }
    }
    
    // MARK: - Smart Recommendations & Capability Validation
    
    /// Returns smart recommended output formats for a given input format, strictly filtered by actual registry support.
    func recommendedOutputFormats(for inputFormat: FileFormat) -> [FileFormat] {
        let supported = supportedOutputFormats(for: inputFormat)
        var recommendations: [FileFormat] = []
        
        switch inputFormat.category {
        case .image:
            let preferred: [FileFormat] = [.webp, .jpg, .png, .jxl, .pdf, .avif, .heic]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .document:
            let preferred: [FileFormat] = (inputFormat == .pdf)
                ? [.docx, .xlsx, .pptx, .png, .jpg]
                : [.pdf, .docx, .xlsx, .pptx, .odt, .ods, .odp]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .video:
            let preferred: [FileFormat] = [.mp4, .mov, .mkv, .webm, .gif, .mp3, .m4a]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .audio:
            let preferred: [FileFormat] = [.mp3, .m4a, .flac, .wav, .opus]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .subtitle:
            let preferred: [FileFormat] = [.srt, .vtt, .ass, .ssa]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .archive:
            let preferred: [FileFormat] = [.zip, .sevenZ, .tgz, .tar]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        }
        
        let remaining = supported.subtracting(recommendations).sorted { $0.displayName < $1.displayName }
        recommendations.append(contentsOf: remaining)
        return recommendations
    }
    
    func routeWarning(from input: FileFormat, to output: FileFormat) -> String? {
        ConversionMatrix.routeWarning(from: input, to: output)
    }
    
    /// Returns all presets supported for a specific conversion route based on engine option descriptors.
    func supportedPresets(from input: FileFormat, to output: FileFormat) -> [ConversionPreset] {
        let descriptors = optionDescriptors(from: input, to: output)
        for descriptor in descriptors {
            if case .preset(let presets) = descriptor.kind {
                return presets
            }
        }
        return [.custom]
    }
    
    /// Validates if a preset can be applied to a given input format, checking both target format and route support.
    func isPresetSupported(_ preset: ConversionPreset, for inputFormat: FileFormat) -> Bool {
        if preset == .custom { return true }
        
        switch preset {
        case .videoMaximumCompatibility:
            guard inputFormat.category == .video else { return false }
            return canConvert(from: inputFormat, to: .mp4)
        case .audioOnly:
            guard inputFormat.category == .video else { return false }
            return canConvert(from: inputFormat, to: .mp3)
        case .documentPDF, .documentPrintArchive:
            guard inputFormat.category == .document else { return false }
            return canConvert(from: inputFormat, to: .pdf)
        case .documentEditable:
            guard inputFormat == .pdf else { return false }
            return canConvert(from: inputFormat, to: .docx)
        case .web, .maximumQuality, .smallFile, .appleDevice:
            let supported = supportedOutputFormats(for: inputFormat)
            return !supported.isEmpty
        case .custom:
            return true
        }
    }
}

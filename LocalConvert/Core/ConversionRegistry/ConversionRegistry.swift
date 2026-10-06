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
    
    /// Returns all output formats supported for a given input format
    func supportedOutputFormats(for inputFormat: FileFormat) -> Set<FileFormat> {
        lock.withLock {
            var formats = Set<FileFormat>()
            for engine in engines {
                if engine.supportedInputFormats.contains(inputFormat) {
                    formats.formUnion(engine.availableOutputFormats(for: inputFormat))
                }
            }
            // Don't include converting to the same format
            formats.remove(inputFormat)
            return formats
        }
    }
    
    /// Returns all currently supported input formats
    var supportedInputFormats: Set<FileFormat> {
        lock.withLock {
            var formats = Set<FileFormat>()
            for engine in engines {
                formats.formUnion(engine.supportedInputFormats)
            }
            return formats
        }
    }
    
    /// Find the best engine for a conversion
    func findEngine(from input: FileFormat, to output: FileFormat, options: ConversionOptions? = nil) -> (any ConversionEngine)? {
        lock.withLock {
            if options?.customOptions["pdf_operation"] != nil {
                if let pdfToolbox = engines.first(where: { $0.name == "PDFToolboxEngine" && $0.canConvert(from: input, to: output) }) {
                    return pdfToolbox
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
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor] {
        lock.withLock {
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
            let preferred: [FileFormat] = [.webp, .jpg, .png, .pdf, .avif]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .document:
            let preferred: [FileFormat] = [.pdf, .docx, .xlsx, .pptx]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .video:
            let preferred: [FileFormat] = [.mp4, .webm, .mp3, .m4a]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .audio:
            let preferred: [FileFormat] = [.mp3, .m4a, .flac, .wav]
            for target in preferred where supported.contains(target) {
                recommendations.append(target)
            }
        case .archive:
            break
        }
        
        let remaining = supported.subtracting(recommendations).sorted { $0.displayName < $1.displayName }
        recommendations.append(contentsOf: remaining)
        return recommendations
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

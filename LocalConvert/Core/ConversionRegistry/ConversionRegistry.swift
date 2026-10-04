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
    func findEngine(from input: FileFormat, to output: FileFormat) -> (any ConversionEngine)? {
        lock.withLock {
            engines.first { $0.canConvert(from: input, to: output) }
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
}

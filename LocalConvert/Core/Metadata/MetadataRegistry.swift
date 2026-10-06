import Foundation
import os.log

final class MetadataRegistry: @unchecked Sendable {
    
    static let shared = MetadataRegistry()
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "MetadataRegistry")
    private var providers: [any MetadataProvider] = []
    private let lock = NSLock()
    
    private init() {}
    
    // MARK: - Registration
    
    func register(_ provider: any MetadataProvider) {
        lock.withLock {
            providers.removeAll { $0.providerName == provider.providerName }
            providers.append(provider)
            logger.info("Registered metadata provider: \(provider.providerName, privacy: .public)")
        }
    }
    
    func register(provider: any MetadataProvider) {
        register(provider)
    }
    
    // MARK: - Query
    
    func provider(for format: FileFormat) -> (any MetadataProvider)? {
        lock.withLock {
            providers.first { $0.supportedFormats.contains(format) }
        }
    }
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        lock.withLock {
            if let p = providers.first(where: { $0.supportedFormats.contains(format) }) {
                return p.capabilities(for: format)
            }
            return MetadataCapabilities.unsupported(for: format)
        }
    }
    
    func canRead(format: FileFormat) -> Bool {
        capabilities(for: format).canRead
    }
    
    func canWrite(format: FileFormat) -> Bool {
        capabilities(for: format).canWrite
    }
    
    var supportedFormats: Set<FileFormat> {
        lock.withLock {
            var formats = Set<FileFormat>()
            for p in providers {
                formats.formUnion(p.supportedFormats)
            }
            return formats
        }
    }
    
    var allSupportedFormats: Set<FileFormat> {
        supportedFormats
    }
    
    var registeredProviders: [any MetadataProvider] {
        lock.withLock { providers }
    }
}

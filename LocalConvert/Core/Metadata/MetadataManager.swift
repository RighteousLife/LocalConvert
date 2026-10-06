import Foundation
import SwiftUI
import os.log

@MainActor
final class MetadataManager: ObservableObject {
    
    static let shared = MetadataManager()
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "MetadataManager")
    private let registry = MetadataRegistry.shared
    
    @Published private(set) var activeURL: URL?
    @Published var document: MetadataDocument?
    @Published private(set) var originalDocument: MetadataDocument?
    @Published private(set) var capabilities: MetadataCapabilities?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isSaving: Bool = false
    @Published var errorMessage: String?
    @Published var showSuccessToast: Bool = false
    
    init() {}
    
    var isDirty: Bool {
        guard let doc = document, let orig = originalDocument else { return false }
        return doc != orig
    }
    
    // MARK: - Load
    
    func load(url: URL) async {
        activeURL = url
        isLoading = true
        errorMessage = nil
        showSuccessToast = false
        
        guard let format = FileDetector.detectFormat(url: url) else {
            isLoading = false
            errorMessage = "Could not detect file format."
            return
        }
        
        let caps = registry.capabilities(for: format)
        capabilities = caps
        
        guard let provider = registry.provider(for: format) else {
            isLoading = false
            errorMessage = "No metadata provider available for \(format.displayName)."
            return
        }
        
        do {
            let doc = try await provider.readMetadata(from: url)
            self.document = doc
            self.originalDocument = doc
            self.isLoading = false
            logger.info("Loaded metadata for \(url.lastPathComponent, privacy: .public)")
        } catch {
            self.isLoading = false
            self.errorMessage = error.localizedDescription
            logger.error("Failed to load metadata: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Update
    
    func updateField(id: String, value: MetadataValue?) {
        guard var doc = document else { return }
        doc.setValue(value, for: id)
        self.document = doc
    }
    
    func updateArtwork(data: Data?, mimeType: String = "image/jpeg") {
        guard var doc = document else { return }
        if let data = data {
            doc.artwork = MetadataArtwork(data: data, mimeType: mimeType)
        } else {
            doc.artwork = nil
        }
        self.document = doc
    }
    
    func removeGPS() {
        guard var doc = document else { return }
        doc.gps = nil
        self.document = doc
    }
    
    func removeAllMetadata() {
        guard let url = activeURL, let format = FileDetector.detectFormat(url: url) else { return }
        var cleanDoc = MetadataDocument(format: format, fileURL: url)
        cleanDoc.technical = document?.technical ?? [:]
        self.document = cleanDoc
    }
    
    func revert() {
        self.document = self.originalDocument
    }
    
    // MARK: - Save
    
    func save() async -> Bool {
        guard let url = activeURL, let doc = document else { return false }
        guard let format = FileDetector.detectFormat(url: url), let provider = registry.provider(for: format) else {
            errorMessage = "No metadata provider for \(url.pathExtension)."
            return false
        }
        
        isSaving = true
        errorMessage = nil
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            _ = try await provider.writeMetadata(doc, to: url)
            self.originalDocument = doc
            self.isSaving = false
            self.showSuccessToast = true
            
            // Record history item
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            
            let historyItem = ConversionHistoryItem(
                id: UUID(),
                inputFilename: url.lastPathComponent,
                inputFormatName: format.displayName,
                outputFilename: url.lastPathComponent,
                outputFormatName: "Metadata Updated",
                date: Date(),
                status: .completed,
                inputSizeBytes: size,
                outputSizeBytes: size,
                presetName: "Metadata Edit",
                outputURLPath: url.path,
                duration: duration
            )
            HistoryManager.shared.addEntry(historyItem)
            
            logger.info("Saved metadata to \(url.lastPathComponent, privacy: .public)")
            return true
        } catch {
            self.isSaving = false
            self.errorMessage = error.localizedDescription
            logger.error("Failed to save metadata: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

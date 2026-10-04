import Foundation
import SwiftUI
import os.log

// MARK: - Dropped File

struct DroppedFile: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let detectionResult: FileDetectionResult
    var selectedOutputFormat: FileFormat?
    var options: ConversionOptions
    
    var fileName: String {
        url.lastPathComponent
    }
    
    var detectedFormat: FileFormat? {
        detectionResult.bestFormat
    }
    
    var fileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
    
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var availableOutputFormats: [FileFormat] {
        guard let format = detectedFormat else { return [] }
        return ConversionRegistry.shared.supportedOutputFormats(for: format)
            .sorted { $0.displayName < $1.displayName }
    }
    
    var optionDescriptors: [ConversionOptionDescriptor] {
        guard let inFormat = detectedFormat, let outFormat = selectedOutputFormat else { return [] }
        return ConversionRegistry.shared.optionDescriptors(from: inFormat, to: outFormat)
    }
    
    init(url: URL, detectionResult: FileDetectionResult, options: ConversionOptions = .default) {
        self.id = UUID()
        self.url = url
        self.detectionResult = detectionResult
        self.options = options
        
        // Auto-select first available output format
        if let detected = detectionResult.bestFormat {
            let outputs = ConversionRegistry.shared.supportedOutputFormats(for: detected)
                .sorted { $0.displayName < $1.displayName }
            self.selectedOutputFormat = outputs.first
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    
    public static weak var shared: AppState?
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "AppState")
    private let fileDetector = FileDetector()
    
    @Published var droppedFiles: [DroppedFile] = []
    @Published var outputLocation: OutputLocation = .sameFolder {
        didSet {
            OutputManager.savePreferences(location: outputLocation, customDirectory: customOutputDirectory)
        }
    }
    @Published var customOutputDirectory: URL? {
        didSet {
            OutputManager.savePreferences(location: outputLocation, customDirectory: customOutputDirectory)
        }
    }
    
    @Published var isConverting = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var errorDetails: String?
    @Published var folderRejectedNotice: String?
    
    let conversionManager: ConversionManager
    let conversionQueue: ConversionQueue
    
    init() {
        // Load saved output location preferences
        let savedPrefs = OutputManager.loadSavedPreferences()
        self.outputLocation = savedPrefs.location
        self.customOutputDirectory = savedPrefs.customDirectory
        
        // Register engines
        let registry = ConversionRegistry.shared
        registry.register(engine: ImageConversionEngine())
        registry.register(engine: OfficeConversionEngine())
        registry.register(engine: PDFConversionEngine())
        registry.register(engine: MediaConversionEngine())
        
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 3, conversionManager: manager)
        self.conversionManager = manager
        self.conversionQueue = queue
        
        queue.onQueueCompleted = { [weak self] in
            self?.isConverting = false
        }
        
        AppState.shared = self
        logger.info("AppState initialized with \(registry.registeredEngines.count, privacy: .public) engines and ConversionQueue")
    }
    
    deinit {
        // Clear shared reference if this instance is deallocated
    }
    
    // MARK: - Batch Progress Metrics
    
    var totalJobCount: Int {
        conversionQueue.totalCount > 0 ? conversionQueue.totalCount : conversionManager.activeJobs.count
    }
    
    var completedJobCount: Int {
        conversionQueue.completedCount
    }
    
    var failedJobCount: Int {
        conversionQueue.failedCount
    }
    
    var cancelledJobCount: Int {
        conversionQueue.cancelledCount
    }
    
    var activeJobCount: Int {
        conversionQueue.activeJobCount
    }
    
    var batchProgress: Double {
        conversionQueue.progress
    }
    
    var isBatchCompleted: Bool {
        conversionQueue.totalCount > 0 && !isConverting && (conversionQueue.completedCount + conversionQueue.failedCount + conversionQueue.cancelledCount >= conversionQueue.totalCount)
    }
    
    // MARK: - File Handling
    
    /// Public API for adding files into the conversion workflow (used by Finder, Services, Drag & Drop, URL scheme)
    public func addFiles(urls: [URL]) {
        handleDroppedURLs(urls)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func handleDroppedURLs(_ urls: [URL]) {
        let validation = FinderHandoffHandler.validateAndSanitize(
            urls: urls,
            registry: ConversionRegistry.shared,
            fileDetector: fileDetector
        )
        
        for url in validation.validURLs + validation.unsupportedURLs {
            let result = fileDetector.detect(url: url)
            let droppedFile = DroppedFile(url: url, detectionResult: result)
            
            // Avoid duplicates
            if !droppedFiles.contains(where: { $0.url == url }) {
                droppedFiles.append(droppedFile)
            }
        }
        
        if !validation.rejectedFolders.isEmpty {
            folderRejectedNotice = "Folders are not supported. Please select individual files to convert."
        }
        
        logger.info("Handled \(urls.count, privacy: .public) items (\(self.droppedFiles.count, privacy: .public) total files in list, \(validation.validURLs.count, privacy: .public) valid, \(validation.rejectedFolders.count, privacy: .public) folders rejected)")
    }
    
    func removeFile(_ file: DroppedFile) {
        droppedFiles.removeAll { $0.id == file.id }
    }
    
    func removeAllFiles() {
        droppedFiles.removeAll()
        conversionManager.clearCompleted()
        conversionQueue.reset()
        folderRejectedNotice = nil
    }
    
    func updateOutputFormat(for fileId: UUID, format: FileFormat) {
        if let index = droppedFiles.firstIndex(where: { $0.id == fileId }) {
            droppedFiles[index].selectedOutputFormat = format
        }
    }
    
    func updateOptions(for fileId: UUID, options: ConversionOptions) {
        if let index = droppedFiles.firstIndex(where: { $0.id == fileId }) {
            droppedFiles[index].options = options
        }
    }
    
    // MARK: - Conversion
    
    func convertAll() {
        folderRejectedNotice = nil
        var jobs: [ConversionJob] = []
        
        for file in droppedFiles {
            guard let inputFormat = file.detectedFormat,
                  let outputFormat = file.selectedOutputFormat else {
                continue
            }
            
            let outputDir = OutputManager.resolveOutputDirectory(
                for: file.url,
                preference: outputLocation,
                customDirectory: customOutputDirectory
            )
            
            // Validate output directory before starting conversion
            guard OutputManager.isOutputDirectoryValid(outputDir) else {
                showError(
                    message: "The destination folder is inaccessible or unwritable.",
                    details: "Directory path: \(outputDir.path)"
                )
                return
            }
            
            let job = ConversionJob(
                inputURL: file.url,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                outputDirectory: outputDir,
                options: file.options
            )
            
            jobs.append(job)
        }
        
        guard !jobs.isEmpty else {
            return
        }
        
        isConverting = true
        conversionQueue.enqueue(jobs: jobs)
    }
    
    func convert(file: DroppedFile) {
        guard let inputFormat = file.detectedFormat,
              let outputFormat = file.selectedOutputFormat else {
            return
        }
        
        let outputDir = OutputManager.resolveOutputDirectory(
            for: file.url,
            preference: outputLocation,
            customDirectory: customOutputDirectory
        )
        
        guard OutputManager.isOutputDirectoryValid(outputDir) else {
            showError(
                message: "The destination folder is inaccessible or unwritable.",
                details: "Directory path: \(outputDir.path)"
            )
            return
        }
        
        let job = ConversionJob(
            inputURL: file.url,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            outputDirectory: outputDir,
            options: file.options
        )
        
        isConverting = true
        conversionQueue.enqueue(job: job)
    }
    
    func cancelConversion() {
        conversionQueue.cancelAll()
        isConverting = false
    }
    
    // MARK: - Error Handling
    
    func showError(message: String, details: String? = nil) {
        errorMessage = message
        errorDetails = details
        showError = true
    }
}

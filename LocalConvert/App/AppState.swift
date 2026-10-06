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
    
    var estimatedOutputSize: Int64? {
        guard let outputFormat = selectedOutputFormat else { return nil }
        
        let ratio: Double
        if outputFormat.category == .image {
            if outputFormat == .webp || outputFormat == .avif || outputFormat == .heic {
                ratio = 0.6 * (options.imageQuality ?? 0.9)
            } else {
                ratio = 1.1 * (options.imageQuality ?? 0.9)
            }
        } else if outputFormat.category == .video {
            ratio = 0.8
        } else {
            ratio = 1.0
        }
        
        return Int64(Double(fileSize) * ratio)
    }
    
    var formattedEstimatedSize: String {
        guard let est = estimatedOutputSize else { return "Unknown size" }
        return "~" + ByteCountFormatter.string(fromByteCount: est, countStyle: .file)
    }
    
    var recommendedOutputFormats: [FileFormat] {
        guard let inFormat = detectedFormat else { return [] }
        let available = ConversionRegistry.shared.supportedOutputFormats(for: inFormat)
        
        var recommended: [FileFormat] = []
        switch inFormat.category {
        case .image:
            recommended = [.webp, .jpg, .png, .pdf]
        case .video:
            recommended = [.mp4, .gif, .mp3]
        case .audio:
            recommended = [.m4a, .mp3, .wav]
        case .document:
            if inFormat == .pdf {
                recommended = [.docx, .xlsx]
            } else {
                recommended = [.pdf, .docx, .xlsx]
            }
        default:
            break
        }
        
        return recommended.filter { $0 != inFormat && available.contains($0) }
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
        
        // Auto-select first recommended output format, fallback to first available
        if let detected = detectionResult.bestFormat {
            let available = ConversionRegistry.shared.supportedOutputFormats(for: detected)
                .sorted { $0.displayName < $1.displayName }
            
            // First check recommended logic we wrote above
            // We need to re-implement a tiny bit of the logic here since we can't call self.recommendedOutputFormats yet
            var recommended: [FileFormat] = []
            switch detected.category {
            case .image: recommended = [.webp, .jpg, .png, .pdf]
            case .video: recommended = [.mp4, .gif, .mp3]
            case .audio: recommended = [.m4a, .mp3, .wav]
            case .document: recommended = (detected == .pdf) ? [.docx, .xlsx] : [.pdf, .docx, .xlsx]
            default: break
            }
            
            let filteredRecommended = recommended.filter { $0 != detected && available.contains($0) }
            self.selectedOutputFormat = filteredRecommended.first ?? available.first
        }
    }
}

// MARK: - App Navigation Tab

enum AppNavigationTab: String, Hashable, CaseIterable, Identifiable {
    case convert = "Convert"
    case jobs = "Jobs"
    case pdfToolbox = "PDF Toolbox"
    case metadata = "Metadata"
    case presets = "Presets"
    case history = "History"
    case settings = "Settings"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .jobs: return "list.bullet.rectangle"
        case .pdfToolbox: return "doc.viewfinder"
        case .metadata: return "tag"
        case .presets: return "slider.horizontal.3"
        case .history: return "clock"
        case .settings: return "gear"
        }
    }
}

// MARK: - Last Conversion Config

struct LastConversionConfig: Sendable, Equatable {
    let inputFormat: FileFormat
    let outputFormat: FileFormat
    let options: ConversionOptions
    let timestamp: Date
    
    var summary: String {
        var details: [String] = []
        if let q = options.imageQuality, q < 0.95 {
            details.append("Quality \(Int(q * 100))%")
        }
        if options.resizeMode != .none, let w = options.resizeWidth {
            details.append("Resize \(w)px")
        }
        let detailsStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "\(inputFormat.displayName) → \(outputFormat.displayName)\(detailsStr)"
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    
    public static weak var shared: AppState?
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "AppState")
    private let fileDetector = FileDetector()
    
    @Published var selectedTab: AppNavigationTab = .convert
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
    @Published var pendingFolderURLs: [URL] = []
    @Published var dropFeedbackText: String?
    @Published var isDraggingOver = false
    @Published var lastConversionConfig: LastConversionConfig?
    
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
        registry.register(engine: TextConversionEngine())
        registry.register(engine: PDFToolboxEngine())
        
        // Register metadata providers
        let metaRegistry = MetadataRegistry.shared
        metaRegistry.register(provider: AudioMetadataProvider())
        metaRegistry.register(provider: ImageMetadataProvider())
        metaRegistry.register(provider: VideoMetadataProvider())
        metaRegistry.register(provider: PDFMetadataProvider())
        metaRegistry.register(provider: OfficeMetadataProvider())
        
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(conversionManager: manager)
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
    
    public func handleQuickAction(urls: [URL], action: String) {
        if action == "convert" {
            addFiles(urls: urls)
            return
        }
        
        let validation = FinderHandoffHandler.validateAndSanitize(
            urls: urls,
            registry: ConversionRegistry.shared,
            fileDetector: fileDetector
        )
        
        // Handle PDF Toolbox actions immediately by mapping them to their executePDFOperation counterparts
        if action == "merge_pdfs" || action == "extract_pdf" || action == "compress_pdf" {
            let pdfFiles = validation.validURLs.compactMap { url -> DroppedFile? in
                let result = fileDetector.detect(url: url)
                guard result.bestFormat == .pdf else { return nil }
                return DroppedFile(url: url, detectionResult: result, options: AppSettings.shared.defaultConversionOptions)
            }
            if !pdfFiles.isEmpty {
                if action == "merge_pdfs" {
                    executePDFOperation(operation: "merge", files: pdfFiles)
                } else if action == "compress_pdf" {
                    for file in pdfFiles {
                        executePDFOperation(operation: "compress", files: [file])
                    }
                } else if action == "extract_pdf" {
                    for file in pdfFiles {
                        executePDFOperation(operation: "splitEveryPage", files: [file])
                    }
                }
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
        
        var filesToConvert: [DroppedFile] = []
        
        for url in validation.validURLs {
            let result = fileDetector.detect(url: url)
            var droppedFile = DroppedFile(
                url: url,
                detectionResult: result,
                options: AppSettings.shared.defaultConversionOptions
            )
            
            // Apply specific action if possible
            var targetFormat: FileFormat? = nil
            var targetPreset: ConversionPreset? = nil
            
            switch action {
            case "pdf":
                if droppedFile.availableOutputFormats.contains(.pdf) {
                    targetFormat = .pdf
                    if result.bestFormat?.category == .document {
                        targetPreset = .documentPDF
                    }
                }
            case "webp":
                if droppedFile.availableOutputFormats.contains(.webp) {
                    targetFormat = .webp
                }
            case "mp4":
                if droppedFile.availableOutputFormats.contains(.mp4) {
                    targetFormat = .mp4
                    if result.bestFormat?.category == .video {
                        targetPreset = .videoMaximumCompatibility
                    }
                }
            case "extract_audio":
                if result.bestFormat?.category == .video && droppedFile.availableOutputFormats.contains(.mp3) {
                    targetFormat = .mp3
                    targetPreset = .audioOnly
                }
            default:
                break
            }
            
            if let targetFormat = targetFormat {
                droppedFile.selectedOutputFormat = targetFormat
                if let preset = targetPreset {
                    var newOptions = droppedFile.options
                    newOptions.preset = preset
                    newOptions.applyPreset()
                    droppedFile.options = newOptions
                }
                filesToConvert.append(droppedFile)
            } else {
                // Just add it to the list if the action wasn't supported
                if !droppedFiles.contains(where: { $0.url == url }) {
                    droppedFiles.append(droppedFile)
                }
            }
        }
        
        // Add to main list to show in UI
        for file in filesToConvert {
            if let index = droppedFiles.firstIndex(where: { $0.url == file.url }) {
                droppedFiles[index] = file
            } else {
                droppedFiles.append(file)
            }
        }
        
        NSApp.activate(ignoringOtherApps: true)
        
        if !validation.rejectedFolders.isEmpty {
            folderRejectedNotice = "Folders can't be converted directly."
            pendingFolderURLs = validation.rejectedFolders
        }
        
        // Start conversion automatically for the ones we configured
        for file in filesToConvert {
            convert(file: file)
        }
    }
    
    func handleDroppedURLs(_ urls: [URL]) {
        let validation = FinderHandoffHandler.validateAndSanitize(
            urls: urls,
            registry: ConversionRegistry.shared,
            fileDetector: fileDetector
        )
        
        for url in validation.validURLs + validation.unsupportedURLs {
            let result = fileDetector.detect(url: url)
            let droppedFile = DroppedFile(
                url: url,
                detectionResult: result,
                options: AppSettings.shared.defaultConversionOptions
            )
            
            // Avoid duplicates
            if !droppedFiles.contains(where: { $0.url == url }) {
                droppedFiles.append(droppedFile)
            }
        }
        
        if !validation.rejectedFolders.isEmpty {
            folderRejectedNotice = "Folders can't be converted directly."
            pendingFolderURLs = validation.rejectedFolders
        }
        
        let validCount = validation.validURLs.count
        if validCount > 0 {
            dropFeedbackText = "\(validCount) file\(validCount == 1 ? "" : "s") added"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.dropFeedbackText?.contains("\(validCount)") == true {
                    self.dropFeedbackText = nil
                }
            }
        }
        
        logger.info("Handled \(urls.count, privacy: .public) items (\(self.droppedFiles.count, privacy: .public) total files in list, \(validation.validURLs.count, privacy: .public) valid, \(validation.rejectedFolders.count, privacy: .public) folders rejected)")
    }
    
    // MARK: - Folder Smart Import
    
    public func importFilesFromPendingFolders() {
        let foldersToScan = pendingFolderURLs
        folderRejectedNotice = nil
        pendingFolderURLs = []
        
        guard !foldersToScan.isEmpty else { return }
        
        var discoveredURLs: [URL] = []
        let fileManager = FileManager.default
        
        for folder in foldersToScan {
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            
            for case let fileURL as URL in enumerator {
                if discoveredURLs.count >= 1000 {
                    break
                }
                
                let standardized = fileURL.resolvingSymlinksInPath().standardizedFileURL
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDir), !isDir.boolValue else {
                    continue
                }
                
                if standardized.lastPathComponent.hasPrefix(".") {
                    continue
                }
                
                let detection = fileDetector.detect(url: standardized)
                if let format = detection.bestFormat {
                    let targets = ConversionRegistry.shared.supportedOutputFormats(for: format)
                    if !targets.isEmpty {
                        discoveredURLs.append(standardized)
                    }
                }
            }
        }
        
        if !discoveredURLs.isEmpty {
            addFiles(urls: discoveredURLs)
            let count = discoveredURLs.count
            dropFeedbackText = "\(count) supported file\(count == 1 ? "" : "s") imported from folder"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.dropFeedbackText?.contains("imported") == true {
                    self.dropFeedbackText = nil
                }
            }
        } else {
            folderRejectedNotice = "No supported files found in the dropped folder."
        }
    }
    
    func removeFile(_ file: DroppedFile) {
        droppedFiles.removeAll { $0.id == file.id }
    }
    
    func removeAllFiles() {
        droppedFiles.removeAll()
        conversionManager.clearCompleted()
        conversionQueue.reset()
        folderRejectedNotice = nil
        pendingFolderURLs = []
        dropFeedbackText = nil
    }
    
    func updateOutputFormat(for fileId: UUID, format: FileFormat) {
        if let index = droppedFiles.firstIndex(where: { $0.id == fileId }) {
            droppedFiles[index].selectedOutputFormat = format
            AppSettings.shared.addRecentOutputFormat(format)
        }
    }
    
    func updateOptions(for fileId: UUID, options: ConversionOptions) {
        if let index = droppedFiles.firstIndex(where: { $0.id == fileId }) {
            droppedFiles[index].options = options
        }
    }
    
    // MARK: - Quick Convert & Presets
    
    var quickConvertFormats: [FileFormat] {
        guard !droppedFiles.isEmpty else { return [] }
        guard let firstFile = droppedFiles.first else { return [] }
        
        // Compute the intersection of available output formats supported by ALL dropped files
        var commonFormats = Set(firstFile.availableOutputFormats)
        for file in droppedFiles.dropFirst() {
            commonFormats.formIntersection(file.availableOutputFormats)
        }
        
        guard !commonFormats.isEmpty else { return [] }
        
        let priorityOrder: [FileFormat] = [.webp, .jpg, .png, .pdf, .mp4, .mp3, .docx, .xlsx, .wav, .flac, .heic, .gif, .mov, .m4a]
        var result: [FileFormat] = []
        for fmt in priorityOrder {
            if commonFormats.contains(fmt) {
                result.append(fmt)
            }
        }
        for fmt in commonFormats where !result.contains(fmt) {
            result.append(fmt)
        }
        return Array(result.prefix(6))
    }
    
    var quickPresets: [SavedPreset] {
        guard !droppedFiles.isEmpty else { return [] }
        let allPresets = PresetManager.shared.presets
        
        // Only include presets whose target format is supported by ALL dropped files
        return allPresets.filter { preset in
            droppedFiles.allSatisfy { file in
                file.availableOutputFormats.contains(preset.targetFormat)
            }
        }
    }
    
    var isRepeatConversionCompatible: Bool {
        guard let config = lastConversionConfig, !droppedFiles.isEmpty else { return false }
        return droppedFiles.allSatisfy { file in
            guard let inFormat = file.detectedFormat else { return false }
            return ConversionRegistry.shared.canConvert(from: inFormat, to: config.outputFormat)
        }
    }
    
    func quickConvert(to targetFormat: FileFormat) {
        var modified = false
        for index in droppedFiles.indices {
            if droppedFiles[index].availableOutputFormats.contains(targetFormat) {
                droppedFiles[index].selectedOutputFormat = targetFormat
                modified = true
            }
        }
        if modified {
            AppSettings.shared.addRecentOutputFormat(targetFormat)
            convertAll()
        }
    }
    
    func repeatLastConversion() {
        guard let config = lastConversionConfig else {
            showError(message: "No previous conversion to repeat.")
            return
        }
        
        guard isRepeatConversionCompatible else {
            showError(
                message: "Your last conversion isn't compatible with the selected files.",
                details: "The previous conversion was to \(config.outputFormat.displayName), which cannot be applied to all currently loaded files."
            )
            return
        }
        
        for index in droppedFiles.indices {
            droppedFiles[index].selectedOutputFormat = config.outputFormat
            droppedFiles[index].options = config.options
        }
        
        AppSettings.shared.addRecentOutputFormat(config.outputFormat)
        convertAll()
    }
    
    // MARK: - Conversion
    
    func convertAll() {
        folderRejectedNotice = nil
        var jobs: [ConversionJob] = []
        let batchID = droppedFiles.count > 1 ? UUID() : nil
        
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
                inputURLs: [file.url],
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                outputDirectory: outputDir,
                options: file.options,
                batchID: batchID
            )
            
            jobs.append(job)
        }
        
        guard !jobs.isEmpty else {
            return
        }
        
        if let first = droppedFiles.first,
           let inF = first.detectedFormat,
           let outF = first.selectedOutputFormat {
            lastConversionConfig = LastConversionConfig(
                inputFormat: inF,
                outputFormat: outF,
                options: first.options,
                timestamp: Date()
            )
            AppSettings.shared.addRecentOutputFormat(outF)
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
        
        lastConversionConfig = LastConversionConfig(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            options: file.options,
            timestamp: Date()
        )
        AppSettings.shared.addRecentOutputFormat(outputFormat)
        
        let job = ConversionJob(
            inputURLs: [file.url],
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

import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import os.log

// MARK: - Dropped File

struct DroppedFile: Identifiable, Sendable {
    let id: UUID
    var url: URL
    let detectionResult: FileDetectionResult
    var selectedOutputFormat: FileFormat?
    var options: ConversionOptions
    let fileSize: Int64
    let formattedFileSize: String
    let availableOutputFormats: [FileFormat]
    
    var fileName: String {
        url.lastPathComponent
    }
    
    var detectedFormat: FileFormat? {
        detectionResult.bestFormat
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
        guard let est = estimatedOutputSize else { return String(localized: "Unknown size") }
        return "~" + ByteCountFormatter.string(fromByteCount: est, countStyle: .file)
    }
    
    var recommendedOutputFormats: [FileFormat] {
        guard let inFormat = detectedFormat else { return [] }
        let available = ConversionRegistry.shared.supportedOutputFormats(for: inFormat)
        return ConversionRegistry.shared.recommendedOutputFormats(for: inFormat)
            .filter { available.contains($0) }
    }
    
    var trimEligibleOutputFormats: [FileFormat] {
        guard let detected = detectedFormat, detected.category == .video else {
            return availableOutputFormats
        }
        var combined = Set(availableOutputFormats)
        if FormatCapabilityRegistry.shared.capability(for: detected).canWrite {
            combined.insert(detected)
        }
        return combined.sorted { $0.displayName < $1.displayName }
    }

    var optionDescriptors: [ConversionOptionDescriptor] {
        guard let inFormat = detectedFormat, let outFormat = selectedOutputFormat else { return [] }
        return ConversionRegistry.shared.optionDescriptors(from: inFormat, to: outFormat, options: options)
    }
    
    init(url: URL, detectionResult: FileDetectionResult, options: ConversionOptions = .default) {
        self.id = UUID()
        self.url = url
        self.detectionResult = detectionResult
        self.options = options

        let resolvedSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        self.fileSize = resolvedSize
        self.formattedFileSize = ByteCountFormatter.string(fromByteCount: resolvedSize, countStyle: .file)

        // Auto-select first recommended output format from ConversionRegistry, fallback to first available
        if let detected = detectionResult.bestFormat {
            let recommended = ConversionRegistry.shared.recommendedOutputFormats(for: detected)
            let available = ConversionRegistry.shared.supportedOutputFormats(for: detected)
                .sorted { $0.displayName < $1.displayName }
            self.availableOutputFormats = available
            self.selectedOutputFormat = recommended.first ?? available.first
        } else {
            self.availableOutputFormats = []
        }
    }
}

// MARK: - App Navigation Tab

enum AppNavigationTab: String, Hashable, CaseIterable, Identifiable {
    case convert = "Convert"
    case jobs = "Jobs"
    case pdfToolbox = "PDF Toolbox"
    case audioToolbox = "Audio Toolbox"
    case audioWorkspace = "Audio Workspace"
    case imageToolbox = "Image Toolbox"
    case metadata = "Metadata"
    case presets = "Presets"
    case history = "History"
    case settings = "Settings"

    /// The 9 primary sidebar tabs in exact navigation/shortcut (`⌘1`–`⌘9`) order.
    /// `.audioToolbox` is retained solely as an internal compatibility route that redirects
    /// into `.audioWorkspace` (`Audio Tools` mode).
    static let allCases: [AppNavigationTab] = [
        .convert,
        .jobs,
        .pdfToolbox,
        .audioWorkspace,
        .imageToolbox,
        .metadata,
        .presets,
        .history,
        .settings
    ]
    
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .convert: return String(localized: "Convert")
        case .jobs: return String(localized: "Jobs")
        case .pdfToolbox: return String(localized: "PDF Toolbox")
        case .audioToolbox: return String(localized: "Audio Toolbox")
        case .audioWorkspace: return String(localized: "Audio Workspace")
        case .imageToolbox: return String(localized: "Image Toolbox")
        case .metadata: return String(localized: "Metadata")
        case .presets: return String(localized: "Presets")
        case .history: return String(localized: "History")
        case .settings: return String(localized: "Settings")
        }
    }

    var localizedDescription: String {
        switch self {
        case .convert:
            return String(localized: "Drop files and convert between formats locally")
        case .jobs:
            return String(localized: "Monitor active, completed, and failed conversion jobs")
        case .pdfToolbox:
            return String(localized: "Merge, split, compress, OCR, and annotate PDFs")
        case .audioToolbox:
            return String(localized: "Convert, normalize, and inspect audio files")
        case .audioWorkspace:
            return String(localized: "Organize audio library, edit waveforms, and run audio tools")
        case .imageToolbox:
            return String(localized: "Resize, optimize, adjust colors, and edit images")
        case .metadata:
            return String(localized: "Inspect, edit, and strip file metadata and EXIF tags")
        case .presets:
            return String(localized: "Manage conversion presets and automated watch folders")
        case .history:
            return String(localized: "Browse past conversions and output file provenance")
        case .settings:
            return String(localized: "Configure appearance, output defaults, shortcuts, and privacy")
        }
    }
    
    var iconName: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .jobs: return "list.bullet.rectangle"
        case .pdfToolbox: return "doc.viewfinder"
        case .audioToolbox: return "waveform"
        case .audioWorkspace: return "music.note.house"
        case .imageToolbox: return "photo.stack"
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
            let qualityPercent = Int(q * 100)
            details.append(String(localized: "Quality \(qualityPercent)%"))
        }
        if options.resizeMode != .none, let w = options.resizeWidth {
            details.append(String(localized: "Resize \(w)px"))
        }
        let detailsStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "\(inputFormat.displayName) → \(outputFormat.displayName)\(detailsStr)"
    }
}

// MARK: - Media Viewer Routing

enum MediaViewerRouteKind: String, Sendable, Equatable {
    case photo
    case video
    case unsupported
}

enum MediaViewerRouter: Sendable {
    private static let explicitPhotoExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jfif", "jpe", "heic", "heif", "hif", "heics", "heifs",
        "webp", "jxl", "tiff", "tif", "bmp", "dib", "gif", "apng", "avif",
        "jp2", "j2k", "jpf", "jpx", "j2c", "psd", "exr", "ppm", "pgm", "pbm", "pnm", "pfm",
        "hdr", "rgbe", "qoi", "pcx", "wbmp", "sgi", "xpm", "svg", "ico", "icns", "tga", "targa",
        "dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "rw2", "orf", "pef", "srw", "raw"
    ]

    private static let explicitVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "ts", "mts", "m2ts",
        "flv", "f4v", "wmv", "asf", "mpg", "mpeg", "mpe", "3gp", "3gpp", "3g2", "3gp2",
        "vob", "m2v", "ogv"
    ]

    static func routeKind(for utType: UTType) -> MediaViewerRouteKind {
        if utType.conforms(to: .video) || utType.conforms(to: .movie) {
            return .video
        }
        if utType.conforms(to: .image) {
            return .photo
        }
        if let format = FileFormat.from(utType: utType) {
            switch format.category {
            case .image: return .photo
            case .video: return .video
            case .document, .audio, .subtitle, .archive: return .unsupported
            }
        }
        return .unsupported
    }

    static func routeKind(for url: URL) -> MediaViewerRouteKind {
        guard url.isFileURL else { return .unsupported }
        if url.hasDirectoryPath { return .unsupported }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return .unsupported
        }

        let ext = url.pathExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        if !ext.isEmpty {
            if explicitPhotoExtensions.contains(ext) {
                return .photo
            }
            if explicitVideoExtensions.contains(ext) {
                return .video
            }
            if let format = FileFormat.from(extension: ext) {
                switch format.category {
                case .image: return .photo
                case .video: return .video
                case .document, .audio, .subtitle, .archive: return .unsupported
                }
            }
            if let extUTType = UTType(filenameExtension: ext) {
                let kind = routeKind(for: extUTType)
                if kind != .unsupported {
                    return kind
                }
            }
        }

        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            let kind = routeKind(for: contentType)
            if kind != .unsupported {
                return kind
            }
        }

        if ext.isEmpty && FileManager.default.fileExists(atPath: url.path),
           let detected = FileDetector.detectFormat(url: url) {
            switch detected.category {
            case .image: return .photo
            case .video: return .video
            case .document, .audio, .subtitle, .archive: return .unsupported
            }
        }

        return .unsupported
    }

    static func shouldRouteSingleOpenedFileToMediaViewer(urls: [URL]) -> Bool {
        guard urls.count == 1, let singleURL = urls.first, singleURL.isFileURL else {
            return false
        }
        return routeKind(for: singleURL) != .unsupported
    }

    static var allowedOpenPanelContentTypes: [UTType] {
        var seen = Set<String>()
        var types: [UTType] = []
        let baseTypes: [UTType] = [.image, .movie, .video]
        let formatTypes: [UTType] = FileFormat.allCases
            .filter { $0.category == .image || $0.category == .video }
            .compactMap(\.utType)
        for type in baseTypes + formatTypes {
            if seen.insert(type.identifier).inserted {
                types.append(type)
            }
        }
        return types
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    
    public static weak var shared: AppState?
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "AppState")
    let fileDetector = FileDetector()
    private var isUITestingOutputLocked = false
    
    @Published var selectedTab: AppNavigationTab = .convert {
        didSet {
            if selectedTab == .audioToolbox {
                audioWorkspace.activeMode = .audioTools
                selectedTab = .audioWorkspace
            }
        }
    }
    @Published var droppedFiles: [DroppedFile] = []
    @Published var outputLocation: OutputLocation = .sameFolder {
        didSet {
            guard !isUITestingOutputLocked else { return }
            OutputManager.savePreferences(location: outputLocation, customDirectory: customOutputDirectory)
            let mapped = DefaultOutputLocation(from: outputLocation)
            if AppSettings.shared.defaultOutputLocation != mapped {
                AppSettings.shared.defaultOutputLocation = mapped
            }
        }
    }
    @Published var customOutputDirectory: URL? {
        didSet {
            guard !isUITestingOutputLocked else { return }
            OutputManager.savePreferences(location: outputLocation, customDirectory: customOutputDirectory)
            if AppSettings.shared.customOutputDirectory != customOutputDirectory {
                AppSettings.shared.customOutputDirectory = customOutputDirectory
            }
        }
    }
    
    @Published var isConverting = false {
        didSet {
            MenuBarManager.shared.updateStatus()
        }
    }
    @Published var showError = false
    @Published var errorTitle = String(localized: "Conversion Notice")
    @Published var errorMessage = ""
    @Published var errorSuggestion: String?
    @Published var errorDetails: String?
    @Published var folderRejectedNotice: String?
    @Published var pendingFolderURLs: [URL] = []
    @Published var dropFeedbackText: String?
    @Published var isDraggingOver = false
    @Published var lastConversionConfig: LastConversionConfig?
    @Published var pendingHistorySourceFilter: HistorySourceFilter? = nil
    @Published var pendingHistoryWatchFolderRuleID: UUID? = nil
    @Published var pendingHistoryWatchFolderRuleName: String? = nil
    @Published var pendingHistoryNavigationNonce: UInt64 = 0
    @Published var activeMediaViewerURL: URL? = nil
    @Published var isMediaViewerPresented: Bool = false {
        didSet {
            if !isMediaViewerPresented && activeMediaViewerURL != nil {
                activeMediaViewerURL = nil
            }
        }
    }
    
    let conversionManager: ConversionManager
    let conversionQueue: ConversionQueue
    let audioEditorStore: AudioEditorStore
    let audioToolboxStore: AudioToolboxStore
    lazy var audioWorkspace = AudioWorkspaceCoordinator()
    let imageToolboxStore: ImageToolboxStore
    let pdfToolboxStore: PDFToolboxStore
    let watchFolderManager: WatchFolderManager
    let undoCoordinator: UndoRedoCoordinator
    let historyManager: HistoryManager
    private var storeChangeCancellables = Set<AnyCancellable>()
    private var progressMilestoneCancellable: AnyCancellable?
    private var lastAnnouncedProgressMilestone: Int = 0
    private var lastSidebarActiveJobCount: Int = 0
    
    init(
        undoCoordinator: UndoRedoCoordinator = .shared,
        watchFolderStoreURL: URL? = nil,
        historyManager: HistoryManager = .shared,
        uitestingOutputDirectory: URL? = nil
    ) {
        self.historyManager = historyManager
        if let uitestingOutputDirectory {
            self.isUITestingOutputLocked = true
            self.outputLocation = .customFolder
            self.customOutputDirectory = uitestingOutputDirectory
        } else {
            // Load saved output location preferences
            let savedPrefs = OutputManager.loadSavedPreferences()
            self.outputLocation = savedPrefs.location
            self.customOutputDirectory = savedPrefs.customDirectory
        }
        
        // Register engines
        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: ImageConversionEngine())
            registry.register(engine: OfficeConversionEngine())
            registry.register(engine: PDFConversionEngine())
            registry.register(engine: MediaConversionEngine())
            registry.register(engine: SubtitleConversionEngine())
            registry.register(engine: ArchiveConversionEngine())
            registry.register(engine: TextConversionEngine())
            registry.register(engine: PDFToolboxEngine())
        }
        
        // Register metadata providers
        let metaRegistry = MetadataRegistry.shared
        metaRegistry.register(provider: AudioMetadataProvider())
        metaRegistry.register(provider: ImageMetadataProvider())
        metaRegistry.register(provider: VideoMetadataProvider())
        metaRegistry.register(provider: PDFMetadataProvider())
        metaRegistry.register(provider: OfficeMetadataProvider())
        
        let manager = ConversionManager(registry: registry, historyManager: historyManager)
        let queue = ConversionQueue(conversionManager: manager, undoCoordinator: undoCoordinator)
        self.conversionManager = manager
        self.conversionQueue = queue
        self.undoCoordinator = undoCoordinator
        self.audioEditorStore = AudioEditorStore(undoCoordinator: undoCoordinator)
        self.audioToolboxStore = AudioToolboxStore(undoCoordinator: undoCoordinator)
        self.imageToolboxStore = ImageToolboxStore(undoCoordinator: undoCoordinator)
        self.pdfToolboxStore = PDFToolboxStore(undoCoordinator: undoCoordinator)
        let watchManager = WatchFolderManager(
            store: WatchFolderStore(fileURL: watchFolderStoreURL),
            conversionManager: manager,
            conversionQueue: queue
        )
        self.watchFolderManager = watchManager

        self.lastSidebarActiveJobCount = manager.runningOrWaitingCount

        conversionManager.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedTab == .convert || self.selectedTab == .jobs {
                    self.objectWillChange.send()
                }
            }
            .store(in: &storeChangeCancellables)

        Publishers.CombineLatest(manager.$activeJobs, manager.$jobStatuses)
            .dropFirst()
            .sink { [weak self] jobs, statuses in
                guard let self else { return }
                let nextActiveCount = jobs.reduce(into: 0) { count, job in
                    if let status = statuses[job.id], status.isActive {
                        count += 1
                    }
                }
                guard nextActiveCount != self.lastSidebarActiveJobCount else { return }
                self.lastSidebarActiveJobCount = nextActiveCount
                if self.selectedTab != .convert && self.selectedTab != .jobs {
                    self.objectWillChange.send()
                }
            }
            .store(in: &storeChangeCancellables)

        conversionQueue.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedTab == .convert || self.selectedTab == .jobs {
                    self.objectWillChange.send()
                }
            }
            .store(in: &storeChangeCancellables)

        audioToolboxStore.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedTab == .audioToolbox || self.selectedTab == .audioWorkspace {
                    self.objectWillChange.send()
                }
            }
            .store(in: &storeChangeCancellables)

        imageToolboxStore.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedTab == .imageToolbox {
                    self.objectWillChange.send()
                }
            }
            .store(in: &storeChangeCancellables)

        pdfToolboxStore.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedTab == .pdfToolbox {
                    self.objectWillChange.send()
                }
            }
            .store(in: &storeChangeCancellables)

        watchManager.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedTab == .presets {
                    self.objectWillChange.send()
                }
                Task { @MainActor in
                    MenuBarManager.shared.updateStatus()
                }
            }
            .store(in: &storeChangeCancellables)

        watchManager.defaultOutputLocationProvider = { [weak self] in
            guard let self else {
                let prefs = OutputManager.loadSavedPreferences()
                return (prefs.location, prefs.customDirectory)
            }
            return (self.outputLocation, self.customOutputDirectory)
        }
        
        queue.onQueueStarted = { [weak self] in
            self?.isConverting = true
            self?.lastAnnouncedProgressMilestone = 0
            let count = self?.conversionQueue.totalCount ?? 0
            if count > 0 {
                let announcement = count == 1
                    ? String(localized: "Started converting 1 file.")
                    : String(localized: "Started converting \(count) files.")
                AccessibilityAnnouncer.announce(announcement, priority: .medium)
            }
        }
        queue.onQueueCompleted = { [weak self] in
            self?.isConverting = false
            self?.lastAnnouncedProgressMilestone = 0
        }
        progressMilestoneCancellable = manager.$jobStatuses.sink { [weak self] _ in
            guard let self, self.isConverting else { return }
            MenuBarManager.shared.updateStatus()
            let pct = Int((self.conversionQueue.progress * 100.0).rounded(.down))
            for milestone in [25, 50, 75] where pct >= milestone && self.lastAnnouncedProgressMilestone < milestone {
                self.lastAnnouncedProgressMilestone = milestone
                AccessibilityAnnouncer.announce(String(localized: "Conversion \(milestone) percent complete."), priority: .low)
            }
        }
        
        AppState.shared = self
        let deferredURLs = AppDelegate.consumePendingOpenURLs()
        if !deferredURLs.isEmpty {
            handleOpenedFileURLs(deferredURLs)
        }
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
        NSApp?.activate(ignoringOtherApps: true)
    }

    // MARK: - Media Viewer

    public func openInMediaViewer(_ url: URL) {
        activeMediaViewerURL = url
        isMediaViewerPresented = true
    }

    public func openMediaViewerEmpty() {
        activeMediaViewerURL = nil
        isMediaViewerPresented = true
    }

    public func closeMediaViewer() {
        isMediaViewerPresented = false
        activeMediaViewerURL = nil
    }

    public func sendToConvertQueue(fromMediaViewer url: URL) {
        closeMediaViewer()
        addFiles(urls: [url])
        selectedTab = .convert
    }

    /// Routes Finder "Open With" and incoming file URLs:
    /// a single validated supported image or video opens in the unified Media Viewer;
    /// multiple files, folders, or non-media files fall back to the Convert queue.
    public func handleOpenedFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if MediaViewerRouter.shouldRouteSingleOpenedFileToMediaViewer(urls: urls),
           let candidateURL = urls.first {
            switch FinderHandoffHandler.validateInputFileURL(candidateURL) {
            case .success(let safeURL):
                openInMediaViewer(safeURL)
                NSApp?.activate(ignoringOtherApps: true)
                return
            case .failure:
                break
            }
        }
        addFiles(urls: urls)
    }

    /// Context-aware file open router for `⌘O` (Add Files...).
    /// Preserves the active toolbox or Metadata tab when compatible files are opened; switches to `.convert` from non-editor tabs.
    public func routeOpenFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if selectedTab == .metadata, let first = urls.first {
            addFiles(urls: urls)
            Task { @MainActor in
                await MetadataManager.shared.load(url: first)
            }
            return
        }

        addFiles(urls: urls)
        let categories = Set(urls.compactMap { fileDetector.detect(url: $0).bestFormat?.category })
        let formats = Set(urls.compactMap { fileDetector.detect(url: $0).bestFormat })

        switch selectedTab {
        case .convert:
            break
        case .imageToolbox where categories.contains(.image):
            break
        case .pdfToolbox where formats.contains(.pdf) || categories.contains(.image):
            break
        case .audioToolbox where categories.contains(.audio) || categories.contains(.video):
            break
        case .audioWorkspace where (categories.contains(.audio) || categories.contains(.video)) && audioWorkspace.activeMode == .audioTools:
            break
        default:
            selectedTab = .convert
        }
    }

    /// Navigates directly to Audio Workspace in Audio Tools mode.
    public func openAudioTools() {
        audioWorkspace.activeMode = .audioTools
        selectedTab = .audioWorkspace
    }

    /// True when at least one queued file has a valid detected format and target output format and no conversion is currently running.
    var canStartBatchConversion: Bool {
        !isConverting && droppedFiles.contains { $0.detectedFormat != nil && $0.selectedOutputFormat != nil }
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
                    newOptions.applyPreset(
                        preset,
                        inputFormat: result.bestFormat,
                        outputFormat: targetFormat
                    )
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
            folderRejectedNotice = String(localized: "Folders can't be converted directly.")
            pendingFolderURLs = validation.rejectedFolders
        }
        
        // Start conversion automatically for the ones we configured
        for file in filesToConvert {
            convert(file: file)
        }
    }
    
    func handleDroppedURLs(_ urls: [URL]) {
        let before = droppedFiles
        let validation = FinderHandoffHandler.validateAndSanitize(
            urls: urls,
            registry: ConversionRegistry.shared,
            fileDetector: fileDetector
        )

        var newValidAdded = 0
        var newUnsupportedAdded = 0
        var duplicateCount = 0
        let validSet = Set(validation.validURLs)
        
        for url in validation.validURLs + validation.unsupportedURLs {
            let std = url.standardizedFileURL
            if droppedFiles.contains(where: { $0.url == url || $0.url.standardizedFileURL == std }) {
                duplicateCount += 1
                continue
            }
            let result = fileDetector.detect(url: url)
            var droppedFile = DroppedFile(
                url: url,
                detectionResult: result,
                options: AppSettings.shared.defaultConversionOptions
            )
            droppedFile.options = AppSettings.shared.initialOptionsForNewFile(
                inputFormat: droppedFile.detectedFormat,
                outputFormat: droppedFile.selectedOutputFormat
            )
            droppedFiles.append(droppedFile)
            if validSet.contains(url) {
                newValidAdded += 1
            } else {
                newUnsupportedAdded += 1
            }
        }

        let addedCount = droppedFiles.count - before.count
        if addedCount > 0 {
            let after = droppedFiles
            let coordinator = undoCoordinator
            let cmd = DroppedFilesUndoCommand(
                operationType: .queueAddFiles,
                title: String(localized: "Add \(addedCount) File(s)"),
                beforeFiles: before,
                afterFiles: after,
                applyFiles: { [weak self] restored in self?.droppedFiles = restored }
            )
            Task { await coordinator.record(cmd) }
        }
        
        if !validation.rejectedFolders.isEmpty {
            folderRejectedNotice = String(localized: "Folders can't be converted directly.")
            pendingFolderURLs = validation.rejectedFolders
        }
        
        if newValidAdded > 0 {
            let baseFeedback = newValidAdded == 1
                ? String(localized: "1 file added")
                : String(localized: "\(newValidAdded) files added")
            let feedback = duplicateCount > 0
                ? String(localized: "\(baseFeedback) (\(duplicateCount) duplicate skipped)")
                : baseFeedback
            dropFeedbackText = feedback
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.dropFeedbackText == feedback {
                    self.dropFeedbackText = nil
                }
            }
        } else if newUnsupportedAdded > 0 {
            let feedback = newUnsupportedAdded == 1
                ? String(localized: "1 unsupported file added")
                : String(localized: "\(newUnsupportedAdded) unsupported files added")
            dropFeedbackText = feedback
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.dropFeedbackText == feedback {
                    self.dropFeedbackText = nil
                }
            }
        } else if duplicateCount > 0 {
            let feedback = duplicateCount == 1
                ? String(localized: "File is already in the queue")
                : String(localized: "\(duplicateCount) duplicate files skipped")
            dropFeedbackText = feedback
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.dropFeedbackText == feedback {
                    self.dropFeedbackText = nil
                }
            }
        }
        
        logger.info("Handled \(urls.count, privacy: .public) items (\(self.droppedFiles.count, privacy: .public) total files in list, \(validation.validURLs.count, privacy: .public) valid, \(duplicateCount, privacy: .public) duplicates, \(validation.rejectedFolders.count, privacy: .public) folders rejected)")
    }

    /// Reorders queued files non-destructively and records an Undo/Redo step.
    public func moveFiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = droppedFiles
        droppedFiles.move(fromOffsets: source, toOffset: destination)
        let after = droppedFiles
        guard before.map(\.id) != after.map(\.id) else { return }
        let coordinator = undoCoordinator
        let cmd = DroppedFilesUndoCommand(
            operationType: .queueAddFiles,
            title: String(localized: "Reorder Queue Files"),
            beforeFiles: before,
            afterFiles: after,
            applyFiles: { [weak self] restored in self?.droppedFiles = restored }
        )
        Task { await coordinator.record(cmd) }
    }

    /// Synchronizes queued `DroppedFile` URLs and `ImageToolboxStore` per-URL state after a batch rename, undo, or redo.
    public func applyRenamedURLs(_ moves: [(from: URL, to: URL)]) {
        guard !moves.isEmpty else { return }
        var moveMap: [URL: URL] = [:]
        for move in moves {
            moveMap[move.from.standardizedFileURL.resolvingSymlinksInPath()] = move.to
        }
        var updatedFiles = droppedFiles
        var didMutateFiles = false
        for idx in updatedFiles.indices {
            let currentKey = updatedFiles[idx].url.standardizedFileURL.resolvingSymlinksInPath()
            if let newURL = moveMap[currentKey] {
                updatedFiles[idx].url = newURL
                didMutateFiles = true
            }
        }
        if didMutateFiles {
            droppedFiles = updatedFiles
        }
        imageToolboxStore.migrateURLs(moves)
        audioToolboxStore.migrateURLs(moves)
    }

    /// Removes any queued `DroppedFile` entries matching the specified URLs (e.g. after moving duplicates to macOS Trash).
    public func removeFiles(matchingURLs urls: Set<URL>, recordUndo: Bool = false) {
        guard !urls.isEmpty else { return }
        let standardizedTargets = Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        let before = droppedFiles
        droppedFiles.removeAll { file in
            standardizedTargets.contains(file.url.standardizedFileURL.resolvingSymlinksInPath())
        }
        let after = droppedFiles
        guard recordUndo, before.count != after.count else { return }
        let removedCount = before.count - after.count
        let coordinator = undoCoordinator
        let cmd = DroppedFilesUndoCommand(
            operationType: .queueRemoveFiles,
            title: String(localized: "Remove \(removedCount) File(s)"),
            beforeFiles: before,
            afterFiles: after,
            applyFiles: { [weak self] restored in self?.droppedFiles = restored }
        )
        Task { await coordinator.record(cmd) }
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
        
        if let firstFormat = firstFile.detectedFormat {
            let recommended = ConversionRegistry.shared.recommendedOutputFormats(for: firstFormat)
            let ordered = recommended.filter { commonFormats.contains($0) }
            if !ordered.isEmpty {
                return Array(ordered.prefix(6))
            }
        }
        
        let sorted = commonFormats.sorted { $0.displayName < $1.displayName }
        return Array(sorted.prefix(6))
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
            showError(message: String(localized: "No previous conversion to repeat."))
            return
        }
        
        guard isRepeatConversionCompatible else {
            showError(
                message: String(localized: "Your last conversion isn't compatible with the selected files."),
                details: String(localized: "The previous conversion was to \(config.outputFormat.displayName), which cannot be applied to all currently loaded files.")
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

    func resolveInteractiveOutputDirectoryIfNeeded() -> (cancelled: Bool, directory: URL?) {
        guard outputLocation == .askEveryTime else {
            return (false, nil)
        }
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isRunningTests, NSApp.windows.contains(where: { $0.isVisible }) else {
            return (false, nil)
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Output Folder")
        panel.message = String(localized: "Select where LocalConvert should save the converted file(s).")
        if let seed = customOutputDirectory ?? OutputManager.lastUsedDirectory {
            panel.directoryURL = seed
        }
        if panel.runModal() == .OK, let url = panel.url {
            OutputManager.lastUsedDirectory = url
            return (false, url)
        }
        return (true, nil)
    }

    func convertAll() {
        folderRejectedNotice = nil
        let interactive = resolveInteractiveOutputDirectoryIfNeeded()
        if interactive.cancelled {
            return
        }
        var jobs: [ConversionJob] = []
        var unwritableDirs: [String] = []
        let batchID = droppedFiles.count > 1 ? UUID() : nil
        
        for file in droppedFiles {
            guard let inputFormat = file.detectedFormat,
                  let outputFormat = file.selectedOutputFormat else {
                continue
            }
            
            let outputDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
                for: file.url,
                preference: outputLocation,
                customDirectory: customOutputDirectory
            )
            
            // Validate output directory without aborting other valid files in the batch
            guard OutputManager.isOutputDirectoryValid(outputDir) else {
                unwritableDirs.append("\(file.url.lastPathComponent) → \(outputDir.path)")
                continue
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
        
        if !unwritableDirs.isEmpty {
            showError(
                message: jobs.isEmpty
                    ? String(localized: "The destination folder is inaccessible or unwritable.")
                    : String(localized: "Some files were skipped because their destination folders are not writable."),
                details: unwritableDirs.joined(separator: "\n")
            )
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

        let interactive = resolveInteractiveOutputDirectoryIfNeeded()
        if interactive.cancelled {
            return
        }

        let outputDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
            for: file.url,
            preference: outputLocation,
            customDirectory: customOutputDirectory
        )
        
        guard OutputManager.isOutputDirectoryValid(outputDir) else {
            showError(
                message: String(localized: "The destination folder is inaccessible or unwritable."),
                details: String(localized: "Directory path: \(outputDir.path)")
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

    func syncOutputPreferencesToDefaults() {
        guard !isUITestingOutputLocked else { return }
        if outputLocation != .sameFolder {
            outputLocation = .sameFolder
        }
        if customOutputDirectory != nil {
            customOutputDirectory = nil
        }
    }

    func openConversionHistory(
        sourceFilter: HistorySourceFilter = .all,
        watchFolderRuleID: UUID? = nil,
        watchFolderRuleName: String? = nil
    ) {
        pendingHistorySourceFilter = sourceFilter
        pendingHistoryWatchFolderRuleID = watchFolderRuleID
        pendingHistoryWatchFolderRuleName = watchFolderRuleName
        pendingHistoryNavigationNonce &+= 1
        selectedTab = .history
    }
    
    // MARK: - Error Handling
    
    func showError(
        title: String = String(localized: "Conversion Notice"),
        message: String,
        suggestion: String? = nil,
        details: String? = nil
    ) {
        errorTitle = title
        errorMessage = ErrorDetailsFormatter.sanitize(message)
        errorSuggestion = suggestion
        errorDetails = details.map { ErrorDetailsFormatter.sanitize($0) }
        showError = true
        AccessibilityAnnouncer.announce(String(localized: "Error: \(errorMessage)"), priority: .high)
    }
}

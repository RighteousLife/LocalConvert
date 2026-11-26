import SwiftUI

// MARK: - Smart Queue Categorization & Recommendation Engine

enum SmartQueueCategory: String, Codable, Equatable, Sendable {
    case empty
    case pdf
    case image
    case audioVideo
    case mixed

    var displayTitle: String {
        switch self {
        case .empty: return ""
        case .pdf: return "PDF"
        case .image: return "Images"
        case .audioVideo: return "Audio / Video"
        case .mixed: return "Mixed Batch"
        }
    }

    var systemImage: String {
        switch self {
        case .empty: return "sparkles"
        case .pdf: return "doc.richtext"
        case .image: return "photo.stack"
        case .audioVideo: return "film.stack"
        case .mixed: return "square.stack.3d.up"
        }
    }
}

enum SmartSuggestionActionID: String, CaseIterable, Identifiable, Codable, Sendable {
    // PDF
    case compressPDF = "compress_pdf"
    case convertToDOCX = "convert_to_docx"
    case pdfToImages = "pdf_to_images"
    case ocrPDF = "ocr_pdf"

    // Image
    case webpOptimize = "webp_optimize"
    case removeBackground = "remove_background"
    case stripMetadata = "strip_metadata"
    case resizeImages = "resize_images"

    // Audio / Video
    case extractMP3 = "extract_mp3"
    case compactMP4 = "compact_mp4"
    case iphoneRingtoneM4R = "iphone_ringtone_m4r"
    case trimMedia = "trim_media"

    // Mixed Batch
    case applySavedPreset = "apply_saved_preset"
    case convertAll = "convert_all"

    var id: String { rawValue }
}

struct ContextualSmartAction: Identifiable, Equatable, Sendable {
    let id: SmartSuggestionActionID
    let title: String
    let systemImage: String
    let helpText: String
    let isEnabled: Bool
    let isPrimary: Bool

    init(
        id: SmartSuggestionActionID,
        title: String,
        systemImage: String,
        helpText: String,
        isEnabled: Bool = true,
        isPrimary: Bool = false
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.helpText = helpText
        self.isEnabled = isEnabled
        self.isPrimary = isPrimary
    }
}

struct SmartSuggestionPlan: Equatable, Sendable {
    let category: SmartQueueCategory
    let actions: [ContextualSmartAction]
}

enum SmartSuggestionEngine: Sendable {
    static func classify(formats: [FileFormat?]) -> SmartQueueCategory {
        guard !formats.isEmpty else { return .empty }

        let resolved = formats.compactMap { $0 }
        guard resolved.count == formats.count else {
            return .mixed
        }

        if resolved.allSatisfy({ $0 == .pdf }) {
            return .pdf
        }
        if resolved.allSatisfy({ $0.category == .image }) {
            return .image
        }
        if resolved.allSatisfy({ $0.category == .audio || $0.category == .video }) {
            return .audioVideo
        }
        return .mixed
    }

    static func suggest(for formats: [FileFormat?]) -> SmartSuggestionPlan {
        let category = classify(formats: formats)
        let resolved = formats.compactMap { $0 }

        switch category {
        case .empty:
            return SmartSuggestionPlan(category: .empty, actions: [])

        case .pdf:
            return SmartSuggestionPlan(
                category: .pdf,
                actions: [
                    ContextualSmartAction(
                        id: .compressPDF,
                        title: "Compress PDF",
                        systemImage: "arrow.down.right.and.arrow.up.left",
                        helpText: "Optimize and reduce PDF file size"
                    ),
                    ContextualSmartAction(
                        id: .convertToDOCX,
                        title: "Convert to DOCX",
                        systemImage: "doc.text",
                        helpText: "Convert staged PDF files to editable Word (.docx) documents"
                    ),
                    ContextualSmartAction(
                        id: .pdfToImages,
                        title: "PDF → Images",
                        systemImage: "photo.on.rectangle",
                        helpText: "Render PDF pages as PNG images"
                    ),
                    ContextualSmartAction(
                        id: .ocrPDF,
                        title: "OCR",
                        systemImage: "text.viewfinder",
                        helpText: "Run on-device Vision OCR to create searchable PDFs"
                    )
                ]
            )

        case .image:
            return SmartSuggestionPlan(
                category: .image,
                actions: [
                    ContextualSmartAction(
                        id: .webpOptimize,
                        title: "WebP Optimize",
                        systemImage: "sparkles.rectangle.stack",
                        helpText: "Optimize staged images as web-ready WebP"
                    ),
                    ContextualSmartAction(
                        id: .removeBackground,
                        title: "Remove Background",
                        systemImage: "person.crop.rectangle",
                        helpText: "Isolate subject and remove image background on-device"
                    ),
                    ContextualSmartAction(
                        id: .stripMetadata,
                        title: "Strip Metadata/GPS",
                        systemImage: "shield.lefthalf.filled",
                        helpText: "Strip EXIF, GPS location, and camera metadata"
                    ),
                    ContextualSmartAction(
                        id: .resizeImages,
                        title: "Resize",
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        helpText: "Resize staged images by percentage or target width"
                    )
                ]
            )

        case .audioVideo:
            let hasVideo = resolved.contains { $0.category == .video }
            let hasExtractableToMP3 = resolved.contains { $0 != .mp3 }
            let hasConvertibleToM4R = resolved.contains { $0 != .m4r }

            return SmartSuggestionPlan(
                category: .audioVideo,
                actions: [
                    ContextualSmartAction(
                        id: .extractMP3,
                        title: "Extract MP3",
                        systemImage: "music.note",
                        helpText: "Extract or convert audio tracks to MP3",
                        isEnabled: hasExtractableToMP3
                    ),
                    ContextualSmartAction(
                        id: .compactMP4,
                        title: "Compact MP4",
                        systemImage: "film",
                        helpText: "Transcode staged video to compact H.264/AAC MP4",
                        isEnabled: hasVideo
                    ),
                    ContextualSmartAction(
                        id: .iphoneRingtoneM4R,
                        title: "iPhone Ringtone (.m4r)",
                        systemImage: "bell.badge",
                        helpText: "Create an iPhone ringtone (.m4r, up to 30s)",
                        isEnabled: hasConvertibleToM4R
                    ),
                    ContextualSmartAction(
                        id: .trimMedia,
                        title: "Trim",
                        systemImage: "scissors",
                        helpText: hasVideo ? "Trim video range before conversion" : "Open Quick Trim in Audio Tools"
                    )
                ]
            )

        case .mixed:
            let hasConvertible = !resolved.isEmpty
            return SmartSuggestionPlan(
                category: .mixed,
                actions: [
                    ContextualSmartAction(
                        id: .applySavedPreset,
                        title: "Apply Saved Preset...",
                        systemImage: "wand.and.stars",
                        helpText: "Apply a saved conversion preset to compatible files in the queue"
                    ),
                    ContextualSmartAction(
                        id: .convertAll,
                        title: "Convert All",
                        systemImage: "arrow.triangle.2.circlepath",
                        helpText: "Start converting all staged files",
                        isEnabled: hasConvertible,
                        isPrimary: true
                    )
                ]
            )
        }
    }

    static func suggest(for files: [DroppedFile]) -> SmartSuggestionPlan {
        var plan = suggest(for: files.map(\.detectedFormat))
        if plan.category == .mixed {
            let canConvert = files.contains { $0.detectedFormat != nil && $0.selectedOutputFormat != nil }
            let updatedActions = plan.actions.map { action in
                if action.id == .convertAll {
                    return ContextualSmartAction(
                        id: action.id,
                        title: action.title,
                        systemImage: action.systemImage,
                        helpText: action.helpText,
                        isEnabled: canConvert,
                        isPrimary: action.isPrimary
                    )
                }
                return action
            }
            plan = SmartSuggestionPlan(category: .mixed, actions: updatedActions)
        }
        return plan
    }
}

// MARK: - Smart Bar Resize Option

enum SmartResizeOption: String, CaseIterable, Identifiable, Sendable {
    case scale50 = "50% Scale"
    case maxWidth1920 = "Max Width 1920 px"
    case maxWidth1280 = "Max Width 1280 px"
    case maxWidth800 = "Max Width 800 px"

    var id: String { rawValue }
}

// MARK: - Smart Bar Action Execution

@MainActor
enum SmartBarActionExecutor {
    static func runPDFAction(_ actionID: SmartSuggestionActionID, appState: AppState) {
        let pdfFiles = appState.droppedFiles.filter { $0.detectedFormat == .pdf }
        guard !pdfFiles.isEmpty else { return }

        switch actionID {
        case .compressPDF:
            let key = PDFToolboxStore.configKey(for: pdfFiles.map(\.url))
            var cfg = appState.pdfToolboxStore.compressionConfig(for: key)
            cfg.password = nil
            var extra: [String: String] = [:]
            if let data = try? JSONEncoder().encode(cfg),
               let json = String(data: data, encoding: .utf8) {
                extra["pdf_compress_config"] = json
            }
            appState.executePDFOperation(operation: "compress", files: pdfFiles, extraOptions: extra)

        case .convertToDOCX:
            appState.quickConvert(to: .docx)

        case .pdfToImages:
            appState.executePDFOperation(operation: "pdfToImages", files: pdfFiles)

        case .ocrPDF:
            let key = PDFToolboxStore.configKey(for: pdfFiles.map(\.url))
            var ocrCfg = appState.pdfToolboxStore.ocrConfig(for: key)
            ocrCfg.password = nil
            var extra: [String: String] = [:]
            if let data = try? JSONEncoder().encode(ocrCfg),
               let json = String(data: data, encoding: .utf8) {
                extra["pdf_ocr_config"] = json
            }
            appState.executePDFOperation(operation: "ocr", files: pdfFiles, extraOptions: extra)

        default:
            break
        }
    }

    static func runWebPOptimize(appState: AppState) {
        let imageFiles = appState.droppedFiles.filter { $0.detectedFormat?.category == .image }
        guard !imageFiles.isEmpty else { return }

        let allCanUseStandardRoute = imageFiles.allSatisfy { $0.availableOutputFormats.contains(.webp) }
        if allCanUseStandardRoute {
            for file in imageFiles {
                appState.updateOutputFormat(for: file.id, format: .webp)
                appState.applyPreset(.web, for: file.id)
            }
            appState.convertAll()
            return
        }

        // Same-format WebP inputs use ImageToolbox pipeline safely without overwriting source
        var fallbackConfig = ImageToolboxConfig()
        fallbackConfig.compressionProfile = .webOptimized
        fallbackConfig.quality = 0.78
        fallbackConfig.webpLossless = false
        fallbackConfig.metadataEdit.policy = .stripAll

        for file in imageFiles {
            appState.imageToolboxStore.setTargetFormat(.webp, for: file.url)
            appState.imageToolboxStore.updateConfig(
                for: file.url,
                explicitTitle: "WebP Optimize"
            ) { cfg in
                cfg.compressionProfile = .webOptimized
                cfg.quality = 0.78
                cfg.webpLossless = false
                cfg.metadataEdit.policy = .stripAll
            }
        }
        appState.executeImageToolbox(
            inputs: imageFiles.map(\.url),
            outputFormat: .webp,
            config: fallbackConfig
        )
    }

    static func runRemoveBackground(appState: AppState) {
        let imageFiles = appState.droppedFiles.filter { $0.detectedFormat?.category == .image }
        guard !imageFiles.isEmpty else { return }

        let engine = ImageConversionEngine()
        var fallbackConfig = ImageToolboxConfig()
        fallbackConfig.backgroundRemoval.enabled = true
        fallbackConfig.backgroundRemoval.fillMode = .transparent

        for file in imageFiles {
            let currentTarget = file.selectedOutputFormat
            let alphaFormat: FileFormat
            if let currentTarget,
               FormatCapabilityRegistry.shared.capability(for: currentTarget).supportsTransparency,
               engine.supportedOutputFormats.contains(currentTarget) {
                alphaFormat = currentTarget
            } else {
                alphaFormat = .png
            }

            appState.imageToolboxStore.setTargetFormat(alphaFormat, for: file.url)
            appState.imageToolboxStore.updateConfig(
                for: file.url,
                explicitTitle: "Remove Background"
            ) { cfg in
                cfg.backgroundRemoval.enabled = true
                cfg.backgroundRemoval.fillMode = .transparent
            }
        }
        appState.executeImageToolbox(
            inputs: imageFiles.map(\.url),
            outputFormat: .png,
            config: fallbackConfig
        )
    }

    static func runStripMetadata(appState: AppState) {
        let imageFiles = appState.droppedFiles.filter { $0.detectedFormat?.category == .image }
        guard !imageFiles.isEmpty else { return }

        let engine = ImageConversionEngine()
        var fallbackConfig = ImageToolboxConfig()
        fallbackConfig.metadataEdit.policy = .stripAll
        fallbackConfig.metadataEdit.stripGPS = true

        for file in imageFiles {
            let targetFormat: FileFormat
            if let detected = file.detectedFormat,
               FormatCapabilityRegistry.shared.capability(for: detected).canWrite,
               engine.supportedOutputFormats.contains(detected) {
                targetFormat = detected
            } else {
                targetFormat = file.selectedOutputFormat ?? .png
            }

            appState.imageToolboxStore.setTargetFormat(targetFormat, for: file.url)
            appState.imageToolboxStore.updateConfig(
                for: file.url,
                explicitTitle: "Strip Metadata & GPS"
            ) { cfg in
                cfg.metadataEdit.policy = .stripAll
                cfg.metadataEdit.stripGPS = true
            }
        }
        appState.executeImageToolbox(
            inputs: imageFiles.map(\.url),
            outputFormat: .png,
            config: fallbackConfig
        )
    }

    static func applyResize(_ option: SmartResizeOption, appState: AppState, startConversion: Bool = true) {
        let imageFiles = appState.droppedFiles.filter { $0.detectedFormat?.category == .image }
        guard !imageFiles.isEmpty else { return }

        for index in appState.droppedFiles.indices {
            guard appState.droppedFiles[index].detectedFormat?.category == .image else { continue }
            var updated = appState.droppedFiles[index].options
            switch option {
            case .scale50:
                updated.resizeMode = .percentage
                updated.resizePercentage = 0.50
                updated.resizeWidth = nil
                updated.resizeHeight = nil
            case .maxWidth1920:
                updated.resizeMode = .exactWidth
                updated.resizeWidth = 1920
                updated.resizeHeight = nil
                updated.preserveAspectRatio = true
            case .maxWidth1280:
                updated.resizeMode = .exactWidth
                updated.resizeWidth = 1280
                updated.resizeHeight = nil
                updated.preserveAspectRatio = true
            case .maxWidth800:
                updated.resizeMode = .exactWidth
                updated.resizeWidth = 800
                updated.resizeHeight = nil
                updated.preserveAspectRatio = true
            }
            appState.updateOptions(for: appState.droppedFiles[index].id, options: updated)
        }

        if startConversion {
            appState.convertAll()
        }
    }

    static func runCompactMP4(appState: AppState) {
        let videoFiles = appState.droppedFiles.filter { $0.detectedFormat?.category == .video }
        guard !videoFiles.isEmpty else { return }

        let allSupportStandardRoute = videoFiles.allSatisfy { $0.availableOutputFormats.contains(.mp4) }
        if allSupportStandardRoute {
            for index in appState.droppedFiles.indices {
                guard appState.droppedFiles[index].detectedFormat?.category == .video else { continue }
                let id = appState.droppedFiles[index].id
                appState.updateOutputFormat(for: id, format: .mp4)
                appState.applyPreset(.videoMaximumCompatibility, for: id)
            }
            appState.convertAll()
            return
        }

        // Same-format MP4 inputs require an explicit MediaEngine job routed safely to a unique output URL
        let interactive = appState.resolveInteractiveOutputDirectoryIfNeeded()
        if interactive.cancelled {
            return
        }

        var jobs: [ConversionJob] = []
        let batchID = videoFiles.count > 1 ? UUID() : nil
        for file in videoFiles {
            guard let inFormat = file.detectedFormat else { continue }
            let outputDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
                for: file.url,
                preference: appState.outputLocation,
                customDirectory: appState.customOutputDirectory
            )
            guard OutputManager.isOutputDirectoryValid(outputDir) else { continue }

            var opts = file.options
            opts.applyPreset(.videoMaximumCompatibility, inputFormat: inFormat, outputFormat: .mp4)
            if inFormat == .mp4 {
                opts.customOptions["audio_operation"] = "convert"
            }
            jobs.append(
                ConversionJob(
                    inputURLs: [file.url],
                    inputFormat: inFormat,
                    outputFormat: .mp4,
                    outputDirectory: outputDir,
                    options: opts,
                    batchID: batchID
                )
            )
        }

        guard !jobs.isEmpty else { return }
        appState.isConverting = true
        appState.conversionQueue.enqueue(jobs: jobs)
    }

    static func runTrim(appState: AppState, openVideoTrimSheet: (DroppedFile) -> Void) {
        if let firstVideo = appState.droppedFiles.first(where: { $0.detectedFormat?.category == .video }) {
            openVideoTrimSheet(firstVideo)
            return
        }
        if let firstAudio = appState.droppedFiles.first(where: { $0.detectedFormat?.category == .audio }) {
            appState.audioToolboxStore.selectedSection = .trim
            appState.audioToolboxStore.selectedFileIds = [firstAudio.id]
            appState.openAudioTools()
        }
    }
}

// MARK: - Contextual Smart Suggestion Bar View

struct ContextualSmartBarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var presetManager = PresetManager.shared
    @State private var trimSheetFile: DroppedFile?

    private var plan: SmartSuggestionPlan {
        SmartSuggestionEngine.suggest(for: appState.droppedFiles)
    }

    var body: some View {
        if plan.category != .empty && !plan.actions.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    smartCategoryBadge

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.xs + 2) {
                            ForEach(plan.actions) { action in
                                actionControl(for: action)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.xs + 2)
                .background(AppTheme.Colors.subtleSurface)

                AppDivider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("filelist.smartBar")
            .sheet(item: $trimSheetFile) { file in
                let liveFile = appState.file(for: file.id) ?? file
                VideoTrimSheetView(file: liveFile) { trimRange, preferredFormat in
                    appState.updateVideoTrim(
                        for: liveFile.id,
                        trim: trimRange,
                        preferredOutputFormat: preferredFormat
                    )
                }
            }
        }
    }

    private var smartCategoryBadge: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "sparkles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.accent)
            Text(plan.category.displayTitle)
                .font(AppTheme.Typography.badge)
                .foregroundStyle(AppTheme.Colors.accent)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, 3)
        .background(AppTheme.Colors.accentTint)
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Smart suggestions for \(plan.category.displayTitle)")
        .accessibilityIdentifier("smartbar.categoryLabel")
    }

    @ViewBuilder
    private func actionControl(for action: ContextualSmartAction) -> some View {
        switch action.id {
        case .resizeImages:
            Menu {
                ForEach(SmartResizeOption.allCases) { option in
                    Button(option.rawValue) {
                        SmartBarActionExecutor.applyResize(option, appState: appState)
                    }
                }
                Divider()
                Button("Open Image Toolbox Resize...") {
                    appState.selectedTab = .imageToolbox
                }
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(AppTheme.Typography.caption)
                    .lineLimit(1)
            }
            .controlSize(.small)
            .menuStyle(.borderlessButton)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 3)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!action.isEnabled || appState.isConverting)
            .help(action.helpText)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier("smartbar.action.\(action.id.rawValue)")

        case .applySavedPreset:
            Menu {
                if presetManager.presets.isEmpty {
                    Text("No saved presets")
                } else {
                    ForEach(presetManager.presets) { preset in
                        Button {
                            let validation = presetManager.apply(preset: preset, to: appState)
                            let count = validation.compatibleURLs.count
                            appState.dropFeedbackText = count > 0
                                ? "Applied preset \"\(preset.name)\" to \(count) file\(count == 1 ? "" : "s")"
                                : "No files compatible with \"\(preset.name)\""
                        } label: {
                            Label(preset.name, systemImage: "wand.and.stars")
                        }
                    }
                }
                Divider()
                Button("Manage Presets...") {
                    appState.selectedTab = .presets
                }
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .font(AppTheme.Typography.caption)
                    .lineLimit(1)
            }
            .controlSize(.small)
            .menuStyle(.borderlessButton)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 3)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!action.isEnabled || appState.isConverting)
            .help(action.helpText)
            .accessibilityLabel(action.title)
            .accessibilityIdentifier("smartbar.action.\(action.id.rawValue)")

        default:
            if action.isPrimary {
                Button {
                    trigger(action.id)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(AppTheme.Typography.caption)
                        .lineLimit(1)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!action.isEnabled || appState.isConverting)
                .help(action.helpText)
                .accessibilityLabel(action.title)
                .accessibilityIdentifier("smartbar.action.\(action.id.rawValue)")
            } else {
                Button {
                    trigger(action.id)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(AppTheme.Typography.caption)
                        .lineLimit(1)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!action.isEnabled || appState.isConverting)
                .help(action.helpText)
                .accessibilityLabel(action.title)
                .accessibilityIdentifier("smartbar.action.\(action.id.rawValue)")
            }
        }
    }

    private func trigger(_ actionID: SmartSuggestionActionID) {
        switch actionID {
        case .compressPDF, .convertToDOCX, .pdfToImages, .ocrPDF:
            SmartBarActionExecutor.runPDFAction(actionID, appState: appState)
        case .webpOptimize:
            SmartBarActionExecutor.runWebPOptimize(appState: appState)
        case .removeBackground:
            SmartBarActionExecutor.runRemoveBackground(appState: appState)
        case .stripMetadata:
            SmartBarActionExecutor.runStripMetadata(appState: appState)
        case .extractMP3:
            appState.quickConvert(to: .mp3)
        case .compactMP4:
            SmartBarActionExecutor.runCompactMP4(appState: appState)
        case .iphoneRingtoneM4R:
            appState.quickConvert(to: .m4r)
        case .trimMedia:
            SmartBarActionExecutor.runTrim(appState: appState) { videoFile in
                trimSheetFile = videoFile
            }
        case .convertAll:
            appState.convertAll()
        case .resizeImages, .applySavedPreset:
            break
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Main Image Toolbox Pro View

struct ImageToolboxView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedSection: ImageToolboxSection = .convert
    @State private var selectedFileIds: Set<UUID> = []
    @State private var overwriteExisting: Bool = false

    private var config: ImageToolboxConfig {
        appState.imageToolboxStore.config(for: primaryURL)
    }

    private var configBinding: Binding<ImageToolboxConfig> {
        appState.imageToolboxStore.binding(for: primaryURL)
    }

    private var targetFormat: FileFormat {
        appState.imageToolboxStore.targetFormat(for: primaryURL)
    }

    private var targetFormatBinding: Binding<FileFormat> {
        appState.imageToolboxStore.targetFormatBinding(for: primaryURL)
    }

    // Live inspected metadata & color state for primary selected image
    @State private var colorInfo: ImageColorProfileInfo?
    @State private var metadataSummary: ImageMetadataPrivacySummary?
    @State private var detailedMetadata: ImageDetailedMetadataSnapshot?
    @State private var primaryDims: (width: Int, height: Int, bytes: Int64)?
    @State private var primaryFrameCount: Int = 1
    @State private var jxlInfo: JXLImageMetadataInfo?
    @State private var primaryPreviewImage: NSImage?
    @State private var usedRAWFallback: Bool = false

    // Preview / Comparison state
    @State private var comparisonSnapshot: ImageComparisonSnapshot?
    @State private var benchmarkTelemetry: ImageProcessingTelemetry?
    @State private var liveAfterImage: NSImage?
    @State private var liveTelemetry: ImageProcessingTelemetry?
    @State private var isUpdatingLivePreview: Bool = false
    @State private var showLivePreview: Bool = true
    @State private var previewPresetID: UUID? = nil
    @State private var livePreviewTask: Task<Void, Never>?
    @State private var isGeneratingPreview: Bool = false
    @State private var previewStatusText: String = ""
    @State private var previewTask: Task<Void, Never>?
    @State private var loadDetailsTask: Task<Void, Never>?

    // Popovers / Alerts
    @State private var showingSavePresetPopover: Bool = false
    @State private var presetNameInput: String = ""
    @State private var presetDescInput: String = ""
    @State private var bannerMessage: (text: String, isError: Bool)?
    @State private var isDropTargeted: Bool = false
    @State private var pendingMissingProject: ImageProjectDocument?
    @State private var showingMissingSourceAlert: Bool = false

    // MARK: - Candidate Files

    private var candidateFiles: [DroppedFile] {
        appState.droppedFiles.filter { $0.detectedFormat?.category == .image }
    }

    private var selectedFiles: [DroppedFile] {
        let matched = candidateFiles.filter { selectedFileIds.contains($0.id) }
        return matched.isEmpty ? candidateFiles : matched
    }

    private var primaryFile: DroppedFile? {
        selectedFiles.first ?? candidateFiles.first
    }

    private var primaryURL: URL? {
        primaryFile?.url
    }

    private var writableImageFormats: [FileFormat] {
        FormatCapabilityRegistry.shared.allCapabilities
            .filter { cap in
                cap.canWrite && (cap.format.category == .image || cap.format == .pdf)
            }
            .map(\.format)
            .sorted { lhs, rhs in
                if lhs == .jxl { return true }
                if rhs == .jxl { return false }
                return lhs.shortExtensionLabel < rhs.shortExtensionLabel
            }
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            // Left Sidebar
            List(ImageToolboxSection.allCases, selection: $selectedSection) { section in
                AppToolboxSidebarRow(
                    section.rawValue,
                    systemImage: section.iconName,
                    isSelected: selectedSection == section
                ) {
                    if isSectionConfigured(section) {
                        AppSidebarIndicatorDot()
                    }
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(minWidth: AppTheme.Layout.toolboxSidebarMin, maxWidth: AppTheme.Layout.toolboxSidebarMax)
            .appSecondarySidebarSurface()

            // Main Workspace
            VStack(spacing: 0) {
                if candidateFiles.isEmpty {
                    emptyDropView
                } else {
                    workspaceContent
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .appWorkspaceSurface()
        }
        .navigationTitle("Image Toolbox")
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onAppear { syncCandidateSelection() }
        .onChange(of: candidateFiles.map(\.id)) { _, _ in syncCandidateSelection() }
        .onChange(of: selectedFileIds) { _, _ in loadPrimaryDetails() }
        .onChange(of: targetFormat) { _, _ in
            benchmarkTelemetry = nil
            comparisonSnapshot = nil
            scheduleLivePreview(immediate: true)
        }
        .onChange(of: config) { _, _ in
            scheduleLivePreview(immediate: false)
        }
        .onChange(of: selectedSection) { _, newSec in
            if sectionSupportsLivePreview(newSec) && liveAfterImage == nil {
                scheduleLivePreview(immediate: true)
            }
        }
        .onChange(of: previewPresetID) { _, _ in
            scheduleLivePreview(immediate: true)
        }
        .onDisappear {
            previewTask?.cancel()
            livePreviewTask?.cancel()
            loadDetailsTask?.cancel()
        }
        .alert("Missing Source Image", isPresented: $showingMissingSourceAlert, presenting: pendingMissingProject) { doc in
            Button("Relink Image...") {
                relinkMissingProjectSource(doc)
            }
            Button("Cancel", role: .cancel) {
                pendingMissingProject = nil
            }
        } message: { doc in
            Text("The original image referenced by this project could not be found:\n\(doc.sourceDisplayPath)\n\nSelect a replacement image file to apply the saved edits.")
        }
    }

    // MARK: - Empty Drop State

    @ViewBuilder
    private var emptyDropView: some View {
        AppEmptyStateView(
            icon: "photo.stack",
            title: "No Images Loaded",
            subtitle: "Drop PNG, JPG, JPEG XL (.jxl), WebP, HEIC, AVIF, TIFF, GIF, RAW images, or a .lcimg project anywhere.",
            isDropTargeted: isDropTargeted,
            primaryButtonTitle: "Add Images...",
            primaryButtonIcon: "plus",
            onPrimaryAction: openImagePicker
        ) {
            Button {
                openImageProjectPicker()
            } label: {
                Label("Open Project (.lcimg)...", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("Open Image Project")
        }
    }

    // MARK: - Workspace Content

    @ViewBuilder
    private var workspaceContent: some View {
        let dimsMetadataText: String? = primaryDims.map { dims in
            let sizeStr = ByteCountFormatter.string(fromByteCount: dims.bytes, countStyle: .file)
            let rawProf = colorInfo?.profileName ?? "Unknown"
            let profStr: String
            if rawProf.hasPrefix("sRGB") {
                profStr = "sRGB"
            } else if rawProf.count > 16 {
                profStr = String(rawProf.prefix(15)) + "…"
            } else {
                profStr = rawProf
            }
            let bitStr = colorInfo.map { "\($0.bitDepth)bpc" } ?? ""
            return "\(dims.width)×\(dims.height) · \(bitStr) · \(profStr) · \(sizeStr)"
        }

        VStack(spacing: 0) {
            AppToolboxHeader(
                title: selectedSection.rawValue,
                subtitle: selectedSection.summary,
                metadataText: dimsMetadataText
            ) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    if let jxl = jxlInfo, jxl.isJPEGReconstructable {
                        AppStatusBadge(text: "JPEG Bitstream Embedded", tint: AppTheme.Colors.success)
                    }
                    Menu {
                        Button("Save Project (.lcimg)...") {
                            saveImageProject()
                        }
                        .disabled(primaryURL == nil)
                        Button("Open Project (.lcimg)...") {
                            openImageProjectPicker()
                        }
                    } label: {
                        Label("Project", systemImage: "doc.badge.gearshape")
                    }
                    .controlSize(.small)
                    .menuStyle(.borderedButton)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Image Project")
                    if sectionSupportsLivePreview(selectedSection) {
                        Button {
                            showLivePreview.toggle()
                            if showLivePreview && liveAfterImage == nil {
                                scheduleLivePreview(immediate: true)
                            }
                        } label: {
                            Label(showLivePreview ? "Hide Preview" : "Show Preview", systemImage: showLivePreview ? "eye.slash" : "eye")
                                .lineLimit(1)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            // Multi-file Queue Strip
            fileSelectionStrip

            // Active Section Area
            if selectedSection == .compare {
                ImageComparisonView(
                    sourceURL: primaryURL,
                    outputFormat: targetFormat,
                    config: config,
                    snapshot: comparisonSnapshot,
                    isLoading: isGeneratingPreview,
                    statusText: previewStatusText,
                    onRefresh: { triggerComparisonBuild() },
                    onCancel: {
                        previewTask?.cancel()
                        isGeneratingPreview = false
                    }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                        if showLivePreview && sectionSupportsLivePreview(selectedSection) {
                            ImageLivePreviewCanvas(
                                beforeImage: primaryPreviewImage,
                                afterImage: liveAfterImage ?? primaryPreviewImage,
                                beforeFormat: primaryFile?.detectedFormat?.shortExtensionLabel ?? "INPUT",
                                afterFormat: targetFormat.shortExtensionLabel,
                                telemetry: liveTelemetry,
                                isLoading: isUpdatingLivePreview,
                                statusText: "Rendering \(selectedSection.rawValue.lowercased()) preview...",
                                minCanvasHeight: 240,
                                showFullRenderButton: true,
                                fullRenderButtonTitle: "Refresh",
                                onRenderFull: { scheduleLivePreview(immediate: true) },
                                onCancel: {
                                    livePreviewTask?.cancel()
                                    isUpdatingLivePreview = false
                                }
                            )
                        }

                        if primaryFrameCount > 1 {
                            if let animWarning = ImageProcessingService.animationFlatteningWarning(
                                frameCount: primaryFrameCount,
                                inputFormat: primaryFile?.detectedFormat,
                                outputFormat: targetFormat,
                                config: config
                            ) {
                                AppInfoBanner(style: .warning, message: animWarning)
                            } else {
                                AppInfoBanner(
                                    style: .info,
                                    message: "Animated input detected (\(primaryFrameCount) frames). All frames and frame timings will be preserved in \(targetFormat.displayName) output."
                                )
                            }
                        }

                        sectionContent
                    }
                    .padding(AppTheme.Spacing.xl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let banner = bannerMessage {
                AppInfoBanner(
                    style: banner.isError ? .warning : .success,
                    message: banner.text,
                    actionTitle: banner.isError ? nil : "View Jobs",
                    onAction: banner.isError ? nil : { appState.selectedTab = .jobs },
                    onDismiss: { bannerMessage = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.sm)
            }

            // Bottom Sticky Export Bar
            bottomActionBar
        }
    }

    // MARK: - File Strip

    @ViewBuilder
    private var fileSelectionStrip: some View {
        let items = candidateFiles.map { file in
            AppFileSelectionStripItem(
                id: file.id,
                title: file.url.lastPathComponent,
                formatLabel: file.detectedFormat?.shortExtensionLabel ?? "",
                isSelected: selectedFileIds.contains(file.id)
            )
        }

        AppFileSelectionStrip(
            title: "Source Images (\(selectedFiles.count) of \(candidateFiles.count) selected)",
            items: items,
            onToggleItem: { id in
                if selectedFileIds.contains(id) && selectedFileIds.count > 1 {
                    selectedFileIds.remove(id)
                } else {
                    selectedFileIds.insert(id)
                }
            }
        ) {
            Button("Add Images...") { openImagePicker() }
                .controlSize(.small)
            Button("Select All") { selectedFileIds = Set(candidateFiles.map(\.id)) }
                .controlSize(.small)
            Button("Only First") {
                if let first = candidateFiles.first {
                    selectedFileIds = [first.id]
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Section Router

    private func sectionSupportsLivePreview(_ section: ImageToolboxSection) -> Bool {
        switch section {
        case .convert, .adjustments, .effects, .rawDevelop, .resize, .upscale, .targetSize, .compression, .watermark, .colorManagement, .backgroundRemoval:
            return true
        case .crop, .metadata, .compare:
            return false
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .effects:
            ImageEffectsChainView(
                store: appState.imageToolboxStore,
                url: primaryURL,
                selectedURLs: selectedFiles.map(\.url),
                targetFormat: targetFormat,
                config: configBinding
            )
        case .rawDevelop:
            ImageRAWDevelopView(
                store: appState.imageToolboxStore,
                url: primaryURL,
                inputFormat: primaryFile?.detectedFormat,
                usedRAWFallback: usedRAWFallback,
                config: configBinding
            )
        case .adjustments:
            ImageColorAdjustmentsView(
                store: appState.imageToolboxStore,
                url: primaryURL,
                config: configBinding,
                livePreviewImage: liveAfterImage,
                beforePreviewImage: primaryPreviewImage,
                colorInfo: colorInfo
            )
        case .convert:
            ImageConvertCodecSectionView(
                config: configBinding,
                targetFormat: targetFormatBinding,
                sourceURL: primaryURL,
                selectedURLs: selectedFiles.map(\.url),
                inputFormat: primaryFile?.detectedFormat,
                sourceDims: primaryDims,
                jxlInfo: jxlInfo,
                writableFormats: writableImageFormats
            )
        case .resize:
            ImageResizeSectionView(
                config: configBinding,
                outputFormat: targetFormat,
                sourceDims: primaryDims,
                detailedMeta: detailedMetadata,
                telemetry: liveTelemetry ?? benchmarkTelemetry,
                previewPresetID: $previewPresetID
            )
        case .upscale:
            ImageUpscaleSectionView(
                config: configBinding,
                sourceDims: primaryDims,
                telemetry: liveTelemetry ?? benchmarkTelemetry
            )
        case .crop:
            ImageCropRotateSectionView(
                config: configBinding,
                previewImage: primaryPreviewImage,
                sourceDims: primaryDims,
                outputFormat: targetFormat,
                store: appState.imageToolboxStore,
                sourceURL: primaryURL
            )
        case .targetSize:
            ImageTargetSizeSectionView(
                config: configBinding,
                outputFormat: targetFormat,
                sourceURL: primaryURL,
                sourceDims: primaryDims,
                benchmarkTelemetry: benchmarkTelemetry,
                isBenchmarking: isGeneratingPreview,
                onRunBenchmark: { runLiveBenchmark() }
            )
        case .compression:
            ImageCompressionSectionView(
                config: configBinding,
                outputFormat: targetFormat,
                sourceURL: primaryURL,
                benchmarkTelemetry: benchmarkTelemetry,
                isBenchmarking: isGeneratingPreview,
                onRunBenchmark: { runLiveBenchmark() }
            )
        case .metadata:
            ImageMetadataPrivacyView(
                config: configBinding,
                sourceURL: primaryURL,
                summary: metadataSummary,
                detailedMeta: detailedMetadata,
                onReload: { loadPrimaryDetails() },
                onSaveMetadataNow: { destinationURL in
                    Task { await saveMetadataInPlaceOrCopy(to: destinationURL) }
                }
            )
        case .watermark:
            ImageWatermarkSectionView(
                config: configBinding,
                sourceURL: primaryURL,
                outputFormat: targetFormat,
                isGeneratingPreview: isUpdatingLivePreview,
                onGeneratePreview: { scheduleLivePreview(immediate: true) }
            )
        case .compare:
            EmptyView()
        case .colorManagement:
            ImageColorManagementSectionView(
                config: configBinding,
                colorInfo: colorInfo,
                previewImage: primaryPreviewImage
            )
        case .backgroundRemoval:
            ImageBackgroundRemovalSectionView(
                config: configBinding,
                outputFormat: targetFormat,
                isGeneratingPreview: isUpdatingLivePreview,
                onGeneratePreview: { scheduleLivePreview(immediate: true) }
            )
        }
    }

    // MARK: - Bottom Sticky Bar

    @ViewBuilder
    private var bottomActionBar: some View {
        let selectedCount = selectedFiles.count
        let exportButtonLabel = config.exportMultipleSizes && !config.multiSizePresets.isEmpty
            ? "Export Multi-Size (\(selectedCount * config.multiSizePresets.count))"
            : (selectedCount > 1 ? "Process \(selectedCount) Images" : "Export Image")

        let formatAndOverwrite = HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs + 2) {
                Text("Output:")
                    .font(AppTheme.Typography.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Output Format", selection: targetFormatBinding) {
                    ForEach(writableImageFormats, id: \.self) { fmt in
                        Text(fmt == .jxl ? "JPEG XL (.jxl)" : fmt.shortExtensionLabel)
                            .tag(fmt)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            Toggle("Overwrite", isOn: $overwriteExisting)
                .toggleStyle(.checkbox)
                .font(AppTheme.Typography.caption)
                .fixedSize()
                .help("Allow overwriting existing destination file names when exporting")
        }

        let resetButton = Button("Reset Pipeline") {
            appState.imageToolboxStore.resetConfig(for: primaryURL)
            benchmarkTelemetry = nil
            comparisonSnapshot = nil
            liveAfterImage = nil
            liveTelemetry = nil
            previewPresetID = nil
            bannerMessage = nil
        }
        .controlSize(.small)
        .fixedSize()

        let savePresetButton = Button("Save Preset...") {
            presetNameInput = "Image Toolbox (\(targetFormat.shortExtensionLabel))"
            presetDescInput = ""
            showingSavePresetPopover = true
        }
        .fixedSize()
        .popover(isPresented: $showingSavePresetPopover) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save Image Toolbox Preset")
                    .font(.headline)
                TextField("Preset Name", text: $presetNameInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                TextField("Description (optional)", text: $presetDescInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { showingSavePresetPopover = false }
                    Button("Save") {
                        let trimmed = presetNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        appState.saveImageToolboxPreset(
                            name: trimmed,
                            description: presetDescInput.isEmpty ? nil : presetDescInput,
                            targetFormat: targetFormat,
                            config: config
                        )
                        showingSavePresetPopover = false
                        bannerMessage = ("Saved preset \"\(trimmed)\" to Presets.", false)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }

        let compareButton = Button("Compare Output") {
            selectedSection = .compare
            triggerComparisonBuild()
        }
        .fixedSize()
        .accessibilityLabel("Compare Output")

        let exportButton = Button {
            exportImages()
        } label: {
            Label(exportButtonLabel, systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .accessibilityLabel(exportButtonLabel)
        .accessibilityIdentifier("imagetoolbox.exportButton")
        .buttonStyle(.borderedProminent)
        .disabled(selectedFiles.isEmpty)

        AppBottomActionBar {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md) {
                    formatAndOverwrite
                    Spacer(minLength: AppTheme.Spacing.sm)
                    resetButton
                    savePresetButton
                    compareButton
                    exportButton
                }

                VStack(spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        formatAndOverwrite
                        Spacer(minLength: 0)
                        resetButton
                    }
                    HStack(spacing: AppTheme.Spacing.sm) {
                        savePresetButton
                        compareButton
                        Spacer(minLength: 0)
                        exportButton
                    }
                }
            }
        }
    }

    // MARK: - Actions & Background Tasks

    private func isSectionConfigured(_ section: ImageToolboxSection) -> Bool {
        switch section {
        case .convert: return targetFormat == .jxl && (config.jxlLossless || config.jxlTranscodeJPEG || config.jxlBitDepth == 16)
        case .adjustments: return config.colorAdjustments.hasActiveAdjustments
        case .effects: return config.effectStack.contains(where: \.isEnabled)
        case .rawDevelop: return config.rawDevelop.hasNonDefaultParameters
        case .resize: return config.resizeStrategy != .none || config.exportMultipleSizes || config.canvasExtension.enabled || config.borderFrame.enabled || config.dpiConfig.enabled
        case .upscale: return config.upscale.enabled
        case .crop: return config.cropTransform.isActive || config.perspective.enabled
        case .targetSize: return config.targetFileSizeEnabled
        case .compression: return config.compressionProfile != .balanced
        case .metadata: return config.metadataEdit.policy != .preserveAll || config.metadataEdit.stripGPS || config.metadataEdit.stripEXIF || config.metadataEdit.stripIPTC || config.metadataEdit.stripXMP || config.metadataEdit.stripSoftware
        case .watermark: return config.watermark.enabled
        case .compare: return comparisonSnapshot != nil
        case .colorManagement: return config.colorTarget != .preserve
        case .backgroundRemoval: return config.backgroundRemoval.enabled
        }
    }

    private func syncCandidateSelection() {
        let validIDs = Set(candidateFiles.map(\.id))
        selectedFileIds = selectedFileIds.intersection(validIDs)
        if selectedFileIds.isEmpty, let first = candidateFiles.first {
            selectedFileIds.insert(first.id)
        }
        loadPrimaryDetails()
    }

    private func loadPrimaryDetails() {
        loadDetailsTask?.cancel()
        guard let url = primaryURL else {
            colorInfo = nil
            metadataSummary = nil
            detailedMetadata = nil
            primaryDims = nil
            jxlInfo = nil
            primaryPreviewImage = nil
            usedRAWFallback = false
            return
        }

        comparisonSnapshot = nil
        benchmarkTelemetry = nil
        liveAfterImage = nil
        liveTelemetry = nil
        usedRAWFallback = false
        primaryFrameCount = 1

        let activeURL = url
        let rawCfg = config.rawDevelop
        loadDetailsTask = Task {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: activeURL.path)[.size] as? Int64) ?? 0
            let decoded = try? await ImageProcessingService.decodeInputImageWithRAW(
                url: activeURL,
                maxPixelDimension: 1400,
                rawConfig: rawCfg,
                useProxyCache: true
            )
            try? Task.checkCancellation()
            guard !Task.isCancelled else { return }
            let cInfo = ImageColorManagementService.inspectColorProfile(url: activeURL, cgImage: decoded?.cgImage)
            let mSummary = try? await ImageMetadataService.inspect(url: activeURL)
            let mDetailed = ImageMetadataInspectorService.inspectDetailed(url: activeURL)
            let detectedFmt = FileDetector.detectFormat(url: activeURL)
            let jxl = (detectedFmt == .jxl) ? (try? JPEGXLCodec.inspect(url: activeURL)) : nil
            let frameCount = ImageProcessingService.inspectAnimationFrameCount(url: activeURL, format: detectedFmt)

            let fullDims: (Int, Int) = {
                if let j = jxl { return (j.width, j.height) }
                if let rw = decoded?.rawNativeWidth, let rh = decoded?.rawNativeHeight, rw > 0, rh > 0 {
                    return (rw, rh)
                }
                if let dims = ImageProcessingService.inspectSourceDimensions(url: activeURL) {
                    return dims
                }
                if let img = decoded?.cgImage { return (img.width, img.height) }
                return (0, 0)
            }()

            let thumb: NSImage? = decoded.map {
                NSImage(cgImage: $0.cgImage, size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height))
            }

            await MainActor.run {
                guard self.primaryURL == activeURL else { return }
                self.colorInfo = cInfo
                self.metadataSummary = mSummary
                self.detailedMetadata = mDetailed
                self.jxlInfo = jxl
                self.primaryFrameCount = frameCount
                self.primaryDims = (fullDims.0, fullDims.1, fileSize)
                self.primaryPreviewImage = thumb
                self.usedRAWFallback = decoded?.usedRAWFallback ?? false

                // Pre-populate metadata editor payload silently if policy is still default
                if let doc = mSummary?.document, config.metadataEdit.policy == .preserveAll {
                    var payload = config.metadataEdit
                    payload.title = doc.common.title
                    payload.author = doc.common.author ?? doc.common.artist
                    payload.copyright = doc.common.copyright
                    payload.description = doc.common.description
                    payload.keywordsCSV = doc.common.keywords.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }
                    payload.cameraMake = doc.common.cameraMake
                    payload.cameraModel = doc.common.cameraModel
                    appState.imageToolboxStore.hydrateMetadataDefaults(for: activeURL, payload: payload)
                }

                if self.showLivePreview && self.sectionSupportsLivePreview(self.selectedSection) {
                    self.scheduleLivePreview(immediate: true)
                }
            }
        }
    }

    private func triggerComparisonBuild() {
        guard let url = primaryURL else { return }
        previewTask?.cancel()
        isGeneratingPreview = true
        previewStatusText = "Running real encoding pipeline for comparison..."
        let activeConfig = config
        let outFmt = targetFormat

        previewTask = Task {
            do {
                let snap = try await ImageComparisonService.buildComparison(
                    sourceURL: url,
                    outputFormat: outFmt,
                    config: activeConfig
                )
                try Task.checkCancellation()
                await MainActor.run {
                    self.comparisonSnapshot = snap
                    self.benchmarkTelemetry = snap.telemetry
                    self.isGeneratingPreview = false
                    self.previewStatusText = ""
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isGeneratingPreview = false
                }
            } catch {
                await MainActor.run {
                    self.isGeneratingPreview = false
                    self.bannerMessage = ("Comparison failed: \(error.localizedDescription)", true)
                }
            }
        }
    }

    private func runLiveBenchmark() {
        guard let url = primaryURL else { return }
        previewTask?.cancel()
        isGeneratingPreview = true
        let activeConfig = config
        let outFmt = targetFormat

        previewTask = Task {
            do {
                let out = try await ImageProcessingService.processInMemory(
                    url: url,
                    outputFormat: outFmt,
                    config: activeConfig
                )
                try Task.checkCancellation()
                await MainActor.run {
                    self.benchmarkTelemetry = out.telemetry
                    self.isGeneratingPreview = false
                }
            } catch is CancellationError {
                await MainActor.run { self.isGeneratingPreview = false }
            } catch {
                await MainActor.run {
                    self.isGeneratingPreview = false
                    self.bannerMessage = ("Size test failed: \(error.localizedDescription)", true)
                }
            }
        }
    }

    private func sectionRequiresCodecPreview(_ section: ImageToolboxSection) -> Bool {
        switch section {
        case .convert, .resize, .upscale, .targetSize, .compression, .compare:
            return true
        case .adjustments, .effects, .rawDevelop, .crop, .metadata, .watermark, .colorManagement, .backgroundRemoval:
            return false
        }
    }

    private func scheduleLivePreview(immediate: Bool) {
        guard showLivePreview, sectionSupportsLivePreview(selectedSection), let url = primaryURL else { return }
        livePreviewTask?.cancel()
        isUpdatingLivePreview = true

        var effectiveConfig = config
        if selectedSection == .resize,
           effectiveConfig.exportMultipleSizes,
           let pid = previewPresetID,
           let preset = effectiveConfig.multiSizePresets.first(where: { $0.id == pid }) {
            effectiveConfig.exportMultipleSizes = false
            effectiveConfig.resizeStrategy = .fitInside
            effectiveConfig.resizeWidth = preset.width
            effectiveConfig.resizeHeight = preset.height
            effectiveConfig.preserveAspectRatio = true
        }
        let outFmt = targetFormat
        let encodeCodec = sectionRequiresCodecPreview(selectedSection)

        livePreviewTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: encodeCodec ? 180_000_000 : 80_000_000)
            }
            guard !Task.isCancelled else { return }

            do {
                let out = try await ImageProcessingService.processInMemory(
                    url: url,
                    outputFormat: outFmt,
                    config: effectiveConfig,
                    previewMaxDimension: 1200,
                    encodeOutput: encodeCodec
                )
                try Task.checkCancellation()
                let img = NSImage(
                    cgImage: out.previewCGImage,
                    size: NSSize(width: out.previewCGImage.width, height: out.previewCGImage.height)
                )
                await MainActor.run {
                    guard self.primaryURL == url else { return }
                    self.liveAfterImage = img
                    self.liveTelemetry = out.telemetry
                    self.usedRAWFallback = out.usedRAWFallback
                    self.isUpdatingLivePreview = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isUpdatingLivePreview = false
                }
            } catch {
                await MainActor.run {
                    self.isUpdatingLivePreview = false
                }
            }
        }
    }

    private func saveMetadataInPlaceOrCopy(to targetURL: URL?) async {
        guard let sourceURL = primaryURL else { return }
        let finalURL = targetURL ?? sourceURL
        let protectedSources = (finalURL.standardizedFileURL == sourceURL.standardizedFileURL) ? [] : [sourceURL]

        do {
            var previousArtifactID: UUID? = nil
            if FileManager.default.fileExists(atPath: finalURL.path) {
                let staged = try await RecoveryArtifactManager.shared.stageFileByCopying(from: finalURL)
                previousArtifactID = staged.id
            }
            let res = try await ImageMetadataInspectorService.writeMetadataAndDPINonDestructively(
                from: sourceURL,
                to: finalURL,
                payload: config.metadataEdit,
                dpi: config.dpiConfig.enabled && !config.dpiConfig.resamplePixels ? config.dpiConfig : nil
            )
            await ImagePreviewProxyCache.shared.invalidate(url: finalURL)
            let cmd = ImageFileWriteUndoCommand(
                title: "Save Metadata (\(finalURL.lastPathComponent))",
                destinationURL: finalURL,
                protectedSourceURLs: protectedSources,
                previousArtifactID: previousArtifactID
            )
            appState.imageToolboxStore.recordFileWriteCommand(cmd)
            await MainActor.run {
                bannerMessage = ("\(finalURL.lastPathComponent): \(res.formatNote)", false)
                loadPrimaryDetails()
            }
        } catch {
            await MainActor.run {
                bannerMessage = ("Metadata write failed: \(error.localizedDescription)", true)
            }
        }
    }

    private func exportImages() {
        let urls = selectedFiles.map(\.url)
        guard !urls.isEmpty else { return }
        let enqueued = appState.executeImageToolbox(
            inputs: urls,
            outputFormat: targetFormat,
            config: config,
            overwriteExisting: overwriteExisting
        )
        if enqueued {
            bannerMessage = ("Enqueued \(urls.count) image job(s) -> \(targetFormat.shortExtensionLabel).", false)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    if let url = item as? URL {
                        urls.append(url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }
            if !urls.isEmpty {
                await MainActor.run {
                    let projectURLs = urls.filter { $0.pathExtension.lowercased() == ImagePresetCatalog.projectFileExtension }
                    let mediaURLs = urls.filter { $0.pathExtension.lowercased() != ImagePresetCatalog.projectFileExtension }
                    if !mediaURLs.isEmpty {
                        appState.addFiles(urls: mediaURLs)
                    }
                    if let proj = projectURLs.first {
                        loadProjectFile(from: proj)
                    }
                }
            }
        }
        return true
    }

    private func openImagePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.addFiles(urls: panel.urls)
        }
    }

    // MARK: - .lcimg Non-Destructive Project Save / Open / Relink

    private func saveImageProject() {
        guard let sourceURL = primaryURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ImagePresetCatalog.projectFileExtension) ?? .json]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + ".\(ImagePresetCatalog.projectFileExtension)"
        panel.title = "Save Non-Destructive Image Project"
        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        do {
            let doc = ImageProjectDocument.create(
                sourceURL: sourceURL,
                targetFormat: targetFormat,
                config: config
            )
            try ImagePresetCatalog.saveProject(
                doc,
                to: destURL,
                protectedSourceURLs: candidateFiles.map(\.url)
            )
            bannerMessage = ("Saved project to \(destURL.lastPathComponent).", false)
        } catch {
            bannerMessage = ("Project save failed: \(error.localizedDescription)", true)
        }
    }

    private func openImageProjectPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let lcimgType = UTType(filenameExtension: ImagePresetCatalog.projectFileExtension) {
            panel.allowedContentTypes = [lcimgType, .json]
        }
        panel.title = "Open Non-Destructive Image Project (.lcimg)"
        guard panel.runModal() == .OK, let projURL = panel.url else { return }
        loadProjectFile(from: projURL)
    }

    private func loadProjectFile(from url: URL) {
        do {
            let loaded = try ImagePresetCatalog.loadProject(from: url)
            if loaded.isSourceMissing || loaded.resolvedSourceURL == nil {
                pendingMissingProject = loaded.document
                showingMissingSourceAlert = true
            } else if let resolved = loaded.resolvedSourceURL {
                applyLoadedProject(loaded.document, sourceURL: resolved)
            }
        } catch {
            bannerMessage = ("Could not open project: \(error.localizedDescription)", true)
        }
    }

    private func relinkMissingProjectSource(_ doc: ImageProjectDocument) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .rawImage]
        panel.title = "Relink Source Image for Project"
        guard panel.runModal() == .OK, let relinkedURL = panel.url else {
            pendingMissingProject = nil
            return
        }
        pendingMissingProject = nil
        applyLoadedProject(doc, sourceURL: relinkedURL)
    }

    private func applyLoadedProject(_ doc: ImageProjectDocument, sourceURL: URL) {
        appState.addFiles(urls: [sourceURL])
        let standardized = sourceURL.standardizedFileURL
        if let matched = candidateFiles.first(where: { $0.url.standardizedFileURL == standardized }) {
            selectedFileIds = [matched.id]
        }
        if writableImageFormats.contains(doc.targetFormat) {
            appState.imageToolboxStore.setTargetFormat(doc.targetFormat, for: sourceURL, recordUndo: false)
        }
        appState.imageToolboxStore.applyLoadedConfig(
            doc.config,
            for: sourceURL,
            title: "Open Image Project (\(sourceURL.lastPathComponent))"
        )
        loadPrimaryDetails()
        scheduleLivePreview(immediate: true)
        bannerMessage = ("Opened project for \(sourceURL.lastPathComponent).", false)
    }
}

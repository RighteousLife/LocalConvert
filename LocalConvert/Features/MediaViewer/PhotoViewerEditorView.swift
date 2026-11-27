import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import Vision

// MARK: - Photo Viewer & Quick Editor View (Milestone 11A)

@MainActor
struct PhotoViewerEditorView: View {

    enum InspectorPanel: String, CaseIterable, Identifiable {
        case adjust = "Adjust"
        case markup = "Markup"
        case backdrop = "Backdrop"
        case colors = "Colors"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .adjust: return "slider.horizontal.3"
            case .markup: return "pencil.tip.crop.circle"
            case .backdrop: return "macwindow"
            case .colors: return "paintpalette"
            }
        }
    }

    private enum CropHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private let initialURL: URL
    private let onSendToConvertQueue: ((URL) -> Void)?
    private let onDismiss: (() -> Void)?

    @StateObject private var model: QuickPhotoEditorModel
    @StateObject private var eyedropper: PhotoEyedropperCoordinator

    @State private var activeInspector: InspectorPanel? = nil
    @State private var showFilmstrip: Bool = false
    @State private var showEXIFHUD: Bool = false

    @State private var zoomScale: CGFloat = 1.0
    @State private var gestureMagnification: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragStartPan: CGSize? = nil
    @State private var viewportSize: CGSize = CGSize(width: 600, height: 420)
    @State private var isHoldingBefore: Bool = false

    // Interactive drawing & crop state
    @State private var activeDragAnnotation: QuickPhotoAnnotation? = nil
    @State private var draftCropRect: NormalizedRect = NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var cropHandleStartRect: NormalizedRect? = nil
    @State private var cropMoveStartRect: NormalizedRect? = nil

    // Inline text annotation entry
    @State private var pendingTextPoint: CodableNormalizedPoint? = nil
    @State private var pendingTextValue: String = ""
    @FocusState private var isTextInputFocused: Bool

    // Dialogs & async busy flags
    @State private var showOverwriteConfirmation: Bool = false
    @State private var showTrashConfirmation: Bool = false
    @State private var isRunningOCR: Bool = false
    @State private var isSavingOutput: Bool = false
    @State private var localBannerError: String? = nil
    @State private var localStatusToast: String? = nil

    // Milestone 13 photo inspection tools
    @State private var detectedBarcodes: [DetectedPhotoBarcode] = []
    @State private var dominantSwatches: [DominantColorSwatch] = []
    @State private var isExtractingPalette: Bool = false

    // Bounded filmstrip thumbnail cache
    @State private var thumbnailCache: [URL: NSImage] = [:]
    @State private var thumbnailOrder: [URL] = []
    private let maxCachedThumbnails = 64

    init(
        url: URL,
        onSendToConvertQueue: ((URL) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        colorSampler: (any ScreenColorSampling)? = nil
    ) {
        self.initialURL = url
        self.onSendToConvertQueue = onSendToConvertQueue
        self.onDismiss = onDismiss
        self._model = StateObject(wrappedValue: QuickPhotoEditorModel(url: url))
        self._eyedropper = StateObject(
            wrappedValue: PhotoEyedropperCoordinator(
                sampler: colorSampler ?? SystemScreenColorSampler()
            )
        )
    }

    private var displayedImage: NSImage? {
        isHoldingBefore ? model.originalPreviewImage : model.previewImage
    }

    private var isEditingText: Bool {
        pendingTextPoint != nil || isTextInputFocused
    }

    private var analysisTaskKey: String {
        if let cg = model.sourceCGImage {
            return "\(model.currentURL.standardizedFileURL.path)|\(cg.width)x\(cg.height)|\(ObjectIdentifier(cg).debugDescription)"
        }
        return "\(model.currentURL.standardizedFileURL.path)|none"
    }

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            AppDivider()

            HStack(spacing: 0) {
                canvasViewport
                    .frame(minWidth: 340, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)

                if let panel = activeInspector {
                    AppDivider()
                        .frame(width: 1)
                    inspectorDrawer(panel)
                        .frame(width: 254)
                        .background(AppTheme.Colors.secondarySidebarBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showFilmstrip && !model.siblings.isEmpty {
                AppDivider()
                filmstripBar
            }

            bottomActionBar
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(AppTheme.Colors.workspaceBackground)
        .accessibilityIdentifier("photoviewer.root")
        .task(id: initialURL) {
            await model.load(url: initialURL)
        }
        .task(id: analysisTaskKey) {
            await analyzeLoadedPhoto()
        }
        .onChange(of: model.currentURL) { _, _ in
            isHoldingBefore = false
            resetViewportTransform()
            pendingTextPoint = nil
            activeDragAnnotation = nil
            detectedBarcodes = []
            dominantSwatches = []
            localStatusToast = nil
        }
        .onChange(of: showOverwriteConfirmation) { _, isPresented in
            if isPresented { isHoldingBefore = false }
        }
        .onChange(of: showTrashConfirmation) { _, isPresented in
            if isPresented { isHoldingBefore = false }
        }
        .onChange(of: pendingTextPoint) { _, point in
            if point != nil { isHoldingBefore = false }
        }
        .onDisappear {
            isHoldingBefore = false
        }
        .confirmationDialog(
            "Overwrite Original Photo?",
            isPresented: $showOverwriteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Overwrite Original", role: .destructive) {
                performOverwriteOriginal()
            }
            Button("Save Copy Instead") {
                presentSaveCopyPanel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces \"\(model.currentURL.lastPathComponent)\" atomically on disk with your current edits.")
        }
        .confirmationDialog(
            "Move Photo to Trash?",
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                performTrashCurrentFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(model.currentURL.lastPathComponent)\" will be moved to the macOS Trash.")
        }
        .background(shortcutOverlay)
        .background(
            PhotoViewerHoldCompareKeyMonitorHost(
                isHoldingBefore: { isHoldingBefore },
                canActivate: { hostWindow in
                    PhotoViewerHoldComparePolicy.canActivateHoldCompare(
                        isSameWindow: true,
                        isKeyWindow: hostWindow.isKeyWindow,
                        hasImage: model.sourceCGImage != nil || model.originalPreviewImage != nil,
                        isEditingText: isEditingText,
                        hasActiveDragAnnotation: activeDragAnnotation != nil,
                        isConfirmationPresented: showOverwriteConfirmation || showTrashConfirmation,
                        isCommandPalettePresented: CommandPaletteController.shared.isPresented,
                        isFirstResponderTextInput: PhotoViewerHoldComparePolicy.isTextInputResponder(hostWindow.firstResponder)
                    )
                },
                onHoldChanged: { holding in
                    if isHoldingBefore != holding {
                        isHoldingBefore = holding
                    }
                }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
            HStack(spacing: AppTheme.Spacing.sm) {
                siblingNavigationGroup
                Spacer(minLength: 0)
                historyAndUtilityGroup
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                zoomToolbarGroup
                Spacer(minLength: 0)
                inspectorToggleGroup
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var siblingNavigationGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            HStack(spacing: 2) {
                Button {
                    Task { await model.goToPreviousSibling() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canGoPrevious || model.isLoading)
                .help("Previous Photo (←)")
                .accessibilityLabel("Previous Photo")
                .accessibilityIdentifier("photoviewer.prevButton")

                Button {
                    Task { await model.goToNextSibling() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canGoNext || model.isLoading)
                .help("Next Photo (→)")
                .accessibilityLabel("Next Photo")
                .accessibilityIdentifier("photoviewer.nextButton")
            }

            Text(model.currentURL.lastPathComponent)
                .font(AppTheme.Typography.cardTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 165, alignment: .leading)

            if !model.siblings.isEmpty {
                AppHeaderPill(text: "\(model.currentSiblingIndex + 1)/\(model.siblings.count)")
            }
        }
    }

    private var zoomToolbarGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button("Fit") {
                resetViewportTransform()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Fit image to window")
            .accessibilityIdentifier("photoviewer.zoomFitButton")

            Button("100%") {
                toggleActualPixelZoom()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Toggle 100% actual pixels (0)")
            .accessibilityIdentifier("photoviewer.zoom100Button")

            Button {
                setZoom(max(0.25, zoomScale / 1.25))
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Zoom Out")
            .accessibilityIdentifier("photoviewer.zoomOutButton")

            Button {
                setZoom(min(8.0, zoomScale * 1.25))
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Zoom In")
            .accessibilityIdentifier("photoviewer.zoomInButton")

            Text("\(Int((zoomScale * gestureMagnification * 100).rounded()))%")
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
    }

    private var historyAndUtilityGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            HStack(spacing: 2) {
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
                .accessibilityLabel("Undo")
                .accessibilityIdentifier("photoviewer.undoButton")

                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
                .accessibilityLabel("Redo")
                .accessibilityIdentifier("photoviewer.redoButton")
            }

            Button {
                runOCRCopy()
            } label: {
                if isRunningOCR {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "text.viewfinder")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.sourceCGImage == nil || isRunningOCR)
            .help("Extract & Copy Text (Vision OCR)")
            .accessibilityLabel("Extract Text with OCR")
            .accessibilityIdentifier("photoviewer.ocrButton")

            Button {
                Task { _ = await model.copyRenderedImageToPasteboard() }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.sourceCGImage == nil)
            .help("Copy Image (⌘C)")
            .accessibilityLabel("Copy Image")
            .accessibilityIdentifier("photoviewer.copyButton")

            Button {
                pinCurrentImageToScreen()
            } label: {
                Image(systemName: "pin")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.sourceCGImage == nil)
            .help("Pin Image to Screen")
            .accessibilityLabel("Pin to Screen")
            .accessibilityIdentifier("photoviewer.pinButton")

            Button {
                pickColorWithEyedropper()
            } label: {
                if eyedropper.isSampling {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "eyedropper")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(eyedropper.isSampling)
            .help("Pick Color from Screen")
            .accessibilityLabel("Color Eyedropper")
            .accessibilityIdentifier("photoviewer.eyedropperButton")

            Toggle(isOn: $showEXIFHUD) {
                Image(systemName: "info.circle")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(showEXIFHUD ? AppTheme.Colors.accent : nil)
            .help("Toggle EXIF & Dimensions HUD")
            .accessibilityLabel("Toggle EXIF HUD")
            .accessibilityIdentifier("photoviewer.exifToggle")

            Toggle(isOn: $showFilmstrip) {
                Image(systemName: "rectangle.grid.1x2")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(showFilmstrip ? AppTheme.Colors.accent : nil)
            .help("Toggle Folder Filmstrip")
            .accessibilityLabel("Toggle Filmstrip")
            .accessibilityIdentifier("photoviewer.filmstripToggle")
        }
    }

    private var inspectorToggleGroup: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(InspectorPanel.allCases) { panel in
                    inspectorToggleButton(panel, compact: false)
                }
            }

            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(InspectorPanel.allCases) { panel in
                    inspectorToggleButton(panel, compact: true)
                }
            }
        }
    }

    @ViewBuilder
    private func inspectorToggleButton(_ panel: InspectorPanel, compact: Bool) -> some View {
        let isSelected = (activeInspector == panel)
        let title = String(localized: String.LocalizationValue(panel.rawValue))
        if isSelected {
            Button {
                toggleInspector(panel)
            } label: {
                if compact {
                    Image(systemName: panel.systemImage)
                } else {
                    Label(title, systemImage: panel.systemImage)
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: true, vertical: false)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityIdentifier(inspectorIdentifier(for: panel))
        } else {
            Button {
                toggleInspector(panel)
            } label: {
                if compact {
                    Image(systemName: panel.systemImage)
                } else {
                    Label(title, systemImage: panel.systemImage)
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityIdentifier(inspectorIdentifier(for: panel))
        }
    }

    private func inspectorIdentifier(for panel: InspectorPanel) -> String {
        switch panel {
        case .adjust: return "photoviewer.adjustToggle"
        case .markup: return "photoviewer.markupToggle"
        case .backdrop: return "photoviewer.backdropToggle"
        case .colors: return "photoviewer.colorsToggle"
        }
    }

    // MARK: - Interactive Image Canvas

    private var canvasViewport: some View {
        GeometryReader { geo in
            ZStack {
                AppTheme.Colors.elevatedSurface

                if model.isLoading {
                    AppLoadingStateView(message: String(localized: "Loading photo..."))
                } else if let error = model.errorMessage ?? localBannerError, displayedImage == nil {
                    AppEmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: String(localized: "Unable to Display Photo"),
                        subtitle: error
                    )
                } else if let nsImage = displayedImage {
                    let frame = fittedImageRect(imageSize: nsImage.size, in: geo.size)

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)

                        if let draft = activeDragAnnotation {
                            annotationPreviewOverlay(draft, in: frame)
                        }

                        if model.activeTool == .crop && !isHoldingBefore {
                            cropOverlay(in: frame)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(canvasMagnifyGesture)
                    .gesture(canvasDragGesture(imageFrame: frame))
                } else {
                    AppEmptyStateView(
                        icon: "photo",
                        title: String(localized: "No Photo Loaded"),
                        subtitle: String(localized: "Select a supported image file to view or edit.")
                    )
                }

                // Floating EXIF / File HUD
                if showEXIFHUD, let summary = model.exifSummary {
                    VStack {
                        HStack {
                            exifHUDView(summary)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(AppTheme.Spacing.md)
                    .allowsHitTesting(false)
                }

                // Top-right Hold-Before & Rendering Indicator
                VStack {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Spacer()
                        if model.isRendering {
                            ProgressView()
                                .controlSize(.small)
                                .padding(6)
                                .background(AppTheme.Colors.cardBackground.opacity(0.92), in: Circle())
                                .overlay(
                                    Circle()
                                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                                )
                        }
                        if model.sourceCGImage != nil || model.originalPreviewImage != nil {
                            Label(
                                isHoldingBefore
                                    ? String(localized: "Original (\\)")
                                    : (model.hasUnsavedChanges ? String(localized: "Hold Before") : String(localized: "Original")),
                                systemImage: isHoldingBefore ? "eye.fill" : "eye"
                            )
                            .font(AppTheme.Typography.caption.weight(.medium))
                            .padding(.horizontal, AppTheme.Spacing.sm + 2)
                            .padding(.vertical, 5)
                            .background(
                                isHoldingBefore
                                    ? AppTheme.Colors.accent.opacity(0.95)
                                    : AppTheme.Colors.cardBackground.opacity(0.95)
                            )
                            .foregroundStyle(
                                isHoldingBefore
                                    ? Color.white
                                    : (model.hasUnsavedChanges ? Color.primary : Color.secondary)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        isHoldingBefore ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder,
                                        lineWidth: 1
                                    )
                            )
                            .opacity(model.hasUnsavedChanges || isHoldingBefore ? 1.0 : 0.85)
                            .shadow(color: Color.black.opacity(0.16), radius: 6, y: 2)
                            .contentShape(Capsule())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in if !isHoldingBefore { isHoldingBefore = true } }
                                    .onEnded { _ in isHoldingBefore = false }
                            )
                            .help("Press and hold or hold \\ key to inspect original")
                            .accessibilityLabel("Hold to Compare Original")
                            .accessibilityIdentifier("photoviewer.holdCompareButton")
                        }
                    }
                    Spacer()
                }
                .padding(AppTheme.Spacing.md)

                // Auto-detected QR / Barcode chip (bottom-left)
                if !detectedBarcodes.isEmpty && pendingTextPoint == nil,
                   let firstBarcode = detectedBarcodes.first {
                    VStack {
                        Spacer()
                        HStack {
                            detectedBarcodeChip(firstBarcode, extraCount: detectedBarcodes.count - 1)
                            Spacer()
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }

                // Inline Text Annotation Popover Bar
                if pendingTextPoint != nil {
                    VStack {
                        Spacer()
                        inlineTextEntryBar
                    }
                    .padding(AppTheme.Spacing.md)
                }
            }
            .clipped()
            .onAppear {
                viewportSize = geo.size
            }
            .onChange(of: geo.size) { _, newSize in
                viewportSize = newSize
            }
            .onTapGesture(count: 2) {
                if model.activeTool == .none {
                    toggleActualPixelZoom()
                }
            }
            .accessibilityIdentifier("photoviewer.canvas")
        }
    }

    private func exifHUDView(_ summary: QuickPhotoEXIFSummary) -> some View {
        let predicted = model.predictedOutputDimensions
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppTheme.Spacing.xs) {
                AppStatusBadge(text: summary.formatName, tint: AppTheme.Colors.accent, style: .rounded)
                Spacer(minLength: AppTheme.Spacing.xs)
                Text(summary.fileSizeText)
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
            AppDivider()
                .padding(.vertical, 2)
            Text("Source: \(summary.dimensionsText)")
                .font(AppTheme.Typography.monoCaption)
            if predicted.width > 0 && (predicted.width != summary.pixelWidth || predicted.height != summary.pixelHeight) {
                Text("Output: \(predicted.width) × \(predicted.height) px")
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            if let dpi = summary.dpiText {
                Text("Resolution: \(dpi)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if let cam = summary.cameraSummary {
                Text(cam)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let date = summary.dateTaken {
                Text("Captured: \(date)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            if let gps = summary.gpsSummary {
                Text("GPS: \(gps)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.sm + 4)
        .background(AppTheme.Colors.cardBackground.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)
        .frame(maxWidth: 260, alignment: .leading)
        .accessibilityIdentifier("photoviewer.exifHUD")
    }

    private func detectedBarcodeChip(_ barcode: DetectedPhotoBarcode, extraCount: Int) -> some View {
        HStack(spacing: AppTheme.Spacing.xs + 2) {
            Image(systemName: "qrcode.viewfinder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.accent)

            Text(barcode.payload)
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)

            if extraCount > 0 {
                AppStatusBadge(text: "+\(extraCount)", tint: AppTheme.Colors.accent)
            }

            Button("Copy QR Payload") {
                copyTextToPasteboard(
                    barcode.payload,
                    feedback: String(localized: "Copied QR payload to clipboard.")
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("photoviewer.copyQRPayloadButton")
        }
        .padding(.horizontal, AppTheme.Spacing.sm + 2)
        .padding(.vertical, AppTheme.Spacing.xs + 2)
        .background(AppTheme.Colors.cardBackground.opacity(0.95))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        .accessibilityIdentifier("photoviewer.detectedBarcodeChip")
    }

    private var inlineTextEntryBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "textformat")
                .foregroundStyle(AppTheme.Colors.accent)
            TextField("Type annotation text...", text: $pendingTextValue)
                .textFieldStyle(.roundedBorder)
                .focused($isTextInputFocused)
                .onSubmit {
                    commitPendingTextAnnotation()
                }
                .frame(minWidth: 180, maxWidth: 280)

            Button("Add") {
                commitPendingTextAnnotation()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(pendingTextValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Cancel") {
                pendingTextPoint = nil
                pendingTextValue = ""
                isTextInputFocused = false
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
    }

    // MARK: - Canvas Geometry & Gestures

    private func fittedImageRect(imageSize: NSSize, in viewportSize: CGSize) -> CGRect {
        let safeW = max(1, imageSize.width)
        let safeH = max(1, imageSize.height)
        let availW = max(1, viewportSize.width - 16)
        let availH = max(1, viewportSize.height - 16)
        let fitScale = min(availW / safeW, availH / safeH)
        let effectiveScale = fitScale * zoomScale * gestureMagnification
        let drawW = safeW * effectiveScale
        let drawH = safeH * effectiveScale
        let cx = viewportSize.width / 2.0 + panOffset.width
        let cy = viewportSize.height / 2.0 + panOffset.height
        return CGRect(x: cx - drawW / 2.0, y: cy - drawH / 2.0, width: drawW, height: drawH)
    }

    private func normalizedPoint(for location: CGPoint, in imageFrame: CGRect) -> CodableNormalizedPoint {
        let nx = Double((location.x - imageFrame.minX) / max(1, imageFrame.width))
        let ny = Double((location.y - imageFrame.minY) / max(1, imageFrame.height))
        return CodableNormalizedPoint(x: nx, y: ny)
    }

    private var canvasMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                gestureMagnification = max(0.25 / zoomScale, min(8.0 / zoomScale, value.magnification))
            }
            .onEnded { value in
                setZoom(max(0.25, min(8.0, zoomScale * value.magnification)))
                gestureMagnification = 1.0
            }
    }

    private func canvasDragGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch model.activeTool {
                case .none:
                    guard zoomScale > 1.01 else { return }
                    let base = dragStartPan ?? panOffset
                    if dragStartPan == nil { dragStartPan = panOffset }
                    panOffset = CGSize(
                        width: base.width + value.translation.width,
                        height: base.height + value.translation.height
                    )

                case .crop:
                    break // Handled by cropOverlay handles

                case .annotation:
                    let kind = model.activeAnnotationKind
                    let startNorm = normalizedPoint(for: value.startLocation, in: imageFrame)
                    let curNorm = normalizedPoint(for: value.location, in: imageFrame)

                    if kind == .text || kind == .stepBadge {
                        return
                    }

                    if kind.isFreehandStroke {
                        if activeDragAnnotation == nil {
                            activeDragAnnotation = QuickPhotoAnnotation(
                                kind: kind,
                                startPoint: startNorm,
                                endPoint: curNorm,
                                points: [startNorm],
                                color: model.selectedColor,
                                strokeWidth: model.strokeWidth
                            )
                        } else {
                            activeDragAnnotation?.endPoint = curNorm
                            activeDragAnnotation?.points.append(curNorm)
                        }
                    } else {
                        activeDragAnnotation = QuickPhotoAnnotation(
                            kind: kind,
                            startPoint: startNorm,
                            endPoint: curNorm,
                            color: model.selectedColor,
                            strokeWidth: model.strokeWidth
                        )
                    }
                }
            }
            .onEnded { value in
                dragStartPan = nil
                guard model.activeTool == .annotation else { return }
                let kind = model.activeAnnotationKind
                let locNorm = normalizedPoint(for: value.location, in: imageFrame)

                if kind == .stepBadge {
                    let badge = QuickPhotoAnnotation(
                        kind: .stepBadge,
                        startPoint: locNorm,
                        color: model.selectedColor,
                        strokeWidth: model.strokeWidth,
                        stepNumber: model.nextStepNumber
                    )
                    model.addAnnotation(badge)
                    activeDragAnnotation = nil
                    return
                }

                if kind == .text {
                    pendingTextPoint = locNorm
                    pendingTextValue = ""
                    isTextInputFocused = true
                    activeDragAnnotation = nil
                    return
                }

                if var finished = activeDragAnnotation {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    if kind == .spotHeal {
                        if finished.points.isEmpty {
                            finished.points = [locNorm]
                        }
                        model.addAnnotation(finished)
                    } else if dx > 3 || dy > 3 || finished.points.count > 2 {
                        model.addAnnotation(finished)
                    }
                    activeDragAnnotation = nil
                }
            }
    }

    // MARK: - Live Draft Annotation & Crop Overlays

    @ViewBuilder
    private func annotationPreviewOverlay(_ ann: QuickPhotoAnnotation, in frame: CGRect) -> some View {
        let color = Color(red: ann.color.red, green: ann.color.green, blue: ann.color.blue, opacity: ann.color.alpha)
        Canvas { ctx, _ in
            switch ann.kind {
            case .rectangle, .redactMosaic, .redactBlur, .redactSolid:
                let b = ann.normalizedBounds
                let rect = CGRect(
                    x: frame.minX + b.minX * frame.width,
                    y: frame.minY + b.minY * frame.height,
                    width: b.width * frame.width,
                    height: b.height * frame.height
                )
                if ann.kind == .rectangle {
                    ctx.stroke(Path(rect), with: .color(color), lineWidth: CGFloat(ann.strokeWidth))
                } else {
                    ctx.fill(Path(rect), with: .color(Color.black.opacity(0.35)))
                    ctx.stroke(
                        Path(rect),
                        with: .color(Color.white.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                    )
                }

            case .ellipse:
                let b = ann.normalizedBounds
                let rect = CGRect(
                    x: frame.minX + b.minX * frame.width,
                    y: frame.minY + b.minY * frame.height,
                    width: b.width * frame.width,
                    height: b.height * frame.height
                )
                ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: CGFloat(ann.strokeWidth))

            case .arrow:
                let p1 = CGPoint(x: frame.minX + CGFloat(ann.startPoint.x) * frame.width, y: frame.minY + CGFloat(ann.startPoint.y) * frame.height)
                let p2 = CGPoint(x: frame.minX + CGFloat(ann.endPoint.x) * frame.width, y: frame.minY + CGFloat(ann.endPoint.y) * frame.height)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: CGFloat(ann.strokeWidth), lineCap: .round))

            case .pen, .highlighter, .spotHeal:
                let pts = ann.points.map {
                    CGPoint(x: frame.minX + CGFloat($0.x) * frame.width, y: frame.minY + CGFloat($0.y) * frame.height)
                }
                guard !pts.isEmpty else { return }
                var path = Path()
                path.move(to: pts[0])
                for pt in pts.dropFirst() { path.addLine(to: pt) }
                let strokeColor: Color = {
                    switch ann.kind {
                    case .highlighter: return color.opacity(0.42)
                    case .spotHeal: return Color.white.opacity(0.75)
                    default: return color
                    }
                }()
                let lw: CGFloat = ann.kind == .highlighter ? CGFloat(ann.strokeWidth) * 3.0 : CGFloat(ann.strokeWidth)
                ctx.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            case .text, .stepBadge:
                break
            }
        }
        .allowsHitTesting(false)
    }

    private func cropOverlay(in frame: CGRect) -> some View {
        let rect = CGRect(
            x: frame.minX + CGFloat(draftCropRect.x) * frame.width,
            y: frame.minY + CGFloat(draftCropRect.y) * frame.height,
            width: CGFloat(draftCropRect.width) * frame.width,
            height: CGFloat(draftCropRect.height) * frame.height
        )
        return ZStack {
            // Dim outside region
            Path { path in
                path.addRect(frame)
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Crop box move area
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if cropMoveStartRect == nil { cropMoveStartRect = draftCropRect }
                            guard let base = cropMoveStartRect else { return }
                            let dx = Double(value.translation.width / max(1, frame.width))
                            let dy = Double(value.translation.height / max(1, frame.height))
                            let nx = max(0.0, min(1.0 - base.width, base.x + dx))
                            let ny = max(0.0, min(1.0 - base.height, base.y + dy))
                            draftCropRect = NormalizedRect(x: nx, y: ny, width: base.width, height: base.height)
                        }
                        .onEnded { _ in
                            cropMoveStartRect = nil
                        }
                )

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Subtle rule-of-thirds guides
            Path { path in
                for step in [1.0 / 3.0, 2.0 / 3.0] {
                    let x = rect.minX + rect.width * step
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    let y = rect.minY + rect.height * step
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.32), lineWidth: 0.75)
            .allowsHitTesting(false)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                let pt = cropHandlePosition(handle, rect: rect)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(AppTheme.Colors.accent, lineWidth: 2))
                    .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1)
                    .position(pt)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if cropHandleStartRect == nil { cropHandleStartRect = draftCropRect }
                                guard let base = cropHandleStartRect else { return }
                                draftCropRect = resizedCropRect(
                                    base: base,
                                    handle: handle,
                                    translation: value.translation,
                                    frameSize: frame.size
                                )
                            }
                            .onEnded { _ in
                                cropHandleStartRect = nil
                            }
                    )
            }
        }
    }

    private func cropHandlePosition(_ handle: CropHandle, rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func resizedCropRect(
        base: NormalizedRect,
        handle: CropHandle,
        translation: CGSize,
        frameSize: CGSize
    ) -> NormalizedRect {
        let dx = Double(translation.width / max(1, frameSize.width))
        let dy = Double(translation.height / max(1, frameSize.height))
        var minX = base.x
        var minY = base.y
        var maxX = base.x + base.width
        var maxY = base.y + base.height
        let minSpan = 0.06

        switch handle {
        case .topLeft:
            minX = max(0, min(maxX - minSpan, base.x + dx))
            minY = max(0, min(maxY - minSpan, base.y + dy))
        case .topRight:
            maxX = min(1, max(minX + minSpan, maxX + dx))
            minY = max(0, min(maxY - minSpan, base.y + dy))
        case .bottomLeft:
            minX = max(0, min(maxX - minSpan, base.x + dx))
            maxY = min(1, max(minY + minSpan, maxY + dy))
        case .bottomRight:
            maxX = min(1, max(minX + minSpan, maxX + dx))
            maxY = min(1, max(minY + minSpan, maxY + dy))
        }

        var w = max(minSpan, maxX - minX)
        var h = max(minSpan, maxY - minY)

        if let targetRatio = model.editState.cropAspect.ratioValue {
            let imgRatio = Double(max(1, frameSize.width)) / Double(max(1, frameSize.height))
            let desiredH = w * (imgRatio / targetRatio)
            if minY + desiredH <= 1.0 && desiredH >= minSpan {
                h = desiredH
            } else {
                h = min(1.0 - minY, h)
                w = min(1.0 - minX, h * (targetRatio / imgRatio))
            }
        }

        return NormalizedRect(x: minX, y: minY, width: w, height: h)
    }

    // MARK: - Progressive Collapsible Inspector Drawer

    @ViewBuilder
    private func inspectorDrawer(_ panel: InspectorPanel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Label(String(localized: String.LocalizationValue(panel.rawValue)), systemImage: panel.systemImage)
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)
                Spacer()
                Button {
                    activeInspector = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Collapse Sidebar")
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm + 2)
            .background(AppTheme.Colors.subtleSurface)

            AppDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    switch panel {
                    case .adjust:
                        adjustInspectorContent
                    case .markup:
                        markupInspectorContent
                    case .backdrop:
                        backdropInspectorContent
                    case .colors:
                        colorsInspectorContent
                    }
                }
                .padding(AppTheme.Spacing.md)
            }
        }
    }

    private func inspectorSectionCard<Content: View>(
        title: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let title {
                Text(title)
                    .font(AppTheme.Typography.cardTitle)
            }
            content()
        }
        .padding(AppTheme.Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private var adjustInspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.xs) {
                if model.editState.adjustments.autoEnhanceEnabled {
                    Button {
                        model.toggleAutoEnhance()
                    } label: {
                        Label("Auto-Enhance", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Colors.accent)
                } else {
                    Button {
                        model.toggleAutoEnhance()
                    } label: {
                        Label("Auto-Enhance", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                Button("Reset") {
                    model.resetAllEdits()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.hasUnsavedChanges)
            }

            inspectorSectionCard(title: "Light & Color") {
                sliderRow(
                    label: "Exposure",
                    value: Binding(
                        get: { model.editState.adjustments.exposure },
                        set: { val in model.updateInteractiveState { $0.adjustments.exposure = val } }
                    ),
                    range: -2.0...2.0,
                    formatted: String(format: "%+.2f", model.editState.adjustments.exposure)
                )
                sliderRow(
                    label: "Brightness",
                    value: Binding(
                        get: { model.editState.adjustments.brightness },
                        set: { val in model.updateInteractiveState { $0.adjustments.brightness = val } }
                    ),
                    range: -0.5...0.5,
                    formatted: String(format: "%+.2f", model.editState.adjustments.brightness)
                )
                sliderRow(
                    label: "Contrast",
                    value: Binding(
                        get: { model.editState.adjustments.contrast },
                        set: { val in model.updateInteractiveState { $0.adjustments.contrast = val } }
                    ),
                    range: 0.5...2.0,
                    formatted: String(format: "%.2f", model.editState.adjustments.contrast)
                )
                sliderRow(
                    label: "Saturation",
                    value: Binding(
                        get: { model.editState.adjustments.saturation },
                        set: { val in model.updateInteractiveState { $0.adjustments.saturation = val } }
                    ),
                    range: 0.0...2.0,
                    formatted: String(format: "%.2f", model.editState.adjustments.saturation)
                )
                sliderRow(
                    label: "Warmth",
                    value: Binding(
                        get: { model.editState.adjustments.temperature },
                        set: { val in model.updateInteractiveState { $0.adjustments.temperature = val } }
                    ),
                    range: -100.0...100.0,
                    formatted: String(format: "%+.0f", model.editState.adjustments.temperature)
                )
                sliderRow(
                    label: "Sharpness",
                    value: Binding(
                        get: { model.editState.adjustments.sharpness },
                        set: { val in model.updateInteractiveState { $0.adjustments.sharpness = val } }
                    ),
                    range: 0.0...2.0,
                    formatted: String(format: "%.2f", model.editState.adjustments.sharpness)
                )
            }

            inspectorSectionCard(title: "Rotate & Flip") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Button { model.rotateCounterClockwise() } label: {
                        Image(systemName: "rotate.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rotate 90° Counter-Clockwise")
                    Button { model.rotateClockwise() } label: {
                        Image(systemName: "rotate.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rotate 90° Clockwise")
                    Button { model.toggleFlipHorizontal() } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Flip Horizontal")
                    Button { model.toggleFlipVertical() } label: {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Flip Vertical")
                }
            }

            inspectorSectionCard(title: "Crop") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                    ForEach(QuickPhotoCropAspect.allCases) { aspect in
                        if model.editState.cropAspect == aspect {
                            Button(LocalizedStringKey(aspect.rawValue)) {
                                applyAspectSelection(aspect)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(LocalizedStringKey(aspect.rawValue)) {
                                applyAspectSelection(aspect)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }
                }

                HStack(spacing: AppTheme.Spacing.xs) {
                    if model.activeTool == .crop {
                        Button("Apply Crop") {
                            let applied = draftCropRect
                            model.applyEdit { $0.cropRect = applied }
                            model.activeTool = .none
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)

                        Button("Cancel") {
                            model.activeTool = .none
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Crop Frame") {
                            draftCropRect = NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
                            model.activeTool = .crop
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if model.editState.cropRect != nil {
                            Button("Clear Crop") {
                                model.clearCrop()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func applyAspectSelection(_ aspect: QuickPhotoCropAspect) {
        model.applyEdit { $0.cropAspect = aspect }
        if let ratio = aspect.ratioValue, let img = displayedImage {
            let imgRatio = Double(max(1, img.size.width)) / Double(max(1, img.size.height))
            var w = 0.84
            var h = w * (imgRatio / ratio)
            if h > 0.84 { h = 0.84; w = h * (ratio / imgRatio) }
            draftCropRect = NormalizedRect(x: (1.0 - w) / 2.0, y: (1.0 - h) / 2.0, width: w, height: h)
        }
    }

    private var markupInspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            inspectorSectionCard(title: "Annotation & Redaction Tool") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.xs), count: 3), spacing: AppTheme.Spacing.xs) {
                    ForEach(QuickPhotoAnnotationKind.allCases) { kind in
                        let selected = (model.activeTool == .annotation && model.activeAnnotationKind == kind)
                        if selected {
                            Button {
                                model.activeTool = .annotation
                                model.activeAnnotationKind = kind
                            } label: {
                                markupToolLabel(kind)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                model.activeTool = .annotation
                                model.activeAnnotationKind = kind
                            } label: {
                                markupToolLabel(kind)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if model.activeTool == .annotation {
                    Button("Switch to Browse / Pan") {
                        model.activeTool = .none
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            inspectorSectionCard(title: "Color") {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(markupColorPalette, id: \.self) { color in
                        let isSelected = model.selectedColor == color
                        Button {
                            model.selectedColor = color
                        } label: {
                            Circle()
                                .fill(Color(red: color.red, green: color.green, blue: color.blue))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .strokeBorder(isSelected ? AppTheme.Colors.accent : Color.primary.opacity(0.24), lineWidth: isSelected ? 2.5 : 1)
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
                                        .padding(2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack {
                        Text("Stroke / Brush")
                            .font(AppTheme.Typography.caption)
                        Spacer()
                        Text("\(Int(model.strokeWidth)) px")
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.strokeWidth, in: 2...28)
                        .controlSize(.small)
                }

                if model.activeAnnotationKind == .text {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack {
                            Text("Text Size")
                                .font(AppTheme.Typography.caption)
                            Spacer()
                            Text("\(Int(model.textFontSize)) pt")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.textFontSize, in: 12...64)
                            .controlSize(.small)
                    }
                }

                if model.activeAnnotationKind == .stepBadge {
                    Text("Next step badge: #\(model.nextStepNumber)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: AppTheme.Spacing.xs) {
                Button("Remove Last") {
                    model.removeLastAnnotation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.editState.annotations.isEmpty)

                Button("Clear All") {
                    model.clearAnnotations()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.editState.annotations.isEmpty)
            }
        }
    }

    private func markupToolLabel(_ kind: QuickPhotoAnnotationKind) -> some View {
        VStack(spacing: 3) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 13))
            Text(LocalizedStringKey(kind.rawValue))
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var backdropInspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            inspectorSectionCard {
                Toggle(
                    "Enable Screenshot Frame",
                    isOn: Binding(
                        get: { model.editState.backdrop.isEnabled },
                        set: { enabled in
                            model.applyEdit { $0.backdrop.isEnabled = enabled }
                        }
                    )
                )
                .fontWeight(.medium)

                Picker(
                    "Style",
                    selection: Binding(
                        get: { model.editState.backdrop.style },
                        set: { style in
                            model.applyEdit { $0.backdrop.style = style }
                        }
                    )
                ) {
                    ForEach(QuickPhotoBackdropStyle.allCases) { style in
                        Text(LocalizedStringKey(style.rawValue)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.editState.backdrop.isEnabled)

                if model.editState.backdrop.style == .gradient {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                        ForEach(QuickPhotoBackdropGradientPreset.allCases.filter { $0 != .custom }) { preset in
                            let pair = preset.colors
                            let isSelected = (model.editState.backdrop.gradientPreset == preset)
                            Button {
                                model.applyEdit { $0.backdrop.applyPreset(preset) }
                            } label: {
                                VStack(spacing: 3) {
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color(red: pair.start.red, green: pair.start.green, blue: pair.start.blue),
                                                    Color(red: pair.end.red, green: pair.end.green, blue: pair.end.blue)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(height: 24)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                                .strokeBorder(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder, lineWidth: isSelected ? 2 : 1)
                                        )
                                    Text(LocalizedStringKey(preset.rawValue))
                                        .font(.caption2.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? AppTheme.Colors.accent : .primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .opacity(model.editState.backdrop.isEnabled ? 1.0 : 0.45)
                            .disabled(!model.editState.backdrop.isEnabled)
                        }
                    }
                }
            }

            inspectorSectionCard(title: "Frame Geometry") {
                sliderRow(
                    label: "Padding",
                    value: Binding(
                        get: { model.editState.backdrop.padding },
                        set: { val in model.updateInteractiveState { $0.backdrop.padding = val } }
                    ),
                    range: 0...180,
                    formatted: "\(Int(model.editState.backdrop.padding.rounded())) px"
                )
                .disabled(!model.editState.backdrop.isEnabled)

                sliderRow(
                    label: "Corner Radius",
                    value: Binding(
                        get: { model.editState.backdrop.cornerRadius },
                        set: { val in model.updateInteractiveState { $0.backdrop.cornerRadius = val } }
                    ),
                    range: 0...48,
                    formatted: "\(Int(model.editState.backdrop.cornerRadius.rounded())) px"
                )
                .disabled(!model.editState.backdrop.isEnabled)

                sliderRow(
                    label: "Shadow Blur",
                    value: Binding(
                        get: { model.editState.backdrop.shadowRadius },
                        set: { val in model.updateInteractiveState { $0.backdrop.shadowRadius = val } }
                    ),
                    range: 0...40,
                    formatted: "\(Int(model.editState.backdrop.shadowRadius.rounded())) px"
                )
                .disabled(!model.editState.backdrop.isEnabled)
            }
        }
    }

    private var colorsInspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            inspectorSectionCard(title: "Color Eyedropper") {
                Button {
                    pickColorWithEyedropper()
                } label: {
                    Label(
                        eyedropper.isSampling ? String(localized: "Sampling…") : String(localized: "Pick Screen Color"),
                        systemImage: "eyedropper"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(eyedropper.isSampling)
                .accessibilityIdentifier("photoviewer.inspectorEyedropperButton")

                if let picked = eyedropper.lastSampledColor {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .fill(Color(red: Double(picked.red) / 255.0, green: Double(picked.green) / 255.0, blue: Double(picked.blue) / 255.0))
                            .frame(width: 28, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(picked.hex)
                                .font(AppTheme.Typography.monoCaption.weight(.semibold))
                            Text(picked.rgbString)
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityIdentifier("photoviewer.lastPickedColorCard")

                    HStack(spacing: AppTheme.Spacing.xs) {
                        Button("Copy #HEX") {
                            copyTextToPasteboard(
                                picked.hex,
                                feedback: String(localized: "Copied \(picked.hex) to clipboard.")
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Copy RGB") {
                            copyTextToPasteboard(
                                picked.rgbString,
                                feedback: String(localized: "Copied \(picked.rgbString) to clipboard.")
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                } else {
                    Text("Copies #HEX and RGB(r, g, b) to the clipboard.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            inspectorSectionCard(title: "Dominant Palette") {
                if isExtractingPalette {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Extracting colors…")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if dominantSwatches.isEmpty {
                    Text("No palette colors extracted.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(dominantSwatches) { swatch in
                            Button {
                                copyTextToPasteboard(
                                    swatch.hex,
                                    feedback: String(localized: "Copied \(swatch.hex) to clipboard.")
                                )
                            } label: {
                                HStack(spacing: AppTheme.Spacing.sm) {
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                        .fill(Color(red: Double(swatch.red) / 255.0, green: Double(swatch.green) / 255.0, blue: Double(swatch.blue) / 255.0))
                                        .frame(width: 20, height: 20)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                                        )

                                    Text(swatch.hex)
                                        .font(AppTheme.Typography.monoCaption.weight(.medium))
                                        .foregroundStyle(.primary)

                                    Spacer(minLength: 0)

                                    Text("\(Int(swatch.percentage.rounded()))%")
                                        .font(AppTheme.Typography.monoCaption)
                                        .foregroundStyle(.secondary)

                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, AppTheme.Spacing.xs + 2)
                                .padding(.vertical, 4)
                                .background(AppTheme.Colors.subtleSurface)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Copy \(swatch.hex)")
                            .accessibilityIdentifier("photoviewer.paletteSwatch.\(swatch.id)")
                        }
                    }

                    Button("Copy All #HEX") {
                        let joined = dominantSwatches.map(\.hex).joined(separator: ", ")
                        copyTextToPasteboard(
                            joined,
                            feedback: String(localized: "Copied palette colors to clipboard.")
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("photoviewer.copyAllPaletteButton")
                }
            }
        }
    }

    private func sliderRow(
        label: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        formatted: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(AppTheme.Typography.caption)
                Spacer()
                Text(formatted)
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range) { editing in
                if editing {
                    model.beginContinuousEdit()
                } else {
                    model.endContinuousEdit()
                }
            }
            .controlSize(.small)
        }
    }

    private var markupColorPalette: [CodableRGBAColor] {
        [
            CodableRGBAColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),
            CodableRGBAColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1.0),
            CodableRGBAColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0),
            CodableRGBAColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0),
            CodableRGBAColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            CodableRGBAColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        ]
    }

    // MARK: - Collapsible Folder Filmstrip

    private var filmstripBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs + 2) {
                ForEach(Array(model.siblings.enumerated()), id: \.element) { idx, siblingURL in
                    let isSelected = (idx == model.currentSiblingIndex)
                    Button {
                        Task { await model.goToSibling(at: idx) }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .fill(AppTheme.Colors.elevatedSurface)
                            if let thumb = thumbnailCache[siblingURL] {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 60, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .strokeBorder(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder, lineWidth: isSelected ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(siblingURL.lastPathComponent)
                    .task(id: siblingURL) {
                        await loadThumbnailIfNeeded(for: siblingURL)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, minHeight: 68, maxHeight: 68)
        .background(AppTheme.Colors.subtleSurface)
        .accessibilityIdentifier("photoviewer.filmstrip")
    }

    // MARK: - Bottom Action Bar

    private var hasStatusSummary: Bool {
        model.exifSummary != nil
            || model.hasUnsavedChanges
            || localBannerError != nil
            || localStatusToast != nil
            || model.statusMessage != nil
    }

    private var bottomActionBar: some View {
        AppBottomActionBar {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                if hasStatusSummary {
                    statusSummaryArea
                }
                bottomActionButtons
            }
        }
    }

    @ViewBuilder
    private var statusSummaryArea: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let summary = model.exifSummary {
                Text(summary.dimensionsText)
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
            if model.hasUnsavedChanges {
                AppStatusBadge(text: String(localized: "Edited"), tint: AppTheme.Colors.accent)
            }
            if let msg = localBannerError ?? localStatusToast ?? model.statusMessage {
                Text(msg)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(localBannerError != nil ? AppTheme.Colors.error : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var bottomActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.sm) {
                bottomSecondaryActionsGroup
                Spacer(minLength: AppTheme.Spacing.xs)
                bottomPrimaryActionsGroup
            }

            VStack(alignment: .trailing, spacing: AppTheme.Spacing.xs) {
                bottomSecondaryActionsGroup
                bottomPrimaryActionsGroup
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var bottomSecondaryActionsGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs + 2) {
            if model.sourceCGImage != nil {
                Label("Drag Output", systemImage: "arrow.up.forward.square")
                    .font(AppTheme.Typography.caption.weight(.medium))
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(AppTheme.Colors.neutralTint)
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .onDrag { makeDragItemProvider() }
                    .help("Drag image to Finder or another app")
                    .accessibilityLabel("Drag Output File")
                    .accessibilityIdentifier("photoviewer.dragOutputChip")
            }

            Button(role: .destructive) {
                showTrashConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Move to Trash (⌘⌫)")
            .accessibilityLabel("Trash")
            .accessibilityIdentifier("photoviewer.trashButton")

            if let onSendToConvertQueue {
                Button {
                    onSendToConvertQueue(model.currentURL)
                } label: {
                    Label("Send to Convert Queue", systemImage: "tray.and.arrow.down")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("photoviewer.sendToQueueButton")
            }
        }
    }

    private var bottomPrimaryActionsGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs + 2) {
            if model.canOverwriteOriginal {
                Button("Overwrite Original") {
                    showOverwriteConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isSavingOutput || !model.hasUnsavedChanges)
                .accessibilityIdentifier("photoviewer.overwriteButton")
            }

            Button("Save Copy…") {
                presentSaveCopyPanel()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(model.sourceCGImage == nil || isSavingOutput)
            .help("Save Copy (⌘S)")
            .accessibilityIdentifier("photoviewer.saveCopyButton")

            if let onDismiss {
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("photoviewer.dismissButton")
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private var shortcutOverlay: some View {
        Group {
            Button("") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { Task { _ = await model.copyRenderedImageToPasteboard() } }
                .keyboardShortcut("c", modifiers: .command)
            Button("") { presentSaveCopyPanel() }
                .keyboardShortcut("s", modifiers: .command)
            Button("") { showTrashConfirmation = true }
                .keyboardShortcut(.delete, modifiers: .command)

            if !isEditingText {
                Button("") { toggleActualPixelZoom() }
                    .keyboardShortcut("0", modifiers: [])
                Button("") { Task { await model.goToPreviousSibling() } }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { Task { await model.goToNextSibling() } }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Helpers & Actions

    private func toggleInspector(_ panel: InspectorPanel) {
        if activeInspector == panel {
            activeInspector = nil
            if panel == .markup && model.activeTool == .annotation {
                model.activeTool = .none
            }
        } else {
            activeInspector = panel
            if panel == .markup {
                model.activeTool = .annotation
            } else if model.activeTool == .annotation {
                model.activeTool = .none
            }
        }
    }

    private func setZoom(_ target: CGFloat) {
        zoomScale = max(0.25, min(8.0, target))
        if zoomScale <= 1.0 {
            panOffset = .zero
            dragStartPan = nil
        }
    }

    private func resetViewportTransform() {
        zoomScale = 1.0
        gestureMagnification = 1.0
        panOffset = .zero
        dragStartPan = nil
    }

    private func actualSizeZoomFactor() -> CGFloat {
        let dims = model.predictedOutputDimensions
        let pxW = CGFloat(max(1, dims.width > 0 ? dims.width : Int(displayedImage?.size.width ?? 1)))
        let pxH = CGFloat(max(1, dims.height > 0 ? dims.height : Int(displayedImage?.size.height ?? 1)))
        let availW = max(1, viewportSize.width - 16)
        let availH = max(1, viewportSize.height - 16)
        let fitScale = min(availW / pxW, availH / pxH)
        guard fitScale > 0.001, fitScale < 1.0 else { return 2.0 }
        return max(1.0, min(8.0, 1.0 / fitScale))
    }

    private func toggleActualPixelZoom() {
        if abs(zoomScale - 1.0) > 0.05 {
            resetViewportTransform()
        } else {
            setZoom(actualSizeZoomFactor())
        }
    }

    private func commitPendingTextAnnotation() {
        guard let point = pendingTextPoint else { return }
        let trimmed = pendingTextValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTextPoint = nil
        pendingTextValue = ""
        isTextInputFocused = false
        guard !trimmed.isEmpty else { return }
        let ann = QuickPhotoAnnotation(
            kind: .text,
            startPoint: point,
            color: model.selectedColor,
            strokeWidth: model.strokeWidth,
            text: trimmed,
            fontSize: model.textFontSize
        )
        model.addAnnotation(ann)
    }

    private func runOCRCopy() {
        guard !isRunningOCR else { return }
        isRunningOCR = true
        localBannerError = nil
        Task {
            do {
                _ = try await model.copyExtractedTextToPasteboard()
            } catch {
                localBannerError = error.localizedDescription
            }
            isRunningOCR = false
        }
    }

    private func presentSaveCopyPanel() {
        let suggested = model.suggestedCopyURL()
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        let targetFormat = QuickPhotoRenderEngine.writableFormat(for: suggested)
        if let utType = targetFormat.utType {
            panel.allowedContentTypes = [utType]
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        isSavingOutput = true
        localBannerError = nil
        Task {
            do {
                _ = try await model.saveCopy(to: destination, policy: .overwrite)
            } catch {
                localBannerError = error.localizedDescription
            }
            isSavingOutput = false
        }
    }

    private func performOverwriteOriginal() {
        isSavingOutput = true
        localBannerError = nil
        Task {
            do {
                _ = try await model.overwriteOriginal()
            } catch {
                localBannerError = error.localizedDescription
            }
            isSavingOutput = false
        }
    }

    private func performTrashCurrentFile() {
        localBannerError = nil
        Task {
            do {
                let nextURL = try await model.moveCurrentFileToTrash()
                if nextURL == nil {
                    onDismiss?()
                }
            } catch {
                localBannerError = error.localizedDescription
            }
        }
    }

    private func loadThumbnailIfNeeded(for url: URL) async {
        if thumbnailCache[url] != nil { return }
        let cg = await Task.detached(priority: .utility) {
            ImageProcessor.createThumbnail(from: url, maxPixelSize: 112)
        }.value
        guard let cg else { return }
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if thumbnailCache[url] == nil {
            thumbnailCache[url] = nsImage
            thumbnailOrder.append(url)
            while thumbnailOrder.count > maxCachedThumbnails {
                let evicted = thumbnailOrder.removeFirst()
                thumbnailCache.removeValue(forKey: evicted)
            }
        }
    }

    // MARK: - Milestone 13 Photo Tools (Pin, Drag Export, QR/Barcode, Eyedropper, Palette)

    private func analyzeLoadedPhoto() async {
        guard let cg = model.sourceCGImage else {
            detectedBarcodes = []
            dominantSwatches = []
            isExtractingPalette = false
            return
        }
        let targetURL = model.currentURL
        isExtractingPalette = true

        async let barcodesTask = (try? PhotoBarcodeAnalyzer.detectBarcodes(in: cg)) ?? []
        async let paletteTask = Task.detached(priority: .utility) {
            PhotoColorPaletteExtractor.extractDominantColors(from: cg, maxColors: 5)
        }.value

        let (barcodes, swatches) = await (barcodesTask, paletteTask)
        guard !Task.isCancelled, model.currentURL == targetURL else { return }
        detectedBarcodes = barcodes
        dominantSwatches = swatches
        isExtractingPalette = false
    }

    private func pinCurrentImageToScreen() {
        let title = model.currentURL.lastPathComponent
        let sourceURL = model.currentURL
        Task {
            let renderedCG = await model.renderFullResolutionCGImageAsync()
            let pinImage: NSImage?
            if let cg = renderedCG {
                pinImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else {
                pinImage = displayedImage
            }
            guard let pinImage else { return }
            PinnedImageWindowController.pin(image: pinImage, title: title, sourceURL: sourceURL)
            localStatusToast = String(localized: "Pinned image to screen.")
        }
    }

    private func pickColorWithEyedropper() {
        Task {
            if let picked = await eyedropper.pickColor() {
                localStatusToast = String(localized: "Picked \(picked.hex) (\(picked.rgbString)).")
            }
        }
    }

    private func copyTextToPasteboard(_ text: String, feedback: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        localStatusToast = feedback
    }

    private func makeDragItemProvider() -> NSItemProvider {
        if !model.hasUnsavedChanges {
            return NSItemProvider(object: model.currentURL as NSURL)
        }
        guard let sourceCG = model.sourceCGImage else {
            return NSItemProvider(object: model.currentURL as NSURL)
        }

        let editSnapshot = model.editState
        let suggestedFilename = model.suggestedCopyURL().lastPathComponent
        let baseName = FileFormat.baseNameByStrippingExtension(from: model.suggestedCopyURL())
        let provider = NSItemProvider()
        provider.suggestedName = suggestedFilename

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let rendered = QuickPhotoRenderEngine.renderCGImage(from: sourceCG, state: editSnapshot) else {
                        completion(nil, false, ConversionError.engineExecutionFailed("Failed to render image for drag export.", underlyingError: nil))
                        return
                    }
                    let pngData = try ImageProcessor.encodeToMemory(
                        cgImage: rendered,
                        format: .png,
                        quality: 1.0,
                        lossless: true,
                        sourceProperties: nil,
                        preserveMetadata: false
                    )
                    let dragDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("LocalConvert-PhotoDrag", isDirectory: true)
                    try FileManager.default.createDirectory(at: dragDir, withIntermediateDirectories: true)
                    let destinationURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                        directory: dragDir,
                        baseName: baseName.isEmpty ? "LocalConvert-Export" : baseName,
                        extension: "png",
                        policy: .createUnique
                    )
                    defer { OutputReservationCoordinator.releaseReservedOutputURL(destinationURL) }
                    let stageURL = dragDir.appendingPathComponent(".stage-\(UUID().uuidString).png")
                    defer { try? FileManager.default.removeItem(at: stageURL) }
                    try pngData.write(to: stageURL, options: [.atomic])
                    let committed = try OutputReservationCoordinator.moveOrReplaceTempFile(
                        stageURL,
                        to: destinationURL,
                        policy: .createUnique
                    )
                    completion(committed, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

// MARK: - Auto QR / Barcode Detector

struct DetectedPhotoBarcode: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let payload: String
    let symbology: String
}

enum PhotoBarcodeAnalyzer: Sendable {
    static func detectBarcodes(in cgImage: CGImage) async throws -> [DetectedPhotoBarcode] {
        guard cgImage.width >= 2, cgImage.height >= 2 else {
            return []
        }
        return try await Task.detached(priority: .utility) {
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            let observations = request.results ?? []
            var seen = Set<String>()
            var detected: [DetectedPhotoBarcode] = []
            for obs in observations {
                guard let payload = obs.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payload.isEmpty else {
                    continue
                }
                let symbology = obs.symbology.rawValue
                let key = "\(symbology)|\(payload)"
                if seen.insert(key).inserted {
                    detected.append(DetectedPhotoBarcode(id: key, payload: payload, symbology: symbology))
                }
            }
            return detected
        }.value
    }
}

// MARK: - Native Color Eyedropper Wrapper

struct SampledPhotoColor: Sendable, Equatable, Hashable {
    let red: Int
    let green: Int
    let blue: Int

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbString: String {
        "RGB(\(red), \(green), \(blue))"
    }

    var clipboardSummary: String {
        "\(hex) · \(rgbString)"
    }

    init(red: Int, green: Int, blue: Int) {
        self.red = max(0, min(255, red))
        self.green = max(0, min(255, green))
        self.blue = max(0, min(255, blue))
    }

    init?(nsColor: NSColor) {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let r = Int((max(0.0, min(1.0, srgb.redComponent)) * 255.0).rounded())
        let g = Int((max(0.0, min(1.0, srgb.greenComponent)) * 255.0).rounded())
        let b = Int((max(0.0, min(1.0, srgb.blueComponent)) * 255.0).rounded())
        self.init(red: r, green: g, blue: b)
    }
}

@MainActor
protocol ScreenColorSampling: AnyObject {
    func sampleColor() async -> NSColor?
}

@MainActor
final class SystemScreenColorSampler: ScreenColorSampling {
    func sampleColor() async -> NSColor? {
        await NSColorSampler().sample()
    }
}

@MainActor
final class PhotoEyedropperCoordinator: ObservableObject {
    @Published private(set) var lastSampledColor: SampledPhotoColor?
    @Published private(set) var isSampling: Bool = false

    private let sampler: any ScreenColorSampling
    private let copyTextHandler: @MainActor (String) -> Void

    init(
        sampler: any ScreenColorSampling = SystemScreenColorSampler(),
        copyTextHandler: (@MainActor (String) -> Void)? = nil
    ) {
        self.sampler = sampler
        self.copyTextHandler = copyTextHandler ?? { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    @discardableResult
    func pickColor() async -> SampledPhotoColor? {
        guard !isSampling else { return nil }
        isSampling = true
        defer { isSampling = false }

        guard let pickedNSColor = await sampler.sampleColor(),
              let sampled = SampledPhotoColor(nsColor: pickedNSColor) else {
            return nil
        }
        lastSampledColor = sampled
        copyTextHandler(sampled.clipboardSummary)
        return sampled
    }
}

// MARK: - Dominant Color Palette Extractor (Pure CoreGraphics Quantized Histogram)

struct DominantColorSwatch: Identifiable, Sendable, Equatable, Hashable {
    let id: Int
    let red: Int
    let green: Int
    let blue: Int
    let percentage: Double

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbString: String {
        "RGB(\(red), \(green), \(blue))"
    }
}

enum PhotoColorPaletteExtractor: Sendable {
    static func extractDominantColors(
        from nsImage: NSImage,
        maxColors: Int = 5,
        maxSampleDimension: Int = 128,
        quantizationBitsPerChannel: Int = 4
    ) -> [DominantColorSwatch] {
        var proposed = NSRect(origin: .zero, size: nsImage.size)
        guard let cgImage = nsImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return []
        }
        return extractDominantColors(
            from: cgImage,
            maxColors: maxColors,
            maxSampleDimension: maxSampleDimension,
            quantizationBitsPerChannel: quantizationBitsPerChannel
        )
    }

    static func extractDominantColors(
        from cgImage: CGImage,
        maxColors: Int = 5,
        maxSampleDimension: Int = 128,
        quantizationBitsPerChannel: Int = 4
    ) -> [DominantColorSwatch] {
        guard maxColors > 0, cgImage.width > 0, cgImage.height > 0 else {
            return []
        }

        let bits = max(2, min(6, quantizationBitsPerChannel))
        let shift = 8 - bits
        let cappedDim = max(8, min(512, maxSampleDimension))
        let scale = min(1.0, Double(cappedDim) / Double(max(cgImage.width, cgImage.height)))
        let dstW = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let dstH = max(1, Int((Double(cgImage.height) * scale).rounded()))

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? cgImage.colorSpace else {
            return []
        }

        var rgba = [UInt8](repeating: 0, count: dstW * dstH * 4)
        let drawn = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bytesPerRow: dstW * 4,
                space: srgb,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            return true
        }
        guard drawn else { return [] }

        struct HistogramBucket {
            var sumR: Int = 0
            var sumG: Int = 0
            var sumB: Int = 0
            var count: Int = 0
        }

        var buckets: [Int: HistogramBucket] = [:]
        var totalOpaquePixels = 0
        let pixelCount = dstW * dstH

        for i in 0..<pixelCount {
            let offset = i * 4
            let a = Int(rgba[offset + 3])
            guard a > 16 else { continue }

            let rawR = Int(rgba[offset])
            let rawG = Int(rgba[offset + 1])
            let rawB = Int(rgba[offset + 2])

            let r: Int
            let g: Int
            let b: Int
            if a < 255 {
                r = min(255, (rawR * 255 + a / 2) / a)
                g = min(255, (rawG * 255 + a / 2) / a)
                b = min(255, (rawB * 255 + a / 2) / a)
            } else {
                r = rawR
                g = rawG
                b = rawB
            }

            let rq = r >> shift
            let gq = g >> shift
            let bq = b >> shift
            let key = (rq << (bits * 2)) | (gq << bits) | bq

            var bucket = buckets[key] ?? HistogramBucket()
            bucket.sumR += r
            bucket.sumG += g
            bucket.sumB += b
            bucket.count += 1
            buckets[key] = bucket
            totalOpaquePixels += 1
        }

        guard totalOpaquePixels > 0 else { return [] }

        let sortedBuckets = buckets
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count {
                    return lhs.value.count > rhs.value.count
                }
                return lhs.key < rhs.key
            }
            .prefix(maxColors)

        return sortedBuckets.enumerated().map { idx, entry in
            let b = entry.value
            let avgR = max(0, min(255, Int((Double(b.sumR) / Double(b.count)).rounded())))
            let avgG = max(0, min(255, Int((Double(b.sumG) / Double(b.count)).rounded())))
            let avgB = max(0, min(255, Int((Double(b.sumB) / Double(b.count)).rounded())))
            let pct = (Double(b.count) / Double(totalOpaquePixels)) * 100.0
            return DominantColorSwatch(
                id: idx,
                red: avgR,
                green: avgG,
                blue: avgB,
                percentage: pct
            )
        }
    }
}

// MARK: - Hold-to-Compare (\) Keyboard Monitor & Guard Policy

enum PhotoViewerHoldComparePolicy: Sendable {
    static let backslashKeyCode: UInt16 = 42

    static func isBackslashEvent(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        let hardDisallowed = modifierFlags.intersection([.command, .control])
        guard hardDisallowed.isEmpty else { return false }
        if characters == "\\" {
            return true
        }
        let allModifiers = modifierFlags.intersection([.command, .option, .control, .shift])
        return allModifiers.isEmpty && (keyCode == backslashKeyCode || charactersIgnoringModifiers == "\\")
    }

    static func isBackslashReleaseEvent(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        keyCode == backslashKeyCode || characters == "\\" || charactersIgnoringModifiers == "\\"
    }

    static func canActivateHoldCompare(
        isSameWindow: Bool,
        isKeyWindow: Bool,
        hasImage: Bool,
        isEditingText: Bool,
        hasActiveDragAnnotation: Bool,
        isConfirmationPresented: Bool,
        isCommandPalettePresented: Bool,
        isFirstResponderTextInput: Bool
    ) -> Bool {
        isSameWindow
            && isKeyWindow
            && hasImage
            && !isEditingText
            && !hasActiveDragAnnotation
            && !isConfirmationPresented
            && !isCommandPalettePresented
            && !isFirstResponderTextInput
    }

    @MainActor
    static func isTextInputResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        return UndoMenuController.activeEditableTextResponder(from: responder) != nil
            || responder is NSTextField
            || responder is NSTextView
    }
}

private struct PhotoViewerHoldCompareKeyMonitorHost: NSViewRepresentable {
    let isHoldingBefore: @MainActor () -> Bool
    let canActivate: @MainActor (NSWindow) -> Bool
    let onHoldChanged: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isHoldingBefore: isHoldingBefore,
            canActivate: canActivate,
            onHoldChanged: onHoldChanged
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.isHoldingBefore = isHoldingBefore
        context.coordinator.canActivate = canActivate
        context.coordinator.onHoldChanged = onHoldChanged
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var isHoldingBefore: @MainActor () -> Bool
        var canActivate: @MainActor (NSWindow) -> Bool
        var onHoldChanged: @MainActor (Bool) -> Void

        private var eventMonitor: Any?
        private var notificationTokens: [any NSObjectProtocol] = []

        init(
            isHoldingBefore: @escaping @MainActor () -> Bool,
            canActivate: @escaping @MainActor (NSWindow) -> Bool,
            onHoldChanged: @escaping @MainActor (Bool) -> Void
        ) {
            self.isHoldingBefore = isHoldingBefore
            self.canActivate = canActivate
            self.onHoldChanged = onHoldChanged
        }

        func install() {
            if eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                    guard let self else { return event }
                    return self.handleEvent(event)
                }
            }

            if notificationTokens.isEmpty {
                let center = NotificationCenter.default
                let resignKeyToken = center.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.resetHoldIfActive()
                    }
                }
                let resignActiveToken = center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.resetHoldIfActive()
                    }
                }
                notificationTokens = [resignKeyToken, resignActiveToken]
            }
        }

        func uninstall() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens.removeAll()
            resetHoldIfActive()
        }

        private func resetHoldIfActive() {
            if isHoldingBefore() {
                onHoldChanged(false)
            }
        }

        private func handleEvent(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .keyDown:
                guard let hostWindow = hostView?.window,
                      event.window === hostWindow else {
                    return event
                }
                guard PhotoViewerHoldComparePolicy.isBackslashEvent(
                    keyCode: event.keyCode,
                    characters: event.characters,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifierFlags: event.modifierFlags
                ) else {
                    return event
                }
                if canActivate(hostWindow) {
                    onHoldChanged(true)
                    return nil
                }
                resetHoldIfActive()
                return event

            case .keyUp:
                guard let hostWindow = hostView?.window,
                      event.window === hostWindow else {
                    resetHoldIfActive()
                    return event
                }
                guard PhotoViewerHoldComparePolicy.isBackslashReleaseEvent(
                    keyCode: event.keyCode,
                    characters: event.characters,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers
                ) else {
                    return event
                }
                if isHoldingBefore() {
                    onHoldChanged(false)
                    return nil
                }
                return event

            case .flagsChanged:
                if isHoldingBefore(),
                   !event.modifierFlags.intersection([.command, .control]).isEmpty {
                    onHoldChanged(false)
                }
                return event

            default:
                return event
            }
        }
    }
}

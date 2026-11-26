import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Photo Viewer & Quick Editor View (Milestone 11A)

@MainActor
struct PhotoViewerEditorView: View {

    enum InspectorPanel: String, CaseIterable, Identifiable {
        case adjust = "Adjust"
        case markup = "Markup"
        case backdrop = "Backdrop"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .adjust: return "slider.horizontal.3"
            case .markup: return "pencil.tip.crop.circle"
            case .backdrop: return "macwindow"
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

    // Bounded filmstrip thumbnail cache
    @State private var thumbnailCache: [URL: NSImage] = [:]
    @State private var thumbnailOrder: [URL] = []
    private let maxCachedThumbnails = 64

    init(
        url: URL,
        onSendToConvertQueue: ((URL) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.initialURL = url
        self.onSendToConvertQueue = onSendToConvertQueue
        self.onDismiss = onDismiss
        self._model = StateObject(wrappedValue: QuickPhotoEditorModel(url: url))
    }

    private var displayedImage: NSImage? {
        isHoldingBefore ? model.originalPreviewImage : model.previewImage
    }

    private var isEditingText: Bool {
        pendingTextPoint != nil || isTextInputFocused
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
                        .frame(width: 246)
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
        .onChange(of: model.currentURL) { _, _ in
            resetViewportTransform()
            pendingTextPoint = nil
            activeDragAnnotation = nil
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
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.sm) {
                siblingNavigationGroup
                AppDivider().frame(width: 1, height: 18)
                zoomToolbarGroup
                Spacer(minLength: AppTheme.Spacing.xs)
                historyAndUtilityGroup
                AppDivider().frame(width: 1, height: 18)
                inspectorToggleGroup
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
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
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var siblingNavigationGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                Task { await model.goToPreviousSibling() }
            } label: {
                Image(systemName: "chevron.left")
            }
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
            .controlSize(.small)
            .disabled(!model.canGoNext || model.isLoading)
            .help("Next Photo (→)")
            .accessibilityLabel("Next Photo")
            .accessibilityIdentifier("photoviewer.nextButton")

            Text(model.currentURL.lastPathComponent)
                .font(AppTheme.Typography.cardTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .leading)

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
            .controlSize(.small)
            .fixedSize()
            .help("Fit image to window")
            .accessibilityIdentifier("photoviewer.zoomFitButton")

            Button("100%") {
                toggleActualPixelZoom()
            }
            .controlSize(.small)
            .fixedSize()
            .help("Toggle 100% actual pixels (0)")
            .accessibilityIdentifier("photoviewer.zoom100Button")

            Button {
                setZoom(max(0.25, zoomScale / 1.25))
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .controlSize(.small)
            .help("Zoom Out")
            .accessibilityIdentifier("photoviewer.zoomOutButton")

            Button {
                setZoom(min(8.0, zoomScale * 1.25))
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
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
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
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
            .controlSize(.small)
            .disabled(!model.canRedo)
            .help("Redo (⇧⌘Z)")
            .accessibilityLabel("Redo")
            .accessibilityIdentifier("photoviewer.redoButton")

            Button {
                runOCRCopy()
            } label: {
                if isRunningOCR {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "text.viewfinder")
                }
            }
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
            .controlSize(.small)
            .disabled(model.sourceCGImage == nil)
            .help("Copy Image (⌘C)")
            .accessibilityLabel("Copy Image")
            .accessibilityIdentifier("photoviewer.copyButton")

            Toggle(isOn: $showEXIFHUD) {
                Image(systemName: "info.circle")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle EXIF & Dimensions HUD")
            .accessibilityLabel("Toggle EXIF HUD")
            .accessibilityIdentifier("photoviewer.exifToggle")

            Toggle(isOn: $showFilmstrip) {
                Image(systemName: "rectangle.grid.1x2")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Toggle Folder Filmstrip")
            .accessibilityLabel("Toggle Filmstrip")
            .accessibilityIdentifier("photoviewer.filmstripToggle")
        }
    }

    private var inspectorToggleGroup: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(InspectorPanel.allCases) { panel in
                let isSelected = (activeInspector == panel)
                Button {
                    toggleInspector(panel)
                } label: {
                    Label(String(localized: String.LocalizationValue(panel.rawValue)), systemImage: panel.systemImage)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(isSelected ? AppTheme.Colors.accent : .secondary)
                .accessibilityIdentifier(inspectorIdentifier(for: panel))
            }
        }
    }

    private func inspectorIdentifier(for panel: InspectorPanel) -> String {
        switch panel {
        case .adjust: return "photoviewer.adjustToggle"
        case .markup: return "photoviewer.markupToggle"
        case .backdrop: return "photoviewer.backdropToggle"
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
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        if model.hasUnsavedChanges {
                            Label("Hold Before", systemImage: isHoldingBefore ? "eye.fill" : "eye")
                                .font(AppTheme.Typography.caption.weight(.medium))
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, 4)
                                .background(AppTheme.Colors.cardBackground.opacity(0.92))
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                        .strokeBorder(isHoldingBefore ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder, lineWidth: 1)
                                )
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in if !isHoldingBefore { isHoldingBefore = true } }
                                        .onEnded { _ in isHoldingBefore = false }
                                )
                                .help("Press and hold to inspect original")
                        }
                    }
                    Spacer()
                }
                .padding(AppTheme.Spacing.md)

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
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(summary.formatName)
                    .font(AppTheme.Typography.badge)
                    .foregroundStyle(AppTheme.Colors.accent)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(summary.fileSizeText)
                    .font(AppTheme.Typography.monoCaption)
            }
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
        .padding(AppTheme.Spacing.sm + 2)
        .background(AppTheme.Colors.cardBackground.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
        .frame(maxWidth: 260, alignment: .leading)
        .accessibilityIdentifier("photoviewer.exifHUD")
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
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
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

            ForEach(CropHandle.allCases, id: \.self) { handle in
                let pt = cropHandlePosition(handle, rect: rect)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(AppTheme.Colors.accent, lineWidth: 2))
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
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Label(String(localized: String.LocalizationValue(panel.rawValue)), systemImage: panel.systemImage)
                        .font(AppTheme.Typography.sectionTitle)
                    Spacer()
                    Button {
                        activeInspector = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse Sidebar")
                }

                AppDivider()

                switch panel {
                case .adjust:
                    adjustInspectorContent
                case .markup:
                    markupInspectorContent
                case .backdrop:
                    backdropInspectorContent
                }
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private var adjustInspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    model.toggleAutoEnhance()
                } label: {
                    Label("Auto-Enhance", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(model.editState.adjustments.autoEnhanceEnabled ? AppTheme.Colors.accent : .secondary)

                Button("Reset") {
                    model.resetAllEdits()
                }
                .controlSize(.small)
                .disabled(!model.hasUnsavedChanges)
            }

            Group {
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

            AppDivider()

            Text("Rotate & Flip")
                .font(AppTheme.Typography.cardTitle)
            HStack(spacing: AppTheme.Spacing.xs) {
                Button { model.rotateCounterClockwise() } label: { Image(systemName: "rotate.left") }
                    .controlSize(.small)
                    .help("Rotate 90° Counter-Clockwise")
                Button { model.rotateClockwise() } label: { Image(systemName: "rotate.right") }
                    .controlSize(.small)
                    .help("Rotate 90° Clockwise")
                Button { model.toggleFlipHorizontal() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .controlSize(.small)
                    .help("Flip Horizontal")
                Button { model.toggleFlipVertical() } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .controlSize(.small)
                    .help("Flip Vertical")
            }

            AppDivider()

            Text("Crop")
                .font(AppTheme.Typography.cardTitle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                ForEach(QuickPhotoCropAspect.allCases) { aspect in
                    Button(LocalizedStringKey(aspect.rawValue)) {
                        model.applyEdit { $0.cropAspect = aspect }
                        if let ratio = aspect.ratioValue, let img = displayedImage {
                            let imgRatio = Double(max(1, img.size.width)) / Double(max(1, img.size.height))
                            var w = 0.84
                            var h = w * (imgRatio / ratio)
                            if h > 0.84 { h = 0.84; w = h * (ratio / imgRatio) }
                            draftCropRect = NormalizedRect(x: (1.0 - w) / 2.0, y: (1.0 - h) / 2.0, width: w, height: h)
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(model.editState.cropAspect == aspect ? AppTheme.Colors.accent : .secondary)
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
                    .controlSize(.small)
                } else {
                    Button("Crop Frame") {
                        draftCropRect = NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
                        model.activeTool = .crop
                    }
                    .controlSize(.small)

                    if model.editState.cropRect != nil {
                        Button("Clear Crop") {
                            model.clearCrop()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var markupInspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Annotation & Redaction Tool")
                .font(AppTheme.Typography.cardTitle)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                ForEach(QuickPhotoAnnotationKind.allCases) { kind in
                    let selected = (model.activeTool == .annotation && model.activeAnnotationKind == kind)
                    Button {
                        model.activeTool = .annotation
                        model.activeAnnotationKind = kind
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: kind.systemImage)
                                .font(.system(size: 13))
                            Text(LocalizedStringKey(kind.rawValue))
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(selected ? AppTheme.Colors.accent : .secondary)
                }
            }

            if model.activeTool == .annotation {
                Button("Switch to Browse / Pan") {
                    model.activeTool = .none
                }
                .controlSize(.small)
            }

            AppDivider()

            Text("Color")
                .font(AppTheme.Typography.cardTitle)

            HStack(spacing: AppTheme.Spacing.sm) {
                ForEach(markupColorPalette, id: \.self) { color in
                    let isSelected = model.selectedColor == color
                    Button {
                        model.selectedColor = color
                    } label: {
                        Circle()
                            .fill(Color(red: color.red, green: color.green, blue: color.blue))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 2)
                            )
                            .shadow(radius: isSelected ? 2 : 0)
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

            AppDivider()

            HStack(spacing: AppTheme.Spacing.xs) {
                Button("Remove Last") {
                    model.removeLastAnnotation()
                }
                .controlSize(.small)
                .disabled(model.editState.annotations.isEmpty)

                Button("Clear All") {
                    model.clearAnnotations()
                }
                .controlSize(.small)
                .disabled(model.editState.annotations.isEmpty)
            }
        }
    }

    private var backdropInspectorContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
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
                                    .frame(height: 22)
                                Text(LocalizedStringKey(preset.rawValue))
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .opacity(model.editState.backdrop.isEnabled ? 1.0 : 0.45)
                        .disabled(!model.editState.backdrop.isEnabled)
                    }
                }
            }

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
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(Array(model.siblings.enumerated()), id: \.element) { idx, siblingURL in
                    let isSelected = (idx == model.currentSiblingIndex)
                    Button {
                        Task { await model.goToSibling(at: idx) }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .fill(AppTheme.Colors.cardBackground)
                            if let thumb = thumbnailCache[siblingURL] {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 56, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
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
            .padding(.vertical, AppTheme.Spacing.xs + 2)
        }
        .frame(height: 64)
        .background(AppTheme.Colors.subtleSurface)
        .accessibilityIdentifier("photoviewer.filmstrip")
    }

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        AppBottomActionBar {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    statusSummaryArea
                    Spacer(minLength: AppTheme.Spacing.sm)
                    bottomActionButtons
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    statusSummaryArea
                    HStack {
                        Spacer(minLength: 0)
                        bottomActionButtons
                    }
                }
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
            if let msg = localBannerError ?? model.statusMessage {
                Text(msg)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(localBannerError != nil ? AppTheme.Colors.error : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var bottomActionButtons: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button(role: .destructive) {
                showTrashConfirmation = true
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .controlSize(.small)
            .help("Move to Trash (⌘⌫)")
            .accessibilityIdentifier("photoviewer.trashButton")

            if let onSendToConvertQueue {
                Button {
                    onSendToConvertQueue(model.currentURL)
                } label: {
                    Label("Send to Convert Queue", systemImage: "tray.and.arrow.down")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("photoviewer.sendToQueueButton")
            }

            if model.canOverwriteOriginal {
                Button("Overwrite Original") {
                    showOverwriteConfirmation = true
                }
                .controlSize(.small)
                .disabled(isSavingOutput || !model.hasUnsavedChanges)
                .accessibilityIdentifier("photoviewer.overwriteButton")
            }

            Button("Save Copy…") {
                presentSaveCopyPanel()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(model.sourceCGImage == nil || isSavingOutput)
            .help("Save Copy (⌘S)")
            .accessibilityIdentifier("photoviewer.saveCopyButton")

            if let onDismiss {
                Button("Done") {
                    onDismiss()
                }
                .controlSize(.small)
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
            } else if panel == .adjust && model.activeTool == .annotation {
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
}

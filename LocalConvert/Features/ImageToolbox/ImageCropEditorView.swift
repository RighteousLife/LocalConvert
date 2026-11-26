import SwiftUI
import AppKit

// MARK: - Interactive Crop & Geometric Shape Editor Section

struct ImageCropRotateSectionView: View {
    @Binding var config: ImageToolboxConfig
    let previewImage: NSImage?
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let outputFormat: FileFormat
    var store: ImageToolboxStore? = nil
    var sourceURL: URL? = nil

    private enum CropEditorMode: String, CaseIterable, Identifiable {
        case cropAndShapes = "Crop, Rotate & Shapes"
        case perspective = "Perspective Correction"
        var id: String { rawValue }
    }

    @State private var editorMode: CropEditorMode = .cropAndShapes
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragStartPan: CGSize = .zero
    @State private var panModeEnabled: Bool = false
    @State private var horizonStatusText: String? = nil
    @State private var isDetectingHorizon: Bool = false

    // Active drag baselines in normalized [0,1] image space
    @State private var activeMoveOrigin: NormalizedRect? = nil
    @State private var activeHandleOrigin: NormalizedRect? = nil
    @State private var activePolygonVertexDrag: [CodableNormalizedPoint]? = nil

    private enum CropDragHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var orientedSourceDims: (width: Int, height: Int) {
        let w = sourceDims?.width ?? max(1, Int(previewImage?.size.width ?? 1000))
        let h = sourceDims?.height ?? max(1, Int(previewImage?.size.height ?? 1000))
        return ImageDimensionCalculator.orientedDimensions(
            width: w,
            height: h,
            rotationDegrees: config.cropTransform.rotationDegrees,
            straightenDegrees: config.cropTransform.straightenDegrees,
            autoCropOnStraighten: config.cropTransform.autoCropOnStraighten
        )
    }

    private var orientedPreviewNSImage: NSImage? {
        guard let base = previewImage else { return nil }
        guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return base }
        let rot = ((config.cropTransform.rotationDegrees % 360) + 360) % 360
        let hasStraighten = abs(config.cropTransform.straightenDegrees) > 0.01
        if rot == 0 && !config.cropTransform.flipHorizontal && !config.cropTransform.flipVertical && !hasStraighten {
            return base
        }
        var current = cg
        if rot != 0 || config.cropTransform.flipHorizontal || config.cropTransform.flipVertical {
            if let t = try? ImageCropService.transformOrientation(
                cgImage: current,
                rotationDegrees: rot,
                flipHorizontal: config.cropTransform.flipHorizontal,
                flipVertical: config.cropTransform.flipVertical
            ) {
                current = t
            }
        }
        if hasStraighten,
           let s = try? ImageCropService.straighten(
               cgImage: current,
               degrees: config.cropTransform.straightenDegrees,
               autoCropInscribed: config.cropTransform.autoCropOnStraighten
           ) {
            current = s
        }
        return NSImage(cgImage: current, size: NSSize(width: current.width, height: current.height))
    }

    private var activeNormRect: NormalizedRect {
        config.cropTransform.normalizedRect ?? NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    }

    private var croppedPixelDims: (width: Int, height: Int) {
        let dims = orientedSourceDims
        if config.cropTransform.cropMode == .none {
            return dims
        }
        let r = activeNormRect
        return (
            max(1, Int((r.width * Double(dims.width)).rounded())),
            max(1, Int((r.height * Double(dims.height)).rounded()))
        )
    }

    private var targetSupportsTransparency: Bool {
        FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Picker("Geometry Tool", selection: $editorMode) {
                ForEach(CropEditorMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            if editorMode == .cropAndShapes {
                interactiveCanvasCard
                rotationAndTransformCard
                aspectRatioAndGeometryCard
                geometricShapeAndFillCard
            } else {
                ImagePerspectiveEditorView(
                    config: $config,
                    previewImage: previewImage,
                    outputFormat: outputFormat,
                    store: store,
                    sourceURL: sourceURL
                )
            }
        }
        .onDisappear {
            store?.endContinuousEdit(for: sourceURL)
        }
    }

    // MARK: - 1. Interactive Crop Canvas

    private var interactiveCanvasCard: some View {
        AppCard(padding: 0) {
            VStack(spacing: 0) {
                canvasToolbar
                AppDivider()
                cropViewport
                    .frame(minHeight: 270, maxHeight: 350)
                    .background(AppTheme.Colors.elevatedSurface)
                    .clipped()
                AppDivider()
                canvasStatusFooter
            }
        }
    }

    private var canvasToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.md) {
                overlayGridPicker
                AppDivider().frame(width: 1, height: 18)
                zoomToolbarControls
                Spacer(minLength: AppTheme.Spacing.sm)
                cropQuickButtons
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    overlayGridPicker
                    Spacer(minLength: 0)
                    cropQuickButtons
                }
                zoomToolbarControls
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var overlayGridPicker: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Grid:")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Grid Overlay", selection: $config.cropTransform.overlayGrid) {
                ForEach(ImageCropOverlayGrid.allCases) { g in
                    Text(g.rawValue).tag(g)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var zoomToolbarControls: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button("Fit") {
                zoomScale = 1.0
                panOffset = .zero
                dragStartPan = .zero
                panModeEnabled = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button("100%") {
                zoomScale = 2.0
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button {
                zoomScale = max(0.5, zoomScale / 1.25)
                if zoomScale <= 1.0 { panOffset = .zero; dragStartPan = .zero }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button {
                zoomScale = min(5.0, zoomScale * 1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Toggle(isOn: $panModeEnabled) {
                Label("Pan", systemImage: "hand.draw")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Pan zoomed image without moving crop handles")

            Text("\(Int((zoomScale * 100).rounded()))%")
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
    }

    private var cropQuickButtons: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Toggle("Crop Active", isOn: Binding(
                get: { config.cropTransform.cropMode != .none },
                set: { active in
                    if active {
                        enableInteractiveCrop()
                    } else {
                        config.cropTransform.cropMode = .none
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .font(AppTheme.Typography.caption)
            .fixedSize()

            Button("Reset") {
                config.cropTransform = ImageCropAndTransformConfig()
                zoomScale = 1.0
                panOffset = .zero
                dragStartPan = .zero
                panModeEnabled = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var cropViewport: some View {
        GeometryReader { geo in
            if let img = orientedPreviewNSImage, img.size.width > 0, img.size.height > 0 {
                let fitRect = fittedImageRect(imageSize: img.size, in: geo.size)
                let dispW = fitRect.width * zoomScale
                let dispH = fitRect.height * zoomScale
                let dispX = (geo.size.width - dispW) / 2.0 + panOffset.width
                let dispY = (geo.size.height - dispH) / 2.0 + panOffset.height
                let displayedImgRect = CGRect(x: dispX, y: dispY, width: dispW, height: dispH)

                let isCropping = config.cropTransform.cropMode != .none
                let norm = isCropping ? activeNormRect : NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                let cropScreenRect = CGRect(
                    x: displayedImgRect.minX + CGFloat(norm.x) * displayedImgRect.width,
                    y: displayedImgRect.minY + CGFloat(norm.y) * displayedImgRect.height,
                    width: max(12, CGFloat(norm.width) * displayedImgRect.width),
                    height: max(12, CGFloat(norm.height) * displayedImgRect.height)
                )

                ZStack(alignment: .topLeading) {
                    // Checkerboard / Solid Fill backdrop inside crop region
                    if config.cropTransform.shape.isGeometricMask {
                        if config.cropTransform.shapeBackgroundFill == .transparent {
                            CheckerboardPattern()
                                .frame(width: cropScreenRect.width, height: cropScreenRect.height)
                                .position(x: cropScreenRect.midX, y: cropScreenRect.midY)
                        } else {
                            config.cropTransform.shapeBackgroundColor.swiftUIColor
                                .frame(width: cropScreenRect.width, height: cropScreenRect.height)
                                .position(x: cropScreenRect.midX, y: cropScreenRect.midY)
                        }
                    }

                    // Source oriented image
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: dispW, height: dispH)
                        .position(x: displayedImgRect.midX, y: displayedImgRect.midY)

                    // Outer dark scrim with geometric shape cutout
                    Canvas { ctx, size in
                        var full = Path(CGRect(origin: .zero, size: size))
                        let shapeCGPath = ImageCropService.cgPath(
                            for: config.cropTransform.shape,
                            in: cropScreenRect,
                            cornerRadiusPercent: config.cropTransform.roundedCornerRadiusPercent,
                            polygonVertices: config.cropTransform.effectivePolygonVertices,
                            flippedTopLeftToCG: false
                        )
                        full.addPath(Path(shapeCGPath))
                        ctx.fill(full, with: .color(Color.black.opacity(isCropping || config.cropTransform.shape.isGeometricMask ? 0.58 : 0.0)), style: FillStyle(eoFill: true))
                    }
                    .allowsHitTesting(false)

                    if !panModeEnabled {
                        // Shape outline + Composition Grid inside crop rect
                        shapeAndGridOverlay(in: cropScreenRect)
                            .allowsHitTesting(false)

                        // Drag interior to reposition crop box
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .frame(width: cropScreenRect.width, height: cropScreenRect.height)
                            .position(x: cropScreenRect.midX, y: cropScreenRect.midY)
                            .gesture(
                                DragGesture()
                                    .onChanged { val in
                                        if activeMoveOrigin == nil {
                                            store?.beginContinuousEdit(for: sourceURL)
                                            enableInteractiveCrop()
                                            activeMoveOrigin = activeNormRect
                                        }
                                        guard let start = activeMoveOrigin else { return }
                                        let dx = Double(val.translation.width / max(1, displayedImgRect.width))
                                        let dy = Double(val.translation.height / max(1, displayedImgRect.height))
                                        let nextX = max(0.0, min(1.0 - start.width, start.x + dx))
                                        let nextY = max(0.0, min(1.0 - start.height, start.y + dy))
                                        config.cropTransform.normalizedRect = NormalizedRect(
                                            x: nextX,
                                            y: nextY,
                                            width: start.width,
                                            height: start.height
                                        )
                                    }
                                    .onEnded { _ in
                                        activeMoveOrigin = nil
                                        store?.endContinuousEdit(for: sourceURL, explicitType: .imageCrop, explicitTitle: "Move Crop")
                                    }
                            )

                        // 8 Corner & Edge Resize Handles
                        ForEach(CropDragHandle.allCases, id: \.self) { handle in
                            handleView(for: handle, in: cropScreenRect, displayedImgRect: displayedImgRect)
                        }

                        // Custom Polygon Interactive Vertex Handles
                        if config.cropTransform.shape == .customPolygon {
                            let verts = config.cropTransform.effectivePolygonVertices
                            ForEach(0..<verts.count, id: \.self) { idx in
                                let v = verts[idx]
                                let vx = cropScreenRect.minX + CGFloat(v.x) * cropScreenRect.width
                                let vy = cropScreenRect.minY + CGFloat(v.y) * cropScreenRect.height
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 11, height: 11)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                                    .position(x: vx, y: vy)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Polygon vertex \(idx + 1)")
                                    .accessibilityValue("X \(Int((v.x * 100).rounded())) percent, Y \(Int((v.y * 100).rounded())) percent")
                                    .gesture(
                                        DragGesture()
                                            .onChanged { val in
                                                enableInteractiveCrop()
                                                if activePolygonVertexDrag == nil {
                                                    store?.beginContinuousEdit(for: sourceURL)
                                                    activePolygonVertexDrag = verts
                                                }
                                                guard var base = activePolygonVertexDrag, idx < base.count else { return }
                                                let dx = Double(val.translation.width / max(1, cropScreenRect.width))
                                                let dy = Double(val.translation.height / max(1, cropScreenRect.height))
                                                let nx = max(0.0, min(1.0, base[idx].x + dx))
                                                let ny = max(0.0, min(1.0, base[idx].y + dy))
                                                base[idx] = CodableNormalizedPoint(id: idx, x: nx, y: ny)
                                                config.cropTransform.polygonVertices = base
                                            }
                                            .onEnded { _ in
                                                activePolygonVertexDrag = nil
                                                store?.endContinuousEdit(
                                                    for: sourceURL,
                                                    explicitType: .imageCrop,
                                                    explicitTitle: "Adjust Polygon Crop Vertices"
                                                )
                                            }
                                    )
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { val in
                            guard panModeEnabled || zoomScale > 1.01 else { return }
                            let maxX = max(0, (geo.size.width * (zoomScale - 1.0)) / 2.0 + 120)
                            let maxY = max(0, (geo.size.height * (zoomScale - 1.0)) / 2.0 + 120)
                            let nextW = max(-maxX, min(maxX, dragStartPan.width + val.translation.width))
                            let nextH = max(-maxY, min(maxY, dragStartPan.height + val.translation.height))
                            panOffset = CGSize(width: nextW, height: nextH)
                        }
                        .onEnded { _ in
                            dragStartPan = panOffset
                        }
                )
            } else {
                AppLoadingStateView(message: "Loading crop canvas...")
            }
        }
    }

    @ViewBuilder
    private func shapeAndGridOverlay(in rect: CGRect) -> some View {
        Canvas { ctx, _ in
            let shapeCG = ImageCropService.cgPath(
                for: config.cropTransform.shape,
                in: rect,
                cornerRadiusPercent: config.cropTransform.roundedCornerRadiusPercent,
                polygonVertices: config.cropTransform.effectivePolygonVertices,
                flippedTopLeftToCG: false
            )
            let shapePath = Path(shapeCG)

            // Composition grid clipped inside crop rect
            if config.cropTransform.overlayGrid != .none {
                ctx.drawLayer { layer in
                    layer.clip(to: shapePath)
                    var gridPath = Path()
                    switch config.cropTransform.overlayGrid {
                    case .ruleOfThirds:
                        for f in [1.0 / 3.0, 2.0 / 3.0] {
                            let gx = rect.minX + rect.width * CGFloat(f)
                            let gy = rect.minY + rect.height * CGFloat(f)
                            gridPath.move(to: CGPoint(x: gx, y: rect.minY))
                            gridPath.addLine(to: CGPoint(x: gx, y: rect.maxY))
                            gridPath.move(to: CGPoint(x: rect.minX, y: gy))
                            gridPath.addLine(to: CGPoint(x: rect.maxX, y: gy))
                        }
                    case .goldenRatio:
                        for f in [0.381966, 0.618034] {
                            let gx = rect.minX + rect.width * CGFloat(f)
                            let gy = rect.minY + rect.height * CGFloat(f)
                            gridPath.move(to: CGPoint(x: gx, y: rect.minY))
                            gridPath.addLine(to: CGPoint(x: gx, y: rect.maxY))
                            gridPath.move(to: CGPoint(x: rect.minX, y: gy))
                            gridPath.addLine(to: CGPoint(x: rect.maxX, y: gy))
                        }
                    case .squareGrid:
                        for idx in 1..<6 {
                            let f = CGFloat(idx) / 6.0
                            let gx = rect.minX + rect.width * f
                            let gy = rect.minY + rect.height * f
                            gridPath.move(to: CGPoint(x: gx, y: rect.minY))
                            gridPath.addLine(to: CGPoint(x: gx, y: rect.maxY))
                            gridPath.move(to: CGPoint(x: rect.minX, y: gy))
                            gridPath.addLine(to: CGPoint(x: rect.maxX, y: gy))
                        }
                    case .none:
                        break
                    }
                    layer.stroke(gridPath, with: .color(Color.white.opacity(0.45)), lineWidth: 1)
                }
            }

            // Outer crop bounding frame (for non-rectangular shapes, draw subtle dashed box too)
            if config.cropTransform.shape.isGeometricMask {
                ctx.stroke(Path(rect), with: .color(Color.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ctx.stroke(shapePath, with: .color(AppTheme.Colors.accent), lineWidth: 2)
        }
    }

    @ViewBuilder
    private func handleView(
        for handle: CropDragHandle,
        in cropRect: CGRect,
        displayedImgRect: CGRect
    ) -> some View {
        let pt: CGPoint = {
            switch handle {
            case .topLeft:     return CGPoint(x: cropRect.minX, y: cropRect.minY)
            case .top:         return CGPoint(x: cropRect.midX, y: cropRect.minY)
            case .topRight:    return CGPoint(x: cropRect.maxX, y: cropRect.minY)
            case .right:       return CGPoint(x: cropRect.maxX, y: cropRect.midY)
            case .bottomRight: return CGPoint(x: cropRect.maxX, y: cropRect.maxY)
            case .bottom:      return CGPoint(x: cropRect.midX, y: cropRect.maxY)
            case .bottomLeft:  return CGPoint(x: cropRect.minX, y: cropRect.maxY)
            case .left:        return CGPoint(x: cropRect.minX, y: cropRect.midY)
            }
        }()

        let isCorner = (handle == .topLeft || handle == .topRight || handle == .bottomLeft || handle == .bottomRight)

        RoundedRectangle(cornerRadius: isCorner ? 3 : 2)
            .fill(Color.white)
            .frame(width: isCorner ? 11 : 9, height: isCorner ? 11 : 9)
            .overlay(
                RoundedRectangle(cornerRadius: isCorner ? 3 : 2)
                    .strokeBorder(AppTheme.Colors.accent, lineWidth: 1.5)
            )
            .position(pt)
            .gesture(
                DragGesture()
                    .onChanged { val in
                        if activeHandleOrigin == nil {
                            store?.beginContinuousEdit(for: sourceURL)
                            enableInteractiveCrop()
                            activeHandleOrigin = activeNormRect
                        }
                        guard let start = activeHandleOrigin else { return }
                        let dx = Double(val.translation.width / max(1, displayedImgRect.width))
                        let dy = Double(val.translation.height / max(1, displayedImgRect.height))
                        config.cropTransform.normalizedRect = resizedNormalizedRect(
                            from: start,
                            handle: handle,
                            dx: dx,
                            dy: dy
                        )
                    }
                    .onEnded { _ in
                        activeHandleOrigin = nil
                        store?.endContinuousEdit(for: sourceURL, explicitType: .imageCrop, explicitTitle: "Resize Crop")
                    }
            )
    }

    private var canvasStatusFooter: some View {
        let dims = orientedSourceDims
        let out = croppedPixelDims
        return HStack(spacing: AppTheme.Spacing.md) {
            Text("Oriented: \(dims.width)×\(dims.height) px")
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text("Crop Selection: \(out.width)×\(out.height) px")
                .font(AppTheme.Typography.monoCaption.weight(.medium))
            if config.cropTransform.shape.isGeometricMask {
                AppStatusBadge(text: config.cropTransform.shape.rawValue, tint: AppTheme.Colors.accent)
            }
            Spacer(minLength: 0)
            Text(panModeEnabled ? "Pan Mode Active" : "Drag handles to resize · Drag inside to move")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs + 2)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - 2. Rotation, Straighten & Mirroring Card

    private var rotationAndTransformCard: some View {
        AppCard(title: "Rotation, Straighten & Mirroring", icon: "rotate.right") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        rotationButtons
                        AppDivider().frame(width: 1, height: 20)
                        flipToggles
                        Spacer(minLength: 0)
                        AppHeaderPill(text: "\(config.cropTransform.rotationDegrees)°")
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            rotationButtons
                            Spacer(minLength: 0)
                            AppHeaderPill(text: "\(config.cropTransform.rotationDegrees)°")
                        }
                        HStack(spacing: AppTheme.Spacing.md) {
                            flipToggles
                            Spacer(minLength: 0)
                        }
                    }
                }

                AppDivider()

                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Straighten:")
                        .font(AppTheme.Typography.caption)
                        .frame(width: 72, alignment: .leading)
                    Slider(value: $config.cropTransform.straightenDegrees, in: -45.0...45.0, step: 0.1) { editing in
                        if editing {
                            store?.beginContinuousEdit(for: sourceURL)
                        } else {
                            store?.endContinuousEdit(for: sourceURL, explicitType: .imageCrop, explicitTitle: "Straighten Image")
                        }
                    }
                    .accessibilityLabel("Straighten angle")
                    .accessibilityValue(String(format: "%+.1f degrees", config.cropTransform.straightenDegrees))

                    Text(String(format: "%+.1f°", config.cropTransform.straightenDegrees))
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)

                    Button("0°") {
                        config.cropTransform.straightenDegrees = 0.0
                        horizonStatusText = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(abs(config.cropTransform.straightenDegrees) < 0.05)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Toggle("Auto-Crop Empty Corners", isOn: $config.cropTransform.autoCropOnStraighten)
                            .toggleStyle(.checkbox)
                            .font(AppTheme.Typography.caption)

                        Button {
                            runAutoHorizonDetection()
                        } label: {
                            if isDetectingHorizon {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Auto Horizon (Vision)", systemImage: "level")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(previewImage == nil || isDetectingHorizon)

                        if let status = horizonStatusText {
                            Text(status)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Toggle("Auto-Crop Empty Corners", isOn: $config.cropTransform.autoCropOnStraighten)
                            .toggleStyle(.checkbox)
                            .font(AppTheme.Typography.caption)
                        Button {
                            runAutoHorizonDetection()
                        } label: {
                            Label("Auto Horizon (Vision)", systemImage: "level")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(previewImage == nil || isDetectingHorizon)
                        if let status = horizonStatusText {
                            Text(status)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func runAutoHorizonDetection() {
        guard let base = previewImage,
              let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rot = ((config.cropTransform.rotationDegrees % 360) + 360) % 360
        let flipH = config.cropTransform.flipHorizontal
        let flipV = config.cropTransform.flipVertical
        isDetectingHorizon = true
        horizonStatusText = "Detecting horizon..."
        Task.detached(priority: .userInitiated) {
            let oriented = (try? ImageCropService.transformOrientation(
                cgImage: cg,
                rotationDegrees: rot,
                flipHorizontal: flipH,
                flipVertical: flipV
            )) ?? cg
            let angle = ImageCropService.detectHorizonAngle(cgImage: oriented)
            await MainActor.run {
                self.isDetectingHorizon = false
                if let detected = angle {
                    self.config.cropTransform.straightenDegrees = detected
                    self.horizonStatusText = String(format: "Horizon aligned (%+.1f°)", detected)
                } else {
                    self.horizonStatusText = "No clear horizon line detected."
                }
            }
        }
    }

    @ViewBuilder
    private var rotationButtons: some View {
        Button {
            config.cropTransform.rotationDegrees = (config.cropTransform.rotationDegrees + 270) % 360
        } label: {
            Label("90° CCW", systemImage: "rotate.left")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button {
            config.cropTransform.rotationDegrees = (config.cropTransform.rotationDegrees + 90) % 360
        } label: {
            Label("90° CW", systemImage: "rotate.right")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button {
            config.cropTransform.rotationDegrees = (config.cropTransform.rotationDegrees + 180) % 360
        } label: {
            Label("180°", systemImage: "arrow.trianglehead.2.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var flipToggles: some View {
        Toggle("Flip H", isOn: $config.cropTransform.flipHorizontal)
            .fixedSize()
        Toggle("Flip V", isOn: $config.cropTransform.flipVertical)
            .fixedSize()
    }

    // MARK: - 3. Aspect Ratio & Framing Card

    private var aspectRatioAndGeometryCard: some View {
        AppCard(title: "Aspect Ratio & Framing", icon: "crop") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                    ForEach(ImageCropRatioPreset.allCases) { preset in
                        let isSelected = config.cropTransform.effectiveRatioPreset == preset
                        Button {
                            applyAspectRatioPreset(preset)
                        } label: {
                            Text(preset.rawValue)
                                .font(AppTheme.Typography.caption.weight(isSelected ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppTheme.Spacing.xs + 1)
                                .background(isSelected ? AppTheme.Colors.accentTint : AppTheme.Colors.subtleSurface)
                                .foregroundStyle(isSelected ? AppTheme.Colors.accent : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                        .strokeBorder(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if config.cropTransform.effectiveRatioPreset == .customRatio {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Custom Ratio:")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        TextField("W", value: $config.cropTransform.customAspectWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 68)
                        Text(":").foregroundStyle(.secondary)
                        TextField("H", value: $config.cropTransform.customAspectHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 68)
                        Button("Apply Ratio") {
                            applyAspectRatioPreset(.customRatio)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }

                AppDivider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        pixelCropDimensionControls
                        Spacer(minLength: 0)
                        Button("Select Full Image") {
                            config.cropTransform.cropMode = .customRect
                            config.cropTransform.normalizedRect = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        pixelCropDimensionControls
                        Button("Select Full Image") {
                            config.cropTransform.cropMode = .customRect
                            config.cropTransform.normalizedRect = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pixelCropDimensionControls: some View {
        let dims = orientedSourceDims
        let cur = croppedPixelDims
        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Crop Size (px):")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            TextField("W", value: Binding(
                get: { cur.width },
                set: { newW in
                    enableInteractiveCrop()
                    let clampedW = max(1, min(dims.width, newW))
                    let wFrac = Double(clampedW) / Double(max(1, dims.width))
                    var r = activeNormRect
                    r.width = min(wFrac, 1.0 - r.x)
                    if wFrac > 1.0 - r.x { r.x = max(0, 1.0 - wFrac); r.width = wFrac }
                    config.cropTransform.normalizedRect = r
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 74)

            Text("×").foregroundStyle(.secondary)

            TextField("H", value: Binding(
                get: { cur.height },
                set: { newH in
                    enableInteractiveCrop()
                    let clampedH = max(1, min(dims.height, newH))
                    let hFrac = Double(clampedH) / Double(max(1, dims.height))
                    var r = activeNormRect
                    r.height = min(hFrac, 1.0 - r.y)
                    if hFrac > 1.0 - r.y { r.y = max(0, 1.0 - hFrac); r.height = hFrac }
                    config.cropTransform.normalizedRect = r
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 74)
        }
    }

    // MARK: - 4. Geometric Crop Shapes Card

    private var geometricShapeAndFillCard: some View {
        AppCard(title: "Geometric Crop Shape & Background", icon: "circle.hexagongrid") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                    ForEach(ImageCropShape.allCases) { shape in
                        let selected = config.cropTransform.shape == shape
                        Button {
                            config.cropTransform.shape = shape
                            if shape.isGeometricMask {
                                config.cropTransform.enabled = true
                            }
                            if shape == .circle {
                                applyAspectRatioPreset(.ratio1x1)
                            } else if shape == .customPolygon && config.cropTransform.polygonVertices == nil {
                                config.cropTransform.polygonVertices = CodableNormalizedPoint.regularPolygon(
                                    sides: config.cropTransform.polygonSides,
                                    rotationDegrees: config.cropTransform.polygonRotationDegrees
                                )
                            }
                        } label: {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Image(systemName: shape.systemImage)
                                    .font(AppTheme.Typography.caption)
                                Text(shape.rawValue)
                                    .font(AppTheme.Typography.caption.weight(selected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .padding(.vertical, AppTheme.Spacing.xs + 2)
                            .background(selected ? AppTheme.Colors.accentTint : AppTheme.Colors.subtleSurface)
                            .foregroundStyle(selected ? AppTheme.Colors.accent : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                                    .strokeBorder(selected ? AppTheme.Colors.accent : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if config.cropTransform.shape == .roundedRectangle {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Corner Radius: \(Int(config.cropTransform.roundedCornerRadiusPercent.rounded()))%")
                            .font(AppTheme.Typography.caption)
                            .fixedSize()
                        Slider(value: $config.cropTransform.roundedCornerRadiusPercent, in: 0...50, step: 1) { editing in
                            if editing {
                                store?.beginContinuousEdit(for: sourceURL)
                            } else {
                                store?.endContinuousEdit(
                                    for: sourceURL,
                                    explicitType: .imageCrop,
                                    explicitTitle: "Adjust Crop Corner Radius"
                                )
                            }
                        }
                        .accessibilityLabel("Crop corner radius")
                        .accessibilityValue("\(Int(config.cropTransform.roundedCornerRadiusPercent.rounded())) percent")
                    }
                }

                if config.cropTransform.shape == .customPolygon {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            polygonControls
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            polygonControls
                        }
                    }
                }

                if config.cropTransform.shape.isGeometricMask {
                    AppDivider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            shapeBackgroundControls
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            shapeBackgroundControls
                        }
                    }

                    if config.cropTransform.shapeBackgroundFill == .transparent && !targetSupportsTransparency {
                        AppInfoBanner(
                            style: .warning,
                            message: "\(outputFormat.shortExtensionLabel) does not support an alpha channel. Outer crop areas will be filled with the fallback color below; switch Output to PNG, WebP, TIFF, or JPEG XL (.jxl) to export transparency."
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var polygonControls: some View {
        Stepper("Sides: \(config.cropTransform.polygonSides)", value: Binding(
            get: { config.cropTransform.polygonSides },
            set: { newSides in
                config.cropTransform.polygonSides = max(3, min(12, newSides))
                config.cropTransform.polygonVertices = CodableNormalizedPoint.regularPolygon(
                    sides: config.cropTransform.polygonSides,
                    rotationDegrees: config.cropTransform.polygonRotationDegrees
                )
            }
        ), in: 3...12)
        .fixedSize()

        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Angle: \(Int(config.cropTransform.polygonRotationDegrees.rounded()))°")
                .font(AppTheme.Typography.caption)
                .fixedSize()
            Slider(value: Binding(
                get: { config.cropTransform.polygonRotationDegrees },
                set: { deg in
                    config.cropTransform.polygonRotationDegrees = deg
                    config.cropTransform.polygonVertices = CodableNormalizedPoint.regularPolygon(
                        sides: config.cropTransform.polygonSides,
                        rotationDegrees: deg
                    )
                }
            ), in: -180...180, step: 5) { editing in
                if editing {
                    store?.beginContinuousEdit(for: sourceURL)
                } else {
                    store?.endContinuousEdit(
                        for: sourceURL,
                        explicitType: .imageCrop,
                        explicitTitle: "Rotate Polygon Crop"
                    )
                }
            }
            .frame(minWidth: 110, maxWidth: 180)
            .accessibilityLabel("Polygon angle")
            .accessibilityValue("\(Int(config.cropTransform.polygonRotationDegrees.rounded())) degrees")
        }

        Button("Reset Vertices") {
            config.cropTransform.polygonVertices = CodableNormalizedPoint.regularPolygon(
                sides: config.cropTransform.polygonSides,
                rotationDegrees: config.cropTransform.polygonRotationDegrees
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var shapeBackgroundControls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Outside Area:")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Picker("Outside Area Fill", selection: $config.cropTransform.shapeBackgroundFill) {
                ForEach(ImageBackgroundFillMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }

        if config.cropTransform.shapeBackgroundFill == .solidColor || !targetSupportsTransparency {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(config.cropTransform.shapeBackgroundFill == .solidColor ? "Background Color:" : "Opaque Fallback Color:")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                ColorPicker("Background Color", selection: Binding(
                    get: { config.cropTransform.shapeBackgroundColor.swiftUIColor },
                    set: { config.cropTransform.shapeBackgroundColor = CodableRGBAColor(swiftUIColor: $0) }
                ))
                .labelsHidden()
            }
        }
    }

    // MARK: - Coordinate & Aspect Math Helpers

    private func enableInteractiveCrop() {
        if config.cropTransform.cropMode != .customRect {
            config.cropTransform.cropMode = .customRect
            if config.cropTransform.normalizedRect == nil {
                config.cropTransform.normalizedRect = NormalizedRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
            }
        }
    }

    private func applyAspectRatioPreset(_ preset: ImageCropRatioPreset) {
        enableInteractiveCrop()
        config.cropTransform.ratioPreset = preset

        switch preset {
        case .freeform: config.cropTransform.aspectRatio = .custom
        case .original: config.cropTransform.aspectRatio = .original
        case .ratio1x1: config.cropTransform.aspectRatio = .square1x1
        case .ratio4x3: config.cropTransform.aspectRatio = .ratio4x3
        case .ratio3x4: config.cropTransform.aspectRatio = .ratio3x4
        case .ratio3x2: config.cropTransform.aspectRatio = .ratio3x2
        case .ratio2x3: config.cropTransform.aspectRatio = .ratio2x3
        case .ratio16x9: config.cropTransform.aspectRatio = .ratio16x9
        case .ratio9x16: config.cropTransform.aspectRatio = .ratio9x16
        case .ratio5x4, .ratio4x5, .ratio21x9, .customRatio: config.cropTransform.aspectRatio = .custom
        }

        let dims = orientedSourceDims
        guard let targetPixelRatio = config.cropTransform.resolvedAspectRatio(sourceWidth: dims.width, sourceHeight: dims.height),
              targetPixelRatio > 0 else {
            return
        }

        let imageRatio = Double(max(1, dims.width)) / Double(max(1, dims.height))
        let normTargetRatio = targetPixelRatio / max(0.0001, imageRatio)
        let current = activeNormRect
        let cx = current.x + current.width / 2.0
        let cy = current.y + current.height / 2.0

        var newW = current.width
        var newH = newW / normTargetRatio
        if newH > 0.96 {
            newH = 0.96
            newW = newH * normTargetRatio
        }
        if newW > 0.96 {
            newW = 0.96
            newH = newW / normTargetRatio
        }
        let clampedX = max(0.0, min(1.0 - newW, cx - newW / 2.0))
        let clampedY = max(0.0, min(1.0 - newH, cy - newH / 2.0))
        config.cropTransform.normalizedRect = NormalizedRect(x: clampedX, y: clampedY, width: newW, height: newH)
    }

    private func resizedNormalizedRect(
        from start: NormalizedRect,
        handle: CropDragHandle,
        dx: Double,
        dy: Double
    ) -> NormalizedRect {
        let minFrac = 0.04
        var left = start.x
        var right = start.x + start.width
        var top = start.y
        var bottom = start.y + start.height

        switch handle {
        case .topLeft:
            left = min(right - minFrac, max(0.0, left + dx))
            top = min(bottom - minFrac, max(0.0, top + dy))
        case .top:
            top = min(bottom - minFrac, max(0.0, top + dy))
        case .topRight:
            right = max(left + minFrac, min(1.0, right + dx))
            top = min(bottom - minFrac, max(0.0, top + dy))
        case .right:
            right = max(left + minFrac, min(1.0, right + dx))
        case .bottomRight:
            right = max(left + minFrac, min(1.0, right + dx))
            bottom = max(top + minFrac, min(1.0, bottom + dy))
        case .bottom:
            bottom = max(top + minFrac, min(1.0, bottom + dy))
        case .bottomLeft:
            left = min(right - minFrac, max(0.0, left + dx))
            bottom = max(top + minFrac, min(1.0, bottom + dy))
        case .left:
            left = min(right - minFrac, max(0.0, left + dx))
        }

        let dims = orientedSourceDims
        if let pixelRatio = config.cropTransform.resolvedAspectRatio(sourceWidth: dims.width, sourceHeight: dims.height),
           pixelRatio > 0 {
            let imgRatio = Double(max(1, dims.width)) / Double(max(1, dims.height))
            let normRatio = pixelRatio / max(0.0001, imgRatio)

            var w = max(minFrac, right - left)
            var h = max(minFrac, bottom - top)

            switch handle {
            case .left, .right:
                h = w / normRatio
                let midY = (top + bottom) / 2.0
                top = max(0.0, min(1.0 - h, midY - h / 2.0))
                if top + h > 1.0 {
                    h = 1.0 - top
                    w = h * normRatio
                    if handle == .left { left = right - w } else { right = left + w }
                }
                bottom = top + h

            case .top, .bottom:
                w = h * normRatio
                let midX = (left + right) / 2.0
                left = max(0.0, min(1.0 - w, midX - w / 2.0))
                if left + w > 1.0 {
                    w = 1.0 - left
                    h = w / normRatio
                    if handle == .top { top = bottom - h } else { bottom = top + h }
                }
                right = left + w

            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                h = w / normRatio
                let anchorTop = (handle == .bottomLeft || handle == .bottomRight)
                let anchorLeft = (handle == .topRight || handle == .bottomRight)

                if anchorTop {
                    if top + h > 1.0 {
                        h = 1.0 - top
                        w = h * normRatio
                    }
                    bottom = top + h
                } else {
                    if bottom - h < 0.0 {
                        h = bottom
                        w = h * normRatio
                    }
                    top = bottom - h
                }

                if anchorLeft {
                    right = min(1.0, left + w)
                    w = right - left
                    h = w / normRatio
                    if anchorTop { bottom = min(1.0, top + h) } else { top = max(0.0, bottom - h) }
                } else {
                    left = max(0.0, right - w)
                    w = right - left
                    h = w / normRatio
                    if anchorTop { bottom = min(1.0, top + h) } else { top = max(0.0, bottom - h) }
                }
            }
        }

        return NormalizedRect(
            x: max(0.0, min(1.0 - minFrac, left)),
            y: max(0.0, min(1.0 - minFrac, top)),
            width: max(minFrac, min(1.0 - left, right - left)),
            height: max(minFrac, min(1.0 - top, bottom - top))
        )
    }

    private func fittedImageRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        let pad: CGFloat = 20.0
        let availW = max(1, containerSize.width - pad * 2)
        let availH = max(1, containerSize.height - pad * 2)
        let scale = min(availW / max(1, imageSize.width), availH / max(1, imageSize.height))
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - w) / 2.0,
            y: (containerSize.height - h) / 2.0,
            width: w,
            height: h
        )
    }
}

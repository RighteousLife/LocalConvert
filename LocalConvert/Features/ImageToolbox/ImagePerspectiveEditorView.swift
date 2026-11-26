import SwiftUI
import AppKit

// MARK: - Interactive 4-Corner Perspective Correction Editor

struct ImagePerspectiveEditorView: View {
    @Binding var config: ImageToolboxConfig
    let previewImage: NSImage?
    let outputFormat: FileFormat
    var store: ImageToolboxStore? = nil
    var sourceURL: URL? = nil

    @State private var correctedPreview: NSImage?
    @State private var showComparison: Bool = false
    @State private var isProcessingPreview: Bool = false
    @State private var statusNote: String? = nil
    @State private var isDraggingCorner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(padding: 0) {
                VStack(spacing: 0) {
                    toolbar
                    AppDivider()
                    canvasViewport
                        .frame(minHeight: 320, maxHeight: 420)
                        .background(AppTheme.Colors.elevatedSurface)
                        .clipped()
                    AppDivider()
                    HStack {
                        Text(showComparison ? "Showing rectified output vs original quad." : "Drag any of the 4 corner handles to define the document or plane boundary.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let statusNote {
                            Text(statusNote)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.accent)
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(AppTheme.Colors.subtleSurface)
                }
            }

            AppCard(title: "Projective Fill & Actions", icon: "perspective") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Toggle("Enable Perspective Correction on Export", isOn: $config.perspective.enabled)
                        .fontWeight(.medium)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            Text("Outer Fill Mode:")
                                .fixedSize()
                            fillPicker
                                .pickerStyle(.segmented)
                                .fixedSize()
                            if config.perspective.fillMode == .custom {
                                customFillPicker
                            }
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Outer Fill Mode:").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                            HStack {
                                fillPicker.pickerStyle(.menu)
                                if config.perspective.fillMode == .custom { customFillPicker }
                            }
                        }
                    }

                    if config.perspective.fillMode == .transparent
                        && !FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency {
                        AppInfoBanner(
                            style: .warning,
                            message: "\(outputFormat.shortExtensionLabel) does not support transparency; edges outside the warped plane will be filled black/opaque."
                        )
                    }
                }
            }
        }
        .onChange(of: config.perspective) { _, _ in
            if showComparison { refreshRectifiedPreview() }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.sm) {
                detectButton
                resetButton
                Spacer(minLength: AppTheme.Spacing.sm)
                compareToggleButton
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    detectButton
                    resetButton
                }
                compareToggleButton
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var detectButton: some View {
        Button {
            autoDetectCorners()
        } label: {
            Label("Auto Detect Quad (Vision)", systemImage: "viewfinder")
        }
        .controlSize(.small)
        .disabled(previewImage == nil)
    }

    private var resetButton: some View {
        Button("Reset Corners") {
            config.perspective = .fullFrame
            statusNote = "Corners reset to full frame."
        }
        .controlSize(.small)
    }

    private var compareToggleButton: some View {
        Button {
            showComparison.toggle()
            if showComparison {
                refreshRectifiedPreview()
            }
        } label: {
            if isProcessingPreview {
                ProgressView().controlSize(.small)
            } else {
                Label(showComparison ? "Edit Corner Handles" : "Preview Corrected Output", systemImage: showComparison ? "slider.horizontal.3" : "eye")
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(previewImage == nil)
    }

    @ViewBuilder
    private var canvasViewport: some View {
        if showComparison, let corrected = correctedPreview, let before = previewImage {
            ImageLivePreviewCanvas(
                beforeImage: before,
                afterImage: corrected,
                beforeFormat: "INPUT",
                afterFormat: "RECTIFIED",
                telemetry: nil,
                isLoading: isProcessingPreview,
                statusText: "Rectifying perspective...",
                minCanvasHeight: 300
            )
        } else if let nsImg = previewImage {
            GeometryReader { geo in
                let fitRect = fittedImageRect(imageSize: nsImg.size, in: geo.size)
                ZStack {
                    CheckerboardPattern()
                    Image(nsImage: nsImg)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitRect.width, height: fitRect.height)
                        .position(x: fitRect.midX, y: fitRect.midY)

                    quadOverlay(in: fitRect)
                }
            }
        } else {
            Text("Load an image to adjust perspective corners.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func quadOverlay(in rect: CGRect) -> some View {
        let tl = CGPoint(x: rect.minX + CGFloat(config.perspective.topLeft.x) * rect.width,
                         y: rect.minY + CGFloat(config.perspective.topLeft.y) * rect.height)
        let tr = CGPoint(x: rect.minX + CGFloat(config.perspective.topRight.x) * rect.width,
                         y: rect.minY + CGFloat(config.perspective.topRight.y) * rect.height)
        let br = CGPoint(x: rect.minX + CGFloat(config.perspective.bottomRight.x) * rect.width,
                         y: rect.minY + CGFloat(config.perspective.bottomRight.y) * rect.height)
        let bl = CGPoint(x: rect.minX + CGFloat(config.perspective.bottomLeft.x) * rect.width,
                         y: rect.minY + CGFloat(config.perspective.bottomLeft.y) * rect.height)

        return ZStack {
            Path { p in
                p.move(to: tl)
                p.addLine(to: tr)
                p.addLine(to: br)
                p.addLine(to: bl)
                p.closeSubpath()
            }
            .stroke(AppTheme.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))

            cornerHandle(position: tl, label: "TL", in: rect, pointBinding: $config.perspective.topLeft)
            cornerHandle(position: tr, label: "TR", in: rect, pointBinding: $config.perspective.topRight)
            cornerHandle(position: br, label: "BR", in: rect, pointBinding: $config.perspective.bottomRight)
            cornerHandle(position: bl, label: "BL", in: rect, pointBinding: $config.perspective.bottomLeft)
        }
    }

    private func cornerHandle(
        position: CGPoint,
        label: String,
        in rect: CGRect,
        pointBinding: Binding<CodableNormalizedPoint>
    ) -> some View {
        Circle()
            .fill(AppTheme.Colors.accent)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .overlay(Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(.white))
            .position(position)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Perspective corner \(label)")
            .accessibilityValue("X \(Int((pointBinding.wrappedValue.x * 100).rounded())) percent, Y \(Int((pointBinding.wrappedValue.y * 100).rounded())) percent")
            .accessibilityHint("Drag to reposition perspective corner")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDraggingCorner {
                            isDraggingCorner = true
                            store?.beginContinuousEdit(for: sourceURL)
                        }
                        let nx = max(0.0, min(1.0, Double((value.location.x - rect.minX) / max(1, rect.width))))
                        let ny = max(0.0, min(1.0, Double((value.location.y - rect.minY) / max(1, rect.height))))
                        pointBinding.wrappedValue = CodableNormalizedPoint(id: pointBinding.wrappedValue.id, x: nx, y: ny)
                        config.perspective.enabled = true
                    }
                    .onEnded { _ in
                        if isDraggingCorner {
                            isDraggingCorner = false
                            store?.endContinuousEdit(for: sourceURL, explicitType: .imageCrop, explicitTitle: "Perspective Crop")
                        }
                    }
            )
    }

    private var fillPicker: some View {
        Picker("Fill Mode", selection: $config.perspective.fillMode) {
            ForEach(ImagePerspectiveFillMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .labelsHidden()
    }

    private var customFillPicker: some View {
        ColorPicker("Fill Color", selection: Binding(
            get: { config.perspective.customColor.swiftUIColor },
            set: { config.perspective.customColor = CodableRGBAColor(swiftUIColor: $0) }
        ))
        .labelsHidden()
    }

    private func fittedImageRect(imageSize: NSSize, in containerSize: CGSize) -> CGRect {
        let pad: CGFloat = 18
        let availW = max(1, containerSize.width - pad * 2)
        let availH = max(1, containerSize.height - pad * 2)
        let imgAspect = max(0.01, imageSize.width / max(1, imageSize.height))
        let boxAspect = availW / availH
        let drawW = (imgAspect > boxAspect) ? availW : (availH * imgAspect)
        let drawH = (imgAspect > boxAspect) ? (availW / imgAspect) : availH
        return CGRect(x: (containerSize.width - drawW) / 2.0, y: (containerSize.height - drawH) / 2.0, width: drawW, height: drawH)
    }

    private func autoDetectCorners() {
        guard let nsImg = previewImage,
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if let detected = ImagePerspectiveService.detectRectangleCorners(in: cg) {
            config.perspective.topLeft = detected.topLeft
            config.perspective.topRight = detected.topRight
            config.perspective.bottomRight = detected.bottomRight
            config.perspective.bottomLeft = detected.bottomLeft
            config.perspective.enabled = true
            statusNote = "Rectangle detected cleanly."
        } else {
            statusNote = "No high-confidence quad detected; adjust handles manually."
        }
    }

    private func refreshRectifiedPreview() {
        guard let nsImg = previewImage,
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let pCfg = config.perspective
        let outFmt = outputFormat
        isProcessingPreview = true
        Task.detached(priority: .userInitiated) {
            var active = pCfg
            active.enabled = true
            let result = try? ImagePerspectiveService.apply(cgImage: cg, config: active, outputFormat: outFmt)
            let outNS = result.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            await MainActor.run {
                self.correctedPreview = outNS
                self.isProcessingPreview = false
            }
        }
    }
}

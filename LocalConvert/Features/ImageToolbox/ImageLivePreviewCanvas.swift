import SwiftUI
import AppKit

// MARK: - Unified Live Image Preview Canvas

struct ImageLivePreviewCanvas: View {
    enum ViewMode: String, CaseIterable, Identifiable {
        case splitSlider = "Split Slider"
        case sideBySide = "Side-by-Side"
        case resultOnly = "Result"

        var id: String { rawValue }
    }

    let beforeImage: NSImage?
    let afterImage: NSImage?
    let beforeFormat: String
    let afterFormat: String
    let telemetry: ImageProcessingTelemetry?
    let isLoading: Bool
    let statusText: String
    var minCanvasHeight: CGFloat = 290
    var showFullRenderButton: Bool = false
    var fullRenderButtonTitle: String = "Render Full"
    var emptyTitle: String = "Generating Live Preview..."
    var emptySubtitle: String = "Adjust parameters below to inspect output in real time."
    var onRenderFull: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    @State private var mode: ViewMode = .splitSlider
    @State private var splitRatio: CGFloat = 0.5
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var isHoldingBefore: Bool = false

    var body: some View {
        AppCard(padding: 0) {
            VStack(spacing: 0) {
                toolbar
                AppDivider()
                canvasArea
                    .frame(minHeight: minCanvasHeight, maxHeight: .infinity)
                    .background(AppTheme.Colors.elevatedSurface)
                    .clipped()

                if let tel = telemetry {
                    AppDivider()
                    compactTelemetryBar(tel)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.md) {
                modePicker
                AppDivider().frame(width: 1, height: 18)
                zoomControls
                Spacer(minLength: AppTheme.Spacing.sm)
                statusAndRenderControls
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    modePicker
                    Spacer(minLength: 0)
                    statusAndRenderControls
                }
                HStack(spacing: AppTheme.Spacing.xs) {
                    zoomControls
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    modePicker
                    Spacer(minLength: 0)
                }
                HStack(spacing: AppTheme.Spacing.xs) {
                    zoomControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: AppTheme.Spacing.xs) {
                    statusAndRenderControls
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var modePicker: some View {
        Picker("Preview Mode", selection: $mode) {
            ForEach(ViewMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var zoomControls: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Button("Fit") { setZoom(1.0, resetPan: true) }
                .controlSize(.small)
                .fixedSize()
                .help("Fit image to viewport")
                .accessibilityLabel("Fit image to viewport")

            Button("100%") { setZoom(actualSizeZoomFactor(), resetPan: true) }
                .controlSize(.small)
                .fixedSize()
                .help("Actual pixel size preview")
                .accessibilityLabel("Actual pixel size 100 percent")

            Button {
                setZoom(max(0.25, zoomScale / 1.25))
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Zoom Out")
            .accessibilityLabel("Zoom out")

            Button {
                setZoom(min(6.0, zoomScale * 1.25))
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Zoom In")
            .accessibilityLabel("Zoom in")

            Text("\(Int((zoomScale * 100).rounded()))%")
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .fixedSize()
                .accessibilityLabel("Zoom level \(Int((zoomScale * 100).rounded())) percent")
        }
    }

    @ViewBuilder
    private var statusAndRenderControls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if isLoading {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusText.isEmpty ? "Updating preview..." : statusText)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let onCancel {
                        Button("Cancel", action: onCancel)
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
            }

            if showFullRenderButton, let onRenderFull, !isLoading {
                Button(action: onRenderFull) {
                    Label(fullRenderButtonTitle, systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }

            if beforeImage != nil {
                Label("Hold Before", systemImage: isHoldingBefore ? "eye.fill" : "eye")
                    .font(AppTheme.Typography.caption.weight(.medium))
                    .foregroundStyle(isHoldingBefore ? Color.accentColor : Color.primary)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(isHoldingBefore ? Color.accentColor.opacity(0.16) : AppTheme.Colors.elevatedSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(isHoldingBefore ? Color.accentColor : AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                    .fixedSize()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !isHoldingBefore { isHoldingBefore = true }
                            }
                            .onEnded { _ in
                                isHoldingBefore = false
                            }
                    )
                    .help("Press and hold to view the unprocessed original image")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Hold to view original image")
                    .accessibilityValue(isHoldingBefore ? "Showing original" : "Showing edited")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        isHoldingBefore.toggle()
                    }
            }
        }
    }

    // MARK: - Canvas Rendering

    @ViewBuilder
    private var canvasArea: some View {
        if let after = afterImage ?? beforeImage {
            let before = beforeImage ?? after
            Group {
                if isHoldingBefore {
                    singleImageView(image: before, badgeText: beforeBadgeText)
                } else {
                    switch mode {
                    case .splitSlider:
                        splitSliderView(before: before, after: after)
                    case .sideBySide:
                        sideBySideView(before: before, after: after)
                    case .resultOnly:
                        singleImageView(image: after, badgeText: afterBadgeText)
                    }
                }
            }
            .onTapGesture(count: 2) {
                if abs(zoomScale - 1.0) < 0.05 {
                    setZoom(2.0)
                } else {
                    setZoom(1.0, resetPan: true)
                }
            }
        } else {
            VStack(spacing: AppTheme.Spacing.sm) {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                }
                Text(emptyTitle)
                    .font(AppTheme.Typography.cardTitle)
                Text(emptySubtitle)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                if showFullRenderButton, let onRenderFull, !isLoading {
                    Button(fullRenderButtonTitle, action: onRenderFull)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppTheme.Spacing.lg)
        }
    }

    private func splitSliderView(before: NSImage, after: NSImage) -> some View {
        GeometryReader { geo in
            let dividerX = geo.size.width * splitRatio

            ZStack {
                CheckerboardPattern()

                Image(nsImage: before)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoomScale)
                    .offset(panOffset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: dividerX, height: geo.size.height)
                    }

                Image(nsImage: after)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoomScale)
                    .offset(panOffset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: max(0, geo.size.width - dividerX), height: geo.size.height)
                    }

                // Divider Bar & Handle
                HStack {
                    Spacer().frame(width: max(0, dividerX - 1))
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .overlay {
                            Circle()
                                .fill(AppTheme.Colors.accent)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                                }
                                .overlay {
                                    Image(systemName: "arrow.left.and.right")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                }
                                .gesture(
                                    DragGesture(coordinateSpace: .named("livePreviewCanvas"))
                                        .onChanged { val in
                                            let next = min(max(val.location.x, 16), max(16, geo.size.width - 16))
                                            splitRatio = next / max(1, geo.size.width)
                                        }
                                )
                        }
                    Spacer()
                }

                VStack {
                    HStack {
                        labelBadge(beforeBadgeText)
                        Spacer()
                        labelBadge(afterBadgeText)
                    }
                    .padding(AppTheme.Spacing.sm)
                    Spacer()
                }
            }
            .coordinateSpace(name: "livePreviewCanvas")
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { val in
                        if zoomScale > 1.01 {
                            let proposed = CGSize(
                                width: dragStartOffset.width + val.translation.width,
                                height: dragStartOffset.height + val.translation.height
                            )
                            panOffset = clampedPan(proposed, in: geo.size, zoom: zoomScale)
                        } else {
                            splitRatio = min(max(val.location.x / max(1, geo.size.width), 0.02), 0.98)
                        }
                    }
                    .onEnded { _ in
                        dragStartOffset = panOffset
                    }
            )
        }
    }

    private func sideBySideView(before: NSImage, after: NSImage) -> some View {
        GeometryReader { geo in
            let paneSize = CGSize(width: max(1, (geo.size.width - 28) / 2), height: max(1, geo.size.height - 36))
            HStack(spacing: AppTheme.Spacing.sm) {
                VStack(spacing: AppTheme.Spacing.xs) {
                    Text(beforeBadgeText)
                        .font(AppTheme.Typography.badge)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ZStack {
                        CheckerboardPattern()
                        Image(nsImage: before)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(zoomScale)
                            .offset(panOffset)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                }

                VStack(spacing: AppTheme.Spacing.xs) {
                    Text(afterBadgeText)
                        .font(AppTheme.Typography.badge)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ZStack {
                        CheckerboardPattern()
                        Image(nsImage: after)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(zoomScale)
                            .offset(panOffset)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                }
            }
            .padding(AppTheme.Spacing.sm)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { val in
                        guard zoomScale > 1.01 else { return }
                        let proposed = CGSize(
                            width: dragStartOffset.width + val.translation.width,
                            height: dragStartOffset.height + val.translation.height
                        )
                        panOffset = clampedPan(proposed, in: paneSize, zoom: zoomScale)
                    }
                    .onEnded { _ in
                        dragStartOffset = panOffset
                    }
            )
        }
    }

    private func singleImageView(image: NSImage, badgeText: String) -> some View {
        GeometryReader { geo in
            ZStack {
                CheckerboardPattern()
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoomScale)
                    .offset(panOffset)
                    .frame(width: geo.size.width, height: geo.size.height)

                VStack {
                    HStack {
                        Spacer()
                        labelBadge(badgeText)
                    }
                    .padding(AppTheme.Spacing.sm)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { val in
                        guard zoomScale > 1.01 else { return }
                        let proposed = CGSize(
                            width: dragStartOffset.width + val.translation.width,
                            height: dragStartOffset.height + val.translation.height
                        )
                        panOffset = clampedPan(proposed, in: geo.size, zoom: zoomScale)
                    }
                    .onEnded { _ in
                        dragStartOffset = panOffset
                    }
            )
        }
    }

    private var beforeBadgeText: String {
        if let tel = telemetry {
            return "BEFORE · \(beforeFormat) · \(tel.originalWidth)×\(tel.originalHeight)"
        }
        return "BEFORE · \(beforeFormat)"
    }

    private var afterBadgeText: String {
        if let tel = telemetry {
            return "AFTER · \(afterFormat) · \(tel.outputWidth)×\(tel.outputHeight)"
        }
        return "AFTER · \(afterFormat)"
    }

    @ViewBuilder
    private func compactTelemetryBar(_ tel: ImageProcessingTelemetry) -> some View {
        let origStr = ByteCountFormatter.string(fromByteCount: tel.originalBytes, countStyle: .file)
        let newStr = ByteCountFormatter.string(fromByteCount: tel.processedBytes, countStyle: .file)
        let delta = tel.sizeReductionPercent

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md) {
                    Text("\(tel.originalWidth)×\(tel.originalHeight) → \(tel.outputWidth)×\(tel.outputHeight) px")
                        .font(AppTheme.Typography.monoCaption)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(origStr) → \(newStr)")
                        .font(AppTheme.Typography.monoCaption.weight(.medium))
                    AppStatusBadge(
                        text: delta >= 0
                            ? "-\(String(format: "%.1f", delta))%"
                            : "+\(String(format: "%.1f", abs(delta)))%",
                        tint: delta >= 0 ? AppTheme.Colors.success : AppTheme.Colors.warning
                    )
                    Spacer(minLength: 0)
                    if let q = tel.finalQuality {
                        Text("Q \(Int((q * 100).rounded()))%")
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("\(tel.originalWidth)×\(tel.originalHeight) → \(tel.outputWidth)×\(tel.outputHeight) px")
                        .font(AppTheme.Typography.monoCaption)
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("\(origStr) → \(newStr)")
                            .font(AppTheme.Typography.monoCaption.weight(.medium))
                        AppStatusBadge(
                            text: delta >= 0
                                ? "-\(String(format: "%.1f", delta))%"
                                : "+\(String(format: "%.1f", abs(delta)))%",
                            tint: delta >= 0 ? AppTheme.Colors.success : AppTheme.Colors.warning
                        )
                    }
                }
            }

            if !tel.warnings.isEmpty {
                ForEach(tel.warnings, id: \.self) { warn in
                    AppInfoBanner(style: .warning, message: warn)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    private func labelBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
    }

    private func actualSizeZoomFactor() -> CGFloat {
        // Compute a crisp actual-pixel zoom multiplier when source image is smaller or larger than viewport
        guard let img = afterImage ?? beforeImage, img.size.height > 0 else { return 1.0 }
        let ratio = img.size.height / max(1.0, minCanvasHeight)
        return max(1.0, min(4.0, ratio))
    }

    private func setZoom(_ newScale: CGFloat, resetPan: Bool = false) {
        zoomScale = newScale
        if resetPan || newScale <= 1.0 {
            panOffset = .zero
            dragStartOffset = .zero
        }
    }

    private func clampedPan(_ offset: CGSize, in containerSize: CGSize, zoom: CGFloat) -> CGSize {
        guard zoom > 1.0 else { return .zero }
        let maxX = max(0, (containerSize.width * (zoom - 1.0)) / 2.0)
        let maxY = max(0, (containerSize.height * (zoom - 1.0)) / 2.0)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}

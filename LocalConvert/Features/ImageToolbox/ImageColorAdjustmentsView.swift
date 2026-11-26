import SwiftUI
import AppKit

// MARK: - Professional Color & Light Editor View

struct ImageColorAdjustmentsView: View {
    enum SubTab: String, CaseIterable, Identifiable {
        case lightAndColor = "Light & Color"
        case curvesAndLevels = "Curves & Levels"
        case colorBalance = "Color Balance"
        case histogram = "Live Histogram"

        var id: String { rawValue }
    }

    @ObservedObject var store: ImageToolboxStore
    let url: URL?
    @Binding var config: ImageToolboxConfig
    let livePreviewImage: NSImage?
    let beforePreviewImage: NSImage?
    let colorInfo: ImageColorProfileInfo?

    @State private var activeTab: SubTab = .lightAndColor
    @State private var selectedCurveChannel: ImageToneChannel = .master
    @State private var selectedLevelsChannel: ImageToneChannel = .master
    @State private var selectedBalanceRegion: ImageTonalRegion = .midtones
    @State private var selectedCurvePointID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            headerControls

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                ForEach(SubTab.allCases) { tab in
                    let selected = (activeTab == tab)
                    Button(tab.rawValue) { activeTab = tab }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .tint(selected ? AppTheme.Colors.accent : .secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(tab.rawValue)
                        .accessibilityValue(selected ? "Selected" : "")
                }
            }

            switch activeTab {
            case .lightAndColor:
                lightCard
                whiteBalanceAndColorCard
            case .curvesAndLevels:
                curvesCard
                levelsCard
            case .colorBalance:
                colorBalanceCard
            case .histogram:
                ImageHistogramAnalysisCardView(
                    previewImage: livePreviewImage ?? beforePreviewImage,
                    colorInfo: colorInfo
                )
            }
        }
    }

    // MARK: - Master Toggle & Reset

    private var headerControls: some View {
        AppCard(padding: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                Toggle("Enable Color & Tone Adjustments", isOn: $config.colorAdjustments.isEnabled)
                    .fontWeight(.medium)
                    .help("Temporarily bypass all color and tone edits for quick A/B visual comparison")

                Spacer(minLength: AppTheme.Spacing.sm)

                if config.colorAdjustments.hasActiveAdjustments {
                    AppStatusBadge(text: "Active", tint: AppTheme.Colors.accent)
                }

                Button("Reset Color & Light") {
                    store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Color & Light") {
                        $0.colorAdjustments.resetAll()
                    }
                    selectedCurvePointID = nil
                }
                .controlSize(.small)
                .disabled(!config.colorAdjustments.hasActiveAdjustments && config.colorAdjustments.isEnabled)
                .accessibilityLabel("Reset Color & Light")
            }
        }
    }

    // MARK: - 1. Light & Tone Card

    private var lightCard: some View {
        AppCard(title: "Light & Tone", icon: "sun.max") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Spacer()
                    Button("Reset Light") {
                        store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Light") {
                            $0.colorAdjustments.resetLight()
                        }
                    }
                    .controlSize(.small)
                }

                sliderRow(title: "Exposure", value: $config.colorAdjustments.exposureEV, range: -5.0...5.0, format: { String(format: "%+.2f EV", $0) }, undoTitle: "Exposure")
                sliderRow(title: "Brightness", value: $config.colorAdjustments.brightness, range: -0.5...0.5, format: { String(format: "%+.2f", $0) }, undoTitle: "Brightness")
                sliderRow(title: "Contrast", value: $config.colorAdjustments.contrast, range: 0.25...2.5, format: { String(format: "%.2f", $0) }, undoTitle: "Contrast")
                AppDivider()
                sliderRow(title: "Highlights", value: $config.colorAdjustments.highlights, range: -1.0...1.0, format: { String(format: "%+.2f", $0) }, undoTitle: "Highlights")
                sliderRow(title: "Shadows", value: $config.colorAdjustments.shadows, range: -1.0...1.0, format: { String(format: "%+.2f", $0) }, undoTitle: "Shadows")
                sliderRow(title: "Whites", value: $config.colorAdjustments.whites, range: -1.0...1.0, format: { String(format: "%+.2f", $0) }, undoTitle: "Whites")
                sliderRow(title: "Blacks", value: $config.colorAdjustments.blacks, range: -1.0...1.0, format: { String(format: "%+.2f", $0) }, undoTitle: "Blacks")
                sliderRow(title: "Gamma", value: $config.colorAdjustments.gamma, range: 0.25...3.0, format: { String(format: "%.2f", $0) }, undoTitle: "Gamma")
            }
        }
    }

    // MARK: - 2. White Balance & Color Card

    private var whiteBalanceAndColorCard: some View {
        AppCard(title: "White Balance & Color", icon: "thermometer.medium") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Spacer()
                    Button("Reset Color") {
                        store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Color") {
                            $0.colorAdjustments.resetColor()
                        }
                    }
                    .controlSize(.small)
                }

                sliderRow(title: "Temperature", value: $config.colorAdjustments.temperatureOffset, range: -100.0...100.0, format: { String(format: "%+.0f", $0) }, undoTitle: "Temperature")
                sliderRow(title: "Tint", value: $config.colorAdjustments.tintOffset, range: -100.0...100.0, format: { String(format: "%+.0f", $0) }, undoTitle: "Tint")
                AppDivider()
                sliderRow(title: "Saturation", value: $config.colorAdjustments.saturation, range: 0.0...2.0, format: { String(format: "%.2f", $0) }, undoTitle: "Saturation")
                sliderRow(title: "Vibrance", value: $config.colorAdjustments.vibrance, range: -1.0...1.0, format: { String(format: "%+.2f", $0) }, undoTitle: "Vibrance")
                sliderRow(title: "Hue", value: $config.colorAdjustments.hueDegrees, range: -180.0...180.0, format: { String(format: "%+.0f°", $0) }, undoTitle: "Hue")
            }
        }
    }

    // MARK: - 3. Curves Card

    private var curvesCard: some View {
        AppCard(title: "Tone Curves (Spline)", icon: "point.topleft.down.curvedto.point.bottomright.up") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Picker("Curve Channel", selection: $selectedCurveChannel) {
                            ForEach(ImageToneChannel.allCases) { ch in
                                Text(ch.rawValue).tag(ch)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)

                        Spacer()
                        curvesHeaderButtons
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                        Picker("Curve Channel", selection: $selectedCurveChannel) {
                            ForEach(ImageToneChannel.allCases) { ch in
                                Text(ch.rawValue).tag(ch)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        HStack(spacing: AppTheme.Spacing.sm) {
                            Spacer(minLength: 0)
                            curvesHeaderButtons
                        }
                    }
                }

                ToneCurveEditorCanvas(
                    points: Binding(
                        get: { config.colorAdjustments.curves[selectedCurveChannel] },
                        set: { newPts in
                            config.colorAdjustments.curves[selectedCurveChannel] = newPts
                        }
                    ),
                    channel: selectedCurveChannel,
                    selectedPointID: $selectedCurvePointID,
                    onBeginDrag: { store.beginContinuousEdit(for: url) },
                    onEndDrag: { store.endContinuousEdit(for: url, explicitType: .imageConfigEdit, explicitTitle: "Tone Curve") }
                )
                .frame(height: 220)

                Text("Click curve to add a point · Drag points to sculpt tone · Double-click interior point or click Remove Point to delete.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var curvesHeaderButtons: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let selID = selectedCurvePointID,
               let idx = config.colorAdjustments.curves[selectedCurveChannel].firstIndex(where: { $0.id == selID }),
               idx > 0, idx < config.colorAdjustments.curves[selectedCurveChannel].count - 1 {
                Button("Remove Point") {
                    store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Edit Tone Curve") { cfg in
                        var pts = cfg.colorAdjustments.curves[selectedCurveChannel]
                        pts.removeAll { $0.id == selID }
                        cfg.colorAdjustments.curves[selectedCurveChannel] = pts
                    }
                    selectedCurvePointID = nil
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }

            Button("Reset Channel") {
                store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Tone Curve") { cfg in
                    cfg.colorAdjustments.curves[selectedCurveChannel] = ImageCurvesConfig.defaultPoints
                }
                selectedCurvePointID = nil
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 4. Levels Card

    private var levelsCard: some View {
        let lvl = config.colorAdjustments.levels[selectedLevelsChannel]
        return AppCard(title: "Levels", icon: "slider.horizontal.below.rectangle") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Picker("Levels Channel", selection: $selectedLevelsChannel) {
                        ForEach(ImageToneChannel.allCases) { ch in
                            Text(ch.rawValue).tag(ch)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    Spacer()
                    Button("Reset Channel") {
                        store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Levels") { cfg in
                            cfg.colorAdjustments.levels[selectedLevelsChannel] = ImageChannelLevels()
                        }
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }

                sliderRow(
                    title: "Input Black",
                    value: Binding(
                        get: { lvl.blackPoint },
                        set: { val in
                            var next = lvl
                            next.blackPoint = min(val, next.whitePoint - 0.02)
                            next.clamped()
                            config.colorAdjustments.levels[selectedLevelsChannel] = next
                        }
                    ),
                    range: 0.0...0.95,
                    format: { String(format: "%.0f", $0 * 255.0) },
                    undoTitle: "Levels"
                )
                sliderRow(
                    title: "Midtone Gamma",
                    value: Binding(
                        get: { lvl.gamma },
                        set: { val in
                            var next = lvl
                            next.gamma = val
                            next.clamped()
                            config.colorAdjustments.levels[selectedLevelsChannel] = next
                        }
                    ),
                    range: 0.2...3.5,
                    format: { String(format: "%.2f", $0) },
                    undoTitle: "Levels"
                )
                sliderRow(
                    title: "Input White",
                    value: Binding(
                        get: { lvl.whitePoint },
                        set: { val in
                            var next = lvl
                            next.whitePoint = max(val, next.blackPoint + 0.02)
                            next.clamped()
                            config.colorAdjustments.levels[selectedLevelsChannel] = next
                        }
                    ),
                    range: 0.05...1.0,
                    format: { String(format: "%.0f", $0 * 255.0) },
                    undoTitle: "Levels"
                )
                AppDivider()
                sliderRow(
                    title: "Output Black",
                    value: Binding(
                        get: { lvl.outBlack },
                        set: { val in
                            var next = lvl
                            next.outBlack = min(val, next.outWhite - 0.01)
                            next.clamped()
                            config.colorAdjustments.levels[selectedLevelsChannel] = next
                        }
                    ),
                    range: 0.0...0.98,
                    format: { String(format: "%.0f", $0 * 255.0) },
                    undoTitle: "Levels"
                )
                sliderRow(
                    title: "Output White",
                    value: Binding(
                        get: { lvl.outWhite },
                        set: { val in
                            var next = lvl
                            next.outWhite = max(val, next.outBlack + 0.01)
                            next.clamped()
                            config.colorAdjustments.levels[selectedLevelsChannel] = next
                        }
                    ),
                    range: 0.02...1.0,
                    format: { String(format: "%.0f", $0 * 255.0) },
                    undoTitle: "Levels"
                )
            }
        }
    }

    // MARK: - 5. Color Balance Card

    private var colorBalanceCard: some View {
        let offset = config.colorAdjustments.colorBalance[selectedBalanceRegion]
        return AppCard(title: "3-Band Color Balance", icon: "paintpalette") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Picker("Tonal Region", selection: $selectedBalanceRegion) {
                        ForEach(ImageTonalRegion.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)

                    Spacer()

                    Button("Reset Region") {
                        store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Color Balance") { cfg in
                            cfg.colorAdjustments.colorBalance[selectedBalanceRegion] = ImageRGBBalanceOffset()
                        }
                    }
                    .controlSize(.small)
                }

                Toggle("Preserve Luminance", isOn: $config.colorAdjustments.colorBalance.preserveLuminance)

                sliderRow(
                    title: "Cyan ↔ Red",
                    value: Binding(
                        get: { offset.cyanRed },
                        set: { v in
                            var next = offset
                            next.cyanRed = v
                            config.colorAdjustments.colorBalance[selectedBalanceRegion] = next
                        }
                    ),
                    range: -1.0...1.0,
                    format: { String(format: "%+.0f%%", $0 * 100.0) },
                    undoTitle: "Color Balance"
                )
                sliderRow(
                    title: "Magenta ↔ Green",
                    value: Binding(
                        get: { offset.magentaGreen },
                        set: { v in
                            var next = offset
                            next.magentaGreen = v
                            config.colorAdjustments.colorBalance[selectedBalanceRegion] = next
                        }
                    ),
                    range: -1.0...1.0,
                    format: { String(format: "%+.0f%%", $0 * 100.0) },
                    undoTitle: "Color Balance"
                )
                sliderRow(
                    title: "Yellow ↔ Blue",
                    value: Binding(
                        get: { offset.yellowBlue },
                        set: { v in
                            var next = offset
                            next.yellowBlue = v
                            config.colorAdjustments.colorBalance[selectedBalanceRegion] = next
                        }
                    ),
                    range: -1.0...1.0,
                    format: { String(format: "%+.0f%%", $0 * 100.0) },
                    undoTitle: "Color Balance"
                )
            }
        }
    }

    // MARK: - Shared Coalesced Slider Helper

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: (Double) -> String,
        undoTitle: String
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(AppTheme.Typography.caption)
                .frame(width: 112, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if editing {
                    store.beginContinuousEdit(for: url)
                } else {
                    store.endContinuousEdit(for: url, explicitType: .imageConfigEdit, explicitTitle: undoTitle)
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(format(value.wrappedValue))
            Text(format(value.wrappedValue))
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - Interactive Spline Tone Curve Canvas

private struct ToneCurveEditorCanvas: View {
    @Binding var points: [ImageCurvePoint]
    let channel: ImageToneChannel
    @Binding var selectedPointID: UUID?
    let onBeginDrag: () -> Void
    let onEndDrag: () -> Void

    @State private var activeDragPointID: UUID? = nil

    private var strokeColor: Color {
        switch channel {
        case .master: return .white
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            let lut = ImageCurvesConfig.buildLUT(points: points, sampleCount: 96)

            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(0.86))

                // Quarter grid & identity diagonal
                Canvas { ctx, size in
                    var grid = Path()
                    for f in [0.25, 0.5, 0.75] {
                        let gx = size.width * CGFloat(f)
                        let gy = size.height * CGFloat(f)
                        grid.move(to: CGPoint(x: gx, y: 0))
                        grid.addLine(to: CGPoint(x: gx, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: gy))
                        grid.addLine(to: CGPoint(x: size.width, y: gy))
                    }
                    ctx.stroke(grid, with: .color(Color.white.opacity(0.14)), lineWidth: 1)

                    var diag = Path()
                    diag.move(to: CGPoint(x: 0, y: size.height))
                    diag.addLine(to: CGPoint(x: size.width, y: 0))
                    ctx.stroke(diag, with: .color(Color.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    var curve = Path()
                    for (i, val) in lut.enumerated() {
                        let px = (CGFloat(i) / CGFloat(max(1, lut.count - 1))) * size.width
                        let py = (1.0 - CGFloat(val)) * size.height
                        if i == 0 { curve.move(to: CGPoint(x: px, y: py)) }
                        else { curve.addLine(to: CGPoint(x: px, y: py)) }
                    }
                    ctx.stroke(curve, with: .color(strokeColor), lineWidth: 2)
                }

                // Control Point Handles
                ForEach(points) { pt in
                    let px = CGFloat(pt.x) * w
                    let py = (1.0 - CGFloat(pt.y)) * h
                    let isSel = (selectedPointID == pt.id)
                    Circle()
                        .fill(isSel ? AppTheme.Colors.accent : strokeColor)
                        .frame(width: isSel ? 12 : 9, height: isSel ? 12 : 9)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.75), lineWidth: 1.5))
                        .position(x: px, y: py)
                        .accessibilityLabel("Curve control point")
                        .accessibilityValue("Input \(Int((pt.x * 100).rounded())) percent, Output \(Int((pt.y * 100).rounded())) percent")
                        .onTapGesture(count: 2) {
                            removeInteriorPoint(id: pt.id)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        let nx = min(1.0, max(0.0, Double(val.location.x / w)))
                        let ny = min(1.0, max(0.0, 1.0 - Double(val.location.y / h)))

                        if activeDragPointID == nil {
                            onBeginDrag()
                            let hitThreshold = 0.045
                            if let nearest = points.min(by: {
                                hypot($0.x - nx, $0.y - ny) < hypot($1.x - nx, $1.y - ny)
                            }), hypot(nearest.x - nx, nearest.y - ny) <= hitThreshold {
                                activeDragPointID = nearest.id
                                selectedPointID = nearest.id
                            } else if points.count < 16 {
                                let created = ImageCurvePoint(x: nx, y: ny)
                                var updated = points + [created]
                                updated = ImageCurvesConfig.normalizedPoints(updated)
                                points = updated
                                activeDragPointID = created.id
                                selectedPointID = created.id
                                return
                            }
                        }

                        guard let dragID = activeDragPointID,
                              var working = Optional(points),
                              let idx = working.firstIndex(where: { $0.id == dragID }) else { return }

                        let isFirst = (idx == 0)
                        let isLast = (idx == working.count - 1)
                        let boundedX: Double
                        if isFirst {
                            boundedX = min(working[min(1, working.count - 1)].x - 0.02, max(0.0, nx))
                        } else if isLast {
                            boundedX = max(working[max(0, working.count - 2)].x + 0.02, min(1.0, nx))
                        } else {
                            boundedX = min(working[idx + 1].x - 0.015, max(working[idx - 1].x + 0.015, nx))
                        }
                        working[idx] = ImageCurvePoint(id: dragID, x: boundedX, y: ny)
                        points = working
                    }
                    .onEnded { _ in
                        if activeDragPointID != nil {
                            activeDragPointID = nil
                            onEndDrag()
                        }
                    }
            )
        }
    }

    private func removeInteriorPoint(id: UUID) {
        guard let idx = points.firstIndex(where: { $0.id == id }),
              idx > 0, idx < points.count - 1 else { return }
        onBeginDrag()
        var next = points
        next.remove(at: idx)
        points = next
        selectedPointID = nil
        onEndDrag()
    }
}

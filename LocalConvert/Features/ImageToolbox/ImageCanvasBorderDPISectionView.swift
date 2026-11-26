import SwiftUI

// MARK: - Canvas Extension, Border/Frame & DPI/PPI Cards

struct ImageCanvasExtensionCardView: View {
    @Binding var config: ImageToolboxConfig
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let outputFormat: FileFormat
    let telemetry: ImageProcessingTelemetry?

    private var baseDims: (width: Int, height: Int) {
        let rawW = sourceDims?.width ?? 1000
        let rawH = sourceDims?.height ?? 1000
        var c = ImageDimensionCalculator.croppedDimensions(sourceWidth: rawW, sourceHeight: rawH, crop: config.cropTransform)
        if config.resizeStrategy != .none {
            c = ImageDimensionCalculator.resizedDimensions(
                currentWidth: c.width,
                currentHeight: c.height,
                strategy: config.resizeStrategy,
                width: config.resizeWidth,
                height: config.resizeHeight,
                percentage: config.resizePercentage,
                preserveAspectRatio: config.preserveAspectRatio
            )
        }
        if config.upscale.enabled {
            let u = ImageDimensionCalculator.upscaledDimensions(currentWidth: c.width, currentHeight: c.height, upscale: config.upscale)
            c = (u.width, u.height)
        }
        return c
    }

    private var outDims: (width: Int, height: Int) {
        ImageDimensionCalculator.extendedCanvasDimensions(
            currentWidth: baseDims.width,
            currentHeight: baseDims.height,
            canvas: config.canvasExtension
        )
    }

    private var targetSupportsAlpha: Bool {
        FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Canvas Extension & Padding (No Pixel Scaling)", icon: "rectangle.expand.vertical") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Toggle("Enable Canvas Extension on Export", isOn: $config.canvasExtension.enabled)
                                .fontWeight(.medium)
                            Spacer()
                            AppStatusBadge(
                                text: config.canvasExtension.enabled ? "\(baseDims.width)×\(baseDims.height) → \(outDims.width)×\(outDims.height)" : "Disabled",
                                tint: config.canvasExtension.enabled ? AppTheme.Colors.accent : .secondary
                            )
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Toggle("Enable Canvas Extension on Export", isOn: $config.canvasExtension.enabled)
                                .fontWeight(.medium)
                            AppStatusBadge(
                                text: config.canvasExtension.enabled ? "\(baseDims.width)×\(baseDims.height) → \(outDims.width)×\(outDims.height)" : "Disabled",
                                tint: config.canvasExtension.enabled ? AppTheme.Colors.accent : .secondary
                            )
                        }
                    }

                    AppDivider()

                    Picker("Canvas Mode", selection: Binding(
                        get: { config.canvasExtension.mode },
                        set: { mode in
                            config.canvasExtension.mode = mode
                            config.canvasExtension.enabled = true
                            if mode == .dimensions && (config.canvasExtension.targetWidth == nil || config.canvasExtension.targetHeight == nil) {
                                config.canvasExtension.targetWidth = baseDims.width + 160
                                config.canvasExtension.targetHeight = baseDims.height + 160
                            }
                        }
                    )) {
                        ForEach(ImageCanvasExtensionMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if config.canvasExtension.mode == .padding {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            padField(label: "Top (px)", value: $config.canvasExtension.padTop)
                            padField(label: "Bottom (px)", value: $config.canvasExtension.padBottom)
                            padField(label: "Left (px)", value: $config.canvasExtension.padLeft)
                            padField(label: "Right (px)", value: $config.canvasExtension.padRight)
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.lg) {
                                AnchorGridPicker(selection: $config.canvasExtension.anchor, title: "Content Anchor")
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                    dimensionFields
                                    Toggle("Lock Current Aspect Ratio", isOn: $config.canvasExtension.preserveAspectRatio)
                                }
                            }
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                                dimensionFields
                                Toggle("Lock Current Aspect Ratio", isOn: $config.canvasExtension.preserveAspectRatio)
                                AnchorGridPicker(selection: $config.canvasExtension.anchor, title: "Content Anchor")
                            }
                        }

                        AppDivider()

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Social, Wallpaper & Print Canvas Presets")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                                ForEach(ImageCanvasPreset.builtInPresets) { preset in
                                    Button(preset.label) {
                                        config.canvasExtension.enabled = true
                                        config.canvasExtension.mode = .dimensions
                                        config.canvasExtension.targetWidth = preset.width
                                        config.canvasExtension.targetHeight = preset.height
                                    }
                                    .controlSize(.small)
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }

                    AppDivider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            Text("Canvas Fill:")
                                .fixedSize()
                            fillPicker
                                .pickerStyle(.segmented)
                                .fixedSize()
                            if config.canvasExtension.fillMode == .custom {
                                customFillPicker
                            }
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Canvas Fill:")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                fillPicker.pickerStyle(.menu)
                                if config.canvasExtension.fillMode == .custom { customFillPicker }
                            }
                        }
                    }

                    if config.canvasExtension.enabled && config.canvasExtension.fillMode == .transparent && !targetSupportsAlpha {
                        AppInfoBanner(
                            style: .warning,
                            message: "\(outputFormat.shortExtensionLabel) does not support transparency; extended canvas areas will be filled opaque."
                        )
                    }

                    if let tel = telemetry {
                        TelemetryResultBanner(telemetry: tel)
                    }
                }
            }
        }
    }

    private func padField(label: String, value: Binding<Int>) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            TextField("px", value: Binding(
                get: { value.wrappedValue },
                set: {
                    value.wrappedValue = max(0, min(8000, $0))
                    config.canvasExtension.enabled = true
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 68)
        }
    }

    @ViewBuilder
    private var dimensionFields: some View {
        let ratio = Double(max(1, baseDims.width)) / Double(max(1, baseDims.height))
        HStack(spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("W:").fixedSize()
                TextField("W", value: Binding(
                    get: { config.canvasExtension.targetWidth ?? baseDims.width },
                    set: { newW in
                        let clamped = max(1, min(ImageDimensionCalculator.maxEdgePixels, newW))
                        config.canvasExtension.targetWidth = clamped
                        config.canvasExtension.enabled = true
                        if config.canvasExtension.preserveAspectRatio {
                            config.canvasExtension.targetHeight = max(1, Int((Double(clamped) / max(0.001, ratio)).rounded()))
                        }
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 78)
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("H:").fixedSize()
                TextField("H", value: Binding(
                    get: { config.canvasExtension.targetHeight ?? baseDims.height },
                    set: { newH in
                        let clamped = max(1, min(ImageDimensionCalculator.maxEdgePixels, newH))
                        config.canvasExtension.targetHeight = clamped
                        config.canvasExtension.enabled = true
                        if config.canvasExtension.preserveAspectRatio {
                            config.canvasExtension.targetWidth = max(1, Int((Double(clamped) * ratio).rounded()))
                        }
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 78)
            }
        }
    }

    private var fillPicker: some View {
        Picker("Canvas Fill", selection: $config.canvasExtension.fillMode) {
            ForEach(ImageCanvasFillMode.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .labelsHidden()
    }

    private var customFillPicker: some View {
        ColorPicker("Custom Canvas Color", selection: Binding(
            get: { config.canvasExtension.customColor.swiftUIColor },
            set: { config.canvasExtension.customColor = CodableRGBAColor(swiftUIColor: $0) }
        ))
        .labelsHidden()
    }
}

struct ImageBorderFrameCardView: View {
    @Binding var config: ImageToolboxConfig
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let outputFormat: FileFormat

    private var preBorderDims: (width: Int, height: Int) {
        let rawW = sourceDims?.width ?? 1000
        let rawH = sourceDims?.height ?? 1000
        var c = ImageDimensionCalculator.croppedDimensions(sourceWidth: rawW, sourceHeight: rawH, crop: config.cropTransform)
        if config.resizeStrategy != .none {
            c = ImageDimensionCalculator.resizedDimensions(currentWidth: c.width, currentHeight: c.height, strategy: config.resizeStrategy, width: config.resizeWidth, height: config.resizeHeight, percentage: config.resizePercentage, preserveAspectRatio: config.preserveAspectRatio)
        }
        if config.upscale.enabled {
            let u = ImageDimensionCalculator.upscaledDimensions(currentWidth: c.width, currentHeight: c.height, upscale: config.upscale)
            c = (u.width, u.height)
        }
        if config.canvasExtension.enabled {
            c = ImageDimensionCalculator.extendedCanvasDimensions(currentWidth: c.width, currentHeight: c.height, canvas: config.canvasExtension)
        }
        return c
    }

    private var finalDims: (width: Int, height: Int) {
        ImageDimensionCalculator.borderedDimensions(currentWidth: preBorderDims.width, currentHeight: preBorderDims.height, border: config.borderFrame)
    }

    var body: some View {
        AppCard(title: "Border, Frame, Corners & Shadow", icon: "photo.artframe") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Toggle("Enable Border / Frame on Export", isOn: $config.borderFrame.enabled)
                        .fontWeight(.medium)
                    Spacer()
                    AppStatusBadge(
                        text: config.borderFrame.enabled ? "\(finalDims.width) × \(finalDims.height) px" : "Disabled",
                        tint: config.borderFrame.enabled ? AppTheme.Colors.accent : .secondary
                    )
                }

                AppDivider()

                Picker("Placement", selection: $config.borderFrame.placement) {
                    ForEach(ImageBorderPlacement.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Toggle("Per-Edge Border Widths", isOn: $config.borderFrame.useIndividualEdges)

                if config.borderFrame.useIndividualEdges {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: AppTheme.Spacing.md)], spacing: AppTheme.Spacing.sm) {
                        edgeWidthField("Top (px)", $config.borderFrame.topWidth)
                        edgeWidthField("Bottom (px)", $config.borderFrame.bottomWidth)
                        edgeWidthField("Left (px)", $config.borderFrame.leftWidth)
                        edgeWidthField("Right (px)", $config.borderFrame.rightWidth)
                    }
                } else {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Border Width: \(config.borderFrame.uniformWidth) px")
                            .fixedSize()
                        Slider(value: Binding(
                            get: { Double(config.borderFrame.uniformWidth) },
                            set: { config.borderFrame.uniformWidth = Int($0.rounded()); config.borderFrame.enabled = true }
                        ), in: 0...400, step: 2)
                    }
                }

                AppDivider()

                HStack(spacing: AppTheme.Spacing.md) {
                    Picker("Fill Style", selection: $config.borderFrame.fillStyle) {
                        ForEach(ImageBorderFillStyle.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)

                    ColorPicker("Primary Color", selection: Binding(
                        get: { config.borderFrame.primaryColor.swiftUIColor },
                        set: { config.borderFrame.primaryColor = CodableRGBAColor(swiftUIColor: $0) }
                    ))
                    .labelsHidden()

                    if config.borderFrame.fillStyle == .linearGradient {
                        ColorPicker("Secondary Color", selection: Binding(
                            get: { config.borderFrame.secondaryColor.swiftUIColor },
                            set: { config.borderFrame.secondaryColor = CodableRGBAColor(swiftUIColor: $0) }
                        ))
                        .labelsHidden()
                    }
                }

                if config.borderFrame.fillStyle == .linearGradient {
                    HStack {
                        Text("Gradient Angle: \(Int(config.borderFrame.gradientAngleDegrees.rounded()))°")
                            .fixedSize()
                        Slider(value: $config.borderFrame.gradientAngleDegrees, in: 0...360, step: 15)
                    }
                }

                HStack {
                    Text("Rounded Corners: \(Int(config.borderFrame.cornerRadius.rounded())) px")
                        .fixedSize()
                    Slider(value: $config.borderFrame.cornerRadius, in: 0...160, step: 2)
                }

                if config.borderFrame.placement == .outer {
                    Toggle("Render Drop Shadow (Outer Canvas)", isOn: $config.borderFrame.shadowEnabled)
                    if config.borderFrame.shadowEnabled {
                        HStack {
                            Text("Shadow Blur: \(Int(config.borderFrame.shadowRadius.rounded())) px")
                                .fixedSize()
                            Slider(value: $config.borderFrame.shadowRadius, in: 4...48, step: 2)
                        }
                    }
                }

                if (config.borderFrame.cornerRadius > 0 || config.borderFrame.shadowEnabled)
                    && !FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency {
                    AppInfoBanner(
                        style: .info,
                        message: "\(outputFormat.shortExtensionLabel) flattens transparent corner/shadow regions onto white. Switch to PNG, WebP, or JXL to preserve alpha."
                    )
                }
            }
        }
    }

    private func edgeWidthField(_ label: String, _ binding: Binding<Int>) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(label).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            TextField("px", value: Binding(
                get: { binding.wrappedValue },
                set: { binding.wrappedValue = max(0, min(1000, $0)); config.borderFrame.enabled = true }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 68)
        }
    }
}

struct ImageDPIEditorCardView: View {
    @Binding var config: ImageToolboxConfig
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let detailedMeta: ImageDetailedMetadataSnapshot?
    let outputFormat: FileFormat

    private var effectiveOutPixels: (width: Int, height: Int) {
        let cur = ImageDimensionCalculator.expectedOutputDimensions(
            sourceWidth: sourceDims?.width ?? 1000,
            sourceHeight: sourceDims?.height ?? 1000,
            config: config
        )
        return cur
    }

    var body: some View {
        AppCard(title: "DPI / PPI Print Resolution Editor", icon: "printer") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Toggle("Set Custom Output DPI / PPI", isOn: $config.dpiConfig.enabled)
                        .fontWeight(.medium)
                    Spacer()
                    AppStatusBadge(
                        text: config.dpiConfig.enabled ? "\(Int(config.dpiConfig.targetDPI.rounded())) DPI" : "Source Default",
                        tint: config.dpiConfig.enabled ? AppTheme.Colors.accent : .secondary
                    )
                }

                if let currentDPI = detailedMeta?.dpiWidth {
                    Text("Source Metadata DPI: \(Int(currentDPI.rounded())) DPI")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            dpiPresetButtons
                            Spacer()
                            dpiCustomField
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                dpiPresetButtons
                            }
                            HStack(spacing: AppTheme.Spacing.xs) {
                                dpiCustomField
                                Spacer(minLength: 0)
                            }
                        }
                    }

                Toggle("Resample Pixel Dimensions to Match Print Size", isOn: $config.dpiConfig.resamplePixels)

                Text(config.dpiConfig.resamplePixels
                     ? "Resampling ON: pixel count scales by target DPI / source DPI (\(effectiveOutPixels.width) × \(effectiveOutPixels.height) px)."
                     : "Resampling OFF: pixel count stays unchanged (\(effectiveOutPixels.width) × \(effectiveOutPixels.height) px); only physical print metadata changes.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)

                AppDivider()

                let dpi = max(1.0, config.dpiConfig.enabled ? config.dpiConfig.targetDPI : (detailedMeta?.effectiveDPI ?? 72.0))
                let wInches = Double(effectiveOutPixels.width) / dpi
                let hInches = Double(effectiveOutPixels.height) / dpi
                let wCm = wInches * 2.54
                let hCm = hInches * 2.54

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    printStat("Pixels", "\(effectiveOutPixels.width) × \(effectiveOutPixels.height) px")
                    printStat("Inches", String(format: "%.2f × %.2f in", wInches, hInches))
                    printStat("Centimeters", String(format: "%.2f × %.2f cm", wCm, hCm))
                    printStat("Millimeters", String(format: "%.1f × %.1f mm", wCm * 10.0, hCm * 10.0))
                }

                AppInfoBanner(
                    style: .info,
                    message: dpiFormatNote(for: outputFormat)
                )
            }
        }
    }

    @ViewBuilder
    private var dpiPresetButtons: some View {
        Text("Presets:").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
        ForEach(ImageDPIConfig.presets, id: \.self) { preset in
            let active = config.dpiConfig.enabled && abs(config.dpiConfig.targetDPI - preset) < 0.5
            Button("\(Int(preset))") {
                config.dpiConfig.sourceDPI = detailedMeta?.effectiveDPI ?? 72.0
                config.dpiConfig.targetDPI = preset
                config.dpiConfig.enabled = true
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(active ? AppTheme.Colors.accent : .secondary)
        }
    }

    @ViewBuilder
    private var dpiCustomField: some View {
        TextField("DPI", value: Binding(
            get: { config.dpiConfig.targetDPI },
            set: {
                config.dpiConfig.sourceDPI = detailedMeta?.effectiveDPI ?? 72.0
                config.dpiConfig.targetDPI = max(18, min(2400, $0))
                config.dpiConfig.enabled = true
            }
        ), format: .number)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: 72)
        Text("DPI").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
    }

    private func printStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AppTheme.Typography.caption).foregroundStyle(.secondary)
            Text(value).font(AppTheme.Typography.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func dpiFormatNote(for format: FileFormat) -> String {
        switch format {
        case .jpg, .tiff, .png, .heic:
            return "\(format.shortExtensionLabel) reliably writes physical DPI metadata (JFIF/TIFF/PNG pHYs/ImageIO tags)."
        case .jxl, .webp, .avif:
            return "\(format.shortExtensionLabel) embeds DPI in EXIF/XMP boxes when preserved, though many web browsers ignore physical DPI."
        default:
            return "Some container formats omit physical DPI tags on export; PNG, TIFF, and JPEG preserve DPI most consistently."
        }
    }
}

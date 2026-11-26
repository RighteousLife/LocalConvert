import SwiftUI
import AppKit

// MARK: - Color Bridge Helper

extension CodableRGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(swiftUIColor: Color) {
        let ns = NSColor(swiftUIColor).usingColorSpace(.sRGB) ?? NSColor.white
        self.init(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }
}

// MARK: - 1. Convert & Codec Section

struct ImageConvertCodecSectionView: View {
    enum ConvertSubTool: String, CaseIterable, Identifiable {
        case formatAndCodec = "Format & Codec"
        case smartAdvisor = "Smart Advisor"
        case contactSheet = "Contact Sheet"
        case batchRename = "Batch Rename"
        case duplicates = "Duplicates"
        case svgOptimizer = "SVG Optimizer"
        var id: String { rawValue }
    }

    @Binding var config: ImageToolboxConfig
    @Binding var targetFormat: FileFormat
    let sourceURL: URL?
    let selectedURLs: [URL]
    let inputFormat: FileFormat?
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let jxlInfo: JXLImageMetadataInfo?
    let writableFormats: [FileFormat]

    @State private var activeSubTool: ConvertSubTool = .formatAndCodec

    private var estimatedBytes: Int64? {
        guard let dims = sourceDims, dims.bytes > 0 else { return nil }
        let opts = config.applying(to: ConversionOptions.default, outputFormat: targetFormat)
        return ImageProcessor.computeEstimatedSize(
            originalSizeBytes: dims.bytes,
            originalDimensions: CGSize(width: max(1, dims.width), height: max(1, dims.height)),
            targetFormat: targetFormat,
            options: opts
        ).estimatedBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                ForEach(ConvertSubTool.allCases) { tool in
                    let isSelected = (activeSubTool == tool)
                    Button {
                        activeSubTool = tool
                    } label: {
                        Text(tool.rawValue)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(isSelected ? AppTheme.Colors.accent : .secondary)
                }
            }

            switch activeSubTool {
            case .formatAndCodec:
                formatCodecContent
            case .smartAdvisor:
                ImageSmartFormatAdvisorView(
                    sourceURL: sourceURL,
                    targetFormat: $targetFormat,
                    config: $config
                )
            case .contactSheet:
                ImageContactSheetBuilderView(selectedURLs: selectedURLs)
            case .batchRename:
                ImageBatchRenameView(sourceURLs: selectedURLs)
            case .duplicates:
                ImageDuplicateFinderView(sourceURLs: selectedURLs)
            case .svgOptimizer:
                ImageSVGOptimizerView(sourceURL: sourceURL)
            }
        }
    }

    @ViewBuilder
    private var formatCodecContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Target Format & Quality", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("Output Container")
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        Picker("Output Format", selection: $targetFormat) {
                            ForEach(writableFormats, id: \.self) { fmt in
                                Text(fmt == .jxl ? "JPEG XL (.jxl)" : "\(fmt.displayName) (.\(fmt.rawValue))")
                                    .tag(fmt)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 150, maxWidth: 240)
                    }

                    if !(targetFormat == .jxl && config.jxlLossless) && !(targetFormat == .webp && config.webpLossless) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Encoding Quality")
                                Spacer()
                                Text("\(Int((config.quality * 100).rounded()))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $config.quality, in: 0.1...1.0, step: 0.01)
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) {
                            Toggle("Preserve Alpha Channel", isOn: $config.preserveAlpha)
                            Toggle("Preserve Animation Frames", isOn: $config.preserveAnimation)
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Toggle("Preserve Alpha Channel", isOn: $config.preserveAlpha)
                            Toggle("Preserve Animation Frames", isOn: $config.preserveAnimation)
                        }
                    }

                    if let est = estimatedBytes {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("Estimated Output Size: ~\(ByteCountFormatter.string(fromByteCount: est, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // JPEG XL Specific Controls
            if targetFormat == .jxl || inputFormat == .jxl {
                AppCard(title: "JPEG XL (libjxl \(JPEGXLCodec.libraryVersion)) Codec Options", icon: "cpu") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if targetFormat == .jxl {
                            Toggle("Lossless JPEG XL Encoding (Modular, 0 pixel loss)", isOn: $config.jxlLossless)

                            HStack(spacing: AppTheme.Spacing.md) {
                                Text("Compression Effort (\(config.jxlEffort) / 9)")
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer()
                                Slider(
                                    value: Binding(
                                        get: { Double(config.jxlEffort) },
                                        set: { config.jxlEffort = Int($0.rounded()) }
                                    ),
                                    in: 1...9,
                                    step: 1
                                )
                                .frame(minWidth: 120, maxWidth: 220)
                            }

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: AppTheme.Spacing.md) {
                                    Text("Channel Bit Depth")
                                        .fixedSize(horizontal: true, vertical: false)
                                    Spacer()
                                    Picker("Channel Bit Depth", selection: $config.jxlBitDepth) {
                                        Text("8-bit Standard").tag(8)
                                        Text("16-bit High Precision").tag(16)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                    .frame(minWidth: 250, maxWidth: 300)
                                }

                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                    Text("Channel Bit Depth")
                                    Picker("Channel Bit Depth", selection: $config.jxlBitDepth) {
                                        Text("8-bit Standard").tag(8)
                                        Text("16-bit High Precision").tag(16)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.segmented)
                                }
                            }

                            if !config.jxlLossless {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: AppTheme.Spacing.sm) {
                                        Toggle("Custom Butteraugli Distance", isOn: Binding(
                                            get: { config.jxlDistance != nil },
                                            set: { config.jxlDistance = $0 ? 1.0 : nil }
                                        ))
                                        .fixedSize()
                                        Spacer(minLength: AppTheme.Spacing.sm)
                                        if let dist = config.jxlDistance {
                                            Text(String(format: "%.2f", dist))
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                            Slider(
                                                value: Binding(
                                                    get: { dist },
                                                    set: { config.jxlDistance = $0 }
                                                ),
                                                in: 0.0...12.0,
                                                step: 0.1
                                            )
                                            .frame(minWidth: 100, maxWidth: 160)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                        Toggle("Custom Butteraugli Distance", isOn: Binding(
                                            get: { config.jxlDistance != nil },
                                            set: { config.jxlDistance = $0 ? 1.0 : nil }
                                        ))
                                        if let dist = config.jxlDistance {
                                            HStack(spacing: AppTheme.Spacing.sm) {
                                                Slider(
                                                    value: Binding(
                                                        get: { dist },
                                                        set: { config.jxlDistance = $0 }
                                                    ),
                                                    in: 0.0...12.0,
                                                    step: 0.1
                                                )
                                                Text(String(format: "%.2f", dist))
                                                    .monospacedDigit()
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if inputFormat == .jpg && targetFormat == .jxl {
                            Divider()
                            Toggle(
                                "Losslessly Transcode JPEG Bitstream (Bit-exact JPEG Reconstruction)",
                                isOn: $config.jxlTranscodeJPEG
                            )
                            Text("Stores exact JPEG DCT coefficients inside the JPEG XL container (~16-24% smaller) without pixel recompression.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if inputFormat == .jxl && targetFormat == .jpg {
                            Divider()
                            Toggle(
                                "Reconstruct Original Embedded JPEG Bitstream",
                                isOn: $config.jxlReconstructJPEG
                            )
                            if let info = jxlInfo {
                                Text(info.isJPEGReconstructable
                                     ? "Source .jxl contains an embedded JPEG bitstream and will reconstruct byte-for-byte."
                                     : "Source .jxl does not contain a JPEG bitstream box; disabling fallback reconstruct uses pixel re-encode.")
                                    .font(.caption)
                                    .foregroundStyle(info.isJPEGReconstructable ? .green : .orange)
                            }
                        }
                    }
                }
            } else if targetFormat == .webp {
                AppCard(title: "WebP Options", icon: "photo") {
                    Toggle("Lossless WebP", isOn: $config.webpLossless)
                }
            }
        }
    }
}

// MARK: - 2. Batch Resize Section

struct ImageResizeSectionView: View {
    enum ResizeSubTool: String, CaseIterable, Identifiable {
        case pixelResize = "Pixel Resize"
        case canvasPadding = "Canvas & Padding"
        case borderFrame = "Border & Frame"
        case dpiEditor = "DPI / PPI"
        var id: String { rawValue }
    }

    @Binding var config: ImageToolboxConfig
    let outputFormat: FileFormat
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let detailedMeta: ImageDetailedMetadataSnapshot?
    let telemetry: ImageProcessingTelemetry?
    @Binding var previewPresetID: UUID?

    @State private var activeSubTool: ResizeSubTool = .pixelResize
    @State private var newPresetLabel: String = "Web Large"
    @State private var newPresetWidth: Int = 1280
    @State private var newPresetHeight: Int = 720

    private var effectiveInputDims: (width: Int, height: Int) {
        let rawW = sourceDims?.width ?? 1024
        let rawH = sourceDims?.height ?? 1024
        return ImageDimensionCalculator.croppedDimensions(
            sourceWidth: rawW,
            sourceHeight: rawH,
            crop: config.cropTransform
        )
    }

    private var activeMultiPreset: ImageBatchSizePreset? {
        guard config.exportMultipleSizes, !config.multiSizePresets.isEmpty else { return nil }
        if let id = previewPresetID, let match = config.multiSizePresets.first(where: { $0.id == id }) {
            return match
        }
        return nil
    }

    private var computedTargetDims: (width: Int, height: Int) {
        let cur = effectiveInputDims
        if let preset = activeMultiPreset {
            return ImageDimensionCalculator.resizedDimensions(
                currentWidth: cur.width,
                currentHeight: cur.height,
                strategy: .fitInside,
                width: preset.width,
                height: preset.height,
                percentage: 100.0,
                preserveAspectRatio: true
            )
        }
        return ImageDimensionCalculator.resizedDimensions(
            currentWidth: cur.width,
            currentHeight: cur.height,
            strategy: config.resizeStrategy,
            width: config.resizeWidth,
            height: config.resizeHeight,
            percentage: config.resizePercentage,
            preserveAspectRatio: config.preserveAspectRatio
        )
    }

    private var scalePercent: Double {
        let cur = effectiveInputDims
        let dst = computedTargetDims
        guard cur.width > 0, cur.height > 0 else { return 100.0 }
        let sx = Double(dst.width) / Double(cur.width)
        let sy = Double(dst.height) / Double(cur.height)
        return ((sx + sy) / 2.0) * 100.0
    }

    private var scalingDirection: (label: String, tint: Color) {
        let cur = effectiveInputDims
        let dst = computedTargetDims
        if dst.width == cur.width && dst.height == cur.height {
            return ("1:1 Unchanged", .secondary)
        }
        if dst.width > cur.width || dst.height > cur.height {
            return ("Upscaling", AppTheme.Colors.warning)
        }
        return ("Downscaling", AppTheme.Colors.success)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                ForEach(ResizeSubTool.allCases) { tool in
                    let isSelected = (activeSubTool == tool)
                    Button {
                        activeSubTool = tool
                    } label: {
                        Text(tool.rawValue)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(isSelected ? AppTheme.Colors.accent : .secondary)
                }
            }

            switch activeSubTool {
            case .pixelResize:
                pixelResizeContent
            case .canvasPadding:
                ImageCanvasExtensionCardView(
                    config: $config,
                    sourceDims: sourceDims,
                    outputFormat: outputFormat,
                    telemetry: telemetry
                )
            case .borderFrame:
                ImageBorderFrameCardView(
                    config: $config,
                    sourceDims: sourceDims,
                    outputFormat: outputFormat
                )
            case .dpiEditor:
                ImageDPIEditorCardView(
                    config: $config,
                    sourceDims: sourceDims,
                    detailedMeta: detailedMeta,
                    outputFormat: outputFormat
                )
            }
        }
    }

    @ViewBuilder
    private var pixelResizeContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            // Review & Dimensions Summary Card
            AppCard(title: "Resize Summary & Target Telemetry", icon: "ruler") {
                let src = effectiveInputDims
                let dst = computedTargetDims
                let estSize = telemetry.map { ByteCountFormatter.string(fromByteCount: $0.processedBytes, countStyle: .file) } ?? "—"
                let dir = scalingDirection

                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        reviewMetric(title: "Original Size", value: "\(src.width) × \(src.height) px")
                        reviewMetric(title: "Target Size", value: "\(dst.width) × \(dst.height) px")
                        reviewMetric(title: "Scale Factor", value: String(format: "%.1f%%", scalePercent))
                        reviewMetric(title: "Est. Output Size", value: estSize)
                    }

                    AppDivider()

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Scaling Direction:")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        AppStatusBadge(text: dir.label, tint: dir.tint)
                        if let preset = activeMultiPreset {
                            AppStatusBadge(text: "Previewing preset: \(preset.label)", tint: AppTheme.Colors.accent)
                        }
                        Spacer(minLength: 0)
                    }

                    if dir.label == "Upscaling" && config.resizeStrategy != .none {
                        AppInfoBanner(
                            style: .info,
                            message: "Target dimensions exceed original size (upscaling). For dedicated 2×–4× enlargement with detail recovery and pre-denoise, you can also use the Upscale section."
                        )
                    }
                }
            }

            AppCard(title: "Single Output Scaling", icon: "arrow.up.left.and.arrow.down.right") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        Text("Resize Strategy")
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Picker("Resize Strategy", selection: Binding(
                            get: { config.resizeStrategy },
                            set: { newStrategy in
                                previewPresetID = nil
                                config.resizeStrategy = newStrategy
                                if config.resizeWidth == nil {
                                    config.resizeWidth = effectiveInputDims.width
                                }
                                if config.resizeHeight == nil {
                                    config.resizeHeight = effectiveInputDims.height
                                }
                            }
                        )) {
                            ForEach(ImageResizeStrategy.allCases) { strat in
                                Text(strat.rawValue).tag(strat)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 180, maxWidth: 240)
                    }

                    if config.resizeStrategy == .percentage {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text("Scale Percentage")
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Slider(value: $config.resizePercentage, in: 5...400, step: 5)
                                .frame(minWidth: 100, maxWidth: 200)
                            TextField("100", value: $config.resizePercentage, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("%")
                                .foregroundStyle(.secondary)
                        }
                    } else if config.resizeStrategy != .none {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.md) {
                                dimensionFields
                                Spacer(minLength: AppTheme.Spacing.sm)
                                if config.resizeStrategy == .exactDimensions {
                                    Toggle("Lock Aspect", isOn: $config.preserveAspectRatio)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }

                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                HStack(spacing: AppTheme.Spacing.md) {
                                    dimensionFields
                                    Spacer(minLength: 0)
                                }
                                if config.resizeStrategy == .exactDimensions {
                                    Toggle("Lock Aspect", isOn: $config.preserveAspectRatio)
                                }
                            }
                        }
                    }

                    AppDivider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            Text("Resampling Filter")
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            resamplingPicker
                                .pickerStyle(.segmented)
                                .fixedSize()
                        }

                        HStack(spacing: AppTheme.Spacing.md) {
                            Text("Resampling Filter")
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            resamplingPicker
                                .pickerStyle(.menu)
                                .frame(minWidth: 150, maxWidth: 210)
                        }
                    }

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Post-Resize Sharpening")
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Slider(value: $config.postResizeSharpen, in: 0...1, step: 0.05)
                            .frame(minWidth: 120, maxWidth: 200)
                        Text(String(format: "%.2f", config.postResizeSharpen))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            AppCard(title: "Multi-Size Batch Export Presets", icon: "square.stack.3d.down.right") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Toggle("Export Multiple Target Sizes Per Image", isOn: Binding(
                        get: { config.exportMultipleSizes },
                        set: { enabled in
                            config.exportMultipleSizes = enabled
                            if !enabled { previewPresetID = nil }
                        }
                    ))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            presetTemplateButtons
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            presetTemplateButtons
                        }
                    }

                    ForEach(config.multiSizePresets) { preset in
                        let isPreviewing = (previewPresetID == preset.id)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text(preset.label)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Text("\(preset.width) × \(preset.height) px")
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                            Button {
                                if isPreviewing {
                                    previewPresetID = nil
                                } else {
                                    config.exportMultipleSizes = true
                                    previewPresetID = preset.id
                                }
                            } label: {
                                Text(isPreviewing ? "Previewing" : "Preview")
                                    .font(AppTheme.Typography.caption)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .tint(isPreviewing ? AppTheme.Colors.accent : .secondary)

                            Button {
                                if previewPresetID == preset.id { previewPresetID = nil }
                                config.multiSizePresets.removeAll { $0.id == preset.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(AppTheme.Colors.error)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, AppTheme.Spacing.xxs)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            addSizeInputs
                            Button("Add Size") { appendCustomPreset() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                addSizeInputs
                            }
                            Button("Add Size") { appendCustomPreset() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func reviewMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppTheme.Typography.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var dimensionFields: some View {
        let ratio = Double(max(1, effectiveInputDims.width)) / Double(max(1, effectiveInputDims.height))

        if config.resizeStrategy != .maxHeight {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Width (px):")
                    .fixedSize(horizontal: true, vertical: false)
                TextField("Width", value: Binding(
                    get: { config.resizeWidth ?? effectiveInputDims.width },
                    set: { newW in
                        let clamped = max(1, newW)
                        previewPresetID = nil
                        config.resizeWidth = clamped
                        if config.preserveAspectRatio && config.resizeStrategy == .exactDimensions {
                            config.resizeHeight = max(1, Int((Double(clamped) / max(0.001, ratio)).rounded()))
                        }
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
            }
        }
        if config.resizeStrategy != .maxWidth {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Height (px):")
                    .fixedSize(horizontal: true, vertical: false)
                TextField("Height", value: Binding(
                    get: { config.resizeHeight ?? effectiveInputDims.height },
                    set: { newH in
                        let clamped = max(1, newH)
                        previewPresetID = nil
                        config.resizeHeight = clamped
                        if config.preserveAspectRatio && config.resizeStrategy == .exactDimensions {
                            config.resizeWidth = max(1, Int((Double(clamped) * ratio).rounded()))
                        }
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
            }
        }
    }

    private var resamplingPicker: some View {
        Picker("Resampling Filter", selection: $config.resamplingMethod) {
            ForEach(ImageResamplingMethod.allCases, id: \.self) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder
    private var presetTemplateButtons: some View {
        Button("+ Web Responsive (400 / 800 / 1600)") {
            config.multiSizePresets = [
                ImageBatchSizePreset(label: "400w", width: 400, height: 400),
                ImageBatchSizePreset(label: "800w", width: 800, height: 800),
                ImageBatchSizePreset(label: "1600w", width: 1600, height: 1600)
            ]
            config.exportMultipleSizes = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button("+ macOS App Icons (128 / 256 / 512 / 1024)") {
            config.multiSizePresets = [
                ImageBatchSizePreset(label: "128px", width: 128, height: 128),
                ImageBatchSizePreset(label: "256px", width: 256, height: 256),
                ImageBatchSizePreset(label: "512px", width: 512, height: 512),
                ImageBatchSizePreset(label: "1024px", width: 1024, height: 1024)
            ]
            config.exportMultipleSizes = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var addSizeInputs: some View {
        TextField("Label", text: $newPresetLabel)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 90, maxWidth: 140)
        TextField("W", value: $newPresetWidth, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 68)
        Text("×")
            .foregroundStyle(.secondary)
        TextField("H", value: $newPresetHeight, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 68)
    }

    private func appendCustomPreset() {
        config.multiSizePresets.append(
            ImageBatchSizePreset(
                label: newPresetLabel.isEmpty ? "\(newPresetWidth)x\(newPresetHeight)" : newPresetLabel,
                width: max(1, newPresetWidth),
                height: max(1, newPresetHeight)
            )
        )
        config.exportMultipleSizes = true
    }
}

// MARK: - 4. Optimize File Size Section

struct ImageTargetSizeSectionView: View {
    enum SizeUnit: String, CaseIterable, Identifiable {
        case kb = "KB"
        case mb = "MB"
        var id: String { rawValue }
    }

    @Binding var config: ImageToolboxConfig
    let outputFormat: FileFormat
    let sourceURL: URL?
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let benchmarkTelemetry: ImageProcessingTelemetry?
    let isBenchmarking: Bool
    let onRunBenchmark: () -> Void

    @State private var unit: SizeUnit = .kb

    private var isLosslessTarget: Bool {
        [.png, .tiff, .bmp, .tga].contains(outputFormat)
            || (outputFormat == .jxl && config.jxlLossless)
            || (outputFormat == .webp && config.webpLossless)
            || config.compressionProfile.prefersLossless
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Target Maximum Output Size", icon: "gauge.with.dots.needle.33percent") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Toggle("Enforce Target Maximum File Size", isOn: $config.targetFileSizeEnabled)

                    let quickTargets: [(String, Int64)] = [
                        ("100 KB", 100 * 1024),
                        ("250 KB", 250 * 1024),
                        ("500 KB", 500 * 1024),
                        ("1 MB", 1024 * 1024),
                        ("2 MB", 2 * 1024 * 1024)
                    ]

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: AppTheme.Spacing.xs)], alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(quickTargets, id: \.0) { item in
                            let isActive = config.targetFileSizeEnabled && config.targetFileSizeBytes == item.1
                            Button {
                                config.targetFileSizeEnabled = true
                                config.targetFileSizeBytes = item.1
                                unit = (item.1 >= 1024 * 1024) ? .mb : .kb
                            } label: {
                                Text(item.0)
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .tint(isActive ? AppTheme.Colors.accent : .secondary)
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            targetCustomInputs
                            Spacer(minLength: 0)
                            targetBenchmarkButton
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                targetCustomInputs
                                Spacer(minLength: 0)
                            }
                            targetBenchmarkButton
                        }
                    }

                    if isLosslessTarget {
                        AppInfoBanner(
                            style: .warning,
                            message: "\(outputFormat.shortExtensionLabel) is currently configured as Lossless. Target file size cannot be guaranteed in lossless mode — switch to lossy JPEG, WebP, AVIF, HEIC, or JXL for quality optimization."
                        )
                    }

                    Text("Optimizes lossy encoder quality in real memory passes. Embedded alpha channels, 16-bit depth, and retained EXIF/ICC metadata add fixed byte overhead.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)

                    if let tel = benchmarkTelemetry {
                        AppDivider()
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Verified In-Memory Encode Result (not a heuristic estimate)")
                                .font(AppTheme.Typography.caption.weight(.semibold))
                                .foregroundStyle(tel.targetReached ? AppTheme.Colors.success : AppTheme.Colors.warning)
                            TelemetryResultBanner(telemetry: tel)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var targetCustomInputs: some View {
        Text("Custom Target:")
            .fixedSize()

        if unit == .kb {
            TextField("KB", value: Binding(
                get: { max(10, Int(config.targetFileSizeBytes / 1024)) },
                set: { config.targetFileSizeBytes = max(10, Int64($0)) * 1024 }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
        } else {
            TextField("MB", value: Binding(
                get: { max(0.05, Double(config.targetFileSizeBytes) / (1024.0 * 1024.0)) },
                set: { config.targetFileSizeBytes = max(10_240, Int64(($0 * 1024.0 * 1024.0).rounded())) }
            ), format: .number.precision(.fractionLength(1...2)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
        }

        Picker("Unit", selection: $unit) {
            ForEach(SizeUnit.allCases) { u in
                Text(u.rawValue).tag(u)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 88)
    }

    private var targetBenchmarkButton: some View {
        Button {
            config.targetFileSizeEnabled = true
            onRunBenchmark()
        } label: {
            if isBenchmarking {
                ProgressView().controlSize(.small)
            } else {
                Label("Test Real Output Size", systemImage: "gauge.with.dots.needle.33percent")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(sourceURL == nil || isBenchmarking)
    }
}

// MARK: - 5. Compression Profile Section

struct ImageCompressionSectionView: View {
    @Binding var config: ImageToolboxConfig
    let outputFormat: FileFormat
    let sourceURL: URL?
    let benchmarkTelemetry: ImageProcessingTelemetry?
    let isBenchmarking: Bool
    let onRunBenchmark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Compression Profile Presets", icon: "slider.horizontal.below.square.and.square.filled") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                        ForEach(ImageCompressionProfile.allCases) { profile in
                            let selected = config.compressionProfile == profile
                            Button {
                                applyProfile(profile)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                    Text(profileDescription(profile))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(AppTheme.Spacing.md)
                                .background(selected ? AppTheme.Colors.accentTint : AppTheme.Colors.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                                        .stroke(selected ? AppTheme.Colors.accent : Color.primary.opacity(0.08), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    AppDivider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            qualityFineTuneRow
                            measureBytesButton
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                qualityFineTuneRow
                            }
                            measureBytesButton
                        }
                    }

                    if let tel = benchmarkTelemetry {
                        TelemetryResultBanner(telemetry: tel)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var qualityFineTuneRow: some View {
        Text("Fine-Tune Quality: \(Int((config.quality * 100).rounded()))%")
            .fixedSize()
        Slider(value: Binding(
            get: { config.quality },
            set: {
                config.quality = $0
                config.compressionProfile = .custom
            }
        ), in: 0.1...1.0, step: 0.01)
    }

    private var measureBytesButton: some View {
        Button {
            onRunBenchmark()
        } label: {
            if isBenchmarking {
                ProgressView().controlSize(.small)
            } else {
                Text("Measure Full Encoded Bytes")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(sourceURL == nil || isBenchmarking)
    }

    private func applyProfile(_ profile: ImageCompressionProfile) {
        config.compressionProfile = profile
        config.quality = profile.suggestedQuality
        config.jxlEffort = profile.suggestedEffort
        config.jxlLossless = profile.prefersLossless
        config.webpLossless = profile.prefersLossless
        if profile == .archiveLossless {
            config.targetFileSizeEnabled = false
        }
    }

    private func profileDescription(_ p: ImageCompressionProfile) -> String {
        switch p {
        case .maximumQuality: return "96% visual fidelity, minimal artifacts"
        case .balanced: return "85% quality, ideal detail vs size"
        case .smallFile: return "65% quality for lightweight sharing"
        case .webOptimized: return "78% quality, crisp fast delivery"
        case .archiveLossless: return "Mathematically lossless (JXL / WebP / PNG)"
        case .custom: return "User-defined codec sliders"
        }
    }
}

// MARK: - 6. Watermark Section

struct ImageWatermarkSectionView: View {
    @Binding var config: ImageToolboxConfig
    let sourceURL: URL?
    let outputFormat: FileFormat
    let isGeneratingPreview: Bool
    let onGeneratePreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Watermark Configuration", icon: "textformat") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Toggle("Apply Watermark on Export", isOn: $config.watermark.enabled)

                    Picker("Watermark Type", selection: $config.watermark.kind) {
                        ForEach(ImageWatermarkKind.allCases) { k in
                            Text(k.rawValue).tag(k)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if config.watermark.kind == .text {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.md) {
                                watermarkTextControls
                            }
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                TextField("Watermark Text", text: $config.watermark.text)
                                    .textFieldStyle(.roundedBorder)
                                HStack(spacing: AppTheme.Spacing.sm) {
                                    fontPicker
                                    textColorPicker
                                }
                            }
                        }

                        HStack {
                            Text("Font Size (% shortest edge): \(String(format: "%.1f%%", config.watermark.fontSizePercent))")
                                .fixedSize()
                            Slider(value: $config.watermark.fontSizePercent, in: 1.5...18.0)
                        }
                    } else {
                        HStack {
                            Text(config.watermark.watermarkImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No logo image chosen")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Logo PNG/SVG/JXL...") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                panel.canChooseFiles = true
                                if panel.runModal() == .OK, let u = panel.url {
                                    config.watermark.watermarkImagePath = u.path
                                    config.watermark.enabled = true
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        HStack {
                            Text("Logo Width (% canvas): \(Int(config.watermark.scalePercent))%")
                                .fixedSize()
                            Slider(value: $config.watermark.scalePercent, in: 5...65)
                        }
                    }

                    HStack {
                        Text("Opacity: \(Int((config.watermark.opacity * 100).rounded()))%")
                            .fixedSize()
                        Slider(value: $config.watermark.opacity, in: 0.05...1.0)
                    }

                    HStack {
                        Text("Rotation: \(Int(config.watermark.rotationDegrees.rounded()))°")
                            .fixedSize()
                        Slider(value: $config.watermark.rotationDegrees, in: -90...90)
                    }

                    Toggle("Tile Repeated Grid Across Image", isOn: $config.watermark.tiled)
                    if config.watermark.tiled {
                        HStack {
                            Text("Tile Spacing: \(String(format: "%.1fx", config.watermark.tileSpacingMultiplier))")
                                .fixedSize()
                            Slider(value: $config.watermark.tileSpacingMultiplier, in: 1.2...4.5)
                        }
                    } else {
                        HStack(spacing: AppTheme.Spacing.lg) {
                            AnchorGridPicker(selection: $config.watermark.anchor, title: "Position Anchor")
                            VStack(alignment: .leading) {
                                Text("Edge Margin: \(String(format: "%.1f%%", config.watermark.marginPercent))")
                                    .font(AppTheme.Typography.caption)
                                Slider(value: $config.watermark.marginPercent, in: 0...15)
                            }
                        }
                    }

                    HStack {
                        Button {
                            config.watermark.enabled = true
                            onGeneratePreview()
                        } label: {
                            if isGeneratingPreview {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Enable & Refresh Live Preview", systemImage: "eye")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(sourceURL == nil || isGeneratingPreview)
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var watermarkTextControls: some View {
        TextField("Watermark Text", text: $config.watermark.text)
            .textFieldStyle(.roundedBorder)
        fontPicker
        textColorPicker
    }

    private var fontPicker: some View {
        Picker("Font", selection: $config.watermark.fontName) {
            Text("Helvetica Neue").tag("Helvetica Neue")
            Text("SF Pro Display").tag(".AppleSystemUIFont")
            Text("Georgia").tag("Georgia")
            Text("Menlo").tag("Menlo")
        }
        .labelsHidden()
        .frame(width: 160)
    }

    private var textColorPicker: some View {
        ColorPicker("Text Color", selection: Binding(
            get: { config.watermark.textColor.swiftUIColor },
            set: { config.watermark.textColor = CodableRGBAColor(swiftUIColor: $0) }
        ))
        .labelsHidden()
    }
}

// MARK: - 7. Color Management Section

struct ImageColorManagementSectionView: View {
    enum ColorSubTool: String, CaseIterable, Identifiable {
        case iccProfile = "ICC & Profile"
        case histogram = "Histogram & Luma"
        case palette = "Color Palette"
        var id: String { rawValue }
    }

    @Binding var config: ImageToolboxConfig
    let colorInfo: ImageColorProfileInfo?
    let previewImage: NSImage?

    @State private var activeSubTool: ColorSubTool = .iccProfile

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                ForEach(ColorSubTool.allCases) { tool in
                    Button {
                        activeSubTool = tool
                    } label: {
                        Text(tool.rawValue)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(activeSubTool == tool ? AppTheme.Colors.accent : .secondary)
                }
            }

            switch activeSubTool {
            case .iccProfile:
                iccProfileCards
            case .histogram:
                ImageHistogramAnalysisCardView(previewImage: previewImage, colorInfo: colorInfo)
            case .palette:
                ImageColorPaletteExtractorCardView(previewImage: previewImage)
            }
        }
    }

    @ViewBuilder
    private var iccProfileCards: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Source Color Profile Inspection", icon: "paintpalette") {
                if let info = colorInfo {
                    ViewThatFits(in: .horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: AppTheme.Spacing.sm) {
                            GridRow {
                                Text("Profile Name").foregroundStyle(.secondary)
                                Text(info.profileName).fontWeight(.medium)
                                Text("Color Model").foregroundStyle(.secondary)
                                Text(info.colorModel)
                            }
                            GridRow {
                                Text("Bit Depth").foregroundStyle(.secondary)
                                Text("\(info.bitDepth)-bit per component")
                                Text("Alpha Channel").foregroundStyle(.secondary)
                                Text(info.hasAlpha ? "Present" : "Opaque")
                            }
                            GridRow {
                                Text("Embedded ICC").foregroundStyle(.secondary)
                                Text(info.hasEmbeddedICC ? "\(ByteCountFormatter.string(fromByteCount: Int64(info.iccSizeBytes), countStyle: .file))" : "None")
                                Text("Gamut").foregroundStyle(.secondary)
                                Text(info.isWideGamut ? "Wide Gamut (P3 / Adobe RGB / Rec.2020)" : "Standard sRGB")
                                    .foregroundStyle(info.isWideGamut ? AppTheme.Colors.accent : .secondary)
                            }
                        }
                        .font(AppTheme.Typography.caption)

                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: AppTheme.Spacing.xs + 2) {
                            GridRow {
                                Text("Profile Name").foregroundStyle(.secondary)
                                Text(info.profileName).fontWeight(.medium)
                            }
                            GridRow {
                                Text("Color Model").foregroundStyle(.secondary)
                                Text(info.colorModel)
                            }
                            GridRow {
                                Text("Bit Depth").foregroundStyle(.secondary)
                                Text("\(info.bitDepth)-bit per component")
                            }
                            GridRow {
                                Text("Alpha Channel").foregroundStyle(.secondary)
                                Text(info.hasAlpha ? "Present" : "Opaque")
                            }
                            GridRow {
                                Text("Embedded ICC").foregroundStyle(.secondary)
                                Text(info.hasEmbeddedICC ? "\(ByteCountFormatter.string(fromByteCount: Int64(info.iccSizeBytes), countStyle: .file))" : "None")
                            }
                            GridRow {
                                Text("Gamut").foregroundStyle(.secondary)
                                Text(info.isWideGamut ? "Wide Gamut (P3 / Adobe RGB / Rec.2020)" : "Standard sRGB")
                                    .foregroundStyle(info.isWideGamut ? AppTheme.Colors.accent : .secondary)
                            }
                        }
                        .font(AppTheme.Typography.caption)
                    }
                } else {
                    Text("Select an image to inspect its ICC profile and bit depth.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            AppCard(title: "Output ICC Color Space Conversion", icon: "wand.and.stars") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm + 2) {
                    Picker("Target Color Profile", selection: $config.colorTarget) {
                        ForEach(ImageColorProfileTarget.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text("Converting wide-gamut Display P3 photos to sRGB IEC61966-2.1 ensures consistent web color rendering while preserving perceptual color accuracy.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 8. Background Removal Section

struct ImageBackgroundRemovalSectionView: View {
    @Binding var config: ImageToolboxConfig
    let outputFormat: FileFormat
    let isGeneratingPreview: Bool
    let onGeneratePreview: () -> Void

    private var targetSupportsAlpha: Bool {
        FormatCapabilityRegistry.shared.capability(for: outputFormat).supportsTransparency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "On-Device Foreground Subject Segmentation (Apple Vision)", icon: "person.crop.rectangle") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Toggle("Enable Automatic Background Removal", isOn: $config.backgroundRemoval.enabled)

                    Picker("Background Fill", selection: $config.backgroundRemoval.fillMode) {
                        ForEach(ImageBackgroundFillMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if config.backgroundRemoval.fillMode == .solidColor {
                        HStack {
                            Text("Replacement Color:")
                            ColorPicker("Fill Color", selection: Binding(
                                get: { config.backgroundRemoval.solidColor.swiftUIColor },
                                set: { config.backgroundRemoval.solidColor = CodableRGBAColor(swiftUIColor: $0) }
                            ))
                            .labelsHidden()
                            Spacer()
                        }
                    }

                    HStack {
                        Text("Mask Edge Refinement: \(String(format: "%.1f px", config.backgroundRemoval.edgeRefinement))")
                            .fixedSize()
                        Slider(value: $config.backgroundRemoval.edgeRefinement, in: 0...8.0, step: 0.5)
                    }

                    if config.backgroundRemoval.enabled && config.backgroundRemoval.fillMode == .transparent && !targetSupportsAlpha {
                        AppInfoBanner(
                            style: .warning,
                            message: "\(outputFormat.shortExtensionLabel) does not support alpha transparency. Switch Output to PNG, WebP, or JPEG XL (.jxl) to keep a transparent background."
                        )
                    }

                    Button {
                        config.backgroundRemoval.enabled = true
                        onGeneratePreview()
                    } label: {
                        if isGeneratingPreview {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Run Vision Cutout in Live Preview", systemImage: "person.crop.rectangle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isGeneratingPreview)
                }
            }
        }
    }
}

// MARK: - Shared UI Helpers

struct AnchorGridPicker: View {
    @Binding var selection: ImageAnchorPosition
    let title: String

    private let rows: [[ImageAnchorPosition]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                ForEach(0..<rows.count, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(rows[r]) { pos in
                            Button {
                                selection = pos
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(selection == pos ? Color.accentColor : Color.secondary.opacity(0.2))
                                    .frame(width: 22, height: 18)
                                    .overlay {
                                        Circle()
                                            .fill(selection == pos ? Color.white : Color.secondary)
                                            .frame(width: 5, height: 5)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(pos.rawValue)
                        }
                    }
                }
            }
        }
    }
}

struct TelemetryResultBanner: View {
    let telemetry: ImageProcessingTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md + 2) {
                    telemetryStats
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    telemetryStats
                }
            }
            .font(.caption.monospacedDigit())

            if let note = telemetry.note {
                if telemetry.targetReached {
                    Text(note)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    AppInfoBanner(style: .warning, message: note)
                }
            }
        }
        .padding(AppTheme.Spacing.sm + 2)
        .background(AppTheme.Colors.neutralTint.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
    }

    @ViewBuilder
    private var telemetryStats: some View {
        Label(
            "Original: \(ByteCountFormatter.string(fromByteCount: telemetry.originalBytes, countStyle: .file))",
            systemImage: "doc"
        )
        Label(
            "Processed (\(telemetry.outputFormat.shortExtensionLabel)): \(ByteCountFormatter.string(fromByteCount: telemetry.processedBytes, countStyle: .file))",
            systemImage: "sparkles"
        )
        Text(String(format: "%.1f%% saved", telemetry.sizeReductionPercent))
            .fontWeight(.semibold)
            .foregroundStyle(telemetry.sizeReductionPercent >= 0 ? AppTheme.Colors.success : AppTheme.Colors.warning)
        if let q = telemetry.finalQuality {
            Text("q=\(Int((q * 100).rounded()))%")
                .foregroundStyle(.secondary)
        }
    }
}

struct CheckerboardPattern: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = (colorScheme == .dark)
        Canvas { ctx, size in
            let tile: CGFloat = 10
            let cols = Int(ceil(size.width / tile))
            let rows = Int(ceil(size.height / tile))
            let a = isDark ? Color(white: 0.22) : Color(white: 0.92)
            let b = isDark ? Color(white: 0.17) : Color(white: 0.80)
            for r in 0..<rows {
                for c in 0..<cols {
                    let isFirst = (r + c).isMultiple(of: 2)
                    ctx.fill(
                        Path(CGRect(x: CGFloat(c) * tile, y: CGFloat(r) * tile, width: tile, height: tile)),
                        with: .color(isFirst ? a : b)
                    )
                }
            }
        }
    }
}

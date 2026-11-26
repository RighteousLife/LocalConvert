import SwiftUI

// MARK: - Dedicated Image Upscaler Section

struct ImageUpscaleSectionView: View {
    @Binding var config: ImageToolboxConfig
    let sourceDims: (width: Int, height: Int, bytes: Int64)?
    let telemetry: ImageProcessingTelemetry?

    private var baseDims: (width: Int, height: Int) {
        let rawW = sourceDims?.width ?? 1000
        let rawH = sourceDims?.height ?? 1000
        return ImageDimensionCalculator.croppedDimensions(
            sourceWidth: rawW,
            sourceHeight: rawH,
            crop: config.cropTransform
        )
    }

    private var previewUpscaleResult: (width: Int, height: Int, clampedByMemoryGuard: Bool) {
        var effective = config.upscale
        effective.enabled = true
        return ImageDimensionCalculator.upscaledDimensions(
            currentWidth: baseDims.width,
            currentHeight: baseDims.height,
            upscale: effective
        )
    }

    private var effectiveScaleFactor: Double {
        let out = previewUpscaleResult
        guard baseDims.width > 0 else { return 1.0 }
        return Double(out.width) / Double(baseDims.width)
    }

    private var estimatedRawBufferMB: Double {
        let out = previewUpscaleResult
        return Double(out.width * out.height * 4) / (1024.0 * 1024.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            AppCard(title: "Resolution Upscaling", icon: "plus.viewfinder") {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Toggle("Enable Image Upscaling on Export", isOn: $config.upscale.enabled)
                                .fontWeight(.medium)
                            Spacer(minLength: AppTheme.Spacing.sm)
                            reviewStatusPill
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Toggle("Enable Image Upscaling on Export", isOn: $config.upscale.enabled)
                                .fontWeight(.medium)
                            reviewStatusPill
                        }
                    }

                    AppDivider()

                    // Preset scale buttons: 2x, 3x, 4x, Custom Scale, Target Size
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Scaling Mode")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)

                        let presetBinding = Binding(
                            get: { config.upscale.preset },
                            set: { newPreset in
                                config.upscale.preset = newPreset
                                config.upscale.enabled = true
                                if let factor = newPreset.fixedScaleFactor {
                                    config.upscale.scaleFactor = factor
                                } else if newPreset == .targetDimensions {
                                    if config.upscale.targetWidth == nil {
                                        config.upscale.targetWidth = baseDims.width * 2
                                    }
                                    if config.upscale.targetHeight == nil {
                                        config.upscale.targetHeight = baseDims.height * 2
                                    }
                                }
                            }
                        )

                        ViewThatFits(in: .horizontal) {
                            Picker("Scaling Mode", selection: presetBinding) {
                                ForEach(ImageUpscalePreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize(horizontal: true, vertical: false)

                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                HStack(spacing: AppTheme.Spacing.xs) {
                                    ForEach([ImageUpscalePreset.scale2x, .scale3x, .scale4x]) { preset in
                                        upscalePresetButton(preset, binding: presetBinding)
                                    }
                                }
                                HStack(spacing: AppTheme.Spacing.xs) {
                                    ForEach([ImageUpscalePreset.customScale, .targetDimensions]) { preset in
                                        upscalePresetButton(preset, binding: presetBinding)
                                    }
                                }
                            }
                        }
                    }

                    if config.upscale.preset == .customScale {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text("Scale Factor")
                                .fixedSize()
                            Slider(value: $config.upscale.scaleFactor, in: 1.1...4.0, step: 0.1)
                                .frame(minWidth: 120)
                            TextField("Scale", value: $config.upscale.scaleFactor, format: .number.precision(.fractionLength(1...2)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Text("×")
                                .foregroundStyle(.secondary)
                        }
                    } else if config.upscale.preset == .targetDimensions {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: AppTheme.Spacing.md) {
                                targetSizeInputs
                                Spacer(minLength: AppTheme.Spacing.sm)
                                Toggle("Lock Aspect", isOn: $config.upscale.preserveAspectRatio)
                                    .fixedSize()
                            }
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                                HStack(spacing: AppTheme.Spacing.md) {
                                    targetSizeInputs
                                }
                                Toggle("Lock Aspect", isOn: $config.upscale.preserveAspectRatio)
                            }
                        }
                    }

                    AppDivider()

                    // Interpolation & Detail Enhancement
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.md) {
                            Text("Interpolation Algorithm")
                                .fixedSize()
                            Spacer(minLength: AppTheme.Spacing.sm)
                            Picker("Interpolation Algorithm", selection: $config.upscale.method) {
                                ForEach(ImageUpscaleMethod.allCases) { m in
                                    Text(m.rawValue).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 200, maxWidth: 260)
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Interpolation Algorithm")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                            Picker("Interpolation Algorithm", selection: $config.upscale.method) {
                                ForEach(ImageUpscaleMethod.allCases) { m in
                                    Text(m.rawValue).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        }
                    }

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Detail Recovery / Crispness")
                            .fixedSize()
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Slider(value: $config.upscale.detailEnhancement, in: 0...1, step: 0.05)
                            .frame(minWidth: 120, maxWidth: 210)
                        Text("\(Int((config.upscale.detailEnhancement * 100).rounded()))%")
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Pre-Upscale Artifact Smoothing")
                            .fixedSize()
                        Spacer(minLength: AppTheme.Spacing.sm)
                        Slider(value: $config.upscale.artifactReduction, in: 0...1, step: 0.05)
                            .frame(minWidth: 120, maxWidth: 210)
                        Text("\(Int((config.upscale.artifactReduction * 100).rounded()))%")
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }

                    if config.resizeStrategy != .none {
                        AppInfoBanner(
                            style: .info,
                            message: "Resize (\(config.resizeStrategy.rawValue)) is also active; Upscale will enlarge the resized output dimensions."
                        )
                    }

                    if previewUpscaleResult.clampedByMemoryGuard {
                        AppInfoBanner(
                            style: .warning,
                            message: "Requested dimensions exceed the 16,384 px edge / 100 MP safety ceiling and are automatically clamped to protect memory."
                        )
                    }
                }
            }

            // Metrics & Memory Footprint Card
            AppCard(title: "Upscale Review & Memory Estimate", icon: "chart.bar.xaxis") {
                let out = previewUpscaleResult
                let mp = Double(out.width * out.height) / 1_000_000.0
                let estBytesStr = telemetry.map { ByteCountFormatter.string(fromByteCount: $0.processedBytes, countStyle: .file) } ?? "—"

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: AppTheme.Spacing.md)], alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    metricCell(label: "Source Size", value: "\(baseDims.width) × \(baseDims.height) px")
                    metricCell(label: "Target Output", value: "\(out.width) × \(out.height) px")
                    metricCell(label: "Effective Scale", value: String(format: "%.2f× (%.1f MP)", effectiveScaleFactor, mp))
                    metricCell(label: "Est. Encoded Size", value: estBytesStr)
                    metricCell(label: "Working Bitmap RAM", value: String(format: "~%.1f MB", estimatedRawBufferMB))
                }
            }

            // Honest AI Super-Resolution Feasibility Notice
            AppInfoBanner(
                style: .info,
                message: "Conventional GPU/Core Image Upscaling active (multi-step Lanczos + Unsharp Detail Recovery). LocalConvert does not bundle neural super-resolution Core ML weights (such as Real-ESRGAN, ~16–67 MB) in v1.0; true Core ML Neural Engine super-resolution is planned as an optional future model pack.",
                icon: "cpu"
            )
        }
    }

    @ViewBuilder
    private var reviewStatusPill: some View {
        let out = previewUpscaleResult
        AppStatusBadge(
            text: config.upscale.enabled
                ? "\(baseDims.width)×\(baseDims.height) → \(out.width)×\(out.height)"
                : "Disabled",
            tint: config.upscale.enabled ? AppTheme.Colors.accent : .secondary
        )
    }

    @ViewBuilder
    private var targetSizeInputs: some View {
        let ratio = Double(max(1, baseDims.width)) / Double(max(1, baseDims.height))

        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Width (px):")
                .fixedSize()
            TextField("W", value: Binding(
                get: { config.upscale.targetWidth ?? (baseDims.width * 2) },
                set: { newW in
                    let clamped = max(1, newW)
                    config.upscale.targetWidth = clamped
                    config.upscale.enabled = true
                    if config.upscale.preserveAspectRatio {
                        config.upscale.targetHeight = max(1, Int((Double(clamped) / max(0.001, ratio)).rounded()))
                    }
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 86)
        }

        HStack(spacing: AppTheme.Spacing.xs) {
            Text("Height (px):")
                .fixedSize()
            TextField("H", value: Binding(
                get: { config.upscale.targetHeight ?? (baseDims.height * 2) },
                set: { newH in
                    let clamped = max(1, newH)
                    config.upscale.targetHeight = clamped
                    config.upscale.enabled = true
                    if config.upscale.preserveAspectRatio {
                        config.upscale.targetWidth = max(1, Int((Double(clamped) * ratio).rounded()))
                    }
                }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 86)
        }
    }

    private func upscalePresetButton(_ preset: ImageUpscalePreset, binding: Binding<ImageUpscalePreset>) -> some View {
        let isSelected = binding.wrappedValue == preset
        return Button {
            binding.wrappedValue = preset
        } label: {
            Text(preset.rawValue)
                .font(AppTheme.Typography.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(isSelected ? AppTheme.Colors.accentTint : AppTheme.Colors.subtleSurface)
                .foregroundStyle(isSelected ? AppTheme.Colors.accent : .primary)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(isSelected ? AppTheme.Colors.accent.opacity(0.45) : AppTheme.Colors.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppTheme.Typography.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
        }
    }
}

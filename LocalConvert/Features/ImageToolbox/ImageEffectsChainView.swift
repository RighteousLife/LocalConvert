import SwiftUI
import AppKit

// MARK: - Ordered Effects Chain & Look Presets View

struct ImageEffectsChainView: View {
    enum SubTab: String, CaseIterable, Identifiable {
        case effectsChain = "Effects Chain"
        case lookPresets = "Look Presets"

        var id: String { rawValue }
    }

    @ObservedObject var store: ImageToolboxStore
    @ObservedObject var presetManager: PresetManager = .shared
    let url: URL?
    let selectedURLs: [URL]
    let targetFormat: FileFormat
    @Binding var config: ImageToolboxConfig

    @State private var activeTab: SubTab = .effectsChain
    @State private var newPresetName: String = ""
    @State private var newPresetDescription: String = ""
    @State private var renamingPreset: SavedPreset? = nil
    @State private var renameText: String = ""
    @State private var batchReport: ImageBatchPresetReport? = nil
    @State private var batchTask: Task<Void, Never>? = nil
    @State private var isApplyingBatch: Bool = false

    private var userImagePresets: [SavedPreset] {
        presetManager.presets.filter { ImagePresetCatalog.isImageToolboxPreset($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                ForEach(SubTab.allCases) { tab in
                    let selected = (activeTab == tab)
                    Button {
                        activeTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(selected ? AppTheme.Colors.accent : .secondary)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityValue(selected ? "Selected" : "")
                }
            }

            if activeTab == .effectsChain {
                addEffectCard
                orderedStackCard
            } else {
                builtInPresetsCard
                userPresetsCard
                if let report = batchReport {
                    batchReportBanner(report)
                }
            }
        }
        .onDisappear {
            batchTask?.cancel()
        }
    }

    // MARK: - Add Effect Toolbar Card

    private var addEffectCard: some View {
        AppCard(title: "Add Effect or Filter", icon: "plus.circle") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: AppTheme.Spacing.xs)], spacing: AppTheme.Spacing.xs) {
                    ForEach(ImageEffectKind.allCases) { kind in
                        Button {
                            store.addEffect(kind, for: url)
                        } label: {
                            Label(kind.rawValue, systemImage: kind.systemImage)
                                .font(AppTheme.Typography.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Add \(kind.rawValue)")
                    }
                }

                if !config.effectStack.isEmpty {
                    HStack {
                        Text("\(config.effectStack.filter(\.isEnabled).count) of \(config.effectStack.count) active")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Entire Stack") {
                            store.resetAllEffects(for: url)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Reset Entire Effects Stack")
                    }
                }
            }
        }
    }

    // MARK: - Ordered Stack Card

    @ViewBuilder
    private var orderedStackCard: some View {
        if config.effectStack.isEmpty {
            AppCard(title: "Active Effects Chain", icon: "square.3.layers.3d") {
                Text("No effects added yet. Choose any effect above to build a non-destructive ordered chain.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(Array(config.effectStack.enumerated()), id: \.element.id) { index, slot in
                AppCard {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Toggle("", isOn: Binding(
                                get: { slot.isEnabled },
                                set: { _ in store.toggleEffect(id: slot.id, for: url) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("Enable \(slot.kind.rawValue)")
                            .accessibilityValue(slot.isEnabled ? "On" : "Off")

                            Image(systemName: slot.kind.systemImage)
                                .foregroundStyle(slot.isEnabled ? AppTheme.Colors.accent : .secondary)

                            Text("\(index + 1). \(slot.kind.rawValue)")
                                .font(AppTheme.Typography.cardTitle)
                                .foregroundStyle(slot.isEnabled ? .primary : .secondary)

                            Spacer()

                            Button {
                                store.moveEffect(id: slot.id, offset: -1, for: url)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(index == 0)
                            .help("Move Effect Up")
                            .accessibilityLabel("Move \(slot.kind.rawValue) up")

                            Button {
                                store.moveEffect(id: slot.id, offset: 1, for: url)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(index == config.effectStack.count - 1)
                            .help("Move Effect Down")
                            .accessibilityLabel("Move \(slot.kind.rawValue) down")

                            Button("Reset") {
                                store.resetEffect(id: slot.id, for: url)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Reset \(slot.kind.rawValue)")

                            Button {
                                store.removeEffect(id: slot.id, for: url)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(AppTheme.Colors.error)
                            }
                            .buttonStyle(.plain)
                            .help("Remove Effect")
                            .accessibilityLabel("Remove \(slot.kind.rawValue)")
                        }

                        if slot.isEnabled {
                            AppDivider()
                            effectParametersEditor(index: index, slot: slot)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func effectParametersEditor(index: Int, slot: ImageEffectSlot) -> some View {
        switch slot.kind {
        case .gaussianBlur:
            effectSlider(index: index, title: "Radius", value: slot.radius, range: 0.5...40.0, format: { String(format: "%.1f px", $0) }) {
                $0.radius = $1
            }
            effectSlider(index: index, title: "Strength", value: slot.intensity, range: 0.0...1.5, format: { String(format: "%.0f%%", $0 * 100) }) {
                $0.intensity = $1
            }

        case .sharpen:
            effectSlider(index: index, title: "Sharpness", value: slot.sharpness, range: 0.0...2.0, format: { String(format: "%.2f", $0) }) {
                $0.sharpness = $1
            }
            effectSlider(index: index, title: "Radius", value: slot.radius, range: 0.5...4.0, format: { String(format: "%.1f px", $0) }) {
                $0.radius = $1
            }

        case .unsharpMask:
            effectSlider(index: index, title: "Intensity", value: slot.intensity, range: 0.0...2.0, format: { String(format: "%.2f", $0) }) {
                $0.intensity = $1
            }
            effectSlider(index: index, title: "Radius", value: slot.radius, range: 0.5...12.0, format: { String(format: "%.1f px", $0) }) {
                $0.radius = $1
            }

        case .noiseReduction:
            effectSlider(index: index, title: "Noise Level", value: slot.intensity, range: 0.0...1.5, format: { String(format: "%.0f%%", $0 * 100) }) {
                $0.intensity = $1
            }
            effectSlider(index: index, title: "Edge Sharpness", value: slot.sharpness, range: 0.0...1.5, format: { String(format: "%.2f", $0) }) {
                $0.sharpness = $1
            }

        case .vignette:
            effectSlider(index: index, title: "Intensity", value: slot.intensity, range: -0.5...1.5, format: { String(format: "%.0f%%", $0 * 100) }) {
                $0.intensity = $1
            }
            effectSlider(index: index, title: "Radius", value: slot.radius, range: 0.5...10.0, format: { String(format: "%.1f", $0) }) {
                $0.radius = $1
            }
            effectSlider(index: index, title: "Falloff", value: slot.falloff, range: 0.0...1.0, format: { String(format: "%.2f", $0) }) {
                $0.falloff = $1
            }

        case .filmGrain:
            effectSlider(index: index, title: "Amount", value: slot.intensity, range: 0.0...1.2, format: { String(format: "%.0f%%", $0 * 100) }) {
                $0.intensity = $1
            }
            effectSlider(index: index, title: "Grain Size", value: slot.grainSize, range: 0.5...3.0, format: { String(format: "%.1f px", $0) }) {
                $0.grainSize = $1
            }

        case .monochrome:
            HStack {
                Text("Monochrome Tint")
                    .font(AppTheme.Typography.caption)
                    .frame(width: 112, alignment: .leading)
                ColorPicker("Monochrome Color", selection: Binding(
                    get: { slot.tintColor.swiftUIColor },
                    set: { newCol in
                        store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Monochrome Tint") { cfg in
                            guard cfg.effectStack.indices.contains(index) else { return }
                            cfg.effectStack[index].tintColor = CodableRGBAColor(swiftUIColor: newCol)
                        }
                    }
                ))
                .labelsHidden()
                Spacer()
            }
            effectSlider(index: index, title: "Intensity", value: slot.intensity, range: 0.0...1.0, format: { String(format: "%.0f%%", $0 * 100) }) {
                $0.intensity = $1
            }

        case .sepia:
            effectSlider(index: index, title: "Intensity", value: slot.intensity, range: 0.0...1.0, format: { String(format: "%.0f%%", $0 * 100) }) {
                $0.intensity = $1
            }

        case .photoFilter:
            HStack {
                Text("Filter Style")
                    .font(AppTheme.Typography.caption)
                    .frame(width: 112, alignment: .leading)
                Picker("Look Filter", selection: Binding(
                    get: { slot.photoStyle },
                    set: { style in
                        store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Color Filter: \(style.rawValue)") { cfg in
                            guard cfg.effectStack.indices.contains(index) else { return }
                            cfg.effectStack[index].photoStyle = style
                        }
                    }
                )) {
                    ForEach(ImagePhotoFilterStyle.allCases) { st in
                        Text(st.rawValue).tag(st)
                    }
                }
                .labelsHidden()
                Spacer()
            }
            effectSlider(index: index, title: "Mix", value: slot.intensity, range: 0.0...1.0, format: { String(format: "%.0f%%", $0 * 100) }) {
                $0.intensity = $1
            }
        }
    }

    private func effectSlider(
        index: Int,
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        format: (Double) -> String,
        assign: @escaping (inout ImageEffectSlot, Double) -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(AppTheme.Typography.caption)
                .frame(width: 112, alignment: .leading)
            Slider(
                value: Binding(
                    get: { value },
                    set: { newVal in
                        guard config.effectStack.indices.contains(index) else { return }
                        assign(&config.effectStack[index], newVal)
                        config.effectStack[index].clamped()
                    }
                ),
                in: range
            ) { editing in
                if editing {
                    store.beginContinuousEdit(for: url)
                } else {
                    store.endContinuousEdit(for: url, explicitType: .imageConfigEdit, explicitTitle: "Adjust \(title)")
                }
            }
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
            Text(format(value))
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }

    // MARK: - Presets Cards

    private var builtInPresetsCard: some View {
        AppCard(title: "Built-In Editing Looks", icon: "sparkles") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                HStack {
                    Text("Look-only presets preserve your chosen Export Format, Crop, Resize & Metadata settings.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Look") {
                        store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset Look") { cfg in
                            cfg.colorAdjustments.resetAll()
                            cfg.effectStack.removeAll()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: AppTheme.Spacing.sm)], spacing: AppTheme.Spacing.sm) {
                    ForEach(ImagePresetCatalog.builtInLookPresets) { preset in
                        presetCard(preset: preset, allowRenameDelete: false)
                    }
                }
            }
        }
    }

    private var userPresetsCard: some View {
        AppCard(title: "My Image Presets", icon: "tray.full") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        TextField("New Look Preset Name...", text: $newPresetName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Description (optional)", text: $newPresetDescription)
                            .textFieldStyle(.roundedBorder)
                        saveLookPresetButton
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        TextField("New Look Preset Name...", text: $newPresetName)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: AppTheme.Spacing.sm) {
                            TextField("Description (optional)", text: $newPresetDescription)
                                .textFieldStyle(.roundedBorder)
                            saveLookPresetButton
                        }
                    }
                }

                if userImagePresets.isEmpty {
                    Text("No saved user image presets yet. Configure Color & Effects and save a look above.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(userImagePresets) { preset in
                        presetCard(preset: preset, allowRenameDelete: true)
                    }
                }
            }
        }
        .sheet(item: $renamingPreset) { target in
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Rename Look Preset").font(AppTheme.Typography.pageTitle)
                TextField("Preset Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack {
                    Spacer()
                    Button("Cancel") { renamingPreset = nil }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Rename") {
                        _ = presetManager.rename(id: target.id, to: renameText)
                        renamingPreset = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .appWorkspaceSurface()
        }
    }

    private var saveLookPresetButton: some View {
        Button("Save Look Preset") {
            let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let preset = ImagePresetCatalog.makeUserLookPreset(
                name: trimmed,
                description: newPresetDescription.isEmpty ? nil : newPresetDescription,
                targetFormat: targetFormat,
                config: config
            )
            presetManager.save(preset: preset)
            newPresetName = ""
            newPresetDescription = ""
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func presetCard(preset: SavedPreset, allowRenameDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Text(preset.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if preset.isBuiltIn {
                    AppStatusBadge(text: "Built-In", tint: AppTheme.Colors.accent)
                } else if ImagePresetCatalog.isLookOnlyPreset(preset) {
                    AppStatusBadge(text: "Look", tint: .secondary)
                }
            }

            if let desc = preset.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: AppTheme.Spacing.xs) {
                Button("Apply") {
                    _ = store.applyPreset(preset, to: url)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                if selectedURLs.count > 1 {
                    Button("Apply to \(selectedURLs.count)") {
                        batchTask?.cancel()
                        isApplyingBatch = true
                        let targets = selectedURLs
                        batchTask = Task {
                            let rep = await store.applyPresetBatch(preset, to: targets)
                            await MainActor.run {
                                self.batchReport = rep
                                self.isApplyingBatch = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isApplyingBatch)
                }

                Spacer()

                if allowRenameDelete {
                    Button("Rename") {
                        renameText = preset.name
                        renamingPreset = preset
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        presetManager.delete(id: preset.id)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(AppTheme.Colors.error)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.lg).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func batchReportBanner(_ report: ImageBatchPresetReport) -> some View {
        AppInfoBanner(
            style: (report.failedCount == 0 && !report.wasCancelled) ? .success : .warning,
            message: "Batch Preset '\(report.presetName)': \(report.succeededCount) succeeded, \(report.failedCount) failed\(report.wasCancelled ? " (cancelled)" : "").",
            onDismiss: { batchReport = nil }
        )
    }
}

// MARK: - Native Camera RAW Development View

struct ImageRAWDevelopView: View {
    @ObservedObject var store: ImageToolboxStore
    let url: URL?
    let inputFormat: FileFormat?
    let usedRAWFallback: Bool
    @Binding var config: ImageToolboxConfig

    private var isRAWFile: Bool {
        guard let fmt = inputFormat else { return false }
        return ImageProcessingService.cameraRAWFormats.contains(fmt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if !isRAWFile {
                AppCard(title: "Camera RAW Development", icon: "camera.aperture") {
                    Text("The currently selected image (\(inputFormat?.shortExtensionLabel ?? "Raster")) is not a Camera RAW sensor file. Load DNG, CR2, CR3, NEF, ARW, RAF, RW2, ORF, PEF, or SRW to unlock native Core Image `CIRAWFilter` sensor controls.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                if usedRAWFallback {
                    AppInfoBanner(
                        style: .warning,
                        message: "macOS Camera RAW (`CIRAWFilter`) could not decode this file; standard ImageIO fallback is active and RAW-specific sliders are bypassed."
                    )
                }

                AppCard(title: "Native Camera RAW (`CIRAWFilter`) Develop", icon: "camera.aperture") {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack {
                            Toggle("Use Core Image RAW Demosaicing", isOn: $config.rawDevelop.useRAWFilter)
                            Spacer()
                            Button("Reset RAW") {
                                store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "Reset RAW Develop") {
                                    $0.rawDevelop = ImageRAWDevelopConfig()
                                }
                            }
                            .controlSize(.small)
                        }

                        AppDivider()

                        rawSlider("RAW Exposure", value: $config.rawDevelop.exposureEV, range: -4.0...4.0) { String(format: "%+.2f EV", $0) }
                        rawSlider("Boost / Tone Curve", value: $config.rawDevelop.boostAmount, range: 0.0...1.0) { String(format: "%.0f%%", $0 * 100) }
                        rawSlider("Highlight Recovery", value: $config.rawDevelop.highlightRecovery, range: 0.0...1.0) { String(format: "%.0f%%", $0 * 100) }
                        rawSlider("Shadow Bias", value: $config.rawDevelop.shadowBias, range: -1.0...1.0) { String(format: "%+.2f", $0) }

                        AppDivider()

                        HStack {
                            Toggle("Custom Kelvin WB", isOn: Binding(
                                get: { config.rawDevelop.neutralTemperatureKelvin != nil },
                                set: { enabled in
                                    store.updateConfig(for: url, explicitType: .imageConfigEdit, explicitTitle: "RAW White Balance") { cfg in
                                        cfg.rawDevelop.neutralTemperatureKelvin = enabled ? 5500.0 : nil
                                        cfg.rawDevelop.neutralTint = enabled ? 0.0 : nil
                                    }
                                }
                            ))
                            Spacer()
                        }

                        if let kelvin = config.rawDevelop.neutralTemperatureKelvin {
                            rawSlider(
                                "WB Kelvin",
                                value: Binding(
                                    get: { kelvin },
                                    set: { config.rawDevelop.neutralTemperatureKelvin = $0 }
                                ),
                                range: 2200.0...12000.0
                            ) { "\(Int($0.rounded())) K" }

                            rawSlider(
                                "WB Tint",
                                value: Binding(
                                    get: { config.rawDevelop.neutralTint ?? 0.0 },
                                    set: { config.rawDevelop.neutralTint = $0 }
                                ),
                                range: -150.0...150.0
                            ) { String(format: "%+.0f", $0) }
                        }

                        AppDivider()

                        rawSlider("Luma Noise Reduction", value: $config.rawDevelop.lumaNoiseReduction, range: 0.0...1.0) { String(format: "%.0f%%", $0 * 100) }
                        rawSlider("Color Noise Reduction", value: $config.rawDevelop.colorNoiseReduction, range: 0.0...1.0) { String(format: "%.0f%%", $0 * 100) }
                        rawSlider("RAW Sharpness", value: $config.rawDevelop.sharpnessAmount, range: 0.0...1.0) { String(format: "%.0f%%", $0 * 100) }

                        HStack(spacing: AppTheme.Spacing.md) {
                            Toggle("Gamut Mapping", isOn: $config.rawDevelop.gamutMappingEnabled)
                            Toggle("Lens Correction (if supported)", isOn: $config.rawDevelop.lensCorrectionEnabled)
                        }
                        .padding(.top, AppTheme.Spacing.xs)
                    }
                }
            }
        }
    }

    private func rawSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: (Double) -> String
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(AppTheme.Typography.caption)
                .frame(width: 140, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if editing { store.beginContinuousEdit(for: url) }
                else { store.endContinuousEdit(for: url, explicitType: .imageConfigEdit, explicitTitle: title) }
            }
            .accessibilityLabel(title)
            .accessibilityValue(format(value.wrappedValue))
            Text(format(value.wrappedValue))
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
        }
    }
}

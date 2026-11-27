import SwiftUI

// MARK: - File Options View

struct FileOptionsView: View {
    @Binding var options: ConversionOptions
    let descriptors: [ConversionOptionDescriptor]
    let fileName: String
    var inputFormat: FileFormat? = nil
    var outputFormat: FileFormat? = nil
    var onOpenVideoTrim: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    @State private var customTargetMBInput: String = ""

    private var isImageOptions: Bool {
        descriptors.contains(where: { $0.id == "imageQuality" || $0.id == "webpLossless" })
            && !descriptors.contains(where: { $0.id == "pdfDPI" })
    }

    private var supportsTargetSizeChips: Bool {
        isImageOptions
            || inputFormat == .pdf
            || inputFormat?.category == .video
            || outputFormat?.category == .video
            || descriptors.contains(where: { $0.id == "targetFileSizeMB" })
    }

    private var availableSmartPresets: [ConversionPreset] {
        for descriptor in descriptors {
            if case .preset(let presets) = descriptor.kind {
                return presets
            }
        }
        return []
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Conversion Options")
                        .font(AppTheme.Typography.sectionTitle)
                    Text(fileName)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md + 2)
            .background(AppTheme.Colors.subtleSurface)
            
            AppDivider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if isImageOptions {
                        if let presetDescriptor = descriptors.first(where: { $0.id == "preset" }) {
                            descriptorRow(for: presetDescriptor)
                            Divider()
                        }
                        ImageOptimizationSectionView(
                            options: $options,
                            isImageTarget: outputFormat != .pdf,
                            availablePresets: availableSmartPresets,
                            descriptors: descriptors,
                            inputFormat: inputFormat,
                            outputFormat: outputFormat
                        )
                    } else {
                        if inputFormat?.category == .video {
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                                Text("Video Trim")
                                    .font(AppTheme.Typography.subheadline)
                                    .fontWeight(.medium)

                                if let trim = options.videoTrim {
                                    Text("\(trim.displaySummary) · \(trim.mode.shortLabel)")
                                        .font(AppTheme.Typography.monoCaption)
                                        .foregroundStyle(AppTheme.Colors.accent)
                                } else {
                                    Text("Full video duration (no trim active)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: AppTheme.Spacing.sm) {
                                    if let onOpenVideoTrim {
                                        Button(options.hasVideoTrim ? "Edit Trim Range..." : "Trim Video...") {
                                            onOpenVideoTrim()
                                        }
                                        .controlSize(.small)
                                    }
                                    if options.hasVideoTrim {
                                        Button("Clear Trim", role: .destructive) {
                                            options.videoTrim = nil
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                            .padding(.vertical, AppTheme.Spacing.xxs)

                            if !descriptors.isEmpty {
                                Divider()
                            }
                        }

                        // Dynamic Options List
                        ForEach(descriptors) { descriptor in
                            descriptorRow(for: descriptor)
                        }
                    }

                    if supportsTargetSizeChips {
                        Divider()
                        quickTargetSizeChipsSection
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
        .frame(minWidth: 340, idealWidth: 380, minHeight: 280, maxHeight: 520)
        .appWorkspaceSurface()
    }

    @ViewBuilder
    private var quickTargetSizeChipsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
            HStack {
                Text("Quick Target File Size")
                    .font(AppTheme.Typography.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let activeBytes = options.effectiveTargetFileSizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: activeBytes, countStyle: .file))
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(AppTheme.Colors.accent)
                    Button("Clear") {
                        customTargetMBInput = ""
                        updateOption {
                            $0.targetFileSizeMB = nil
                            $0.targetFileSizeBytes = nil
                            if isImageOptions && $0.imageOptimizationMode == .targetFileSize {
                                $0.imageOptimizationMode = .balanced
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(TargetSizeQuickPreset.allCases) { preset in
                        let isSelected = options.effectiveTargetFileSizeBytes == preset.targetBytes
                        Button(preset.localizedTitle) {
                            applyQuickTargetMB(preset.megabytes)
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? AppTheme.Colors.accent : nil)
                        .controlSize(.small)
                        .accessibilityIdentifier("fileoptions.targetSize.\(preset.megabytes)")
                    }
                }
            }

            HStack(spacing: AppTheme.Spacing.xs) {
                TextField("Custom MB", text: $customTargetMBInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .accessibilityLabel("Custom target size in MB")
                    .accessibilityIdentifier("fileoptions.targetSize.customInput")

                Text("MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Apply") {
                    let normalized = customTargetMBInput
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: ",", with: ".")
                    if let mb = Double(normalized), mb > 0 {
                        applyQuickTargetMB(mb)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled((Double(customTargetMBInput.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
                .accessibilityIdentifier("fileoptions.targetSize.applyCustom")
            }
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    private func applyQuickTargetMB(_ mb: Double) {
        let bytes = Int64((mb * 1_000_000.0).rounded())
        customTargetMBInput = mb.rounded() == mb ? "\(Int(mb))" : String(format: "%.1f", mb)
        updateOption {
            $0.targetFileSizeMB = mb
            $0.targetFileSizeBytes = bytes
            if isImageOptions {
                $0.imageOptimizationMode = .targetFileSize
            }
        }
    }

    @ViewBuilder
    private func descriptorRow(for descriptor: ConversionOptionDescriptor) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
            Text(descriptor.title)
                .font(AppTheme.Typography.subheadline)
                .fontWeight(.medium)

            Text(descriptor.description)
                .font(.caption2)
                .foregroundStyle(.secondary)

            renderControl(for: descriptor)
        }
        .padding(.vertical, AppTheme.Spacing.xxs)
    }

    func selectSmartPreset(_ newPreset: ConversionPreset) {
        let currentSelection = options.effectivePreset ?? .custom
        if newPreset == currentSelection && (newPreset == .custom || options.matchesPreset(newPreset, descriptors: descriptors, inputFormat: inputFormat, outputFormat: outputFormat)) {
            return
        }
        var updated = options
        let candidateTargetFormat = inputFormat.flatMap { newPreset.targetOutputFormat(for: $0.category) }
        let resolvedOutputFormat = (candidateTargetFormat != nil && candidateTargetFormat != inputFormat)
            ? candidateTargetFormat
            : outputFormat
        updated.applyPreset(newPreset, inputFormat: inputFormat, outputFormat: resolvedOutputFormat)
        options = updated
    }

    func setPreserveMetadata(_ newValue: Bool) {
        updateOption { $0.preserveMetadata = newValue }
    }

    private func updateOption(_ mutate: (inout ConversionOptions) -> Void) {
        var updated = options
        mutate(&updated)
        updated.reconcilePresetAfterManualEdit(
            availablePresets: availableSmartPresets,
            descriptors: descriptors,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )
        options = updated
    }
    
    // MARK: - Control Renderer
    
    @ViewBuilder
    private func renderControl(for descriptor: ConversionOptionDescriptor) -> some View {
        switch descriptor.kind {
        case .preset(let presets):
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Picker("", selection: Binding(
                    get: { options.effectivePreset ?? .custom },
                    set: { newPreset in
                        selectSmartPreset(newPreset)
                    }
                )) {
                    ForEach(presets, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(descriptor.title)

                if let notice = options.unsupportedPresetNotice(for: outputFormat) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.info)
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            
        case .qualityPreset(let presets):
            if descriptor.id == "mediaQuality" {
                Picker("", selection: Binding(
                    get: { options.effectiveMediaQuality },
                    set: { newQuality in
                        updateOption { $0.mediaQuality = newQuality }
                    }
                )) {
                    ForEach(presets, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel(descriptor.title)
            } else {
                Picker("", selection: Binding(
                    get: {
                        let current = options.effectiveImageQuality
                        return presets.min(by: { abs($0.value - current) < abs($1.value - current) }) ?? .high
                    },
                    set: { newPreset in
                        updateOption { $0.imageQuality = newPreset.value }
                    }
                )) {
                    ForEach(presets, id: \.self) { preset in
                        Text("\(preset.rawValue) (\(Int(preset.value * 100))%)").tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(descriptor.title)
            }
            
        case .targetSize(let sizes):
            let resolvedSizes: [Double] = {
                var list = sizes.compactMap { $0 }
                if let current = options.targetFileSizeMB, !list.contains(where: { abs($0 - current) < 0.001 }) {
                    list.append(current)
                }
                return list.sorted()
            }()
            Picker("", selection: Binding(
                get: { options.targetFileSizeMB },
                set: { newMB in
                    updateOption {
                        $0.targetFileSizeMB = newMB
                        $0.targetFileSizeBytes = newMB.map { Int64($0 * 1_000_000) }
                    }
                }
            )) {
                Text("Off (No limit)").tag(Double?.none)
                ForEach(resolvedSizes, id: \.self) { size in
                    let label = size.rounded() == size ? "\(Int(size)) MB" : String(format: "%.1f MB", size)
                    Text(label).tag(Double?.some(size))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(descriptor.title)
            
        case .dpiPreset(let dpis):
            Picker("", selection: Binding(
                get: { options.pdfDPI ?? 150.0 },
                set: { newDPI in
                    updateOption { $0.pdfDPI = newDPI }
                }
            )) {
                ForEach(dpis, id: \.self) { dpi in
                    Text("\(Int(dpi)) DPI").tag(dpi)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(descriptor.title)
            
        case .pdfOfficeMode(let modes):
            Picker("", selection: Binding(
                get: { options.pdfOfficeMode ?? .automatic },
                set: { newMode in
                    updateOption { $0.pdfOfficeMode = newMode }
                }
            )) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(descriptor.title)
            
        case .toggle(let title, let defaultValue):
            if descriptor.id == "webpLossless" {
                Toggle(title, isOn: Binding(
                    get: { options.webpLossless },
                    set: { newValue in updateOption { $0.webpLossless = newValue } }
                ))
                .accessibilityLabel(descriptor.title)
            } else if descriptor.id == "preserveMetadata" {
                Toggle(title, isOn: Binding(
                    get: { options.preserveMetadata },
                    set: { newValue in setPreserveMetadata(newValue) }
                ))
                .accessibilityLabel(descriptor.title)
            } else if descriptor.id == "overwriteExisting" {
                Toggle(title, isOn: $options.overwriteExisting)
                    .accessibilityLabel(descriptor.title)
            } else {
                Toggle(title, isOn: Binding(
                    get: { options.customOptions[descriptor.id].map { $0 == "true" } ?? defaultValue },
                    set: { newValue in
                        updateOption { $0.customOptions[descriptor.id] = newValue ? "true" : "false" }
                    }
                ))
                .accessibilityLabel(descriptor.title)
            }
            
        case .picker(let choices, let defaultValue):
            Picker("", selection: Binding(
                get: { options.customOptions[descriptor.id] ?? defaultValue },
                set: { newVal in
                    updateOption {
                        if newVal.isEmpty {
                            $0.customOptions.removeValue(forKey: descriptor.id)
                        } else {
                            $0.customOptions[descriptor.id] = newVal
                        }
                    }
                }
            )) {
                ForEach(choices) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(descriptor.title)
        }
    }
}

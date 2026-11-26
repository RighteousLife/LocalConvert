import SwiftUI

struct ImageOptimizationSectionView: View {
    @Binding var options: ConversionOptions
    var isImageTarget: Bool = true
    var availablePresets: [ConversionPreset] = []
    var descriptors: [ConversionOptionDescriptor] = []
    var inputFormat: FileFormat? = nil
    var outputFormat: FileFormat? = nil
    
    @State private var targetSizeInputKB: String = ""
    @State private var customWidthInput: String = ""
    @State private var customHeightInput: String = ""
    @State private var customPercentInput: String = ""
    @State private var lastSyncedTargetSizeKB: String = ""
    @State private var lastSyncedWidth: String = ""
    @State private var lastSyncedHeight: String = ""
    @State private var lastSyncedPercent: String = ""

    private var showsWebPLosslessToggle: Bool {
        outputFormat == .webp || descriptors.contains(where: { $0.id == "webpLossless" })
    }

    private func updateOption(_ mutate: (inout ConversionOptions) -> Void) {
        var updated = options
        mutate(&updated)
        if !availablePresets.isEmpty {
            updated.reconcilePresetAfterManualEdit(
                availablePresets: availablePresets,
                descriptors: descriptors,
                inputFormat: inputFormat,
                outputFormat: outputFormat
            )
        }
        options = updated
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section Header
            HStack {
                Image(systemName: "photo.badge.checkmark")
                    .foregroundStyle(.tint)
                Text("Image Optimization & Transform")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if options.hasImageOptimization {
                    Button("Reset") {
                        resetToDefaults()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reset image optimization settings")
                }
            }
            
            // 1. Optimization Mode
            VStack(alignment: .leading, spacing: 4) {
                Text("Optimization Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Picker("", selection: Binding(
                    get: { options.imageOptimizationMode },
                    set: { newMode in
                        applyModeChange(newMode)
                    }
                )) {
                    ForEach(ImageOptimizationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Optimization Mode")
            }
            
            // 2. Target File Size (if selected)
            if options.imageOptimizationMode == .targetFileSize {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target File Size (Maximum)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 8) {
                        TextField("e.g. 500", text: $targetSizeInputKB)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityLabel("Target File Size in KB")
                            .onChange(of: targetSizeInputKB) { _, newValue in
                                guard newValue != lastSyncedTargetSizeKB else { return }
                                if let kb = Int64(newValue.trimmingCharacters(in: .whitespaces)), kb > 0 {
                                    let newBytes = kb * 1_000
                                    if options.targetFileSizeBytes != newBytes {
                                        updateOption {
                                            $0.targetFileSizeBytes = newBytes
                                            $0.targetFileSizeMB = Double(newBytes) / 1_000_000.0
                                        }
                                    }
                                }
                            }
                        
                        Text("KB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                    }
                    
                    // Quick presets
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            targetPresetButton(label: "250 KB", bytes: 250_000)
                            targetPresetButton(label: "500 KB", bytes: 500_000)
                            targetPresetButton(label: "1 MB", bytes: 1_000_000)
                            targetPresetButton(label: "2 MB", bytes: 2_000_000)
                            targetPresetButton(label: "5 MB", bytes: 5_000_000)
                        }
                    }
                    
                    // Quality floor & lossless feedback
                    if let bytes = options.targetFileSizeBytes, bytes < 15_000 {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text("Target size could not be reached without exceeding the minimum quality.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    } else if options.imageOptimizationMode == .lossless && options.targetFileSizeBytes != nil {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "info.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Text("Target size cannot be reached with lossless compression.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(AppTheme.Spacing.sm)
                .background(AppTheme.Colors.subtleSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                )
            }
            
            // 3. Quality Slider (if lossy and not fixed target size)
            if options.imageOptimizationMode != .lossless && options.imageOptimizationMode != .targetFileSize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Quality")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((options.imageQuality ?? 0.85) * 100))%")
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    
                    Slider(
                        value: Binding(
                            get: { options.imageQuality ?? 0.85 },
                            set: { newQuality in
                                applyQualitySliderChange(newQuality)
                            }
                        ),
                        in: 0.10...1.0,
                        step: 0.05
                    )
                    .accessibilityLabel("Image Quality")
                }
            }

            if showsWebPLosslessToggle {
                Toggle(isOn: Binding(
                    get: { options.webpLossless || options.imageOptimizationMode == .lossless },
                    set: { newValue in
                        applyWebPLosslessToggle(newValue)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lossless WebP")
                            .font(.caption)
                        Text("Encode without quality loss (larger file)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Lossless WebP")
            }
            
            Divider()
            
            // 4. Resize Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Resize")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                
                Picker("Resize Mode", selection: $options.resizeMode) {
                    ForEach(ImageResizeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Resize Mode")
                
                if options.resizeMode != .none {
                    resizeInputsView
                }
            }
            
            Divider()
            
            // 5. Crop Section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "crop")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Crop")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                
                Picker("Crop Mode", selection: $options.cropMode) {
                    ForEach(ImageCropMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Crop Mode")
                
                if options.cropMode != .none {
                    Picker("Aspect Ratio", selection: $options.cropAspectRatio) {
                        ForEach(ImageCropAspectRatio.allCases, id: \.self) { ratio in
                            Text(ratio.displayName).tag(ratio)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel("Crop Aspect Ratio")
                }
            }
            
            Divider()
            
            // 6. Metadata preservation toggle
            Toggle(isOn: Binding(
                get: { options.preserveMetadata },
                set: { newValue in
                    updateOption { $0.preserveMetadata = newValue }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Preserve Metadata")
                        .font(.caption)
                    Text("Keep EXIF, color profile, and camera info")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Preserve Metadata")
        }
        .onAppear {
            syncInputsFromOptions()
        }
        .onChange(of: options.targetFileSizeBytes) { _, _ in
            syncInputsFromOptions()
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var resizeInputsView: some View {
        switch options.resizeMode {
        case .none:
            EmptyView()
        case .exactWidth, .longestEdge, .shortestEdge:
            HStack(spacing: 8) {
                TextField("Width (px)", text: $customWidthInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Resize Width in pixels")
                    .onChange(of: customWidthInput) { _, val in
                        guard val != lastSyncedWidth else { return }
                        options.resizeWidth = Int(val.trimmingCharacters(in: .whitespaces))
                    }
                Text("pixels")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
        case .exactHeight:
            HStack(spacing: 8) {
                TextField("Height (px)", text: $customHeightInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .accessibilityLabel("Resize Height in pixels")
                    .onChange(of: customHeightInput) { _, val in
                        guard val != lastSyncedHeight else { return }
                        options.resizeHeight = Int(val.trimmingCharacters(in: .whitespaces))
                    }
                Text("pixels")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
        case .exactDimensions:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("W", text: $customWidthInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .accessibilityLabel("Resize Width in pixels")
                        .onChange(of: customWidthInput) { _, val in
                            guard val != lastSyncedWidth else { return }
                            options.resizeWidth = Int(val.trimmingCharacters(in: .whitespaces))
                        }
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("H", text: $customHeightInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .accessibilityLabel("Resize Height in pixels")
                        .onChange(of: customHeightInput) { _, val in
                            guard val != lastSyncedHeight else { return }
                            options.resizeHeight = Int(val.trimmingCharacters(in: .whitespaces))
                        }
                    Text("px")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Toggle("Preserve Aspect Ratio", isOn: $options.preserveAspectRatio)
                    .font(.caption2)
                    .accessibilityLabel("Preserve Aspect Ratio")
            }
            
        case .percentage:
            HStack(spacing: 8) {
                TextField("50", text: $customPercentInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .accessibilityLabel("Resize Percentage")
                    .onChange(of: customPercentInput) { _, val in
                        guard val != lastSyncedPercent else { return }
                        if let pct = Double(val.trimmingCharacters(in: .whitespaces)) {
                            options.resizePercentage = pct / 100.0
                        }
                    }
                Text("% of original")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func targetPresetButton(label: String, bytes: Int64) -> some View {
        let isActive = options.targetFileSizeBytes == bytes
        return Button(action: {
            let formatted = formatTargetSizeKB(bytes)
            lastSyncedTargetSizeKB = formatted
            targetSizeInputKB = formatted
            updateOption {
                $0.targetFileSizeBytes = bytes
                $0.targetFileSizeMB = Double(bytes) / 1_000_000.0
            }
        }) {
            Text(label)
                .font(AppTheme.Typography.badge)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, AppTheme.Spacing.xs + 2)
                .padding(.vertical, AppTheme.Spacing.xxs)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? AppTheme.Colors.accent : nil)
        .controlSize(.mini)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Set target file size to \(label)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
    
    // MARK: - Helpers

    private func formatTargetSizeKB(_ bytes: Int64) -> String {
        if bytes % 1_000 == 0 {
            return "\(bytes / 1_000)"
        }
        if bytes % 1024 == 0 {
            return "\(bytes / 1024)"
        }
        return "\(max(1, Int64((Double(bytes) / 1_000.0).rounded())))"
    }
    
    func applyModeChange(_ mode: ImageOptimizationMode) {
        if mode == .smallFile {
            lastSyncedTargetSizeKB = "1000"
            targetSizeInputKB = "1000"
        } else if mode == .targetFileSize && options.targetFileSizeBytes == nil {
            lastSyncedTargetSizeKB = "500"
            targetSizeInputKB = "500"
        }
        updateOption { opts in
            opts.imageOptimizationMode = mode
            switch mode {
            case .balanced:
                opts.imageQuality = 0.80
                opts.webpLossless = false
                opts.targetFileSizeBytes = nil
                opts.targetFileSizeMB = nil
            case .quality:
                opts.imageQuality = 0.90
                opts.webpLossless = false
                opts.targetFileSizeBytes = nil
                opts.targetFileSizeMB = nil
            case .maximum:
                opts.imageQuality = 1.0
                opts.webpLossless = (outputFormat == .webp || outputFormat == nil)
                opts.preserveMetadata = true
                opts.targetFileSizeBytes = nil
                opts.targetFileSizeMB = nil
                opts.imageOptimizationMode = .quality
            case .smallFile:
                opts.imageQuality = 0.50
                opts.webpLossless = false
                opts.preserveMetadata = false
                opts.targetFileSizeBytes = 1_000_000 // 1 MB canonical Small File preset target
                opts.targetFileSizeMB = 1.0
                opts.imageOptimizationMode = .targetFileSize
            case .lossless:
                opts.imageQuality = 1.0
                opts.webpLossless = (outputFormat == .webp || outputFormat == nil)
                opts.targetFileSizeBytes = nil
                opts.targetFileSizeMB = nil
            case .targetFileSize:
                if opts.targetFileSizeBytes == nil {
                    opts.targetFileSizeBytes = 500_000
                    opts.targetFileSizeMB = 0.5
                }
            case .custom:
                break
            }
        }
    }
    
    func applyQualitySliderChange(_ newQuality: Double) {
        updateOption {
            $0.imageQuality = newQuality
            $0.webpLossless = false
            if $0.imageOptimizationMode != .custom {
                $0.imageOptimizationMode = .custom
            }
        }
    }

    func applyWebPLosslessToggle(_ newValue: Bool) {
        updateOption {
            $0.webpLossless = newValue
            if !newValue && $0.imageOptimizationMode == .lossless {
                $0.imageOptimizationMode = .custom
            }
        }
    }

    func resetToDefaults() {
        lastSyncedTargetSizeKB = ""
        lastSyncedWidth = ""
        lastSyncedHeight = ""
        lastSyncedPercent = ""
        targetSizeInputKB = ""
        customWidthInput = ""
        customHeightInput = ""
        customPercentInput = ""
        updateOption { opts in
            opts.imageOptimizationMode = .balanced
            opts.imageQuality = 0.90
            opts.webpLossless = false
            opts.targetFileSizeBytes = nil
            opts.targetFileSizeMB = nil
            opts.resizeMode = .none
            opts.resizeWidth = nil
            opts.resizeHeight = nil
            opts.resizePercentage = nil
            opts.cropMode = .none
            opts.cropAspectRatio = .original
            opts.cropRect = nil
            opts.preserveMetadata = true
        }
    }
    
    private func syncInputsFromOptions() {
        let nextKB: String
        if let bytes = options.effectiveTargetFileSizeBytes {
            nextKB = formatTargetSizeKB(bytes)
        } else {
            nextKB = ""
        }
        lastSyncedTargetSizeKB = nextKB
        if targetSizeInputKB != nextKB {
            targetSizeInputKB = nextKB
        }

        if let w = options.resizeWidth {
            let s = "\(w)"
            lastSyncedWidth = s
            if customWidthInput != s { customWidthInput = s }
        } else {
            lastSyncedWidth = ""
            if !customWidthInput.isEmpty { customWidthInput = "" }
        }

        if let h = options.resizeHeight {
            let s = "\(h)"
            lastSyncedHeight = s
            if customHeightInput != s { customHeightInput = s }
        } else {
            lastSyncedHeight = ""
            if !customHeightInput.isEmpty { customHeightInput = "" }
        }

        if let p = options.resizePercentage {
            let s = "\(Int(round(p * 100)))"
            lastSyncedPercent = s
            if customPercentInput != s { customPercentInput = s }
        } else {
            lastSyncedPercent = ""
            if !customPercentInput.isEmpty { customPercentInput = "" }
        }
    }
}

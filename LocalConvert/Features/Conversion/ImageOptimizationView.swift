import SwiftUI

struct ImageOptimizationSectionView: View {
    @Binding var options: ConversionOptions
    var isImageTarget: Bool = true
    
    @State private var targetSizeInputKB: String = ""
    @State private var customWidthInput: String = ""
    @State private var customHeightInput: String = ""
    @State private var customPercentInput: String = ""
    
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
                }
            }
            
            // 1. Optimization Mode
            VStack(alignment: .leading, spacing: 4) {
                Text("Optimization Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Picker("", selection: $options.imageOptimizationMode) {
                    ForEach(ImageOptimizationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: options.imageOptimizationMode) { _, newMode in
                    handleModeChange(newMode)
                }
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
                            .onChange(of: targetSizeInputKB) { _, newValue in
                                if let kb = Int64(newValue.trimmingCharacters(in: .whitespaces)), kb > 0 {
                                    options.targetFileSizeBytes = kb * 1024
                                }
                            }
                        
                        Text("KB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                    }
                    
                    // Quick presets
                    HStack(spacing: 4) {
                        targetPresetButton(label: "250 KB", bytes: 250 * 1024)
                        targetPresetButton(label: "500 KB", bytes: 500 * 1024)
                        targetPresetButton(label: "1 MB", bytes: 1_000_000)
                        targetPresetButton(label: "2 MB", bytes: 2_000_000)
                        targetPresetButton(label: "5 MB", bytes: 5_000_000)
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
                .padding(8)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
                            set: {
                                options.imageQuality = $0
                                if options.imageOptimizationMode != .custom {
                                    options.imageOptimizationMode = .custom
                                }
                            }
                        ),
                        in: 0.10...1.0,
                        step: 0.05
                    )
                }
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
                .pickerStyle(.menu)
                
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
                .pickerStyle(.menu)
                
                if options.cropMode != .none {
                    Picker("Aspect Ratio", selection: $options.cropAspectRatio) {
                        ForEach(ImageCropAspectRatio.allCases, id: \.self) { ratio in
                            Text(ratio.displayName).tag(ratio)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            Divider()
            
            // 6. Metadata preservation toggle
            Toggle(isOn: $options.preserveMetadata) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Preserve Metadata")
                        .font(.caption)
                    Text("Keep EXIF, color profile, and camera info")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
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
                    .onChange(of: customWidthInput) { _, val in
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
                    .onChange(of: customHeightInput) { _, val in
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
                        .onChange(of: customWidthInput) { _, val in
                            options.resizeWidth = Int(val.trimmingCharacters(in: .whitespaces))
                        }
                    Text("×")
                        .foregroundStyle(.secondary)
                    TextField("H", text: $customHeightInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: customHeightInput) { _, val in
                            options.resizeHeight = Int(val.trimmingCharacters(in: .whitespaces))
                        }
                    Text("px")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Toggle("Preserve Aspect Ratio", isOn: $options.preserveAspectRatio)
                    .font(.caption2)
            }
            
        case .percentage:
            HStack(spacing: 8) {
                TextField("50", text: $customPercentInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onChange(of: customPercentInput) { _, val in
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
        Button(action: {
            options.targetFileSizeBytes = bytes
            targetSizeInputKB = "\(bytes / 1024)"
        }) {
            Text(label)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
    
    // MARK: - Helpers
    
    private func handleModeChange(_ mode: ImageOptimizationMode) {
        switch mode {
        case .balanced:
            options.imageQuality = 0.80
            options.webpLossless = false
            options.targetFileSizeBytes = nil
        case .quality:
            options.imageQuality = 0.90
            options.webpLossless = false
            options.targetFileSizeBytes = nil
        case .maximum:
            options.imageQuality = 0.95
            options.webpLossless = true
            options.targetFileSizeBytes = nil
        case .smallFile:
            options.imageQuality = 0.55
            options.webpLossless = false
            options.targetFileSizeBytes = 500_000 // 500 KB
            targetSizeInputKB = "500"
        case .lossless:
            options.imageQuality = 1.0
            options.webpLossless = true
            options.targetFileSizeBytes = nil
        case .targetFileSize:
            if options.targetFileSizeBytes == nil {
                options.targetFileSizeBytes = 500_000
                targetSizeInputKB = "500"
            }
        case .custom:
            break
        }
    }
    
    private func resetToDefaults() {
        options.imageOptimizationMode = .balanced
        options.imageQuality = 0.85
        options.webpLossless = false
        options.targetFileSizeBytes = nil
        options.targetFileSizeMB = nil
        options.resizeMode = .none
        options.resizeWidth = nil
        options.resizeHeight = nil
        options.resizePercentage = nil
        options.cropMode = .none
        options.cropAspectRatio = .original
        options.cropRect = nil
        options.preserveMetadata = true
        targetSizeInputKB = ""
        customWidthInput = ""
        customHeightInput = ""
        customPercentInput = ""
    }
    
    private func syncInputsFromOptions() {
        if let bytes = options.targetFileSizeBytes {
            targetSizeInputKB = "\(bytes / 1024)"
        }
        if let w = options.resizeWidth {
            customWidthInput = "\(w)"
        }
        if let h = options.resizeHeight {
            customHeightInput = "\(h)"
        }
        if let p = options.resizePercentage {
            customPercentInput = "\(Int(round(p * 100)))"
        }
    }
}

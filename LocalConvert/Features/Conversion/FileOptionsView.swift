import SwiftUI

// MARK: - File Options View

struct FileOptionsView: View {
    @Binding var options: ConversionOptions
    let descriptors: [ConversionOptionDescriptor]
    let fileName: String
    @Environment(\.dismiss) private var dismiss
    
    private var isImageOptions: Bool {
        descriptors.contains(where: { $0.id == "imageQuality" || $0.id == "webpLossless" })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversion Options")
                        .font(.headline)
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isImageOptions {
                        ImageOptimizationSectionView(options: $options)
                    } else {
                        // Dynamic Options List
                        ForEach(descriptors) { descriptor in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(descriptor.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Text(descriptor.description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                
                                renderControl(for: descriptor)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 340, idealWidth: 380, minHeight: 280, maxHeight: 520)
    }
    
    // MARK: - Control Renderer
    
    @ViewBuilder
    private func renderControl(for descriptor: ConversionOptionDescriptor) -> some View {
        switch descriptor.kind {
        case .preset(let presets):
            Picker("", selection: Binding(
                get: { options.preset ?? .custom },
                set: { 
                    options.preset = $0
                    options.applyPreset()
                }
            )) {
                ForEach(presets, id: \.self) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)
            
        case .qualityPreset(let presets):
            if descriptor.id == "mediaQuality" {
                Picker("", selection: Binding(
                    get: { options.mediaQuality ?? .high },
                    set: { options.mediaQuality = $0 }
                )) {
                    ForEach(presets, id: \.self) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("", selection: Binding(
                    get: {
                        let current = options.effectiveImageQuality
                        return presets.min(by: { abs($0.value - current) < abs($1.value - current) }) ?? .high
                    },
                    set: { options.imageQuality = $0.value }
                )) {
                    ForEach(presets, id: \.self) { preset in
                        Text("\(preset.rawValue) (\(Int(preset.value * 100))%)").tag(preset)
                    }
                }
                .pickerStyle(.menu)
            }
            
        case .targetSize(let sizes):
            Picker("", selection: Binding(
                get: { options.targetFileSizeMB },
                set: { options.targetFileSizeMB = $0 }
            )) {
                Text("Off (No limit)").tag(Double?.none)
                ForEach(sizes.compactMap { $0 }, id: \.self) { size in
                    Text("\(Int(size)) MB").tag(Double?.some(size))
                }
            }
            .pickerStyle(.menu)
            
        case .dpiPreset(let dpis):
            Picker("", selection: Binding(
                get: { options.pdfDPI ?? 150.0 },
                set: { options.pdfDPI = $0 }
            )) {
                ForEach(dpis, id: \.self) { dpi in
                    Text("\(Int(dpi)) DPI").tag(dpi)
                }
            }
            .pickerStyle(.menu)
            
        case .pdfOfficeMode(let modes):
            Picker("", selection: Binding(
                get: { options.pdfOfficeMode ?? .automatic },
                set: { options.pdfOfficeMode = $0 }
            )) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            
        case .toggle(let title, _):
            if descriptor.id == "webpLossless" {
                Toggle(title, isOn: $options.webpLossless)
            } else if descriptor.id == "preserveMetadata" {
                Toggle(title, isOn: $options.preserveMetadata)
            } else if descriptor.id == "overwriteExisting" {
                Toggle(title, isOn: $options.overwriteExisting)
            } else {
                Toggle(title, isOn: Binding(
                    get: { options.customOptions[descriptor.id] == "true" },
                    set: { options.customOptions[descriptor.id] = $0 ? "true" : "false" }
                ))
            }
        }
    }
}

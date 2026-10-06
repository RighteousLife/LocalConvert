import SwiftUI
import AppKit

struct PresetManagerView: View {
    @ObservedObject var presetManager = PresetManager.shared
    @EnvironmentObject var appState: AppState
    
    @State private var selectedPresetId: UUID?
    @State private var isShowingCreateSheet = false
    @State private var presetToEdit: SavedPreset?
    @State private var showDeleteConfirmation = false
    @State private var presetToDelete: SavedPreset?
    @State private var applyFeedbackMessage: String?
    
    private var selectedPreset: SavedPreset? {
        if let id = selectedPresetId {
            return presetManager.presets.first { $0.id == id }
        }
        return presetManager.presets.first
    }
    
    private var builtInPresets: [SavedPreset] {
        presetManager.presets.filter { $0.isBuiltIn }
    }
    
    private var customPresets: [SavedPreset] {
        presetManager.presets.filter { !$0.isBuiltIn }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Column: Preset List (~230-250 pt)
            presetListColumn
                .frame(width: 240)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
            
            Divider()
            
            // Right Column: Preset Detail (Expands to fill all remaining width)
            Group {
                if let preset = selectedPreset {
                    presetDetailView(preset)
                } else {
                    ContentUnavailableView(
                        "No Preset Selected",
                        systemImage: "slider.horizontal.3",
                        description: Text("Select a preset from the list or create a new one.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Presets")
        .sheet(isPresented: $isShowingCreateSheet) {
            PresetEditView()
        }
        .sheet(item: $presetToEdit) { preset in
            PresetEditView(preset: preset)
        }
        .confirmationDialog(
            "Delete Preset?",
            isPresented: $showDeleteConfirmation,
            presenting: presetToDelete
        ) { preset in
            Button("Delete '\(preset.name)'", role: .destructive) {
                presetManager.delete(id: preset.id)
                if selectedPresetId == preset.id {
                    selectedPresetId = presetManager.presets.first?.id
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text("Are you sure you want to delete this preset? This action cannot be undone.")
        }
    }
    
    // MARK: - Preset List Column
    
    private var presetListColumn: some View {
        VStack(spacing: 0) {
            List(selection: $selectedPresetId) {
                if !builtInPresets.isEmpty {
                    Section("Built-in Presets") {
                        ForEach(builtInPresets) { preset in
                            PresetRow(preset: preset)
                                .tag(preset.id)
                        }
                    }
                }
                
                Section("My Presets") {
                    if customPresets.isEmpty {
                        Text("No custom presets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        ForEach(customPresets) { preset in
                            PresetRow(preset: preset)
                                .tag(preset.id)
                                .contextMenu {
                                    Button("Edit...") {
                                        presetToEdit = preset
                                    }
                                    Button("Duplicate") {
                                        _ = presetManager.duplicate(id: preset.id)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        presetToDelete = preset
                                        showDeleteConfirmation = true
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            
            Divider()
            
            // Bottom Action Bar
            HStack {
                Button(action: { isShowingCreateSheet = true }) {
                    Label("New Preset", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                
                Spacer()
                
                Button(action: { presetManager.resetToDefaults() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .help("Reset default presets")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - Detail View (Native macOS Inspector Style)
    
    private func presetDetailView(_ preset: SavedPreset) -> some View {
        VStack(spacing: 0) {
            // Compact Header Bar
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(preset.name)
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        Text(preset.targetFormat.displayName)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        
                        if preset.isBuiltIn {
                            Text("Built-in")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.12))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
                        }
                    }
                    
                    if let desc = preset.description, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // Actions
                HStack(spacing: 6) {
                    if !preset.isBuiltIn {
                        Button("Edit...") {
                            presetToEdit = preset
                        }
                        .controlSize(.small)
                        
                        Button(role: .destructive) {
                            presetToDelete = preset
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                    }
                    
                    Button("Duplicate") {
                        if let dup = presetManager.duplicate(id: preset.id) {
                            selectedPresetId = dup.id
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            
            Divider()
            
            // Queue Compatibility Banner (if files exist in queue)
            if !appState.droppedFiles.isEmpty {
                let urls = appState.droppedFiles.map { $0.url }
                let validation = presetManager.validator.validateBatch(preset: preset, urls: urls)
                
                HStack(spacing: 10) {
                    Image(systemName: validation.hasCompatibleFiles ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(validation.hasCompatibleFiles ? .green : .secondary)
                    
                    Text(validation.summary)
                        .font(.caption)
                    
                    if let feedback = applyFeedbackMessage {
                        Text("— \(feedback)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    
                    Spacer()
                    
                    if validation.hasCompatibleFiles {
                        Button("Apply to Queue") {
                            presetManager.apply(preset: preset, to: appState)
                            applyFeedbackMessage = "Applied!"
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(validation.hasCompatibleFiles ? Color.green.opacity(0.08) : Color.secondary.opacity(0.08))
                
                Divider()
            }
            
            // Native macOS Inspector Layout (Clean grouped sections without heavy cards)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Conversion Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Conversion")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        VStack(spacing: 6) {
                            inspectorRow(
                                title: "Output Target",
                                value: "\(preset.targetFormat.displayName) (.\(preset.targetFormat.fileExtension))"
                            )
                            Divider()
                            inspectorRow(
                                title: "Input Compatibility",
                                value: compatibilityDescription(for: preset)
                            )
                            Divider()
                            inspectorRow(
                                title: "Output Location",
                                value: preset.outputDestinationPolicy.displayName
                            )
                            Divider()
                            inspectorRow(
                                title: "File Naming",
                                value: preset.outputNamingPolicy.displayName
                            )
                        }
                    }
                    
                    // Options Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Options")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        
                        VStack(spacing: 6) {
                            inspectorRow(
                                title: "Preserve Metadata",
                                value: preset.options.preserveMetadata ? "Yes" : "No"
                            )
                            
                            if let q = preset.options.imageQuality {
                                Divider()
                                inspectorRow(
                                    title: "Image Quality",
                                    value: "\(Int(q * 100))%"
                                )
                            }
                            
                            if preset.options.webpLossless {
                                Divider()
                                inspectorRow(
                                    title: "WebP Lossless",
                                    value: "Enabled"
                                )
                            }
                            
                            if let dpi = preset.options.pdfDPI {
                                Divider()
                                inspectorRow(
                                    title: "PDF Rasterization",
                                    value: "\(Int(dpi)) DPI"
                                )
                            }
                            
                            if let mq = preset.options.mediaQuality {
                                Divider()
                                inspectorRow(
                                    title: "Media Quality",
                                    value: mq.rawValue
                                )
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func inspectorRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            
            Spacer(minLength: 20)
            
            Text(value)
                .font(.body)
                .fontWeight(.regular)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Helpers
    
    private func compatibilityDescription(for preset: SavedPreset) -> String {
        if let source = preset.sourceConstraint {
            return "Only \(source.displayName)"
        }
        if let category = preset.sourceCategoryConstraint {
            return "All \(category.rawValue.capitalized) Files"
        }
        return "All Convertible Formats"
    }
}

// MARK: - Preset Row

struct PresetRow: View {
    let preset: SavedPreset
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: preset.targetFormat.category))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)
                
                Text(preset.targetFormat.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
    
    private func iconName(for category: FormatCategory) -> String {
        switch category {
        case .image: return "photo"
        case .video: return "video"
        case .audio: return "music.note"
        case .document: return "doc.text"
        default: return "doc"
        }
    }
}

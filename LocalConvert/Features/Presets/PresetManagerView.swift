import SwiftUI
import AppKit

struct PresetManagerView: View {
    enum PresetSection: String, CaseIterable, Identifiable {
        case presets = "Presets"
        case watchFolders = "Watch Folders"

        var id: String { rawValue }
    }

    @ObservedObject var presetManager = PresetManager.shared
    @EnvironmentObject var appState: AppState
    
    @State private var selectedSection: PresetSection = .presets
    @State private var selectedPresetId: UUID?
    @State private var isShowingCreateSheet = false
    @State private var presetToEdit: SavedPreset?
    @State private var showDeleteConfirmation = false
    @State private var showResetConfirmation = false
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
        VStack(spacing: 0) {
            sectionHeaderBar
            AppDivider()

            Group {
                switch selectedSection {
                case .presets:
                    presetsSplitView
                case .watchFolders:
                    WatchFoldersSectionView(manager: appState.watchFolderManager, presetManager: presetManager)
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

    private var sectionHeaderBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Picker("Presets Section", selection: $selectedSection) {
                ForEach(PresetSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .accessibilityLabel("Presets and Watch Folders")
            .accessibilityIdentifier("presets.sectionPicker")

            Spacer()

            if !appState.watchFolderManager.rules.isEmpty {
                let activeCount = appState.watchFolderManager.rules.filter {
                    $0.isEnabled && !$0.isPaused && !$0.lastStatus.isError && !appState.watchFolderManager.isGloballyPaused
                }.count
                AppStatusBadge(
                    text: appState.watchFolderManager.isGloballyPaused
                        ? "Watch Folders Paused"
                        : "\(activeCount) Watch Folder\(activeCount == 1 ? "" : "s") Active",
                    tint: appState.watchFolderManager.isGloballyPaused ? AppTheme.Colors.warning : AppTheme.Colors.success
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var presetsSplitView: some View {
        HSplitView {
            // Left Column: Preset List
            presetListColumn
                .frame(
                    minWidth: AppTheme.Layout.toolboxSidebarMin,
                    idealWidth: AppTheme.Layout.toolboxSidebarIdeal,
                    maxWidth: AppTheme.Layout.toolboxSidebarMax
                )
                .appSecondarySidebarSurface()
            
            // Right Column: Preset Detail (Expands to fill all remaining width)
            Group {
                if let preset = selectedPreset {
                    presetDetailView(preset)
                } else {
                    AppEmptyStateView(
                        icon: "slider.horizontal.3",
                        title: "No Preset Selected",
                        subtitle: "Select a preset from the list or create a new one.",
                        primaryButtonTitle: "Create New Preset...",
                        primaryButtonIcon: "plus",
                        onPrimaryAction: { isShowingCreateSheet = true }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appWorkspaceSurface()
        }
    }
    
    // MARK: - Preset List Column
    
    private var presetListColumn: some View {
        VStack(spacing: 0) {
            List(selection: $selectedPresetId) {
                if !builtInPresets.isEmpty {
                    Section("Built-in Presets") {
                        ForEach(builtInPresets) { preset in
                            PresetRow(preset: preset, isSelected: selectedPresetId == preset.id)
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
                            PresetRow(preset: preset, isSelected: selectedPresetId == preset.id)
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
            .appSecondarySidebarSurface()
            
            AppDivider()
            
            // Bottom Action Bar
            HStack {
                Button(action: { isShowingCreateSheet = true }) {
                    Label("New Preset", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                
                Spacer()
                
                Button(action: { showResetConfirmation = true }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .help("Reset default presets")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset default presets")
                .alert("Reset Default Presets?", isPresented: $showResetConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reset Defaults", role: .destructive) {
                        presetManager.resetToDefaults()
                    }
                } message: {
                    Text("This restores built-in presets to factory settings while keeping custom presets unchanged.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - Detail View (Native macOS Inspector Style)
    
    private func presetDetailView(_ preset: SavedPreset) -> some View {
        VStack(spacing: 0) {
            // Compact Header Bar
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    presetHeaderTitleBlock(preset)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    presetHeaderActions(preset)
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                        Text(preset.name)
                            .font(AppTheme.Typography.pageTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        AppStatusBadge(text: preset.targetFormat.displayName, tint: AppTheme.Colors.accent)

                        if preset.isBuiltIn {
                            AppStatusBadge(text: "Built-in", tint: .secondary)
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                        if let desc = preset.description, !desc.isEmpty {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: AppTheme.Spacing.sm)
                        presetHeaderActions(preset)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.sm + 2)
            .background(AppTheme.Colors.subtleSurface)
            
            AppDivider()
            
            // Queue Compatibility Banner (if files exist in queue)
            if !appState.droppedFiles.isEmpty {
                let urls = appState.droppedFiles.map { $0.url }
                let validation = presetManager.validator.validateBatch(preset: preset, urls: urls)
                let feedbackSuffix = applyFeedbackMessage.map { " — \($0)" } ?? ""
                
                AppInfoBanner(
                    style: validation.hasCompatibleFiles ? .success : .info,
                    message: validation.summary + feedbackSuffix,
                    icon: validation.hasCompatibleFiles ? "checkmark.circle.fill" : "info.circle",
                    actionTitle: validation.hasCompatibleFiles ? "Apply to Queue" : nil,
                    onAction: validation.hasCompatibleFiles ? {
                        presetManager.apply(preset: preset, to: appState)
                        applyFeedbackMessage = "Applied!"
                    } : nil
                )
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.top, AppTheme.Spacing.md)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    AppCard(title: "Conversion", icon: "arrow.triangle.2.circlepath") {
                        VStack(spacing: AppTheme.Spacing.xs + 2) {
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
                    
                    AppCard(title: "Options", icon: "slider.horizontal.3") {
                        VStack(spacing: AppTheme.Spacing.xs + 2) {
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
                .padding(AppTheme.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func presetHeaderTitleBlock(_ preset: SavedPreset) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                Text(preset.name)
                    .font(AppTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                AppStatusBadge(text: preset.targetFormat.displayName, tint: AppTheme.Colors.accent)

                if preset.isBuiltIn {
                    AppStatusBadge(text: "Built-in", tint: .secondary)
                }
            }

            if let desc = preset.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func presetHeaderActions(_ preset: SavedPreset) -> some View {
        HStack(spacing: 6) {
            if !preset.isBuiltIn {
                Button("Edit...") {
                    presetToEdit = preset
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Button(role: .destructive) {
                    presetToDelete = preset
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Delete preset")
            }

            Button("Duplicate") {
                if let dup = presetManager.duplicate(id: preset.id) {
                    selectedPresetId = dup.id
                }
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func inspectorRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            
            Spacer(minLength: 20)
            
            Text(value)
                .font(.body)
                .fontWeight(.regular)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
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
    var isSelected: Bool = false

    @Environment(\.backgroundProminence) private var backgroundProminence
    
    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: iconName(for: preset.targetFormat.category))
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(backgroundProminence == .increased ? Color.white : AppTheme.Colors.accent)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)
                
                Text(preset.targetFormat.displayName)
                    .font(.caption2)
                    .foregroundStyle(backgroundProminence == .increased ? Color.white.opacity(0.85) : .secondary)
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
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        }
    }
}

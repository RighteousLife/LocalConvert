import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarArea
            
            if let notice = appState.folderRejectedNotice {
                folderNoticeArea(notice: notice)
            }
            
            if appState.isBatchCompleted {
                batchCompletionBanner
            }
            
            if !appState.isConverting && !appState.droppedFiles.isEmpty {
                quickActionsStrip
            }
            
            AppDivider()
            
            fileListArea
            
            AppBottomActionBar {
                VStack(spacing: AppTheme.Spacing.sm) {
                    if appState.isConverting {
                        progressArea
                    }
                    bottomBarArea
                }
            }
            .onDrop(of: [.fileURL], isTargeted: .constant(false)) { providers in
                handleFolderDrop(providers: providers)
                return true
            }
        }
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .padding(AppTheme.Spacing.xs)
            }
        }
    }
    
    // MARK: - Toolbar Area
    
    @ViewBuilder
    private var toolbarArea: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("\(appState.droppedFiles.count) file\(appState.droppedFiles.count == 1 ? "" : "s") in queue")
                    .font(AppTheme.Typography.sectionTitle)
                    .accessibilityIdentifier("filelist.countLabel")
                
                if appState.isConverting {
                    Text("\(appState.activeJobCount) active • \(appState.completedJobCount) / \(appState.totalJobCount) completed")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Menu {
                ForEach(PresetManager.shared.presets) { preset in
                    Button(action: {
                        PresetManager.shared.apply(preset: preset, to: appState)
                    }) {
                        Label(preset.name, systemImage: "wand.and.stars")
                    }
                }
            } label: {
                Label("Apply Preset", systemImage: "wand.and.stars")
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(appState.isConverting || appState.droppedFiles.isEmpty)
            .accessibilityLabel("Apply saved preset to queue")
            
            Button(action: addMoreFiles) {
                Label("Add Files", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(appState.isConverting)
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityLabel("Add files")
            
            Button(role: .destructive, action: { appState.removeAllFiles() }) {
                Label("Clear All", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(appState.isConverting)
            .accessibilityLabel("Clear all files")
            .accessibilityIdentifier("filelist.clearAll")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }
    
    // MARK: - Folder Rejection Notice
    
    @ViewBuilder
    private func folderNoticeArea(notice: String) -> some View {
        AppInfoBanner(
            style: .warning,
            message: notice,
            icon: "folder.badge.questionmark",
            actionTitle: appState.pendingFolderURLs.isEmpty ? nil : "Import Files",
            onAction: appState.pendingFolderURLs.isEmpty ? nil : { appState.importFilesFromPendingFolders() },
            onDismiss: {
                appState.folderRejectedNotice = nil
                appState.pendingFolderURLs = []
            }
        )
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.sm)
    }
    
    // MARK: - Batch Completion Banner
    
    @ViewBuilder
    private var batchCompletionBanner: some View {
        AppCard(padding: AppTheme.Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md) {
                    batchCompletionSummaryContent
                    Spacer(minLength: AppTheme.Spacing.sm)
                    batchCompletionActionButtons
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        batchCompletionSummaryContent
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Spacer(minLength: 0)
                        batchCompletionActionButtons
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    @ViewBuilder
    private var batchCompletionSummaryContent: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: appState.failedJobCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(appState.failedJobCount == 0 ? AppTheme.Colors.success : AppTheme.Colors.warning)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(appState.failedJobCount == 0 ? "Batch Conversion Complete" : "Batch Finished with Issues")
                    .font(AppTheme.Typography.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .accessibilityIdentifier("filelist.batchBannerTitle")

                Text("\(appState.completedJobCount) succeeded\(appState.failedJobCount > 0 ? ", \(appState.failedJobCount) failed" : "")\(appState.cancelledJobCount > 0 ? ", \(appState.cancelledJobCount) cancelled" : "")")
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var batchCompletionActionButtons: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button(action: {
                appState.selectedTab = .jobs
            }) {
                Label("View in Jobs", systemImage: "tray.full")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("View completed batch in Jobs Center")

            if let outputDir = resolvedOutputDirectoryForFirstFile() {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                }) {
                    Label("Open Destination", systemImage: "folder")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Open destination folder")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    
    // MARK: - Quick Actions Strip
    
    @ViewBuilder
    private var quickActionsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Repeat Last Conversion
                if let last = appState.lastConversionConfig {
                    if appState.isRepeatConversionCompatible {
                        Button(action: {
                            appState.repeatLastConversion()
                        }) {
                            Label("Repeat: \(last.summary)", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .help("Repeat last conversion (\(last.summary)) (⌘⇧R)")
                        .accessibilityLabel("Repeat last conversion: \(last.summary)")
                        .accessibilityHint("Applies previous conversion settings and starts conversion.")
                    } else {
                        Label("Repeat: \(last.summary)", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .padding(.vertical, 3)
                            .background(AppTheme.Colors.neutralTint)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                            .help("Your last conversion isn't compatible with the selected files.")
                            .accessibilityLabel("Repeat last conversion — unavailable for the selected files")
                            .accessibilityHint("Last conversion is not compatible with the selected files.")
                    }
                    
                    Divider()
                        .frame(height: 14)
                }
                
                // Quick Convert Formats
                if !appState.quickConvertFormats.isEmpty {
                    HStack(spacing: 6) {
                        Text("Quick Convert:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        ForEach(appState.quickConvertFormats, id: \.self) { format in
                            Button(format.shortExtensionLabel) {
                                appState.quickConvert(to: format)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .font(.caption)
                            .help("Convert all files to \(format.displayName)")
                            .accessibilityLabel("Quick convert to \(format.displayName)")
                            .accessibilityHint("Sets all files to \(format.displayName) and starts conversion.")
                        }
                    }
                }
                
                // Quick Presets
                if !appState.quickPresets.isEmpty {
                    Divider()
                        .frame(height: 14)
                    
                    HStack(spacing: 6) {
                        Text("Quick Presets:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        ForEach(appState.quickPresets) { preset in
                            Button(action: {
                                PresetManager.shared.apply(preset: preset, to: appState)
                            }) {
                                Label(preset.name, systemImage: "bolt.fill")
                                    .font(.caption)
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .help("Apply preset: \(preset.name)")
                            .accessibilityLabel("Apply preset \(preset.name)")
                            .accessibilityHint("Applies the \(preset.name) preset to all files.")
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.xs + 2)
        }
        .background(AppTheme.Colors.subtleSurface)
    }
    
    // MARK: - File List Area
    
    @ViewBuilder
    private var fileListArea: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.sm) {
                ForEach(appState.droppedFiles) { file in
                    FileRowView(file: file)
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    // MARK: - Overall Progress Area
    
    @ViewBuilder
    private var progressArea: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            HStack {
                let currentStep = min(appState.completedJobCount + 1, appState.totalJobCount)
                Text("Converting \(currentStep) of \(appState.totalJobCount)")
                    .font(AppTheme.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(Int(appState.batchProgress * 100))%")
                    .font(AppTheme.Typography.monoCaption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            
            ProgressView(value: appState.batchProgress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Overall conversion progress")
                .accessibilityValue("\(Int(appState.batchProgress * 100)) percent")
        }
    }
    
    // MARK: - Bottom Controls Bar
    
    @ViewBuilder
    private var bottomBarArea: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.md + 2) {
                outputLocationControls
                Spacer(minLength: AppTheme.Spacing.sm)
                conversionActionButtons
            }
            VStack(alignment: .trailing, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.md) {
                    outputLocationControls
                    Spacer(minLength: 0)
                }
                conversionActionButtons
            }
        }
    }

    @ViewBuilder
    private var outputLocationControls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Output:")
                .font(AppTheme.Typography.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize()

            Picker("", selection: $appState.outputLocation) {
                ForEach(OutputLocation.allCases) { location in
                    Text(location.rawValue).tag(location)
                }
            }
            .frame(minWidth: 150, maxWidth: 200)
            .accessibilityLabel("Output destination selection")
        }

        if appState.outputLocation == .customFolder {
            Button(action: selectCustomFolder) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "folder")
                        .font(AppTheme.Typography.caption)
                    Text(appState.customOutputDirectory?.lastPathComponent ?? "Choose Folder...")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .controlSize(.small)
            .help(appState.customOutputDirectory?.path ?? "Click to choose custom output directory")
            .accessibilityLabel("Choose custom output folder")
        }
    }

    @ViewBuilder
    private var conversionActionButtons: some View {
        if appState.isConverting {
            Button("Cancel", role: .cancel) {
                appState.cancelConversion()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .fixedSize()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel ongoing conversion")
        } else {
            Button(action: { appState.convertAll() }) {
                Label("Convert All", systemImage: "arrow.triangle.2.circlepath")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize()
            .disabled(!canConvert)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Convert all files")
            .accessibilityIdentifier("filelist.convertAll")
        }
    }
    
    // MARK: - Private Helpers
    
    private var canConvert: Bool {
        appState.droppedFiles.contains { file in
            file.detectedFormat != nil && file.selectedOutputFormat != nil
        }
    }
    
    private func resolvedOutputDirectoryForFirstFile() -> URL? {
        guard let first = appState.droppedFiles.first else { return nil }
        return OutputManager.resolveOutputDirectory(
            for: first.url,
            preference: appState.outputLocation,
            customDirectory: appState.customOutputDirectory
        )
    }
    
    private func addMoreFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Select"
        
        if panel.runModal() == .OK {
            appState.handleDroppedURLs(panel.urls)
        }
    }
    
    private func selectCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            appState.customOutputDirectory = selectedURL
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        Task {
            var droppedURLs: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    if let url = item as? URL {
                        droppedURLs.append(url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        droppedURLs.append(url)
                    }
                }
            }
            if !droppedURLs.isEmpty {
                await MainActor.run {
                    appState.handleDroppedURLs(droppedURLs)
                }
            }
        }
    }
    
    private func handleFolderDrop(providers: [NSItemProvider]) {
        Task {
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    var targetURL: URL?
                    if let url = item as? URL {
                        targetURL = url
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        targetURL = url
                    }
                    if let url = targetURL {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            await MainActor.run {
                                appState.outputLocation = .customFolder
                                appState.customOutputDirectory = url
                            }
                            return
                        }
                    }
                }
            }
        }
    }
}

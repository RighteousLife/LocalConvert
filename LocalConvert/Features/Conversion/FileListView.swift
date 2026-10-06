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
            
            Divider()
            
            fileListArea
            
            Divider()
            
            if appState.isConverting {
                progressArea
            }
            
            bottomBarArea
        }
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .padding(4)
            }
        }
    }
    
    // MARK: - Toolbar Area
    
    @ViewBuilder
    private var toolbarArea: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appState.droppedFiles.count) file\(appState.droppedFiles.count == 1 ? "" : "s") in queue")
                    .font(.headline)
                
                if appState.isConverting {
                    Text("\(appState.activeJobCount) active • \(appState.completedJobCount) / \(appState.totalJobCount) completed")
                        .font(.caption)
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
            .disabled(appState.isConverting || appState.droppedFiles.isEmpty)
            .accessibilityLabel("Apply saved preset to queue")
            
            Button(action: addMoreFiles) {
                Label("Add Files", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(appState.isConverting)
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityLabel("Add files")
            
            Button(role: .destructive, action: { appState.removeAllFiles() }) {
                Label("Clear All", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(appState.isConverting)
            .accessibilityLabel("Clear all files")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // MARK: - Folder Rejection Notice
    
    @ViewBuilder
    private func folderNoticeArea(notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.orange)
            Text(notice)
                .font(.caption)
            
            if !appState.pendingFolderURLs.isEmpty {
                Button(action: {
                    appState.importFilesFromPendingFolders()
                }) {
                    Label("Import Files", systemImage: "arrow.down.doc")
                        .font(.caption)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Import Files")
                .accessibilityHint("Adds supported files from the dropped folder.")
            }
            
            Spacer()
            
            Button(action: {
                appState.folderRejectedNotice = nil
                appState.pendingFolderURLs = []
            }) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss folder notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
    
    // MARK: - Batch Completion Banner
    
    @ViewBuilder
    private var batchCompletionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: appState.failedJobCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(appState.failedJobCount == 0 ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.failedJobCount == 0 ? "Batch Conversion Complete" : "Batch Finished with Issues")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("\(appState.completedJobCount) succeeded\(appState.failedJobCount > 0 ? ", \(appState.failedJobCount) failed" : "")\(appState.cancelledJobCount > 0 ? ", \(appState.cancelledJobCount) cancelled" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                appState.selectedTab = .jobs
            }) {
                Label("View in Jobs", systemImage: "tray.full")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .accessibilityLabel("View completed batch in Jobs Center")
            
            if let outputDir = resolvedOutputDirectoryForFirstFile() {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                }) {
                    Label("Open Destination", systemImage: "folder")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityLabel("Open destination folder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08))
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
                        Button(action: {
                            appState.repeatLastConversion()
                        }) {
                            Label("Repeat: \(last.summary)", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .disabled(true)
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
                            Button(format.fileExtension.uppercased()) {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }
    
    // MARK: - File List Area
    
    @ViewBuilder
    private var fileListArea: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(appState.droppedFiles) { file in
                    FileRowView(file: file)
                }
            }
            .padding(16)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    // MARK: - Overall Progress Area
    
    @ViewBuilder
    private var progressArea: some View {
        VStack(spacing: 4) {
            HStack {
                let currentStep = min(appState.completedJobCount + 1, appState.totalJobCount)
                Text("Converting \(currentStep) of \(appState.totalJobCount)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(Int(appState.batchProgress * 100))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            
            ProgressView(value: appState.batchProgress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
    
    // MARK: - Bottom Controls Bar
    
    @ViewBuilder
    private var bottomBarArea: some View {
        HStack(spacing: 14) {
            // Output location picker
            HStack(spacing: 8) {
                Text("Output:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Picker("", selection: $appState.outputLocation) {
                    ForEach(OutputLocation.allCases) { location in
                        Text(location.rawValue).tag(location)
                    }
                }
                .frame(maxWidth: 200)
                .accessibilityLabel("Output destination selection")
            }
            
            if appState.outputLocation == .customFolder {
                Button(action: selectCustomFolder) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption)
                        Text(appState.customOutputDirectory?.lastPathComponent ?? "Choose Folder...")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .controlSize(.small)
                .help(appState.customOutputDirectory?.path ?? "Click to choose custom output directory")
                .accessibilityLabel("Choose custom output folder")
            }
            
            Spacer()
            
            // Convert / Cancel Actions
            if appState.isConverting {
                Button("Cancel", role: .cancel) {
                    appState.cancelConversion()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel ongoing conversion")
            } else {
                Button(action: { appState.convertAll() }) {
                    Label("Convert All", systemImage: "arrow.triangle.2.circlepath")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canConvert)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Convert all files")
            }
        }
        .padding(16)
        .onDrop(of: [.fileURL], isTargeted: .constant(false)) { providers in
            handleFolderDrop(providers: providers)
            return true
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

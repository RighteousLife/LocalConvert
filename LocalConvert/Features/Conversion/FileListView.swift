import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Toolbar Area
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
            
            // MARK: - Folder Rejection Banner (if user tried to drop folders)
            if let notice = appState.folderRejectedNotice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.caption)
                    Spacer()
                    Button(action: { appState.folderRejectedNotice = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            
            // MARK: - Batch Completion Banner
            if appState.isBatchCompleted {
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
            
            Divider()
            
            // MARK: - File List Area
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
            
            Divider()
            
            // MARK: - Overall Progress Bar (Visible while converting)
            if appState.isConverting {
                ProgressView(value: appState.batchProgress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            
            // MARK: - Bottom Controls Bar
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
        }
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .padding(4)
            }
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
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                
                Task { @MainActor in
                    appState.handleDroppedURLs([url])
                }
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Folder rejection banner if user dropped a folder
            if let notice = appState.folderRejectedNotice {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            
            VStack(spacing: 24) {
                // MARK: - Dashed Drop Zone Box (Focused only on drop action)
                VStack(spacing: 16) {
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                        .symbolEffect(.bounce, value: isTargeted)
                    
                    VStack(spacing: 6) {
                        Text(isTargeted ? "Release to add files" : "Drop files here")
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundStyle(isTargeted ? Color.accentColor : .primary)
                        
                        Text("Images · PDF · Office · Audio · Video")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    
                    Button(action: selectFiles) {
                        Label("Add Files", systemImage: "plus")
                            .frame(minWidth: 120)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityLabel("Add files to convert")
                    
                    // Drop Feedback Indicator (e.g. "3 files added")
                    if let feedback = appState.dropFeedbackText {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(feedback)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                        )
                }
                
                // MARK: - Privacy & Offline Guarantee (Outside the drop zone)
                VStack(spacing: 4) {
                    Text("Your files, Your Mac.")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    
                    Text("All conversions happen locally on your Mac. No data is sent to the cloud.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .accessibilityLabel("File drop zone")
        .accessibilityHint("Drop files here to convert them, or press Command-O to select files")
    }
    
    // MARK: - Actions
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select files to convert"
        panel.prompt = "Select"
        
        if panel.runModal() == .OK {
            appState.handleDroppedURLs(panel.urls)
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
}

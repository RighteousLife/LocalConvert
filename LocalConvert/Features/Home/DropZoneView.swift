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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            
            VStack(spacing: 24) {
                Spacer()
                
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                        .symbolEffect(.bounce, value: isTargeted)
                    
                    Text("Drop files here")
                        .font(.title2)
                        .fontWeight(.medium)
                    
                    Text("or")
                        .foregroundStyle(.secondary)
                    
                    Button(action: selectFiles) {
                        Label("Add Files", systemImage: "folder")
                            .frame(minWidth: 120)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityLabel("Add files to convert")
                }
                
                Spacer()
                
                // Privacy / Local conversion guarantee
                VStack(spacing: 4) {
                    Text("Your files. Your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("All conversions happen locally and offline.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                    )
                    .padding(20)
            }
        }
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

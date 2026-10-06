import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ArtworkEditorView: View {
    let artwork: MetadataArtwork?
    let isWritable: Bool
    let onArtworkChanged: (Data?) -> Void
    
    @State private var isTargeted: Bool = false
    
    init(
        artwork: MetadataArtwork?,
        isWritable: Bool = true,
        onArtworkChanged: @escaping (Data?) -> Void
    ) {
        self.artwork = artwork
        self.isWritable = isWritable
        self.onArtworkChanged = onArtworkChanged
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Artwork Preview
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: 110, height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isTargeted ? Color.accentColor : Color(NSColor.separatorColor), lineWidth: isTargeted ? 2 : 1)
                    )
                
                if let image = artwork?.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .cornerRadius(6)
                        .accessibilityLabel("Cover Artwork Image")
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("No Cover")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("No artwork image set")
                }
            }
            .onDrop(of: [.image], isTargeted: $isTargeted) { providers in
                guard isWritable, let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data = data {
                        DispatchQueue.main.async {
                            onArtworkChanged(data)
                        }
                    }
                }
                return true
            }
            
            // Actions
            if isWritable {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Album Artwork")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("Drop an image or choose a file (JPEG, PNG, HEIC).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        Button("Choose Artwork...") {
                            chooseArtworkFile()
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Choose artwork file from disk")
                        
                        if artwork != nil {
                            Button("Remove", role: .destructive) {
                                onArtworkChanged(nil)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Remove current album artwork")
                        }
                    }
                }
                .padding(.top, 4)
            }
            
            Spacer()
        }
    }
    
    private func chooseArtworkFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Select Artwork"
        
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            onArtworkChanged(data)
        }
    }
}

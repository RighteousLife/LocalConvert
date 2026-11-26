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
        HStack(alignment: .top, spacing: AppTheme.Spacing.lg) {
            // Artwork Preview
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .fill(AppTheme.Colors.cardBackground)
                    .frame(width: 110, height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                            .stroke(isTargeted ? AppTheme.Colors.accent : Color.primary.opacity(0.08), lineWidth: isTargeted ? 2 : 1)
                    )
                
                if let image = artwork?.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .accessibilityLabel("Cover Artwork Image")
                } else {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Cover")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                    
                    if let art = artwork {
                        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(art.data.count), countStyle: .file)
                        let dimStr = art.image.map { " · \(Int($0.size.width))×\(Int($0.size.height))" } ?? ""
                        Text("\(art.mimeType)\(dimStr) · \(sizeStr)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Button("Choose Artwork...") {
                            chooseArtworkFile()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Choose artwork file from disk")
                        
                        if artwork != nil {
                            Button("Remove", role: .destructive) {
                                onArtworkChanged(nil)
                            }
                            .buttonStyle(.bordered)
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

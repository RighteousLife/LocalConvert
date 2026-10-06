import SwiftUI
import UniformTypeIdentifiers

struct MetadataView: View {
    @StateObject private var metadataManager = MetadataManager.shared
    @State private var isTargeted: Bool = false
    @State private var showDiscardAlert: Bool = false
    
    init() {}
    
    var body: some View {
        VStack(spacing: 0) {
            // Content
            if metadataManager.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading metadata...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let doc = metadataManager.document, let caps = metadataManager.capabilities {
                editorContent(doc: doc, caps: caps)
            } else {
                emptyDropZone
            }
        }
        .navigationTitle("Metadata")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.item], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        await metadataManager.load(url: url)
                    }
                } else if let data = item as? Data, let urlStr = String(data: data, encoding: .utf8), let url = URL(string: urlStr) {
                    Task { @MainActor in
                        await metadataManager.load(url: url)
                    }
                }
            }
            return true
        }
    }
    
    // MARK: - Editor Content
    
    @ViewBuilder
    private func editorContent(doc: MetadataDocument, caps: MetadataCapabilities) -> some View {
        VStack(spacing: 0) {
            // File Identity Header
            HStack(spacing: 12) {
                Image(systemName: doc.format.category.systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadataManager.activeURL?.lastPathComponent ?? "Document")
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        Text(doc.format.displayName)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        
                        Text(caps.writeStrategy.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // Quick Actions
                if caps.canRemoveGPS && doc.gps != nil {
                    Button("Remove GPS", role: .destructive) {
                        metadataManager.removeGPS()
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Strip GPS location tags from this file")
                }
                
                if caps.canRemoveAll {
                    Button("Clear All Tags", role: .destructive) {
                        metadataManager.removeAllMetadata()
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Clear all editable metadata tags from this file")
                }
                
                Button("Open Another...") {
                    chooseFile()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            
            Divider()
            
            // Scrollable Sections
            ScrollView {
                VStack(spacing: 16) {
                    // Artwork Section (if supported)
                    if caps.fields.contains(where: { $0.id == "artwork" }) {
                        sectionContainer(title: "Album Artwork", icon: "photo") {
                            ArtworkEditorView(
                                artwork: doc.artwork,
                                isWritable: caps.canWrite,
                                onArtworkChanged: { newArt in
                                    metadataManager.updateArtwork(data: newArt)
                                }
                            )
                        }
                    }
                    
                    // Categorized Sections
                    let sections = MetadataSection.allCases
                    ForEach(sections) { section in
                        let sectionFields = caps.fields.filter { $0.section == section && $0.id != "artwork" && $0.valueType != .readOnlyTechnical }
                        if !sectionFields.isEmpty {
                            sectionContainer(title: section.rawValue, icon: section.iconName) {
                                VStack(spacing: 6) {
                                    ForEach(sectionFields) { field in
                                        MetadataFieldView(
                                            descriptor: field,
                                            value: doc.value(for: field.id),
                                            onValueChanged: { newVal in
                                                metadataManager.updateField(id: field.id, value: newVal)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    
                    // Technical Section (Read-Only)
                    let techFields = caps.fields.filter { $0.section == .technical || $0.valueType == .readOnlyTechnical }
                    if !techFields.isEmpty {
                        sectionContainer(title: "Technical Information", icon: "gearshape.2") {
                            VStack(spacing: 6) {
                                ForEach(techFields) { field in
                                    MetadataFieldView(
                                        descriptor: field,
                                        value: doc.value(for: field.id),
                                        onValueChanged: { _ in }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            
            Divider()
            
            // Bottom Action Bar
            HStack {
                if let err = metadataManager.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if metadataManager.showSuccessToast {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Metadata saved successfully")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                
                Spacer()
                
                Button("Revert") {
                    metadataManager.revert()
                }
                .disabled(!metadataManager.isDirty || metadataManager.isSaving)
                .accessibilityLabel("Revert unsaved metadata changes")
                
                Button(action: {
                    Task {
                        _ = await metadataManager.save()
                    }
                }) {
                    HStack(spacing: 6) {
                        if metadataManager.isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Save Metadata")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!metadataManager.isDirty || metadataManager.isSaving || !caps.canWrite)
                .accessibilityLabel("Save changes to file")
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        }
    }
    
    // MARK: - Subviews & Helpers
    
    @ViewBuilder
    private var emptyDropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "tag")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            
            VStack(spacing: 4) {
                Text("Drop a file to edit metadata")
                    .font(.title2)
                    .fontWeight(.medium)
                
                Text("or")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Button("Choose File...") {
                chooseFile()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("Choose file from disk for metadata editing")
            
            Text("Supports audio, video, image, PDF, and Office documents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    
    private func sectionContainer<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            
            Divider()
            
            content()
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await metadataManager.load(url: url)
            }
        }
    }
}

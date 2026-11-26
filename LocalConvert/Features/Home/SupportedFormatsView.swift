import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SupportedFormatsView: View {
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var selectedCategory: FormatCategory? = nil
    @State private var showReadOnlyOnly = false
    
    private var filteredCapabilities: [FormatCapability] {
        FormatCapabilityRegistry.shared
            .searchableCapabilities(matching: searchText, category: selectedCategory)
            .filter { cap in
                if showReadOnlyOnly {
                    return cap.isReadOnly
                }
                return true
            }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md + 2) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Supported Formats & Conversion Matrix")
                        .font(AppTheme.Typography.sectionTitle)
                    Text("\(FileFormat.allCases.count) formats registered · \(ConversionMatrix.snapshot().totalRoutes) supported conversion routes")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Button {
                    exportMatrixJSON()
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .help("Export machine-readable conversion matrix JSON")
                
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
            
            // Search & Category Filters
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search extension, format, MIME, or note...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(AppTheme.Spacing.xs + 2)
                .background(AppTheme.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                
                Picker("Category", selection: $selectedCategory) {
                    Text("All Categories").tag(FormatCategory?.none)
                    ForEach(FormatCategory.allCases, id: \.self) { category in
                        Text(category.displayName).tag(FormatCategory?.some(category))
                    }
                }
                .fixedSize()
                
                Toggle("Read-Only", isOn: $showReadOnlyOnly)
                    .toggleStyle(.checkbox)
                    .font(AppTheme.Typography.caption)
            }
            
            // Format Rows
            List(filteredCapabilities) { cap in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(cap.format.shortExtensionLabel)
                            .font(.caption.monospaced().bold())
                            .padding(.horizontal, AppTheme.Spacing.xs + 2)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                            .background(AppTheme.Colors.accentTint)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        
                        Text(cap.displayName)
                            .font(AppTheme.Typography.subheadline)
                            .fontWeight(.medium)
                        
                        Text(cap.category.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        if cap.canRead && cap.canWrite {
                            AppStatusBadge(text: "Read / Write", tint: AppTheme.Colors.success, style: .rounded)
                        } else if cap.isReadOnly {
                            AppStatusBadge(text: "Read-Only Input", tint: AppTheme.Colors.warning, style: .rounded)
                        } else if cap.canWrite {
                            AppStatusBadge(text: "Output Only", tint: AppTheme.Colors.info, style: .rounded)
                        } else {
                            AppStatusBadge(text: "Unsupported", tint: .secondary, style: .rounded)
                        }
                        
                        if cap.supportsMetadata {
                            AppStatusBadge(text: "Metadata", tint: .indigo, style: .rounded)
                        }
                        if cap.supportsAnimation {
                            AppStatusBadge(text: "Animated", tint: .purple, style: .rounded)
                        }
                        if cap.supportsMultiplePages {
                            AppStatusBadge(text: "Multi-page", tint: .teal, style: .rounded)
                        }
                    }
                    
                    let targets = ConversionRegistry.shared.supportedOutputFormats(for: cap.format)
                        .map(\.shortExtensionLabel)
                        .sorted()
                    if !targets.isEmpty {
                        Text("Converts to: \(targets.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    
                    if let note = cap.limitationNote, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Colors.warning)
                    }
                }
                .padding(.vertical, AppTheme.Spacing.xxs + 1)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(minWidth: 680, minHeight: 520)
        .appWorkspaceSurface()
        .onExitCommand { isPresented = false }
    }
    
    private func exportMatrixJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LocalConvert-Conversion-Matrix.json"
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? ConversionMatrix.exportJSON() {
            try? data.write(to: url, options: .atomic)
        }
    }
}

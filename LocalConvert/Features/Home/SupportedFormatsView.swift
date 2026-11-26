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
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: AppTheme.Spacing.md) {
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export machine-readable conversion matrix JSON")
                
                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md + 2)
            .background(AppTheme.Colors.subtleSurface)

            AppDivider()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                // Search & Category Filters
                HStack(spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.xs + 2) {
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
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs + 2)
                    .background(AppTheme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )
                    
                    Picker("Category", selection: $selectedCategory) {
                        Text("All Categories").tag(FormatCategory?.none)
                        ForEach(FormatCategory.allCases, id: \.self) { category in
                            Text(category.displayName).tag(FormatCategory?.some(category))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.regular)
                    .fixedSize()
                    
                    Toggle("Read-Only", isOn: $showReadOnlyOnly)
                        .toggleStyle(.checkbox)
                        .font(AppTheme.Typography.caption)
                        .fixedSize()
                }

                // Matrix Table Container
                VStack(spacing: 0) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("Format")
                            .textCase(.uppercase)
                            .frame(width: 58, alignment: .leading)
                        Text("Name & Category")
                            .textCase(.uppercase)
                        Spacer()
                        Text("\(filteredCapabilities.count) shown")
                            .font(AppTheme.Typography.monoCaption)
                    }
                    .font(AppTheme.Typography.sidebarHeader)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.xs + 2)
                    .background(AppTheme.Colors.subtleSurface)

                    AppDivider()

                    if filteredCapabilities.isEmpty {
                        AppEmptyStateView(
                            icon: "magnifyingglass",
                            title: String(localized: "No Matching Formats"),
                            subtitle: String(localized: "Try clearing the search query or switching to All Categories."),
                            primaryButtonTitle: String(localized: "Reset Filters"),
                            onPrimaryAction: {
                                searchText = ""
                                selectedCategory = nil
                                showReadOnlyOnly = false
                            }
                        )
                    } else {
                        List(filteredCapabilities) { cap in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: AppTheme.Spacing.sm) {
                                        formatHeaderLabels(for: cap)
                                        Spacer(minLength: AppTheme.Spacing.sm)
                                        capabilityBadges(for: cap)
                                    }

                                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                        HStack(spacing: AppTheme.Spacing.sm) {
                                            formatHeaderLabels(for: cap)
                                            Spacer(minLength: 0)
                                        }
                                        HStack(spacing: AppTheme.Spacing.xs) {
                                            capabilityBadges(for: cap)
                                            Spacer(minLength: 0)
                                        }
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
                                        .padding(.leading, 66)
                                }
                                
                                if let note = cap.limitationNote, !note.isEmpty {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.Colors.warning)
                                        .padding(.leading, 66)
                                }
                            }
                            .padding(.vertical, AppTheme.Spacing.xs)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
                .background(AppTheme.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                }
            }
            .padding(AppTheme.Spacing.xl)
        }
        .frame(minWidth: 680, minHeight: 480)
        .appWorkspaceSurface()
        .onExitCommand { isPresented = false }
    }

    @ViewBuilder
    private func formatHeaderLabels(for cap: FormatCapability) -> some View {
        Text(cap.format.shortExtensionLabel)
            .font(.caption.monospaced().bold())
            .frame(minWidth: 50, alignment: .center)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(AppTheme.Colors.accentTint)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .strokeBorder(AppTheme.Colors.accent.opacity(0.25), lineWidth: 0.75)
            )

        Text(cap.displayName)
            .font(AppTheme.Typography.subheadline.weight(.medium))
            .lineLimit(1)

        Text(cap.category.displayName)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func capabilityBadges(for cap: FormatCapability) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
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
        .fixedSize(horizontal: true, vertical: false)
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

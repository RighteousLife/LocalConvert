import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false
    @State private var showingFormatsSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Folder rejection banner if user dropped a folder
            if let notice = appState.folderRejectedNotice {
                AppInfoBanner(
                    style: .warning,
                    message: notice,
                    icon: "folder.badge.questionmark",
                    actionTitle: appState.pendingFolderURLs.isEmpty ? nil : String(localized: "Import Files"),
                    onAction: appState.pendingFolderURLs.isEmpty ? nil : { appState.importFilesFromPendingFolders() },
                    onDismiss: {
                        appState.folderRejectedNotice = nil
                        appState.pendingFolderURLs = []
                    }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.top, AppTheme.Spacing.sm)
            }
            
            VStack(spacing: AppTheme.Spacing.xxl) {
                // MARK: - Dashed Drop Zone Box (Focused only on drop action)
                VStack(spacing: AppTheme.Spacing.lg) {
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                        .font(.system(size: AppTheme.Layout.emptyIconSize, weight: .light))
                        .foregroundStyle(isTargeted ? AppTheme.Colors.accent : Color.secondary)
                        .symbolEffect(.bounce, value: isTargeted)
                    
                    VStack(spacing: AppTheme.Spacing.xs + 2) {
                        Text(isTargeted ? String(localized: "Release to add files") : String(localized: "Drop files here"))
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundStyle(isTargeted ? AppTheme.Colors.accent : .primary)
                        
                        Text("Images · PDF · Office · Audio · Video · Subtitles · Archives")
                            .font(AppTheme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Button {
                            showingFormatsSheet = true
                        } label: {
                            Label("Supported Formats & Matrix", systemImage: "list.bullet.rectangle")
                                .font(AppTheme.Typography.caption)
                        }
                        .buttonStyle(.link)
                        .accessibilityLabel("View Supported Formats and Conversion Matrix")
                        .accessibilityIdentifier("dropzone.supportedFormats")
                        
                        Text("or")
                            .font(AppTheme.Typography.caption)
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
                    .accessibilityIdentifier("dropzone.addFiles")
                    
                    // Drop Feedback Indicator (e.g. "3 files added")
                    if let feedback = appState.dropFeedbackText {
                        HStack(spacing: AppTheme.Spacing.xs + 2) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppTheme.Colors.success)
                            Text(feedback)
                                .font(AppTheme.Typography.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(AppTheme.Colors.successTint)
                        .clipShape(Capsule())
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                        .strokeBorder(
                            isTargeted ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder,
                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                        )
                }
                
                // MARK: - Privacy & Offline Guarantee (Outside the drop zone)
                VStack(spacing: AppTheme.Spacing.xs) {
                    Text("Your files, Your Mac.")
                        .font(AppTheme.Typography.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    
                    Text("All conversions happen locally on your Mac. No data is sent to the cloud.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, AppTheme.Spacing.xs)
                .padding(.bottom, AppTheme.Spacing.md)
            }
            .padding(.horizontal, AppTheme.Spacing.xxl + 4)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .accessibilityLabel("File drop zone")
        .accessibilityHint("Drop files here to convert them, or press Command-O to select files")
        .sheet(isPresented: $showingFormatsSheet) {
            SupportedFormatsView(isPresented: $showingFormatsSheet)
        }
    }
    
    // MARK: - Actions
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Select files to convert")
        panel.prompt = String(localized: "Select")
        
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

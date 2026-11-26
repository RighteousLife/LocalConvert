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
            
            VStack(spacing: AppTheme.Spacing.lg) {
                // MARK: - Dashed Drop Zone Box (Focused only on drop action)
                VStack(spacing: AppTheme.Spacing.lg) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                            .fill(isTargeted ? AppTheme.Colors.accentTint : AppTheme.Colors.subtleSurface)
                            .frame(width: 68, height: 68)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                                    .strokeBorder(
                                        isTargeted ? AppTheme.Colors.accent.opacity(0.45) : AppTheme.Colors.cardBorder,
                                        lineWidth: 1
                                    )
                            )

                        Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(isTargeted ? AppTheme.Colors.accent : Color.secondary)
                            .symbolEffect(.bounce, value: isTargeted)
                    }
                    .accessibilityHidden(true)

                    VStack(spacing: AppTheme.Spacing.xs + 2) {
                        Text(isTargeted ? String(localized: "Release to add files") : String(localized: "Drop files here"))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(isTargeted ? AppTheme.Colors.accent : .primary)

                        Text("Images · PDF · Office · Audio · Video · Subtitles · Archives")
                            .font(AppTheme.Typography.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            showingFormatsSheet = true
                        } label: {
                            Label("Supported Formats & Matrix", systemImage: "list.bullet.rectangle")
                                .font(AppTheme.Typography.caption)
                        }
                        .buttonStyle(.link)
                        .padding(.top, AppTheme.Spacing.xxs)
                        .accessibilityLabel("View Supported Formats and Conversion Matrix")
                        .accessibilityIdentifier("dropzone.supportedFormats")
                    }

                    HStack(spacing: AppTheme.Spacing.md) {
                        Button(action: selectFiles) {
                            Label("Add Files", systemImage: "plus")
                                .frame(minWidth: 112)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .fixedSize(horizontal: true, vertical: false)
                        .keyboardShortcut("o", modifiers: .command)
                        .accessibilityLabel("Add files to convert")
                        .accessibilityIdentifier("dropzone.addFiles")

                        Button(action: pasteFromClipboard) {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Label("Paste", systemImage: "doc.on.clipboard")
                                Text(verbatim: "⌘V")
                                    .font(AppTheme.Typography.badge.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.Colors.neutralTint)
                                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                            .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 0.75)
                                    )
                            }
                            .frame(minWidth: 112)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(appState.isConverting)
                        .accessibilityLabel("Paste from Clipboard")
                        .accessibilityHint("Pastes copied files, images, or text from the clipboard into the conversion queue. Shortcut: Command-V.")
                        .accessibilityIdentifier("dropzone.pasteFromClipboard")
                    }
                    
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
                        .overlay(
                            Capsule()
                                .strokeBorder(AppTheme.Colors.success.opacity(0.28), lineWidth: 1)
                        )
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.vertical, AppTheme.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                        .fill(isTargeted ? AppTheme.Colors.accentTint.opacity(0.35) : AppTheme.Colors.cardBackground.opacity(0.55))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                                .strokeBorder(
                                    isTargeted ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder,
                                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [7, 5])
                                )
                        }
                }
                .animation(.easeInOut(duration: 0.16), value: isTargeted)
                
                // MARK: - Privacy & Offline Guarantee (Outside the drop zone)
                VStack(spacing: AppTheme.Spacing.xxs) {
                    Label("Your files, Your Mac.", systemImage: "lock.shield")
                        .font(AppTheme.Typography.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    
                    Text("All conversions happen locally on your Mac. No data is sent to the cloud.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, AppTheme.Spacing.xxs)
                .padding(.bottom, AppTheme.Spacing.sm)
            }
            .padding(.horizontal, AppTheme.Spacing.xxl)
            .padding(.top, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .accessibilityLabel("File drop zone")
        .accessibilityHint("Drop files here to convert them, press Command-O to select files, or press Command-V to paste from clipboard")
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

    private func pasteFromClipboard() {
        Task { @MainActor in
            _ = await ClipboardIntakeService.pasteToConvert(into: appState)
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

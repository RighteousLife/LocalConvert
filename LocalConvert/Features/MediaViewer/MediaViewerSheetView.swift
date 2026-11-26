import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Media Viewer Clipboard Helper

enum MediaViewerClipboardError: Error, LocalizedError, Equatable, Sendable {
    case noMediaOnClipboard
    case unsupportedClipboardFile
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noMediaOnClipboard:
            return String(localized: "No image or video file found on the clipboard.")
        case .unsupportedClipboardFile:
            return String(localized: "The copied file is not a supported image or video.")
        case .failed(let message):
            return message
        }
    }
}

enum MediaViewerClipboardHelper: Sendable {
    @MainActor
    static func stageMedia(
        from pasteboard: NSPasteboard = .general,
        stagingDirectory: URL? = nil
    ) async -> Result<URL, MediaViewerClipboardError> {
        do {
            let result = try await ClipboardIntakeService.intake(
                from: pasteboard,
                stagingDirectory: stagingDirectory
            )
            switch result.sourceKind {
            case .image:
                if let stagedURL = result.stagedURLs.first {
                    return .success(stagedURL)
                }
                return .failure(.noMediaOnClipboard)
            case .fileURLs:
                if let supportedURL = result.stagedURLs.first(where: {
                    MediaViewerRouter.routeKind(for: $0) != .unsupported
                }) {
                    return .success(supportedURL)
                }
                return .failure(.unsupportedClipboardFile)
            case .json, .xml, .plainText:
                for tempURL in result.createdTempFiles {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                return .failure(.noMediaOnClipboard)
            }
        } catch let error as ClipboardIntakeError {
            switch error {
            case .emptyPasteboard, .unsupportedPasteboardContent:
                return .failure(.noMediaOnClipboard)
            default:
                return .failure(.failed(error.localizedDescription))
            }
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}

// MARK: - Unified Media Viewer Sheet

struct MediaViewerSheetView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false
    @State private var emptyStateNotice: String? = nil
    @State private var isPastingClipboard = false

    private var responsiveIdealSize: CGSize {
        if let windowSize = AppLifecycleManager.shared.resolvePrimaryWindow()?.frame.size {
            let width = min(max(windowSize.width - 40, 740), 980)
            let height = min(max(windowSize.height - 50, 500), 680)
            return CGSize(width: width, height: height)
        }
        return CGSize(width: 960, height: 660)
    }

    var body: some View {
        Group {
            if let activeURL = appState.activeMediaViewerURL {
                routedContent(for: activeURL)
            } else {
                emptyStateView
            }
        }
        .frame(
            minWidth: 740,
            idealWidth: responsiveIdealSize.width,
            maxWidth: .infinity,
            minHeight: 500,
            idealHeight: responsiveIdealSize.height,
            maxHeight: .infinity
        )
        .background(AppTheme.Colors.workspaceBackground)
        .onExitCommand {
            appState.closeMediaViewer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mediaviewer.container")
    }

    // MARK: - Routed Media Content

    @ViewBuilder
    private func routedContent(for url: URL) -> some View {
        switch MediaViewerRouter.routeKind(for: url) {
        case .photo:
            PhotoViewerEditorView(
                url: url,
                onSendToConvertQueue: { targetURL in
                    appState.sendToConvertQueue(fromMediaViewer: targetURL)
                },
                onDismiss: {
                    appState.closeMediaViewer()
                }
            )
            .id(url)

        case .video:
            VideoViewerEditorView(
                url: url,
                onSendToConvertQueue: { targetURL in
                    appState.sendToConvertQueue(fromMediaViewer: targetURL)
                },
                onDismiss: {
                    appState.closeMediaViewer()
                }
            )
            .id(url)

        case .unsupported:
            unsupportedStateView(for: url)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: String(localized: "Media Viewer"),
                subtitle: String(localized: "View, annotate, crop, trim, and export photos or videos locally")
            )

            AppDivider()

            VStack(spacing: AppTheme.Spacing.lg) {
                if let notice = emptyStateNotice {
                    AppInfoBanner(
                        style: .warning,
                        message: notice,
                        onDismiss: { emptyStateNotice = nil }
                    )
                }

                VStack(spacing: AppTheme.Spacing.lg) {
                    Image(systemName: isDropTargeted ? "photo.badge.plus.fill" : "photo.on.rectangle.angled")
                        .font(.system(size: AppTheme.Layout.emptyIconSize, weight: .light))
                        .foregroundStyle(isDropTargeted ? AppTheme.Colors.accent : .secondary)

                    VStack(spacing: AppTheme.Spacing.xs) {
                        Text(isDropTargeted
                             ? String(localized: "Release to open in Media Viewer")
                             : String(localized: "Drop a photo or video here"))
                            .font(AppTheme.Typography.emptyTitle)
                            .foregroundStyle(isDropTargeted ? AppTheme.Colors.accent : .primary)

                        Text(String(localized: "Supports PNG, JPEG, HEIC, WebP, JXL, TIFF, GIF, RAW, MP4, MOV, MKV, WebM, and more"))
                            .font(AppTheme.Typography.emptySubtitle)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }

                    HStack(spacing: AppTheme.Spacing.md) {
                        Button(action: openFilePicker) {
                            Label("Open File...", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Open File")
                        .accessibilityIdentifier("mediaviewer.openFileButton")

                        Button(action: pasteFromClipboard) {
                            Label("Paste Image (⌘V)", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isPastingClipboard)
                        .keyboardShortcut("v", modifiers: .command)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Paste Image from Clipboard")
                        .accessibilityIdentifier("mediaviewer.pasteImageButton")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppTheme.Spacing.xl)
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                        .strokeBorder(
                            isDropTargeted ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder,
                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                        )
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDroppedProviders(providers)
                    return true
                }
            }
            .padding(AppTheme.Spacing.xl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mediaviewer.emptyState")
    }

    // MARK: - Unsupported File State

    private func unsupportedStateView(for url: URL) -> some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: url.lastPathComponent,
                subtitle: String(localized: "Unsupported Media Viewer format")
            )

            AppDivider()

            AppEmptyStateView(
                icon: "doc.questionmark",
                title: String(localized: "Can't preview this file in Media Viewer"),
                subtitle: String(localized: "Media Viewer supports images and videos. You can send \"\(url.lastPathComponent)\" to the Convert queue or open a different media file."),
                primaryButtonTitle: String(localized: "Send to Convert Queue"),
                primaryButtonIcon: "arrow.triangle.2.circlepath",
                onPrimaryAction: {
                    appState.sendToConvertQueue(fromMediaViewer: url)
                }
            ) {
                HStack(spacing: AppTheme.Spacing.md) {
                    Button(action: openFilePicker) {
                        Label("Open Another File...", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)

                    Button("Close") {
                        appState.closeMediaViewer()
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("mediaviewer.sendToConvertFallbackClose")
                }
            }
            .accessibilityIdentifier("mediaviewer.unsupportedState")
        }
    }

    // MARK: - Header Chrome

    private func sheetHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(title)
                    .font(AppTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("Close") {
                appState.closeMediaViewer()
            }
            .keyboardShortcut(.cancelAction)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Close Media Viewer")
            .accessibilityIdentifier("mediaviewer.closeButton")
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MediaViewerRouter.allowedOpenPanelContentTypes
        panel.message = String(localized: "Select an image or video to open in Media Viewer")
        panel.prompt = String(localized: "Open")

        if panel.runModal() == .OK, let selectedURL = panel.url {
            openValidatedFile(selectedURL)
        }
    }

    private func pasteFromClipboard() {
        guard !isPastingClipboard else { return }
        isPastingClipboard = true
        emptyStateNotice = nil

        Task { @MainActor in
            let result = await MediaViewerClipboardHelper.stageMedia(from: .general)
            isPastingClipboard = false
            switch result {
            case .success(let mediaURL):
                appState.openInMediaViewer(mediaURL)
            case .failure(let error):
                emptyStateNotice = error.localizedDescription
            }
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
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
            await MainActor.run {
                guard let firstURL = droppedURLs.first else { return }
                openValidatedFile(firstURL)
            }
        }
    }

    private func openValidatedFile(_ candidateURL: URL) {
        switch FinderHandoffHandler.validateInputFileURL(candidateURL) {
        case .success(let safeURL):
            if MediaViewerRouter.routeKind(for: safeURL) != .unsupported {
                emptyStateNotice = nil
                appState.openInMediaViewer(safeURL)
            } else {
                emptyStateNotice = String(localized: "\"\(safeURL.lastPathComponent)\" is not a supported image or video.")
            }
        case .failure(let error):
            emptyStateNotice = error.localizedDescription
        }
    }
}

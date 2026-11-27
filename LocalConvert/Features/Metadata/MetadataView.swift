import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import AppKit

// MARK: - Offline Streaming File Checksum Calculator

struct FileChecksums: Equatable, Sendable {
    let sha256: String
    let md5: String
}

enum FileChecksumCalculator {
    static let defaultChunkSize = 1_048_576 // 1 MiB

    static func computeChecksums(for url: URL, chunkSize: Int = defaultChunkSize) throws -> FileChecksums {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.inputFileNotFound(url)
        }
        let effectiveChunkSize = max(4096, chunkSize)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var sha256 = SHA256()
        var md5 = Insecure.MD5()

        while true {
            try Task.checkCancellation()
            let shouldContinue: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: effectiveChunkSize), !chunk.isEmpty else {
                    return false
                }
                sha256.update(data: chunk)
                md5.update(data: chunk)
                return true
            }
            if !shouldContinue {
                break
            }
        }

        let shaDigest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        let md5Digest = md5.finalize().map { String(format: "%02x", $0) }.joined()
        return FileChecksums(sha256: shaDigest, md5: md5Digest)
    }

    static func computeChecksumsAsync(for url: URL, chunkSize: Int = defaultChunkSize) async throws -> FileChecksums {
        try await Task.detached(priority: .utility) {
            try computeChecksums(for: url, chunkSize: chunkSize)
        }.value
    }
}

struct MetadataView: View {
    @ObservedObject var metadataManager: MetadataManager
    @State private var isTargeted: Bool = false
    @State private var showDiscardAlert: Bool = false
    @State private var fileChecksums: FileChecksums? = nil
    @State private var checksumError: String? = nil
    @State private var isComputingChecksums: Bool = false
    @State private var copiedChecksumLabel: String? = nil
    
    init(metadataManager: MetadataManager = .shared) {
        self.metadataManager = metadataManager
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Content
            if metadataManager.isLoading {
                AppLoadingStateView(message: "Loading metadata...")
            } else if let doc = metadataManager.document, let caps = metadataManager.capabilities {
                editorContent(doc: doc, caps: caps)
            } else {
                emptyDropZone
            }
        }
        .navigationTitle("Metadata")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: metadataManager.activeURL) {
            await refreshChecksums(for: metadataManager.activeURL)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        await metadataManager.load(url: url)
                    }
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md) {
                    metadataIdentityBlock(doc: doc, caps: caps)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    metadataHeaderActions(doc: doc, caps: caps)
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                    metadataIdentityBlock(doc: doc, caps: caps)
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Spacer(minLength: 0)
                        metadataHeaderActions(doc: doc, caps: caps)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.sm + 2)
            .background(AppTheme.Colors.subtleSurface)
            .alert("Discard Unsaved Metadata Changes?", isPresented: $showDiscardAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Discard & Open", role: .destructive) {
                    chooseFile()
                }
            } message: {
                Text("You have unsaved metadata edits on the current file. Opening another file will discard those edits.")
            }
            
            AppDivider()
            
            // Scrollable Sections
            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {
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
                                VStack(spacing: AppTheme.Spacing.xs + 2) {
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
                            VStack(spacing: AppTheme.Spacing.xs + 2) {
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

                    // Offline File Checksums (SHA-256 & MD5)
                    checksumsSection
                }
                .padding(AppTheme.Spacing.xl)
            }
            
            // Bottom Action Bar
            AppBottomActionBar {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        metadataStatusFeedback
                        Spacer(minLength: AppTheme.Spacing.sm)
                        metadataBottomButtons
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        if metadataManager.errorMessage != nil || metadataManager.showSuccessToast {
                            metadataStatusFeedback
                        }
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Spacer(minLength: 0)
                            metadataBottomButtons
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var metadataStatusFeedback: some View {
        if let err = metadataManager.errorMessage {
            Label(err, systemImage: "xmark.octagon.fill")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Colors.error)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if metadataManager.showSuccessToast {
            Label("Metadata saved successfully", systemImage: "checkmark.circle.fill")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Colors.success)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var metadataBottomButtons: some View {
        let canWrite = metadataManager.capabilities?.canWrite ?? false
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Revert") {
                metadataManager.revert()
            }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!metadataManager.isDirty || metadataManager.isSaving)
            .accessibilityLabel("Revert unsaved metadata changes")

            Button("Save In-Place") {
                Task {
                    _ = await metadataManager.saveInPlace(context: .metadata)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!metadataManager.isDirty || metadataManager.isSaving || !canWrite)
            .help("Overwrite metadata in the original file on disk (supports Undo)")
            .accessibilityLabel("Save metadata changes in-place to original file")

            Button(action: {
                presentSaveCopyPanel()
            }) {
                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    if metadataManager.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save Copy...")
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!metadataManager.isDirty || metadataManager.isSaving || !canWrite)
            .help("Write updated metadata to a new file without modifying the original source")
            .accessibilityLabel("Save metadata changes to a new copy")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func metadataIdentityBlock(doc: MetadataDocument, caps: MetadataCapabilities) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: doc.format.category.systemImage)
                .font(.title3)
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 32, height: 32)
                .background(AppTheme.Colors.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(metadataManager.activeURL?.lastPathComponent ?? "Document")
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("metadata.activeFilename")

                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    AppStatusBadge(text: doc.format.displayName, tint: .secondary, style: .rounded)

                    Text(caps.writeStrategy.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder
    private func metadataHeaderActions(doc: MetadataDocument, caps: MetadataCapabilities) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if caps.canRemoveGPS && doc.gps != nil {
                Button("Remove GPS", role: .destructive) {
                    metadataManager.removeGPS()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Strip GPS location tags from this file")
            }

            if caps.canRemoveAll {
                Button("Clear All Tags", role: .destructive) {
                    metadataManager.removeAllMetadata()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Clear all editable metadata tags from this file")
            }

            Button("Open Another...") {
                if metadataManager.isDirty {
                    showDiscardAlert = true
                } else {
                    chooseFile()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func presentSaveCopyPanel() {
        guard let suggestedURL = metadataManager.suggestedSaveCopyURL() else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestedURL.lastPathComponent
        panel.prompt = "Save Metadata Copy"
        if panel.runModal() == .OK, let targetURL = panel.url {
            Task {
                _ = await metadataManager.saveCopy(to: targetURL, context: .metadata)
            }
        }
    }
    
    // MARK: - Subviews & Helpers

    @ViewBuilder
    private var checksumsSection: some View {
        sectionContainer(title: String(localized: "File Checksums"), icon: "checkmark.shield") {
            if isComputingChecksums {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Calculating SHA-256 and MD5 checksums...")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let checksumError {
                Text(checksumError)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Colors.error)
            } else if let fileChecksums {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    checksumRow(
                        label: "SHA-256",
                        digest: fileChecksums.sha256,
                        identifier: "metadata.checksum.sha256"
                    )
                    AppDivider()
                    checksumRow(
                        label: "MD5",
                        digest: fileChecksums.md5,
                        identifier: "metadata.checksum.md5"
                    )
                }
            } else {
                Text("Select a file to compute offline cryptographic checksums.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func checksumRow(label: String, digest: String, identifier: String) -> some View {
        let isCopied = (copiedChecksumLabel == label)
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(AppTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Text(digest)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier(identifier)

            Spacer(minLength: AppTheme.Spacing.xs)

            Button {
                copyChecksum(digest, label: label)
            } label: {
                Label(isCopied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Copy \(label) checksum")
            .accessibilityIdentifier("\(identifier).copy")
        }
    }

    private func copyChecksum(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedChecksumLabel = label
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedChecksumLabel == label {
                copiedChecksumLabel = nil
            }
        }
    }

    private func refreshChecksums(for url: URL?) async {
        guard let url else {
            fileChecksums = nil
            checksumError = nil
            isComputingChecksums = false
            return
        }
        isComputingChecksums = true
        checksumError = nil
        do {
            let result = try await FileChecksumCalculator.computeChecksumsAsync(for: url)
            guard !Task.isCancelled, metadataManager.activeURL == url else { return }
            fileChecksums = result
            isComputingChecksums = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, metadataManager.activeURL == url else { return }
            fileChecksums = nil
            checksumError = error.localizedDescription
            isComputingChecksums = false
        }
    }
    
    @ViewBuilder
    private var emptyDropZone: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            if let err = metadataManager.errorMessage {
                AppInfoBanner(style: .error, message: err)
                    .padding(.horizontal, AppTheme.Spacing.xl)
                    .padding(.top, AppTheme.Spacing.md)
            }
            AppEmptyStateView(
                icon: "tag",
                title: "Drop a file to edit metadata",
                subtitle: "Supports audio, video, image, PDF, and Office documents.",
                isDropTargeted: isTargeted,
                primaryButtonTitle: "Choose File...",
                primaryButtonIcon: "plus",
                onPrimaryAction: chooseFile
            )
        }
    }

    private func sectionContainer<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        AppCard(title: title, icon: icon, content: content)
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

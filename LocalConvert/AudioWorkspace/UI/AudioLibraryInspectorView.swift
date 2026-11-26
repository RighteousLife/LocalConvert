import SwiftUI

struct AudioLibraryInspectorView: View {
    @ObservedObject var store: AudioLibraryStore
    let record: AudioLibraryRecord?

    @State private var titleDraft = ""
    @State private var artistDraft = ""
    @State private var albumDraft = ""
    @State private var albumArtistDraft = ""
    @State private var genreDraft = ""
    @State private var yearDraft = ""
    @State private var commentDraft = ""
    @State private var isSavingFileTags = false
    @State private var feedbackMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Inspector", systemImage: "info.circle")
                    .font(AppTheme.Typography.sectionTitle)
                Spacer()
                if let record {
                    originBadge(for: record)
                }
            }
            .padding(AppTheme.Spacing.md)

            Divider()

            if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        headerArtworkAndTitle(record)
                        technicalSpecsCard(record)
                        metadataEditorSection(record)

                        if let feedbackMessage {
                            Text(feedbackMessage)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.info)
                        }
                    }
                    .padding(AppTheme.Spacing.md)
                }
            } else {
                AppEmptyStateView(
                    icon: "music.note",
                    title: "No Track Selected",
                    subtitle: "Select a track in the library to inspect technical details and edit metadata."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
        .background(AppTheme.Colors.secondarySidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioworkspace.inspector.panel")
        .onAppear { loadDrafts(from: record) }
        .onChange(of: record?.asset.id) { _, _ in
            feedbackMessage = nil
            loadDrafts(from: record)
        }
    }

    private func originBadge(for record: AudioLibraryRecord) -> some View {
        let origin = record.metadata.metadataOrigin
        let (title, icon, tint): (String, String, Color) = {
            switch origin {
            case .embeddedAndIndexed:
                return ("Embedded Tags", "tag.fill", AppTheme.Colors.success)
            case .libraryOnlyOverride:
                return ("Library DB Only", "internaldrive.fill", AppTheme.Colors.warning)
            case .readOnlyTechnical:
                return ("Read-Only Tags", "lock.fill", .secondary)
            }
        }()

        return Label(title, systemImage: icon)
            .font(AppTheme.Typography.badge)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Metadata origin: \(title)")
            .accessibilityIdentifier("audioworkspace.inspector.origin_badge")
    }

    private func headerArtworkAndTitle(_ record: AudioLibraryRecord) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            AudioArtworkThumbnailView(
                cacheKey: record.metadata.artworkCacheKey,
                provider: store.artworkProvider,
                size: 56
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(record.metadata.title ?? record.asset.displayFilename)
                    .font(AppTheme.Typography.cardTitle)
                    .lineLimit(2)
                Text(record.metadata.artist ?? "Unknown Artist")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.asset.displayFilename)
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func technicalSpecsCard(_ record: AudioLibraryRecord) -> some View {
        let asset = record.asset
        let sr = String(format: "%.1f kHz", Double(asset.sampleRate.hz) / 1000.0)
        let depthText = asset.bitDepth.map { "\($0)-bit" } ?? "Compressed / VBR"
        let bitrateText = asset.bitrateBps.map { "\($0 / 1000) kbps" } ?? "—"
        let sizeText = ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Read-Only Stream Specs")
                .font(AppTheme.Typography.sidebarHeader)
                .foregroundStyle(.secondary)

            specRow("Format", "\(asset.codecName.uppercased()) (\(asset.fileExtension.uppercased()))")
            specRow("Sample Rate", sr)
            specRow("Depth / Channels", "\(depthText) · \(asset.channelCount) ch")
            specRow("Bitrate", bitrateText)
            specRow("Duration", AudioLibraryTrackListView.formatDuration(asset.durationSeconds))
            specRow("File Size", sizeText)
            specRow("Availability", asset.status.rawValue.capitalized)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.cardBackground, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioworkspace.inspector.tech_specs")
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Text(value)
                .font(AppTheme.Typography.monoCaption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func metadataEditorSection(_ record: AudioLibraryRecord) -> some View {
        let fileFormat = record.asset.fileFormat
        let canWriteFile = fileFormat.map { AudioMetadataProvider().capabilities(for: $0).canWrite } ?? false
        let fileExists = FileManager.default.fileExists(atPath: store.resolveInspectableURL(for: record.asset).path)
        let note = fileFormat.map { AudioMetadataProvider.containerLimitationNote(for: $0) }
            ?? "Container format tag writing availability unknown."

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Metadata Editor")
                .font(AppTheme.Typography.sidebarHeader)
                .foregroundStyle(.secondary)

            labeledField("Title", text: $titleDraft, id: "audioworkspace.inspector.field.title")
            labeledField("Artist", text: $artistDraft, id: "audioworkspace.inspector.field.artist")
            labeledField("Album", text: $albumDraft, id: "audioworkspace.inspector.field.album")
            labeledField("Album Artist", text: $albumArtistDraft, id: "audioworkspace.inspector.field.album_artist")
            labeledField("Genre", text: $genreDraft, id: "audioworkspace.inspector.field.genre")
            labeledField("Year", text: $yearDraft, id: "audioworkspace.inspector.field.year")
            labeledField("Comment", text: $commentDraft, id: "audioworkspace.inspector.field.comment")

            Text(note)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            VStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    let updated = builtMetadata(from: record.metadata, origin: .libraryOnlyOverride)
                    Task {
                        if await store.saveLibraryOnlyMetadata(assetID: record.asset.id, metadata: updated) {
                            feedbackMessage = "Saved in Library database only (source audio file unchanged)."
                        }
                    }
                } label: {
                    Label("Save Library Notes (DB Only)", systemImage: "internaldrive")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("audioworkspace.inspector.save_db_only")
                .accessibilityHint("Saves changes to the SQLite Library index without modifying the source audio file")

                Button {
                    isSavingFileTags = true
                    let updated = builtMetadata(from: record.metadata, origin: .embeddedAndIndexed)
                    Task {
                        let ok = await store.writeEmbeddedTagsToFile(assetID: record.asset.id, metadata: updated)
                        isSavingFileTags = false
                        if ok {
                            feedbackMessage = "Embedded tags written to audio file and synced with Library."
                        }
                    }
                } label: {
                    Label(isSavingFileTags ? "Writing Tags..." : "Save Tags to File", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canWriteFile || !fileExists || isSavingFileTags)
                .accessibilityIdentifier("audioworkspace.inspector.save_to_file")
                .accessibilityHint(canWriteFile ? "Explicitly writes metadata tags into the audio file on disk" : "Container is read-only; use Save Library Notes instead")
            }
            .padding(.top, AppTheme.Spacing.xs)
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppTheme.Typography.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(AppTheme.Typography.caption)
                .accessibilityLabel(title)
                .accessibilityIdentifier(id)
        }
    }

    private func loadDrafts(from record: AudioLibraryRecord?) {
        guard let m = record?.metadata else {
            titleDraft = ""
            artistDraft = ""
            albumDraft = ""
            albumArtistDraft = ""
            genreDraft = ""
            yearDraft = ""
            commentDraft = ""
            return
        }
        titleDraft = m.title ?? ""
        artistDraft = m.artist ?? ""
        albumDraft = m.album ?? ""
        albumArtistDraft = m.albumArtist ?? ""
        genreDraft = m.genre ?? ""
        yearDraft = m.year.map(String.init) ?? ""
        commentDraft = m.comment ?? ""
    }

    private func builtMetadata(from base: AudioMetadata, origin: MetadataOrigin) -> AudioMetadata {
        var copy = base
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        copy.title = clean(titleDraft)
        copy.artist = clean(artistDraft)
        copy.album = clean(albumDraft)
        copy.albumArtist = clean(albumArtistDraft)
        copy.genre = clean(genreDraft)
        copy.year = Int(yearDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        copy.comment = clean(commentDraft)
        copy.metadataOrigin = origin
        return copy
    }
}

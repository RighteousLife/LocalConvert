import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AudioLibrarySidebarView: View {
    @ObservedObject var coordinator: AudioWorkspaceCoordinator
    @ObservedObject var store: AudioLibraryStore

    @State private var localSelection: AudioLibrarySidebarSection = .allTracks
    @State private var showNewPlaylistSheet = false
    @State private var newPlaylistName = ""
    @State private var renamingPlaylist: AudioPlaylist?
    @State private var renameText = ""
    @State private var showNewCollectionSheet = false
    @State private var newCollectionName = ""
    @State private var newCollectionLossless = false
    @State private var newCollectionHiRes = false
    @State private var newCollectionFavorites = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $localSelection) {
                Section("Library") {
                    sidebarRow(.allTracks, title: String(localized: "All Tracks"), icon: "music.note.list")
                        .accessibilityIdentifier("audioworkspace.sidebar.all_tracks")
                    sidebarRow(.recentlyAdded, title: String(localized: "Recently Added"), icon: "clock")
                        .accessibilityIdentifier("audioworkspace.sidebar.recently_added")
                    sidebarRow(.recentlyPlayed, title: String(localized: "Recently Played"), icon: "play.circle")
                        .accessibilityIdentifier("audioworkspace.sidebar.recently_played")
                    sidebarRow(.artists, title: String(localized: "Artists"), icon: "music.mic")
                        .accessibilityIdentifier("audioworkspace.sidebar.artists")
                    sidebarRow(.albums, title: String(localized: "Albums"), icon: "square.stack")
                        .accessibilityIdentifier("audioworkspace.sidebar.albums")
                    sidebarRow(.genres, title: String(localized: "Genres"), icon: "guitars")
                        .accessibilityIdentifier("audioworkspace.sidebar.genres")
                }

                Section("Hygiene") {
                    if store.missingFileCount > 0 {
                        Label("Missing Files", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.Colors.warning)
                            .badge(store.missingFileCount)
                            .tag(AudioLibrarySidebarSection.missingFiles)
                            .accessibilityLabel("Missing Files, \(store.missingFileCount) tracks")
                            .accessibilityIdentifier("audioworkspace.sidebar.missing_files")
                    } else {
                        sidebarRow(.missingFiles, title: String(localized: "Missing Files"), icon: "exclamationmark.triangle")
                            .accessibilityIdentifier("audioworkspace.sidebar.missing_files")
                    }

                    if store.duplicateReport.totalGroupCount > 0 {
                        Label("Duplicates", systemImage: "square.on.square")
                            .badge(store.duplicateReport.totalGroupCount)
                            .tag(AudioLibrarySidebarSection.duplicates)
                            .accessibilityLabel("Duplicates, \(store.duplicateReport.totalGroupCount) groups")
                            .accessibilityIdentifier("audioworkspace.sidebar.duplicates")
                    } else {
                        sidebarRow(.duplicates, title: String(localized: "Duplicates"), icon: "square.on.square")
                            .accessibilityIdentifier("audioworkspace.sidebar.duplicates")
                    }
                }

                Section("Collections") {
                    sidebarRow(.favorites, title: String(localized: "Favorites"), icon: "star.fill")
                        .accessibilityIdentifier("audioworkspace.sidebar.favorites")
                    sidebarRow(.lossless, title: String(localized: "Lossless"), icon: "waveform")
                        .accessibilityIdentifier("audioworkspace.sidebar.lossless")
                    sidebarRow(.hiRes, title: String(localized: "Hi-Res Audio"), icon: "hifispeaker")
                        .accessibilityIdentifier("audioworkspace.sidebar.hires")

                    ForEach(store.smartCollections) { col in
                        sidebarRow(.collection(col.id), title: col.name, icon: col.iconName)
                            .accessibilityIdentifier("audioworkspace.sidebar.collection.\(col.id.uuidString)")
                            .contextMenu {
                                Button("Play Collection") {
                                    Task { await coordinator.playCollection(col) }
                                }
                                Divider()
                                Button("Delete Collection", role: .destructive) {
                                    Task { await store.deleteSmartCollection(id: col.id) }
                                }
                            }
                    }
                }

                Section("Playlists") {
                    ForEach(store.playlists) { playlist in
                        Label(playlist.name, systemImage: "text.badge.plus")
                            .badge(playlist.orderedAssetIDs.count)
                            .tag(AudioLibrarySidebarSection.playlist(playlist.id))
                            .accessibilityLabel("Playlist \(playlist.name), \(playlist.orderedAssetIDs.count) tracks")
                            .accessibilityIdentifier("audioworkspace.sidebar.playlist.\(playlist.id.uuidString)")
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                handleDrop(providers, intoPlaylistID: playlist.id)
                            }
                            .contextMenu {
                                Button("Play Playlist") {
                                    Task { await coordinator.playPlaylist(playlist) }
                                }
                                Button("Add Playlist to Queue") {
                                    Task { await coordinator.queuePlaylist(playlist) }
                                }
                                Divider()
                                Button("Rename Playlist...") {
                                    renameText = playlist.name
                                    renamingPlaylist = playlist
                                }
                                Button("Delete Playlist", role: .destructive) {
                                    Task { await store.deletePlaylist(id: playlist.id) }
                                }
                            }
                    }
                }

                Section("Watched Folders") {
                    ForEach(store.rootFolders) { folder in
                        let folderName = URL(fileURLWithPath: folder.path).lastPathComponent
                        HStack(spacing: 4) {
                            Label(folderName.isEmpty ? folder.path : folderName, systemImage: "folder")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                Task { await store.rescanFolder(id: folder.id) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Rescan Folder")
                            .accessibilityLabel("Rescan folder \(folderName)")
                        }
                        .tag(AudioLibrarySidebarSection.folder(folder.id))
                        .help(folderHelpText(folder))
                        .accessibilityIdentifier("audioworkspace.sidebar.folder.\(folder.id.uuidString)")
                        .contextMenu {
                            Button("Rescan Folder") {
                                Task { await store.rescanFolder(id: folder.id) }
                            }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                            }
                            Divider()
                            Button("Remove from Library", role: .destructive) {
                                Task { await store.removeFolder(id: folder.id) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("audioworkspace.sidebar.list")
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers, intoPlaylistID: nil)
            }

            Divider()

            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    chooseFolderAndScan()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Add Audio Library Folder")
                .accessibilityLabel("Add audio library folder")
                .accessibilityIdentifier("audioworkspace.sidebar.add_folder")

                Spacer()

                Button {
                    newCollectionName = ""
                    newCollectionLossless = false
                    newCollectionHiRes = false
                    newCollectionFavorites = false
                    showNewCollectionSheet = true
                } label: {
                    Image(systemName: "sparkles.rectangle.stack")
                }
                .buttonStyle(.borderless)
                .help("New Smart Collection")
                .accessibilityLabel("Create new smart collection")
                .accessibilityIdentifier("audioworkspace.sidebar.add_collection")

                Button {
                    newPlaylistName = ""
                    showNewPlaylistSheet = true
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New Playlist")
                .accessibilityLabel("Create new playlist")
                .accessibilityIdentifier("audioworkspace.sidebar.add_playlist")
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs + 2)
        }
        .background(AppTheme.Colors.secondarySidebarBackground)
        .onAppear {
            if localSelection != store.sidebarSection {
                localSelection = store.sidebarSection
            }
        }
        .onChange(of: localSelection) { _, next in
            if store.sidebarSection != next {
                Task { @MainActor in
                    store.sidebarSection = next
                    store.selectedCategoryFilter = nil
                    await store.reloadMetadataAndTracks()
                    if case .duplicates = next {
                        await store.refreshDuplicates()
                    }
                }
            }
        }
        .onChange(of: store.sidebarSection) { _, next in
            if localSelection != next {
                localSelection = next
            }
        }
        .sheet(isPresented: $showNewPlaylistSheet) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("New Playlist")
                    .font(AppTheme.Typography.sectionTitle)
                TextField("Playlist Name", text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("audioworkspace.playlist.name_field")
                HStack {
                    Spacer()
                    Button("Cancel") { showNewPlaylistSheet = false }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        showNewPlaylistSheet = false
                        Task {
                            if let created = await store.createPlaylist(name: name) {
                                store.sidebarSection = .playlist(created.id)
                                await store.reloadMetadataAndTracks()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("audioworkspace.playlist.create_confirm")
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(width: 340)
            .appWorkspaceSurface()
        }
        .sheet(isPresented: $showNewCollectionSheet) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("New Smart Collection")
                    .font(AppTheme.Typography.sectionTitle)
                TextField("Collection Name", text: $newCollectionName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("audioworkspace.collection.name_field")
                Toggle("Favorites Only", isOn: $newCollectionFavorites)
                Toggle("Lossless Codecs Only", isOn: $newCollectionLossless)
                Toggle("Hi-Res (> 48 kHz or ≥ 24-bit)", isOn: $newCollectionHiRes)
                HStack {
                    Spacer()
                    Button("Cancel") { showNewCollectionSheet = false }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        let lossless = newCollectionLossless
                        let hiRes = newCollectionHiRes
                        let favs = newCollectionFavorites
                        showNewCollectionSheet = false
                        Task {
                            if let filter = try? AudioCollectionFilter(
                                losslessOnly: lossless,
                                hiResOnly: hiRes,
                                favoritesOnly: favs
                            ),
                               let created = await store.createSmartCollection(name: name, filter: filter) {
                                store.sidebarSection = .collection(created.id)
                                await store.reloadMetadataAndTracks()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("audioworkspace.collection.create_confirm")
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(width: 360)
            .appWorkspaceSurface()
        }
        .sheet(item: $renamingPlaylist) { playlist in
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Rename Playlist")
                    .font(AppTheme.Typography.sectionTitle)
                TextField("Playlist Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { renamingPlaylist = nil }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Rename") {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        renamingPlaylist = nil
                        Task { await store.renamePlaylist(id: playlist.id, newName: trimmed) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(width: 340)
            .appWorkspaceSurface()
        }
    }

    private func sidebarRow(_ section: AudioLibrarySidebarSection, title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .tag(section)
            .accessibilityLabel(title)
    }

    private func folderHelpText(_ folder: LibraryRootFolder) -> String {
        if let scanned = folder.lastScannedAt {
            return String(localized: "\(folder.path)\nLast scanned: \(scanned.formatted(date: .abbreviated, time: .shortened))")
        }
        return folder.path
    }

    private func chooseFolderAndScan() {
        let env = ProcessInfo.processInfo.environment
        if env["LOCALCONVERT_UITEST"] == "1",
           let overridePath = env["LOCALCONVERT_UITEST_AUDIO_PICKER_FOLDER"],
           !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath, isDirectory: true)
            Task {
                await store.addFolderAndScan(url: url)
            }
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Audio Library Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await store.addFolderAndScan(url: url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], intoPlaylistID playlistID: UUID?) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    if let url = item as? URL {
                        urls.append(url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }
            if !urls.isEmpty {
                await store.importDroppedURLs(urls, intoPlaylistID: playlistID)
            }
        }
        return true
    }
}

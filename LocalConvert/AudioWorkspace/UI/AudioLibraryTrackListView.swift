import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AudioLibraryTrackListView: View {
    @ObservedObject var coordinator: AudioWorkspaceCoordinator
    @ObservedObject var store: AudioLibraryStore
    @ObservedObject var playback: PlaybackCoordinator
    let searchFocusRequestToken: UInt64
    let onOpenInEditor: (AudioLibraryRecord) -> Void

    @State private var localSearchText = ""
    @State private var localSortField: AudioCollectionSortField = .title
    @State private var localSortAscending = true
    @State private var localSelection: Set<UUID> = []
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showRelinkSheet = false
    @State private var isDropTargeted = false
    @FocusState private var isSearchFieldFocused: Bool

    init(
        coordinator: AudioWorkspaceCoordinator,
        store: AudioLibraryStore,
        playback: PlaybackCoordinator,
        searchFocusRequestToken: UInt64 = 0,
        onOpenInEditor: @escaping (AudioLibraryRecord) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.store = store
        self.playback = playback
        self.searchFocusRequestToken = searchFocusRequestToken
        self.onOpenInEditor = onOpenInEditor
    }

    var body: some View {
        VStack(spacing: 0) {
            headerToolbar

            if store.isScanning || store.errorMessage != nil || showMissingBanner {
                statusStrip
            }

            if showCategoryFilterStrip {
                categoryFilterBar
            }

            Divider()

            mainContentArea
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .stroke(isDropTargeted ? AppTheme.Colors.accent : .clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .sheet(isPresented: $showRelinkSheet) {
            LibraryMissingRelinkSheet(store: store)
        }
        .onAppear {
            if localSearchText != store.searchQuery { localSearchText = store.searchQuery }
            if localSortField != store.sortField { localSortField = store.sortField }
            if localSortAscending != store.sortAscending { localSortAscending = store.sortAscending }
            if localSelection != store.selectedAssetIDs { localSelection = store.selectedAssetIDs }
        }
        .onChange(of: searchFocusRequestToken) { _, _ in
            isSearchFieldFocused = true
        }
        .onChange(of: localSearchText) { _, next in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                store.searchQuery = next
                await store.reloadMetadataAndTracks()
            }
        }
        .onChange(of: localSortField) { _, next in
            if store.sortField != next {
                store.sortField = next
                Task { await store.reloadMetadataAndTracks() }
            }
        }
        .onChange(of: localSortAscending) { _, next in
            if store.sortAscending != next {
                store.sortAscending = next
                Task { await store.reloadMetadataAndTracks() }
            }
        }
        .onChange(of: localSelection) { _, next in
            if store.selectedAssetIDs != next {
                Task { @MainActor in
                    store.selectedAssetIDs = next
                    if let firstID = next.first {
                        store.inspectedAssetID = firstID
                    }
                }
            }
        }
    }

    private var showMissingBanner: Bool {
        store.missingFileCount > 0 && store.sidebarSection == .missingFiles
    }

    private var headerToolbar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.md) {
                    headerTitleStack
                    Spacer(minLength: AppTheme.Spacing.sm)
                    headerSearchField
                    headerSortControls
                    headerActionButtons
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        headerTitleStack
                        Spacer(minLength: AppTheme.Spacing.xs)
                        headerActionButtons
                    }
                    HStack(spacing: AppTheme.Spacing.sm) {
                        headerSearchField
                        headerSortControls
                    }
                }
            }

            if store.sidebarSection != .duplicates {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AudioLibraryQuickFilter.allCases) { filter in
                            let isActive = store.quickFilter == filter
                            Button(filter.rawValue) {
                                Task {
                                    store.quickFilter = filter
                                    await store.reloadMetadataAndTracks()
                                }
                            }
                            .buttonStyle(.plain)
                            .fixedSize(horizontal: true, vertical: false)
                            .font(AppTheme.Typography.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(isActive ? AppTheme.Colors.accent : AppTheme.Colors.cardBackground)
                            .foregroundStyle(isActive ? Color.white : Color.primary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(isActive ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .contentShape(Capsule())
                            .accessibilityIdentifier("audioworkspace.library.filter.\(filter.rawValue.lowercased().replacingOccurrences(of: "-", with: "_"))")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    @ViewBuilder
    private var headerTitleStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sectionTitle)
                .font(AppTheme.Typography.pageTitle)
                .lineLimit(1)
            Text(sectionSubtitle)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var headerSearchField: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search title, artist, album, codec...", text: $localSearchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 140, maxWidth: .infinity)
                .focused($isSearchFieldFocused)
                .accessibilityLabel("Search Audio Library")
                .accessibilityHint("Filter tracks with FTS5 full-text search (Command-F)")
                .accessibilityIdentifier("audioworkspace.library.search_field")
            if !localSearchText.isEmpty {
                Button {
                    localSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs + 1)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var headerSortControls: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Picker("Sort by", selection: $localSortField) {
                Text("Title").tag(AudioCollectionSortField.title)
                Text("Artist").tag(AudioCollectionSortField.artist)
                Text("Album").tag(AudioCollectionSortField.album)
                Text("Duration").tag(AudioCollectionSortField.duration)
                Text("Sample Rate").tag(AudioCollectionSortField.sampleRate)
                Text("Date Added").tag(AudioCollectionSortField.dateAdded)
                Text("Plays").tag(AudioCollectionSortField.playCount)
            }
            .labelsHidden()
            .frame(width: 112)
            .accessibilityLabel("Sort tracks by")
            .accessibilityIdentifier("audioworkspace.library.sort_picker")

            Button {
                localSortAscending.toggle()
            } label: {
                Image(systemName: localSortAscending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.bordered)
            .help(localSortAscending ? "Ascending order" : "Descending order")
            .accessibilityLabel(localSortAscending ? "Sort ascending" : "Sort descending")
            .accessibilityIdentifier("audioworkspace.library.sort_direction")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var headerActionButtons: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if store.sidebarSection == .duplicates {
                Button {
                    Task { await store.refreshDuplicates() }
                } label: {
                    Label(store.isCheckingDuplicates ? "Scanning..." : "Scan Duplicates", systemImage: "square.on.square")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(store.isCheckingDuplicates)
                .accessibilityIdentifier("audioworkspace.library.scan_duplicates")
            }

            if store.missingFileCount > 0 {
                Button {
                    showRelinkSheet = true
                } label: {
                    Label("Relink (\(store.missingFileCount))", systemImage: "exclamationmark.triangle.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.Colors.warning)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Relink \(store.missingFileCount) missing files")
                .accessibilityIdentifier("audioworkspace.library.relink_missing")
            }

            if case .playlist(let playlistID) = store.sidebarSection,
               let playlist = store.playlists.first(where: { $0.id == playlistID }) {
                Button {
                    Task { await coordinator.playPlaylist(playlist) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(store.displayedRecords.isEmpty)
            }

            if store.isScanning {
                Button("Cancel Scan") {
                    store.cancelActiveScan()
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("audioworkspace.library.cancel_scan")
            } else {
                Button {
                    Task { await store.rescanAllFolders() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(store.rootFolders.isEmpty)
                .accessibilityIdentifier("audioworkspace.library.rescan_all")
            }

            Button {
                coordinator.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.bordered)
            .tint(coordinator.isInspectorVisible ? AppTheme.Colors.accent : .secondary)
            .help("Toggle Track Inspector (⌘I)")
            .accessibilityLabel("Toggle Inspector")
            .accessibilityValue(coordinator.isInspectorVisible ? "Shown" : "Hidden")
            .accessibilityIdentifier("audioworkspace.library.inspector_toggle")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statusStrip: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if store.isScanning, let prog = store.scanProgress {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(prog.phase): \(prog.rootFolderName) (\(prog.processedCount)/\(max(prog.discoveredCount, prog.processedCount)))")
                        .font(AppTheme.Typography.caption)
                    Spacer()
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.xs)
            }
            if showMissingBanner {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("\(store.missingFileCount) audio file(s) could not be found at their indexed paths.")
                        .font(AppTheme.Typography.caption)
                    Spacer()
                    Button("Relink Missing Files...") {
                        showRelinkSheet = true
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("audioworkspace.library.banner_relink")
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(AppTheme.Colors.warningTint)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Colors.warning.opacity(0.28), lineWidth: 1)
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.xs)
            }
            if let errorMessage = store.errorMessage {
                AppInfoBanner(
                    style: .warning,
                    message: errorMessage,
                    onDismiss: { store.errorMessage = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.xs)
            }
        }
    }

    private var showCategoryFilterStrip: Bool {
        switch store.sidebarSection {
        case .artists, .albums, .genres:
            return !categoryValues.isEmpty
        default:
            return false
        }
    }

    private var categoryValues: [String] {
        switch store.sidebarSection {
        case .artists: return store.allArtists
        case .albums: return store.allAlbums
        case .genres: return store.allGenres
        default: return []
        }
    }

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                categoryChip(title: "All", isSelected: store.selectedCategoryFilter == nil) {
                    store.selectedCategoryFilter = nil
                    Task { await store.reloadMetadataAndTracks() }
                }
                ForEach(categoryValues, id: \.self) { val in
                    categoryChip(title: val, isSelected: store.selectedCategoryFilter == val) {
                        store.selectedCategoryFilter = val
                        Task { await store.reloadMetadataAndTracks() }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
    }

    private func categoryChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(AppTheme.Typography.caption)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBackground)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var mainContentArea: some View {
        if store.sidebarSection == .duplicates {
            duplicatesContentArea
        } else if store.isLoading && store.displayedRecords.isEmpty {
            VStack(spacing: AppTheme.Spacing.md) {
                ProgressView()
                Text("Loading Audio Library...")
                    .font(AppTheme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.rootFolders.isEmpty && store.displayedRecords.isEmpty {
            AppEmptyStateView(
                icon: "music.note.house",
                title: "Audio Library Is Empty",
                subtitle: "Drop folders or audio files here to index tracks, inspect tags, build playlists, and play losslessly inside LocalConvert.",
                primaryButtonTitle: "Add Audio Folder...",
                primaryButtonIcon: "folder.badge.plus",
                onPrimaryAction: {
                    let env = ProcessInfo.processInfo.environment
                    if env["LOCALCONVERT_UITEST"] == "1",
                       let overridePath = env["LOCALCONVERT_UITEST_AUDIO_PICKER_FOLDER"],
                       !overridePath.isEmpty {
                        let url = URL(fileURLWithPath: overridePath, isDirectory: true)
                        Task { await store.addFolderAndScan(url: url) }
                        return
                    }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        Task { await store.addFolderAndScan(url: url) }
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.displayedRecords.isEmpty {
            AppEmptyStateView(
                icon: "magnifyingglass",
                title: "No Matching Tracks",
                subtitle: localSearchText.isEmpty ? "This section currently contains no indexed tracks." : "No tracks matched \"\(localSearchText)\"."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            trackListView
        }
    }

    @ViewBuilder
    private var duplicatesContentArea: some View {
        if store.isCheckingDuplicates {
            VStack(spacing: AppTheme.Spacing.md) {
                ProgressView()
                Text("Analyzing library for exact binary and metadata (±1s) duplicates...")
                    .font(AppTheme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.duplicateReport.allGroups.isEmpty {
            AppEmptyStateView(
                icon: "checkmark.seal",
                title: "No Duplicate Tracks Detected",
                subtitle: "Exact binary SHA-256 and normalized Title + Artist (±1s duration) checks found no duplicates."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.duplicateReport.allGroups) { group in
                    Section {
                        ForEach(group.records, id: \.asset.id) { record in
                            HStack(spacing: AppTheme.Spacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.metadata.title ?? record.asset.displayFilename)
                                        .font(AppTheme.Typography.body)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(record.asset.canonicalPath)
                                        .font(AppTheme.Typography.monoCaption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(formatTechBadge(record.asset))
                                    .font(AppTheme.Typography.badge)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Text(Self.formatDuration(record.asset.durationSeconds))
                                    .font(AppTheme.Typography.monoCaption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                Button("Editor") {
                                    onOpenInEditor(record)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                                Button("Remove Entry", role: .destructive) {
                                    Task { await store.removeAssetFromLibrary(id: record.asset.id) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .fixedSize(horizontal: true, vertical: false)
                                .help("Removes index entry only; audio file stays on disk")
                            }
                        }
                    } header: {
                        HStack {
                            Label(group.kind.badgeTitle, systemImage: group.kind.systemImage)
                                .font(AppTheme.Typography.cardTitle)
                            Spacer()
                            Text("\(group.records.count) files · Reclaimable index size: \(ByteCountFormatter.string(fromByteCount: group.potentialReclaimableBytes, countStyle: .file))")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("audioworkspace.library.duplicates_list")
        }
    }

    private var trackListView: some View {
        List(selection: $localSelection) {
            ForEach(Array(store.displayedRecords.enumerated()), id: \.element.asset.id) { index, record in
                trackRow(index: index, record: record)
                    .tag(record.asset.id)
                    .onDrag {
                        let url = store.resolveInspectableURL(for: record.asset)
                        return NSItemProvider(object: url as NSURL)
                    }
                    .listRowBackground(
                        playback.currentTrack?.asset.id == record.asset.id
                            ? AppTheme.Colors.accentTint
                            : Color.clear
                    )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("audioworkspace.library.track_list")
    }

    private func trackRow(index: Int, record: AudioLibraryRecord) -> some View {
        let isCurrent = playback.currentTrack?.asset.id == record.asset.id
        return HStack(spacing: AppTheme.Spacing.md) {
            AudioArtworkThumbnailView(
                cacheKey: record.metadata.artworkCacheKey,
                provider: store.artworkProvider,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.accent)
                            .accessibilityLabel("Currently playing")
                    }
                    Text(record.metadata.title ?? record.asset.displayFilename)
                        .font(AppTheme.Typography.body)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    if record.asset.status == .missing {
                        Label("Missing", systemImage: "exclamationmark.triangle.fill")
                            .font(AppTheme.Typography.badge)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AppTheme.Colors.warningTint)
                            .foregroundStyle(AppTheme.Colors.warning)
                            .clipShape(Capsule())
                    }
                    if record.metadata.metadataOrigin == .libraryOnlyOverride {
                        Label("DB Only", systemImage: "internaldrive")
                            .font(AppTheme.Typography.badge)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(AppTheme.Colors.infoTint)
                            .foregroundStyle(AppTheme.Colors.info)
                            .clipShape(Capsule())
                    }
                }
                Text([record.metadata.artist, record.metadata.album].compactMap { $0 }.joined(separator: " — "))
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(formatTechBadge(record.asset))
                .font(AppTheme.Typography.badge)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppTheme.Colors.neutralTint)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))

            Button {
                Task { await store.toggleFavorite(assetID: record.asset.id) }
            } label: {
                Image(systemName: record.asset.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(record.asset.isFavorite ? AppTheme.Colors.warning : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(record.asset.isFavorite ? "Remove from Favorites" : "Mark as Favorite")

            Text(Self.formatDuration(record.asset.durationSeconds))
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Button {
                Task {
                    await playback.playTrack(record, withinRecords: store.displayedRecords)
                }
            } label: {
                Image(systemName: "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(record.metadata.title ?? record.asset.displayFilename)")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.inspectedAssetID = record.asset.id
            if !localSelection.contains(record.asset.id) {
                localSelection = [record.asset.id]
            }
        }
        .onTapGesture(count: 2) {
            Task {
                await playback.playTrack(record, withinRecords: store.displayedRecords)
            }
        }
        .contextMenu {
            let targetRecords = selectedRecords(fallback: record)
            Button("Play Now") {
                Task { await playback.playTrack(record, withinRecords: store.displayedRecords) }
            }
            Button("Play Next") {
                Task { await playback.enqueueNext(record) }
            }
            Button(targetRecords.count > 1 ? "Add \(targetRecords.count) Tracks to Queue" : "Add to Queue") {
                Task { await playback.enqueue(targetRecords) }
            }
            if !store.playlists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(store.playlists) { pl in
                        Button(pl.name) {
                            Task { await store.addAssets(targetRecords.map(\.asset.id), toPlaylist: pl.id) }
                        }
                    }
                }
            }
            Divider()
            Button("Open in Waveform Editor") {
                onOpenInEditor(record)
            }
            Button("Inspect / Edit Metadata...") {
                store.inspectedAssetID = record.asset.id
                coordinator.isInspectorVisible = true
            }
            Divider()
            Button(record.asset.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { await store.toggleFavorite(assetID: record.asset.id) }
            }
            if record.asset.status == .missing {
                Button("Relink Missing File...") {
                    showRelinkSheet = true
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.resolveInspectableURL(for: record.asset)])
            }
            if case .playlist(let playlistID) = store.sidebarSection {
                Divider()
                if index > 0 {
                    Button("Move Up in Playlist") {
                        Task { await store.movePlaylistEntries(in: playlistID, fromOffsets: IndexSet(integer: index), toOffset: index - 1) }
                    }
                }
                if index + 1 < store.displayedRecords.count {
                    Button("Move Down in Playlist") {
                        Task { await store.movePlaylistEntries(in: playlistID, fromOffsets: IndexSet(integer: index), toOffset: index + 2) }
                    }
                }
                Button("Remove Entry from Playlist", role: .destructive) {
                    Task { await store.removePlaylistEntry(atIndex: index, from: playlistID) }
                }
            } else {
                Divider()
                Button("Remove from Library (Keep File on Disk)", role: .destructive) {
                    Task {
                        for item in targetRecords {
                            await store.removeAssetFromLibrary(id: item.asset.id)
                        }
                    }
                }
            }
        }
    }

    private func selectedRecords(fallback: AudioLibraryRecord) -> [AudioLibraryRecord] {
        if localSelection.contains(fallback.asset.id) && localSelection.count > 1 {
            let matching = store.displayedRecords.filter { localSelection.contains($0.asset.id) }
            return matching.isEmpty ? [fallback] : matching
        }
        return [fallback]
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
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
                let targetPlaylist: UUID? = {
                    if case .playlist(let pid) = store.sidebarSection { return pid }
                    return nil
                }()
                await store.importDroppedURLs(urls, intoPlaylistID: targetPlaylist)
            }
        }
        return true
    }

    private var sectionTitle: String {
        switch store.sidebarSection {
        case .allTracks: return "All Tracks"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .artists: return store.selectedCategoryFilter ?? "Artists"
        case .albums: return store.selectedCategoryFilter ?? "Albums"
        case .genres: return store.selectedCategoryFilter ?? "Genres"
        case .favorites: return "Favorites"
        case .lossless: return "Lossless Audio"
        case .hiRes: return "Hi-Res Audio"
        case .missingFiles: return "Missing Files"
        case .duplicates: return "Duplicates"
        case .playlist(let id): return store.playlists.first { $0.id == id }?.name ?? "Playlist"
        case .collection(let id): return store.smartCollections.first { $0.id == id }?.name ?? "Collection"
        case .folder(let id):
            if let path = store.rootFolders.first(where: { $0.id == id })?.path {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Folder"
        }
    }

    private var sectionSubtitle: String {
        if store.sidebarSection == .duplicates {
            return "\(store.duplicateReport.exactBinaryGroups.count) exact binary · \(store.duplicateReport.normalizedMetadataGroups.count) metadata (±1s)"
        }
        let count = store.displayedRecords.count
        let mode = store.fts5Available ? "FTS5" : "LIKE Fallback"
        return "\(count) track\(count == 1 ? "" : "s") · Search index: \(mode)"
    }

    private func formatTechBadge(_ asset: AudioAsset) -> String {
        let sr = String(format: "%.1fkHz", Double(asset.sampleRate.hz) / 1000.0)
        if let bits = asset.bitDepth {
            return "\(asset.codecName.uppercased()) · \(sr)/\(bits)b"
        }
        return "\(asset.codecName.uppercased()) · \(sr)"
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct AudioArtworkThumbnailView: View {
    let cacheKey: String?
    let provider: AudioArtworkProvider
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(AppTheme.Colors.neutralTint)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        .task(id: cacheKey) {
            guard let cacheKey else {
                image = nil
                return
            }
            image = await AudioArtworkImageCache.shared.image(forKey: cacheKey, provider: provider)
        }
    }
}

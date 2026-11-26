import Foundation
import Combine

enum AudioWorkspaceMode: String, CaseIterable, Identifiable, Sendable {
    case library = "Library"
    case waveformEditor = "Waveform Editor"
    case audioTools = "Audio Tools"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .library: return "music.note.list"
        case .waveformEditor: return "waveform.path.ecg"
        case .audioTools: return "wrench.and.screwdriver"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .library: return "audioworkspace.mode.library"
        case .waveformEditor: return "audioworkspace.mode.editor"
        case .audioTools: return "audioworkspace.mode.tools"
        }
    }
}

@MainActor
final class AudioWorkspaceCoordinator: ObservableObject {
    let database: AudioLibraryDatabase
    let artworkProvider: AudioArtworkProvider
    let libraryStore: AudioLibraryStore
    let playbackCoordinator: PlaybackCoordinator

    @Published var activeMode: AudioWorkspaceMode = .library
    @Published var isInspectorVisible: Bool = false
    @Published private(set) var isInitialized = false
    private var initTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        databaseURL: URL? = nil,
        artworkDirectoryURL: URL? = nil,
        playerStateURL: URL? = nil,
        transport: (any AudioPlaybackTransportProtocol)? = nil,
        outputDeviceMonitor: CoreAudioOutputDeviceMonitor? = nil,
        arbitrationCenter: PlaybackArbitrationCenter = .shared,
        forceDisableFTS5: Bool = false
    ) {
        let db = AudioLibraryDatabase(databaseURL: databaseURL, forceDisableFTS5: forceDisableFTS5)
        let art = AudioArtworkProvider(cacheDirectory: artworkDirectoryURL)
        let libStore = AudioLibraryStore(database: db, artworkProvider: art)
        let engine = AudioLibraryPlayerEngine(transport: transport)
        let persistence = PlaybackStatePersistence(stateFileURL: playerStateURL)
        let monitor = outputDeviceMonitor ?? CoreAudioOutputDeviceMonitor()
        let playCoord = PlaybackCoordinator(
            database: db,
            engine: engine,
            persistence: persistence,
            outputDeviceMonitor: monitor,
            arbitrationCenter: arbitrationCenter
        )

        self.database = db
        self.artworkProvider = art
        self.libraryStore = libStore
        self.playbackCoordinator = playCoord

        if arbitrationCenter === PlaybackArbitrationCenter.shared {
            arbitrationCenter.setAutoPauseEnabled(AppSettings.shared.audioAutoPauseArbitration)
        }

        libStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        playCoord.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func ensureInitialized() async {
        if isInitialized { return }
        if let initTask {
            await initTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.libraryStore.loadAndRefresh()
            await self.playbackCoordinator.restoreSavedSessionIfPresent()
            self.playbackCoordinator.outputDeviceMonitor.startMonitoring()
            self.isInitialized = true
        }
        initTask = task
        await task.value
        initTask = nil
    }

    func playPlaylist(_ playlist: AudioPlaylist) async {
        guard let records = try? await libraryStore.playlistService.resolveRecords(for: playlist.id),
              !records.isEmpty else { return }
        await playbackCoordinator.playQueue(records: records, startAt: 0)
    }

    func queuePlaylist(_ playlist: AudioPlaylist) async {
        guard let records = try? await libraryStore.playlistService.resolveRecords(for: playlist.id),
              !records.isEmpty else { return }
        await playbackCoordinator.enqueue(records)
    }

    func playCollection(_ collection: AudioCollection) async {
        guard let records = try? await libraryStore.collectionService.resolveTracks(for: collection),
              !records.isEmpty else { return }
        await playbackCoordinator.playQueue(records: records, startAt: 0)
    }

    func saveQueueAsPlaylist(name: String) async -> AudioPlaylist? {
        let ids = playbackCoordinator.queueManager.orderedTrackIDs
        guard !ids.isEmpty else { return nil }
        return await libraryStore.createPlaylist(name: name, initialAssetIDs: ids)
    }

    func resolveAssetURL(for record: AudioLibraryRecord) -> URL {
        libraryStore.resolveInspectableURL(for: record.asset)
    }
}

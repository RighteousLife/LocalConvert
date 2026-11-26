import Foundation

struct PersistedPlaybackState: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var queue: PlaybackQueue
    var session: PlaybackSession
    var savedAt: Date
}

actor PlaybackStatePersistence {
    private let customStateURL: URL?

    init(stateFileURL: URL? = nil) {
        self.customStateURL = stateFileURL
    }

    var stateURL: URL {
        customStateURL ?? AppStoragePaths.audioPlayerStateURL
    }

    func save(queue: PlaybackQueue, session: PlaybackSession) throws {
        var sanitizedSession = session
        // Never persist `.playing` or `.loading` as an active launch trigger.
        if sanitizedSession.activeAssetID != nil {
            sanitizedSession.playbackState = .paused
        } else {
            sanitizedSession.playbackState = .stopped
        }

        let payload = PersistedPlaybackState(
            schemaVersion: 1,
            queue: queue,
            session: sanitizedSession,
            savedAt: Date()
        )

        let url = stateURL
        let parent = url.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let tmp = parent.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

    /// Loads saved state and guarantees restored playbackState never causes unsolicited auto-playback.
    func loadRestoredState() -> PersistedPlaybackState? {
        let url = stateURL
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var payload = try? decoder.decode(PersistedPlaybackState.self, from: data),
              payload.schemaVersion >= 1 else {
            return nil
        }
        if payload.session.activeAssetID != nil {
            payload.session.playbackState = .paused
        } else {
            payload.session.playbackState = .stopped
        }
        return payload
    }

    func clear() {
        try? FileManager.default.removeItem(at: stateURL)
    }
}

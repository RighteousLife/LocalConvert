import Foundation

/// Identifies independent playback subsystems participating in non-destructive
/// mutual-exclusion arbitration without creating cross-module dependencies.
enum PlaybackClientID: String, Hashable, Sendable {
    case audioLibraryPlayer
    case audioEditor
}

struct PlaybackArbitrationRegistrationToken: Hashable, Sendable {
    let id: UUID
    let client: PlaybackClientID
}

/// Lightweight `@MainActor` arbitration service that pauses peer audio transports when
/// another registered transport begins playback, leaving project/queue/edit state untouched.
@MainActor
final class PlaybackArbitrationCenter {
    static let shared = PlaybackArbitrationCenter()

    private struct Entry {
        let client: PlaybackClientID
        let onPauseRequested: @MainActor () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private(set) var isAutoPauseEnabled: Bool = true
    private(set) var lastActiveClient: PlaybackClientID?
    private var isDispatching = false

    init() {}

    func setAutoPauseEnabled(_ enabled: Bool) {
        isAutoPauseEnabled = enabled
    }

    func registerClient(
        _ client: PlaybackClientID,
        onPauseRequested: @escaping @MainActor () -> Void
    ) -> PlaybackArbitrationRegistrationToken {
        let token = PlaybackArbitrationRegistrationToken(id: UUID(), client: client)
        entries[token.id] = Entry(client: client, onPauseRequested: onPauseRequested)
        return token
    }

    func unregisterClient(_ token: PlaybackArbitrationRegistrationToken) {
        entries.removeValue(forKey: token.id)
    }

    func notifyPlaybackStarted(by client: PlaybackClientID) {
        lastActiveClient = client
        guard isAutoPauseEnabled, !isDispatching else { return }

        isDispatching = true
        defer { isDispatching = false }

        let targets = entries.values.filter { $0.client != client }
        for target in targets {
            target.onPauseRequested()
        }
    }

    var registeredClientCount: Int {
        entries.count
    }
}

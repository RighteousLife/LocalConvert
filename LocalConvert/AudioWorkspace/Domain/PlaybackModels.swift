import Foundation

// MARK: - Playback Queue & Session Models

enum PlaybackRepeatMode: String, Codable, Hashable, CaseIterable, Sendable {
    case off
    case all
    case one
}

enum PlaybackTransportState: Codable, Hashable, Equatable, Sendable {
    case stopped
    case loading
    case playing
    case paused
    case error(String)
}

struct PlaybackQueue: Codable, Hashable, Equatable, Sendable {
    var originalOrderIDs: [UUID]
    var activeOrderIDs: [UUID]
    var currentIndex: Int?
    var repeatMode: PlaybackRepeatMode
    var isShuffleEnabled: Bool

    init(
        originalOrderIDs: [UUID] = [],
        activeOrderIDs: [UUID] = [],
        currentIndex: Int? = nil,
        repeatMode: PlaybackRepeatMode = .off,
        isShuffleEnabled: Bool = false
    ) throws {
        if let currentIndex {
            guard !activeOrderIDs.isEmpty, activeOrderIDs.indices.contains(currentIndex) else {
                throw AudioDomainValidationError.invalidIndex(index: currentIndex, count: activeOrderIDs.count)
            }
        }
        self.originalOrderIDs = originalOrderIDs
        self.activeOrderIDs = activeOrderIDs
        self.currentIndex = currentIndex
        self.repeatMode = repeatMode
        self.isShuffleEnabled = isShuffleEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            originalOrderIDs: try c.decodeIfPresent([UUID].self, forKey: .originalOrderIDs) ?? [],
            activeOrderIDs: try c.decodeIfPresent([UUID].self, forKey: .activeOrderIDs) ?? [],
            currentIndex: try c.decodeIfPresent(Int.self, forKey: .currentIndex),
            repeatMode: try c.decodeIfPresent(PlaybackRepeatMode.self, forKey: .repeatMode) ?? .off,
            isShuffleEnabled: try c.decodeIfPresent(Bool.self, forKey: .isShuffleEnabled) ?? false
        )
    }

    var currentTrackID: UUID? {
        guard let currentIndex, activeOrderIDs.indices.contains(currentIndex) else { return nil }
        return activeOrderIDs[currentIndex]
    }
}

struct PlaybackSession: Codable, Hashable, Equatable, Sendable {
    static let validVolumeRange: ClosedRange<Double> = 0.0...1.0
    static let validRateRange: ClosedRange<Double> = 0.25...4.0

    var activeAssetID: UUID?
    var playbackState: PlaybackTransportState
    var position: SourceFrameTime?
    var totalFrames: Int64
    var volume: Double
    var isMuted: Bool
    var preMuteVolume: Double
    var playbackRate: Double
    var outputDeviceUID: String?
    var outputDeviceName: String

    init(
        activeAssetID: UUID? = nil,
        playbackState: PlaybackTransportState = .stopped,
        position: SourceFrameTime? = nil,
        totalFrames: Int64 = 0,
        volume: Double = 1.0,
        isMuted: Bool = false,
        preMuteVolume: Double = 1.0,
        playbackRate: Double = 1.0,
        outputDeviceUID: String? = nil,
        outputDeviceName: String = "System Default"
    ) throws {
        guard totalFrames >= 0 else {
            throw AudioDomainValidationError.negativeValue(field: "PlaybackSession.totalFrames", value: totalFrames)
        }
        guard volume.isFinite, Self.validVolumeRange.contains(volume) else {
            throw AudioDomainValidationError.outOfBoundsDouble(field: "PlaybackSession.volume", value: volume, rangeDescription: "0.0...1.0")
        }
        guard preMuteVolume.isFinite, Self.validVolumeRange.contains(preMuteVolume) else {
            throw AudioDomainValidationError.outOfBoundsDouble(field: "PlaybackSession.preMuteVolume", value: preMuteVolume, rangeDescription: "0.0...1.0")
        }
        guard playbackRate.isFinite, Self.validRateRange.contains(playbackRate) else {
            throw AudioDomainValidationError.outOfBoundsDouble(field: "PlaybackSession.playbackRate", value: playbackRate, rangeDescription: "0.25...4.0")
        }
        self.activeAssetID = activeAssetID
        self.playbackState = playbackState
        self.position = position
        self.totalFrames = totalFrames
        self.volume = volume
        self.isMuted = isMuted
        self.preMuteVolume = preMuteVolume
        self.playbackRate = playbackRate
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
    }

    private init(validatedDefault: Void) {
        self.activeAssetID = nil
        self.playbackState = .stopped
        self.position = nil
        self.totalFrames = 0
        self.volume = 1.0
        self.isMuted = false
        self.preMuteVolume = 1.0
        self.playbackRate = 1.0
        self.outputDeviceUID = nil
        self.outputDeviceName = "System Default"
    }

    static let systemDefault = PlaybackSession(validatedDefault: ())

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            activeAssetID: try c.decodeIfPresent(UUID.self, forKey: .activeAssetID),
            playbackState: try c.decodeIfPresent(PlaybackTransportState.self, forKey: .playbackState) ?? .stopped,
            position: try c.decodeIfPresent(SourceFrameTime.self, forKey: .position),
            totalFrames: try c.decodeIfPresent(Int64.self, forKey: .totalFrames) ?? 0,
            volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0,
            isMuted: try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            preMuteVolume: try c.decodeIfPresent(Double.self, forKey: .preMuteVolume) ?? 1.0,
            playbackRate: try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1.0,
            outputDeviceUID: try c.decodeIfPresent(String.self, forKey: .outputDeviceUID),
            outputDeviceName: try c.decodeIfPresent(String.self, forKey: .outputDeviceName) ?? "System Default"
        )
    }
}

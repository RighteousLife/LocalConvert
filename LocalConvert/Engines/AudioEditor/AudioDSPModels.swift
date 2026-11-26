import Foundation

// MARK: - Parametric EQ Models

enum EQFilterType: String, Codable, Sendable, CaseIterable, Identifiable {
    case highPass = "High-Pass"
    case lowShelf = "Low Shelf"
    case peaking = "Peaking"
    case highShelf = "High Shelf"
    case lowPass = "Low-Pass"

    var id: String { rawValue }

    var supportsGain: Bool {
        self == .lowShelf || self == .peaking || self == .highShelf
    }
}

struct EQBand: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var isEnabled: Bool = true
    var type: EQFilterType = .peaking
    var frequencyHz: Double = 1000
    var gainDB: Double = 0
    var q: Double = 1.0

    mutating func clamped(sampleRate: Double = 48_000) {
        let nyquistLimit = max(100.0, sampleRate * 0.46)
        frequencyHz = min(nyquistLimit, max(20.0, frequencyHz))
        gainDB = min(24.0, max(-24.0, gainDB))
        q = min(18.0, max(0.2, q))
    }
}

struct ParametricEQParams: Codable, Sendable, Equatable {
    var bands: [EQBand] = ParametricEQParams.defaultBands
    var isBypassed: Bool = false

    static var defaultBands: [EQBand] {
        [
            EQBand(isEnabled: true, type: .highPass, frequencyHz: 80, gainDB: 0, q: 0.707),
            EQBand(isEnabled: true, type: .lowShelf, frequencyHz: 120, gainDB: 0, q: 0.707),
            EQBand(isEnabled: true, type: .peaking, frequencyHz: 1_000, gainDB: 0, q: 1.0),
            EQBand(isEnabled: true, type: .peaking, frequencyHz: 3_500, gainDB: 0, q: 1.2),
            EQBand(isEnabled: true, type: .highShelf, frequencyHz: 8_000, gainDB: 0, q: 0.707)
        ]
    }

    static let presets: [(name: String, bands: [EQBand])] = [
        ("Flat", defaultBands),
        ("Vocal Presence", [
            EQBand(isEnabled: true, type: .highPass, frequencyHz: 90, gainDB: 0, q: 0.707),
            EQBand(isEnabled: true, type: .peaking, frequencyHz: 280, gainDB: -2.5, q: 1.4),
            EQBand(isEnabled: true, type: .peaking, frequencyHz: 3_200, gainDB: 3.5, q: 1.1),
            EQBand(isEnabled: true, type: .highShelf, frequencyHz: 10_000, gainDB: 2.0, q: 0.707)
        ]),
        ("Warm Bass", [
            EQBand(isEnabled: true, type: .lowShelf, frequencyHz: 110, gainDB: 4.5, q: 0.707),
            EQBand(isEnabled: true, type: .peaking, frequencyHz: 450, gainDB: -1.5, q: 1.2),
            EQBand(isEnabled: true, type: .highShelf, frequencyHz: 7_500, gainDB: -1.5, q: 0.707)
        ]),
        ("Broadcast Clarity", [
            EQBand(isEnabled: true, type: .highPass, frequencyHz: 100, gainDB: 0, q: 0.707),
            EQBand(isEnabled: true, type: .peaking, frequencyHz: 220, gainDB: -3.0, q: 1.5),
            EQBand(isEnabled: true, type: .peaking, frequencyHz: 2_500, gainDB: 3.0, q: 1.0),
            EQBand(isEnabled: true, type: .lowPass, frequencyHz: 16_000, gainDB: 0, q: 0.707)
        ])
    ]
}

// MARK: - Dynamics, Gate, Spectral Denoise, Delay, Reverb

struct CompressorParams: Codable, Sendable, Equatable {
    var thresholdDB: Double = -18.0
    var ratio: Double = 3.0
    var attackMs: Double = 10.0
    var releaseMs: Double = 160.0
    var kneeDB: Double = 6.0
    var makeupGainDB: Double = 0.0
    var isBypassed: Bool = false

    mutating func clamped() {
        thresholdDB = min(0.0, max(-60.0, thresholdDB))
        ratio = min(20.0, max(1.0, ratio))
        attackMs = min(200.0, max(0.1, attackMs))
        releaseMs = min(1500.0, max(10.0, releaseMs))
        kneeDB = min(24.0, max(0.0, kneeDB))
        makeupGainDB = min(24.0, max(-12.0, makeupGainDB))
    }
}

struct LimiterParams: Codable, Sendable, Equatable {
    /// Sample-peak ceiling in dBFS. Real-time limiting enforces sample peaks cleanly; true-peak compliance is validated on export.
    var ceilingDB: Double = -1.0
    var lookaheadMs: Double = 4.0
    var releaseMs: Double = 80.0
    var isBypassed: Bool = false

    mutating func clamped() {
        ceilingDB = min(-0.1, max(-12.0, ceilingDB))
        lookaheadMs = min(10.0, max(0.0, lookaheadMs))
        releaseMs = min(500.0, max(10.0, releaseMs))
    }
}

struct NoiseGateParams: Codable, Sendable, Equatable {
    var thresholdDB: Double = -42.0
    var attackMs: Double = 2.0
    var holdMs: Double = 80.0
    var releaseMs: Double = 180.0
    var rangeDB: Double = -60.0
    var hysteresisDB: Double = 4.0
    var isBypassed: Bool = false

    mutating func clamped() {
        thresholdDB = min(-5.0, max(-80.0, thresholdDB))
        attackMs = min(100.0, max(0.2, attackMs))
        holdMs = min(1000.0, max(0.0, holdMs))
        releaseMs = min(2000.0, max(10.0, releaseMs))
        rangeDB = min(0.0, max(-80.0, rangeDB))
        hysteresisDB = min(12.0, max(0.0, hysteresisDB))
    }
}

struct NoiseReductionParams: Codable, Sendable, Equatable {
    /// Reduction percentage in 0...100%.
    var reductionAmount: Double = 60.0
    /// Spectral/temporal smoothing factor in 0...1.
    var smoothing: Double = 0.45
    /// Adaptive noise floor estimate in dBFS when no captured noise profile is supplied.
    var noiseFloorDB: Double = -45.0
    /// Optional FFT bin magnitude profile captured from a quiet/noise region.
    var noiseProfile: [Float]? = nil
    var isBypassed: Bool = false

    mutating func clamped() {
        reductionAmount = min(100.0, max(0.0, reductionAmount))
        smoothing = min(0.95, max(0.0, smoothing))
        noiseFloorDB = min(-15.0, max(-90.0, noiseFloorDB))
    }
}

struct DelayParams: Codable, Sendable, Equatable {
    var delayTimeMs: Double = 280.0
    var feedback: Double = 0.35
    var wetDryMix: Double = 0.25
    var dampingHz: Double = 6_500.0
    var pingPong: Bool = false
    var isBypassed: Bool = false

    mutating func clamped() {
        delayTimeMs = min(2_000.0, max(1.0, delayTimeMs))
        // Clamp feedback below 0.90 to guarantee stable decay without runaway oscillation.
        feedback = min(0.90, max(0.0, feedback))
        wetDryMix = min(1.0, max(0.0, wetDryMix))
        dampingHz = min(20_000.0, max(400.0, dampingHz))
    }
}

enum ReverbRoomPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case smallRoom = "Small Room"
    case mediumHall = "Medium Hall"
    case largeHall = "Large Hall"
    case plate = "Plate"

    var id: String { rawValue }
}

struct ReverbParams: Codable, Sendable, Equatable {
    var roomPreset: ReverbRoomPreset = .mediumHall
    var decaySeconds: Double = 1.6
    var preDelayMs: Double = 18.0
    var damping: Double = 0.45
    var stereoWidth: Double = 0.85
    var wetDryMix: Double = 0.22
    var isBypassed: Bool = false

    mutating func clamped() {
        decaySeconds = min(8.0, max(0.2, decaySeconds))
        preDelayMs = min(150.0, max(0.0, preDelayMs))
        damping = min(0.98, max(0.02, damping))
        stereoWidth = min(1.0, max(0.0, stereoWidth))
        wetDryMix = min(1.0, max(0.0, wetDryMix))
    }
}

// MARK: - Ordered Effect Slot & Track/Clip Chain

enum AudioEffectKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case parametricEQ = "Parametric EQ"
    case compressor = "Compressor"
    case limiter = "Limiter"
    case noiseGate = "Noise Gate"
    case noiseReduction = "Noise Reduction"
    case delay = "Delay"
    case reverb = "Reverb"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .parametricEQ: return "slider.vertical.3"
        case .compressor: return "waveform.path.ecg"
        case .limiter: return "arrow.up.to.line.compact"
        case .noiseGate: return "door.left.hand.closed"
        case .noiseReduction: return "wand.and.stars"
        case .delay: return "arrow.trianglehead.2.counterclockwise.rotate.90"
        case .reverb: return "waveform.circle"
        }
    }
}

struct AudioEffectSlot: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: AudioEffectKind
    var isEnabled: Bool = true
    var isBypassed: Bool = false
    var eq: ParametricEQParams?
    var compressor: CompressorParams?
    var limiter: LimiterParams?
    var noiseGate: NoiseGateParams?
    var noiseReduction: NoiseReductionParams?
    var delay: DelayParams?
    var reverb: ReverbParams?

    static func makeDefault(kind: AudioEffectKind) -> AudioEffectSlot {
        switch kind {
        case .parametricEQ:
            return AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams())
        case .compressor:
            return AudioEffectSlot(kind: .compressor, compressor: CompressorParams())
        case .limiter:
            return AudioEffectSlot(kind: .limiter, limiter: LimiterParams())
        case .noiseGate:
            return AudioEffectSlot(kind: .noiseGate, noiseGate: NoiseGateParams())
        case .noiseReduction:
            return AudioEffectSlot(kind: .noiseReduction, noiseReduction: NoiseReductionParams())
        case .delay:
            return AudioEffectSlot(kind: .delay, delay: DelayParams())
        case .reverb:
            return AudioEffectSlot(kind: .reverb, reverb: ReverbParams())
        }
    }

    var isActive: Bool {
        guard isEnabled && !isBypassed else { return false }
        switch kind {
        case .parametricEQ: return !(eq?.isBypassed ?? true)
        case .compressor: return !(compressor?.isBypassed ?? true)
        case .limiter: return !(limiter?.isBypassed ?? true)
        case .noiseGate: return !(noiseGate?.isBypassed ?? true)
        case .noiseReduction: return !(noiseReduction?.isBypassed ?? true)
        case .delay: return !(delay?.isBypassed ?? true)
        case .reverb: return !(reverb?.isBypassed ?? true)
        }
    }
}

// MARK: - Effect Chain Presets & Normalization

enum AudioEditorNormalizeMethod: Sendable, Equatable {
    case peak(targetDBFS: Double)
    case rms(targetDBFS: Double)
}

enum AudioPresetScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case trackChain = "Track / Clip Chain"
    case parametricEQ = "Parametric EQ"
    var id: String { rawValue }
}

struct AudioEffectChainPreset: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var scope: AudioPresetScope
    var slots: [AudioEffectSlot]
    var isFactory: Bool = false
    var createdAt: Date = Date()
}

// MARK: - Grid Snapping & Track Grouping Models

enum TimelineSnapInterval: String, Codable, Sendable, CaseIterable, Identifiable {
    case milliseconds100 = "0.1 s"
    case halfSecond = "0.5 s"
    case oneSecond = "1.0 s"
    case beatQuarter = "1/4 Beat"
    case beatHalf = "1/2 Beat"
    case beatBar = "1 Bar (4 Beats)"

    var id: String { rawValue }

    func intervalSeconds(bpm: Double) -> TimeInterval {
        let clampedBPM = min(300.0, max(30.0, bpm))
        let beatSec = 60.0 / clampedBPM
        switch self {
        case .milliseconds100: return 0.1
        case .halfSecond: return 0.5
        case .oneSecond: return 1.0
        case .beatQuarter: return beatSec * 0.25
        case .beatHalf: return beatSec * 0.5
        case .beatBar: return beatSec * 4.0
        }
    }
}

struct TimelineGridConfig: Codable, Sendable, Equatable {
    var snapEnabled: Bool = false
    var interval: TimelineSnapInterval = .halfSecond
    var bpm: Double = 120.0

    var stepSeconds: TimeInterval {
        interval.intervalSeconds(bpm: bpm)
    }

    func snap(_ time: TimeInterval) -> TimeInterval {
        guard snapEnabled else { return max(0, time) }
        let step = max(0.01, stepSeconds)
        return max(0, (time / step).rounded() * step)
    }
}

struct AudioTrackGroup: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var trackIDs: [UUID] = []
    var isMuted: Bool = false
    var isSolo: Bool = false
    var colorHex: String = "#0A84FF"
}

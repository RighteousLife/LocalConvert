import Foundation
import CryptoKit

// MARK: - Migration Errors & Exact Sample-Frame Migration Helpers

enum AudioProjectMigrationError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidSampleRate(Double)
    case nonFiniteTime(field: String, value: Double)
    case negativeTime(field: String, value: Double)
    case integerOverflow(field: String, value: Double)
    case negativeFrameValue(field: String, value: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported Audio Editor project schema version: \(version)."
        case .invalidSampleRate(let rate):
            return "Invalid Audio Editor project sample rate: \(rate) Hz."
        case .nonFiniteTime(let field, let value):
            return "Legacy time field '\(field)' is non-finite (\(value))."
        case .negativeTime(let field, let value):
            return "Legacy time field '\(field)' cannot be negative (\(value))."
        case .integerOverflow(let field, let value):
            return "Time field '\(field)' (\(value)) overflows Int64 sample frames."
        case .negativeFrameValue(let field, let value):
            return "Frame field '\(field)' cannot be negative (\(value))."
        }
    }
}

/// Deterministic legacy-seconds <-> integer sample-frame conversion utilities.
enum SampleFrameMigration {
    private static let minInt64Decimal = Decimal(string: "-9223372036854775808")!
    private static let maxInt64Decimal = Decimal(string: "9223372036854775807")!

    /// Converts legacy seconds (`Double`) into integer sample frames using `Decimal` arithmetic
    /// and half-away-from-zero rounding (`.plain`), rejecting `NaN`, `±Inf`, negative values, and `Int64` overflow.
    static func secondsToFrames(
        _ seconds: Double,
        sampleRate: SampleRate,
        field: String,
        allowNegative: Bool = false
    ) throws -> Int64 {
        guard seconds.isFinite else {
            throw AudioProjectMigrationError.nonFiniteTime(field: field, value: seconds)
        }
        guard allowNegative || seconds >= 0 else {
            throw AudioProjectMigrationError.negativeTime(field: field, value: seconds)
        }
        if seconds == 0 {
            return 0
        }

        // Convert binary floating point through string decimal representation so decimal inputs
        // (e.g. 0.5, 0.125, 1.5) avoid spurious binary fraction drift where representable.
        var product = Decimal(seconds) * Decimal(Int(sampleRate.hz))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)

        guard rounded >= minInt64Decimal && rounded <= maxInt64Decimal else {
            throw AudioProjectMigrationError.integerOverflow(field: field, value: seconds)
        }
        let result = NSDecimalNumber(decimal: rounded).int64Value
        if !allowNegative && result < 0 {
            throw AudioProjectMigrationError.negativeTime(field: field, value: seconds)
        }
        return result
    }

    static func framesToSeconds(_ frames: Int64, sampleRate: SampleRate) -> TimeInterval {
        Double(frames) / Double(sampleRate.hz)
    }

    /// Best-effort `SampleRate` from a raw `Double` frequency, throwing if invalid.
    static func validatedSampleRate(_ rawRate: Double) throws -> SampleRate {
        guard rawRate.isFinite, rawRate >= 1, rawRate <= Double(SampleRate.validRange.upperBound) else {
            throw AudioProjectMigrationError.invalidSampleRate(rawRate)
        }
        return try SampleRate(Int32(rawRate.rounded()))
    }
}

// MARK: - Media Reference (immutable source media; never modified by the editor)

struct AudioMediaReference: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var path: String
    var displayName: String
    var fileSize: Int64
    var modificationTime: TimeInterval
    var duration: TimeInterval
    var sampleRate: Double
    var channels: Int
    var bookmarkData: Data?
    var contentSHA256: String?
    var relativePath: String?
    var durationFrames: Int64?

    var url: URL { URL(fileURLWithPath: path) }

    init(
        id: UUID,
        path: String,
        displayName: String,
        fileSize: Int64,
        modificationTime: TimeInterval,
        duration: TimeInterval,
        sampleRate: Double,
        channels: Int,
        bookmarkData: Data? = nil,
        contentSHA256: String? = nil,
        relativePath: String? = nil,
        durationFrames: Int64? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.fileSize = fileSize
        self.modificationTime = modificationTime
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.bookmarkData = bookmarkData
        self.contentSHA256 = contentSHA256
        self.relativePath = relativePath
        self.durationFrames = durationFrames
    }

    /// Captures a fingerprint for missing/changed-source detection.
    static func fingerprint(of url: URL) -> (size: Int64, mtime: TimeInterval) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    /// Computes a bounded-memory streaming SHA-256 hex digest for cross-Mac asset relinking.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum SourceStatus: Sendable, Equatable { case ok, missing, modified }

    var status: SourceStatus {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let fp = Self.fingerprint(of: url)
        if fp.size != fileSize || abs(fp.mtime - modificationTime) > 1.0 { return .modified }
        return .ok
    }
}

// MARK: - Fades / Channel / Effects

enum ClipFadeCurve: String, Codable, Sendable, CaseIterable, Identifiable {
    case linear = "Linear"
    case equalPower = "Equal Power"
    case exponential = "Exponential"
    case logarithmic = "Logarithmic"
    case sCurve = "S-Curve"
    var id: String { rawValue }

    /// Gain for a fade-IN at normalized progress x in 0...1.
    func fadeIn(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        switch self {
        case .linear: return c
        case .equalPower: return sin(c * .pi / 2)
        case .exponential: return c * c
        case .logarithmic: return log10(1.0 + 9.0 * c)
        case .sCurve: return 0.5 - 0.5 * cos(c * .pi)
        }
    }

    /// Gain for a fade-OUT at normalized progress x in 0...1.
    func fadeOut(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        switch self {
        case .linear: return 1 - c
        case .equalPower: return cos(c * .pi / 2)
        case .exponential: return (1 - c) * (1 - c)
        case .logarithmic: return log10(1.0 + 9.0 * (1 - c))
        case .sCurve: return 0.5 + 0.5 * cos(c * .pi)
        }
    }
}

struct ClipFadeSpec: Codable, Sendable, Equatable {
    var duration: TimeInterval
    var curve: ClipFadeCurve = .linear
}

/// Sample-accurate fade specification storing integer duration frames.
struct ClipFadeSpecFrames: Codable, Sendable, Equatable, Hashable {
    var durationFrames: Int64
    var curve: ClipFadeCurve

    init(durationFrames: Int64, curve: ClipFadeCurve = .equalPower) {
        self.durationFrames = max(0, durationFrames)
        self.curve = curve
    }

    init(spec: ClipFadeSpec, sampleRate: SampleRate) throws {
        let frames = try SampleFrameMigration.secondsToFrames(spec.duration, sampleRate: sampleRate, field: "fade.duration")
        self.init(durationFrames: frames, curve: spec.curve)
    }

    func durationSeconds(at rate: SampleRate) -> TimeInterval {
        SampleFrameMigration.framesToSeconds(durationFrames, sampleRate: rate)
    }
}

enum AudioEditorChannelMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case original = "Original"
    case mono = "Mono (Downmix)"
    case stereo = "Stereo (Upmix)"
    var id: String { rawValue }
}

/// Non-destructive per-clip processing chain, rendered to cached proxies for preview/export.
struct AudioEffectChainConfig: Codable, Sendable, Equatable {
    var eqEnabled = false
    var eqLowDB: Double = 0      // low shelf @ 120 Hz
    var eqMidDB: Double = 0      // peak @ 1 kHz
    var eqHighDB: Double = 0     // high shelf @ 8 kHz
    var highPassHz: Double? = nil
    var lowPassHz: Double? = nil
    var compressorEnabled = false
    var compressorThresholdDB: Double = -18
    var compressorRatio: Double = 3
    var limiterCeilingDB: Double? = nil
    var gateThresholdDB: Double? = nil
    var noiseReductionDB: Double? = nil
    var pitchSemitones: Double = 0
    var timeStretch: Double = 1.0   // speed factor; 2.0 = twice as fast (clip consumes 2x source per timeline second)

    var isIdentity: Bool { self == AudioEffectChainConfig() }

    var affectsTiming: Bool { abs(timeStretch - 1.0) > 0.0001 }
}

// MARK: - Clip / Track / Marker / Project (v3 Sample-Frame Core + TimeInterval Compatibility)

struct AudioClip: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// nil == generated silence.
    var sourceAssetID: UUID?
    var name: String

    // MARK: Authoritative v3 Sample-Frame Coordinates
    var timelineStartFrame: Int64
    var sourceStartFrame: Int64
    var durationFrames: Int64
    var projectRate: SampleRate = .rate48k
    var sourceRate: SampleRate = .rate48k

    var gainDB: Double = 0
    var isMuted = false
    var isLocked = false
    var isReversed = false
    var swapChannels = false
    var channelMode: AudioEditorChannelMode = .original
    var fadeInFrames: ClipFadeSpecFrames? = nil
    var fadeOutFrames: ClipFadeSpecFrames? = nil
    /// Curve used for the automatic crossfade when this clip overlaps an earlier clip on the same track.
    var crossfadeCurve: ClipFadeCurve = .equalPower
    var effects = AudioEffectChainConfig()
    /// Ordered native DSP effect chain processed identically during live playback and offline export.
    var effectSlots: [AudioEffectSlot] = []

    // MARK: Primary Sample-Frame Initializer
    init(
        id: UUID = UUID(),
        sourceAssetID: UUID? = nil,
        name: String,
        timelineStartFrame: Int64,
        sourceStartFrame: Int64,
        durationFrames: Int64,
        projectRate: SampleRate = .rate48k,
        sourceRate: SampleRate = .rate48k,
        gainDB: Double = 0,
        isMuted: Bool = false,
        isLocked: Bool = false,
        isReversed: Bool = false,
        swapChannels: Bool = false,
        channelMode: AudioEditorChannelMode = .original,
        fadeInFrames: ClipFadeSpecFrames? = nil,
        fadeOutFrames: ClipFadeSpecFrames? = nil,
        crossfadeCurve: ClipFadeCurve = .equalPower,
        effects: AudioEffectChainConfig = AudioEffectChainConfig(),
        effectSlots: [AudioEffectSlot] = []
    ) {
        self.id = id
        self.sourceAssetID = sourceAssetID
        self.name = name
        self.timelineStartFrame = max(0, timelineStartFrame)
        self.sourceStartFrame = max(0, sourceStartFrame)
        self.durationFrames = max(0, durationFrames)
        self.projectRate = projectRate
        self.sourceRate = sourceRate
        self.gainDB = gainDB
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.isReversed = isReversed
        self.swapChannels = swapChannels
        self.channelMode = channelMode
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
        self.crossfadeCurve = crossfadeCurve
        self.effects = effects
        self.effectSlots = effectSlots
    }

    // MARK: Backward-Compatible TimeInterval Initializer
    init(
        id: UUID = UUID(),
        sourceAssetID: UUID? = nil,
        name: String,
        timelineStart: TimeInterval,
        sourceStart: TimeInterval,
        duration: TimeInterval,
        projectRate: SampleRate = .rate48k,
        sourceRate: SampleRate? = nil,
        gainDB: Double = 0,
        isMuted: Bool = false,
        isLocked: Bool = false,
        isReversed: Bool = false,
        swapChannels: Bool = false,
        channelMode: AudioEditorChannelMode = .original,
        fadeIn: ClipFadeSpec? = nil,
        fadeOut: ClipFadeSpec? = nil,
        crossfadeCurve: ClipFadeCurve = .equalPower,
        effects: AudioEffectChainConfig = AudioEffectChainConfig(),
        effectSlots: [AudioEffectSlot] = []
    ) {
        let resolvedSourceRate = sourceRate ?? projectRate
        let tStart = (try? SampleFrameMigration.secondsToFrames(max(0, timelineStart), sampleRate: projectRate, field: "timelineStart")) ?? 0
        let sStart = (try? SampleFrameMigration.secondsToFrames(max(0, sourceStart), sampleRate: resolvedSourceRate, field: "sourceStart")) ?? 0
        let dur = (try? SampleFrameMigration.secondsToFrames(max(0, duration), sampleRate: projectRate, field: "duration")) ?? 0
        let fi = fadeIn.flatMap { try? ClipFadeSpecFrames(spec: $0, sampleRate: projectRate) }
        let fo = fadeOut.flatMap { try? ClipFadeSpecFrames(spec: $0, sampleRate: projectRate) }

        self.init(
            id: id,
            sourceAssetID: sourceAssetID,
            name: name,
            timelineStartFrame: tStart,
            sourceStartFrame: sStart,
            durationFrames: dur,
            projectRate: projectRate,
            sourceRate: resolvedSourceRate,
            gainDB: gainDB,
            isMuted: isMuted,
            isLocked: isLocked,
            isReversed: isReversed,
            swapChannels: swapChannels,
            channelMode: channelMode,
            fadeInFrames: fi,
            fadeOutFrames: fo,
            crossfadeCurve: crossfadeCurve,
            effects: effects,
            effectSlots: effectSlots
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceAssetID, name
        case timelineStartFrame, sourceStartFrame, durationFrames, projectRate, sourceRate
        case timelineStart, sourceStart, duration
        case gainDB, isMuted, isLocked, isReversed, swapChannels, channelMode
        case fadeInFrames, fadeOutFrames, fadeIn, fadeOut
        case crossfadeCurve, effects, effectSlots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let sourceAssetID = try c.decodeIfPresent(UUID.self, forKey: .sourceAssetID)
        let name = try c.decode(String.self, forKey: .name)
        let gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        let isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        let isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        let isReversed = try c.decodeIfPresent(Bool.self, forKey: .isReversed) ?? false
        let swapChannels = try c.decodeIfPresent(Bool.self, forKey: .swapChannels) ?? false
        let channelMode = try c.decodeIfPresent(AudioEditorChannelMode.self, forKey: .channelMode) ?? .original
        let crossfadeCurve = try c.decodeIfPresent(ClipFadeCurve.self, forKey: .crossfadeCurve) ?? .equalPower
        let effects = try c.decodeIfPresent(AudioEffectChainConfig.self, forKey: .effects) ?? AudioEffectChainConfig()
        let effectSlots = try c.decodeIfPresent([AudioEffectSlot].self, forKey: .effectSlots) ?? []

        if c.contains(.timelineStartFrame) || c.contains(.durationFrames) {
            let tStart = try c.decode(Int64.self, forKey: .timelineStartFrame)
            let sStart = try c.decodeIfPresent(Int64.self, forKey: .sourceStartFrame) ?? 0
            let dur = try c.decode(Int64.self, forKey: .durationFrames)
            guard tStart >= 0 else { throw AudioProjectMigrationError.negativeFrameValue(field: "timelineStartFrame", value: tStart) }
            guard sStart >= 0 else { throw AudioProjectMigrationError.negativeFrameValue(field: "sourceStartFrame", value: sStart) }
            guard dur >= 0 else { throw AudioProjectMigrationError.negativeFrameValue(field: "durationFrames", value: dur) }
            if tStart.addingReportingOverflow(dur).overflow {
                throw SampleFrameError.integerOverflow
            }
            let pRate = try c.decodeIfPresent(SampleRate.self, forKey: .projectRate) ?? .rate48k
            let sRate = try c.decodeIfPresent(SampleRate.self, forKey: .sourceRate) ?? pRate
            let fi = try c.decodeIfPresent(ClipFadeSpecFrames.self, forKey: .fadeInFrames)
            let fo = try c.decodeIfPresent(ClipFadeSpecFrames.self, forKey: .fadeOutFrames)

            self.init(
                id: id,
                sourceAssetID: sourceAssetID,
                name: name,
                timelineStartFrame: tStart,
                sourceStartFrame: sStart,
                durationFrames: dur,
                projectRate: pRate,
                sourceRate: sRate,
                gainDB: gainDB,
                isMuted: isMuted,
                isLocked: isLocked,
                isReversed: isReversed,
                swapChannels: swapChannels,
                channelMode: channelMode,
                fadeInFrames: fi,
                fadeOutFrames: fo,
                crossfadeCurve: crossfadeCurve,
                effects: effects,
                effectSlots: effectSlots
            )
        } else {
            let pRate = try c.decodeIfPresent(SampleRate.self, forKey: .projectRate) ?? .rate48k
            let sRate = try c.decodeIfPresent(SampleRate.self, forKey: .sourceRate) ?? pRate
            let tSec = try c.decode(TimeInterval.self, forKey: .timelineStart)
            let sSec = try c.decode(TimeInterval.self, forKey: .sourceStart)
            let dSec = try c.decode(TimeInterval.self, forKey: .duration)

            let tStart = try SampleFrameMigration.secondsToFrames(tSec, sampleRate: pRate, field: "clip.timelineStart")
            let sStart = try SampleFrameMigration.secondsToFrames(sSec, sampleRate: sRate, field: "clip.sourceStart")
            let dur = try SampleFrameMigration.secondsToFrames(dSec, sampleRate: pRate, field: "clip.duration")
            if tStart.addingReportingOverflow(dur).overflow {
                throw AudioProjectMigrationError.integerOverflow(field: "clip.timelineEnd", value: tSec + dSec)
            }
            let fi = try c.decodeIfPresent(ClipFadeSpec.self, forKey: .fadeIn).map {
                try ClipFadeSpecFrames(spec: $0, sampleRate: pRate)
            }
            let fo = try c.decodeIfPresent(ClipFadeSpec.self, forKey: .fadeOut).map {
                try ClipFadeSpecFrames(spec: $0, sampleRate: pRate)
            }

            self.init(
                id: id,
                sourceAssetID: sourceAssetID,
                name: name,
                timelineStartFrame: tStart,
                sourceStartFrame: sStart,
                durationFrames: dur,
                projectRate: pRate,
                sourceRate: sRate,
                gainDB: gainDB,
                isMuted: isMuted,
                isLocked: isLocked,
                isReversed: isReversed,
                swapChannels: swapChannels,
                channelMode: channelMode,
                fadeInFrames: fi,
                fadeOutFrames: fo,
                crossfadeCurve: crossfadeCurve,
                effects: effects,
                effectSlots: effectSlots
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(sourceAssetID, forKey: .sourceAssetID)
        try c.encode(name, forKey: .name)
        try c.encode(timelineStartFrame, forKey: .timelineStartFrame)
        try c.encode(sourceStartFrame, forKey: .sourceStartFrame)
        try c.encode(durationFrames, forKey: .durationFrames)
        try c.encode(projectRate, forKey: .projectRate)
        try c.encode(sourceRate, forKey: .sourceRate)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(isMuted, forKey: .isMuted)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encode(isReversed, forKey: .isReversed)
        try c.encode(swapChannels, forKey: .swapChannels)
        try c.encode(channelMode, forKey: .channelMode)
        try c.encodeIfPresent(fadeInFrames, forKey: .fadeInFrames)
        try c.encodeIfPresent(fadeOutFrames, forKey: .fadeOutFrames)
        try c.encode(crossfadeCurve, forKey: .crossfadeCurve)
        try c.encode(effects, forKey: .effects)
        try c.encode(effectSlots, forKey: .effectSlots)
    }

    // MARK: Sample-Accurate Computeds & Derived UI TimeInterval Shims

    var timelineEndFrame: Int64 {
        let (sum, ov) = timelineStartFrame.addingReportingOverflow(durationFrames)
        return ov ? Int64.max : sum
    }

    var timelineRange: SampleFrameRange? {
        try? SampleFrameRange(startFrame: timelineStartFrame, frameCount: durationFrames, sampleRate: projectRate)
    }

    /// Integer frames of source audio consumed by this clip in `sourceRate`.
    var sourceSpanFrames: Int64 {
        let s = stretch
        if abs(s - 1.0) <= 0.00001 {
            if sourceRate == projectRate {
                return durationFrames
            }
            return (try? SampleFrameTime.convertInt128(Int128(durationFrames), from: projectRate, to: sourceRate)) ?? durationFrames
        }
        let sec = Double(durationFrames) / Double(projectRate.hz) * s
        return (try? SampleFrameMigration.secondsToFrames(max(0, sec), sampleRate: sourceRate, field: "sourceSpan")) ?? 0
    }

    var timelineStart: TimeInterval {
        get { SampleFrameMigration.framesToSeconds(timelineStartFrame, sampleRate: projectRate) }
        set {
            guard newValue.isFinite else { return }
            if let f = try? SampleFrameMigration.secondsToFrames(max(0, newValue), sampleRate: projectRate, field: "timelineStart") {
                timelineStartFrame = f
            }
        }
    }

    var sourceStart: TimeInterval {
        get { SampleFrameMigration.framesToSeconds(sourceStartFrame, sampleRate: sourceRate) }
        set {
            guard newValue.isFinite else { return }
            if let f = try? SampleFrameMigration.secondsToFrames(max(0, newValue), sampleRate: sourceRate, field: "sourceStart") {
                sourceStartFrame = f
            }
        }
    }

    /// Duration on the timeline (seconds, derived from `durationFrames` and `projectRate`).
    var duration: TimeInterval {
        get { SampleFrameMigration.framesToSeconds(durationFrames, sampleRate: projectRate) }
        set {
            guard newValue.isFinite else { return }
            if let f = try? SampleFrameMigration.secondsToFrames(max(0, newValue), sampleRate: projectRate, field: "duration") {
                durationFrames = f
            }
        }
    }

    var fadeIn: ClipFadeSpec? {
        get { fadeInFrames.map { ClipFadeSpec(duration: $0.durationSeconds(at: projectRate), curve: $0.curve) } }
        set { fadeInFrames = newValue.flatMap { try? ClipFadeSpecFrames(spec: $0, sampleRate: projectRate) } }
    }

    var fadeOut: ClipFadeSpec? {
        get { fadeOutFrames.map { ClipFadeSpec(duration: $0.durationSeconds(at: projectRate), curve: $0.curve) } }
        set { fadeOutFrames = newValue.flatMap { try? ClipFadeSpecFrames(spec: $0, sampleRate: projectRate) } }
    }

    var timelineEnd: TimeInterval { SampleFrameMigration.framesToSeconds(timelineEndFrame, sampleRate: projectRate) }
    var stretch: Double { max(0.25, min(4.0, effects.timeStretch)) }
    /// Seconds of source consumed by this clip.
    var sourceSpan: TimeInterval { SampleFrameMigration.framesToSeconds(sourceSpanFrames, sampleRate: sourceRate) }

    var needsProcessedProxy: Bool {
        isReversed || swapChannels || channelMode != .original || !effects.isIdentity
    }
}

struct AudioTrack: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var clips: [AudioClip] = []
    var volume: Double = 1.0        // linear 0...1.5
    var pan: Double = 0             // -1...1
    var isMuted = false
    var isSolo = false
    var isLocked = false
    var effectSlots: [AudioEffectSlot] = []
    var groupID: UUID? = nil

    init(
        id: UUID = UUID(),
        name: String,
        clips: [AudioClip] = [],
        volume: Double = 1.0,
        pan: Double = 0,
        isMuted: Bool = false,
        isSolo: Bool = false,
        isLocked: Bool = false,
        effectSlots: [AudioEffectSlot] = [],
        groupID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.clips = clips
        self.volume = volume
        self.pan = pan
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.isLocked = isLocked
        self.effectSlots = effectSlots
        self.groupID = groupID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decodeIfPresent([AudioClip].self, forKey: .clips) ?? []
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try c.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        effectSlots = try c.decodeIfPresent([AudioEffectSlot].self, forKey: .effectSlots) ?? []
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
    }
}

struct AudioMarker: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var frame: Int64
    var sampleRate: SampleRate = .rate48k
    var name: String

    var time: TimeInterval {
        get { SampleFrameMigration.framesToSeconds(frame, sampleRate: sampleRate) }
        set {
            guard newValue.isFinite else { return }
            if let f = try? SampleFrameMigration.secondsToFrames(max(0, newValue), sampleRate: sampleRate, field: "marker.time") {
                frame = f
            }
        }
    }

    init(id: UUID = UUID(), frame: Int64, sampleRate: SampleRate = .rate48k, name: String) {
        self.id = id
        self.frame = max(0, frame)
        self.sampleRate = sampleRate
        self.name = name
    }

    init(id: UUID = UUID(), time: TimeInterval, name: String, sampleRate: SampleRate = .rate48k) {
        let f = (try? SampleFrameMigration.secondsToFrames(max(0, time), sampleRate: sampleRate, field: "marker.time")) ?? 0
        self.init(id: id, frame: f, sampleRate: sampleRate, name: name)
    }

    private enum CodingKeys: String, CodingKey {
        case id, frame, sampleRate, time, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let name = try c.decode(String.self, forKey: .name)
        if c.contains(.frame) {
            let f = try c.decode(Int64.self, forKey: .frame)
            guard f >= 0 else {
                throw AudioProjectMigrationError.negativeFrameValue(field: "marker.frame", value: f)
            }
            let rate = try c.decodeIfPresent(SampleRate.self, forKey: .sampleRate) ?? .rate48k
            self.init(id: id, frame: f, sampleRate: rate, name: name)
        } else {
            let t = try c.decode(TimeInterval.self, forKey: .time)
            let rate = try c.decodeIfPresent(SampleRate.self, forKey: .sampleRate) ?? .rate48k
            let f = try SampleFrameMigration.secondsToFrames(t, sampleRate: rate, field: "marker.time")
            self.init(id: id, frame: f, sampleRate: rate, name: name)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(frame, forKey: .frame)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(name, forKey: .name)
    }
}

struct AudioEditorProject: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 3

    var id: UUID = UUID()
    var schemaVersion: Int = AudioEditorProject.currentSchemaVersion
    var name: String = "Untitled Project"
    var projectSampleRate: SampleRate = .rate48k
    var tracks: [AudioTrack] = []
    var markers: [AudioMarker] = []
    var mediaAssets: [AudioMediaReference] = []
    var masterEffects: [AudioEffectSlot] = []
    var trackGroups: [AudioTrackGroup] = []
    var gridConfig: TimelineGridConfig = TimelineGridConfig()
    /// Optional mapping from project mediaAsset IDs to AudioWorkspace library track IDs.
    var linkedLibraryAssetMap: [UUID: UUID] = [:]
    var lastExportConfiguration: AudioExportConfiguration? = nil

    /// Backward-compatible Double representation of `projectSampleRate`.
    var sampleRate: Double {
        get { Double(projectSampleRate.hz) }
        set {
            if let validated = try? SampleFrameMigration.validatedSampleRate(newValue) {
                if validated != projectSampleRate {
                    projectSampleRate = validated
                }
            }
        }
    }

    init(
        id: UUID = UUID(),
        schemaVersion: Int = AudioEditorProject.currentSchemaVersion,
        name: String = "Untitled Project",
        sampleRate: Double = 48_000,
        tracks: [AudioTrack] = [],
        markers: [AudioMarker] = [],
        mediaAssets: [AudioMediaReference] = [],
        masterEffects: [AudioEffectSlot] = [],
        trackGroups: [AudioTrackGroup] = [],
        gridConfig: TimelineGridConfig = TimelineGridConfig(),
        linkedLibraryAssetMap: [UUID: UUID] = [:],
        lastExportConfiguration: AudioExportConfiguration? = nil
    ) {
        let resolvedRate = (try? SampleFrameMigration.validatedSampleRate(sampleRate)) ?? .rate48k
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.projectSampleRate = resolvedRate
        self.tracks = Self.alignTracksToProjectRate(tracks, projectRate: resolvedRate)
        self.markers = Self.alignMarkersToProjectRate(markers, projectRate: resolvedRate)
        self.mediaAssets = mediaAssets
        self.masterEffects = masterEffects
        self.trackGroups = trackGroups
        self.gridConfig = gridConfig
        self.linkedLibraryAssetMap = linkedLibraryAssetMap
        self.lastExportConfiguration = lastExportConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, sampleRate, tracks, markers, mediaAssets
        case masterEffects, trackGroups, gridConfig
        case linkedLibraryAssetMap, lastExportConfiguration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedSchema = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard decodedSchema >= 1 && decodedSchema <= AudioEditorProject.currentSchemaVersion else {
            throw AudioProjectMigrationError.unsupportedSchemaVersion(decodedSchema)
        }

        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Project"
        let rawRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48_000
        let resolvedRate = try SampleFrameMigration.validatedSampleRate(rawRate)

        let mediaAssets = try c.decodeIfPresent([AudioMediaReference].self, forKey: .mediaAssets) ?? []
        let masterEffects = try c.decodeIfPresent([AudioEffectSlot].self, forKey: .masterEffects) ?? []
        let trackGroups = try c.decodeIfPresent([AudioTrackGroup].self, forKey: .trackGroups) ?? []
        let gridConfig = try c.decodeIfPresent(TimelineGridConfig.self, forKey: .gridConfig) ?? TimelineGridConfig()
        let linkedLibraryAssetMap = try c.decodeIfPresent([UUID: UUID].self, forKey: .linkedLibraryAssetMap) ?? [:]
        let lastExportConfiguration = try c.decodeIfPresent(AudioExportConfiguration.self, forKey: .lastExportConfiguration)

        let resolvedTracks: [AudioTrack]
        let resolvedMarkers: [AudioMarker]

        if decodedSchema < AudioEditorProject.currentSchemaVersion {
            let legacyTracks = try c.decodeIfPresent([LegacyAudioTrack].self, forKey: .tracks) ?? []
            let legacyMarkers = try c.decodeIfPresent([LegacyAudioMarker].self, forKey: .markers) ?? []
            let assetRatesByID: [UUID: SampleRate] = Dictionary(
                uniqueKeysWithValues: mediaAssets.compactMap { asset in
                    guard let rate = try? SampleFrameMigration.validatedSampleRate(asset.sampleRate) else { return nil }
                    return (asset.id, rate)
                }
            )
            resolvedTracks = try legacyTracks.map { lt in
                try lt.migrated(projectRate: resolvedRate, assetRatesByID: assetRatesByID)
            }
            resolvedMarkers = try legacyMarkers.map { lm in
                try lm.migrated(projectRate: resolvedRate)
            }
        } else {
            let rawTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .tracks) ?? []
            let rawMarkers = try c.decodeIfPresent([AudioMarker].self, forKey: .markers) ?? []
            for track in rawTracks {
                for clip in track.clips {
                    guard clip.timelineStartFrame >= 0 else {
                        throw AudioProjectMigrationError.negativeFrameValue(field: "clip.timelineStartFrame", value: clip.timelineStartFrame)
                    }
                    guard clip.sourceStartFrame >= 0 else {
                        throw AudioProjectMigrationError.negativeFrameValue(field: "clip.sourceStartFrame", value: clip.sourceStartFrame)
                    }
                    guard clip.durationFrames >= 0 else {
                        throw AudioProjectMigrationError.negativeFrameValue(field: "clip.durationFrames", value: clip.durationFrames)
                    }
                    if clip.timelineStartFrame.addingReportingOverflow(clip.durationFrames).overflow {
                        throw SampleFrameError.integerOverflow
                    }
                }
            }
            for marker in rawMarkers where marker.frame < 0 {
                throw AudioProjectMigrationError.negativeFrameValue(field: "marker.frame", value: marker.frame)
            }
            resolvedTracks = Self.alignTracksToProjectRate(rawTracks, projectRate: resolvedRate)
            resolvedMarkers = Self.alignMarkersToProjectRate(rawMarkers, projectRate: resolvedRate)
        }

        self.id = id
        self.schemaVersion = AudioEditorProject.currentSchemaVersion
        self.name = name
        self.projectSampleRate = resolvedRate
        self.tracks = resolvedTracks
        self.markers = resolvedMarkers
        self.mediaAssets = mediaAssets
        self.masterEffects = masterEffects
        self.trackGroups = trackGroups
        self.gridConfig = gridConfig
        self.linkedLibraryAssetMap = linkedLibraryAssetMap
        self.lastExportConfiguration = lastExportConfiguration
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(AudioEditorProject.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(name, forKey: .name)
        try c.encode(Double(projectSampleRate.hz), forKey: .sampleRate)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(markers, forKey: .markers)
        try c.encode(mediaAssets, forKey: .mediaAssets)
        try c.encode(masterEffects, forKey: .masterEffects)
        try c.encode(trackGroups, forKey: .trackGroups)
        try c.encode(gridConfig, forKey: .gridConfig)
        try c.encode(linkedLibraryAssetMap, forKey: .linkedLibraryAssetMap)
        try c.encodeIfPresent(lastExportConfiguration, forKey: .lastExportConfiguration)
    }

    var durationFrames: Int64 {
        tracks.flatMap(\.clips).map(\.timelineEndFrame).max() ?? 0
    }

    var duration: TimeInterval {
        SampleFrameMigration.framesToSeconds(durationFrames, sampleRate: projectSampleRate)
    }

    func asset(_ id: UUID?) -> AudioMediaReference? {
        guard let id else { return nil }
        return mediaAssets.first { $0.id == id }
    }

    func trackIndex(containingClip clipID: UUID) -> Int? {
        tracks.firstIndex { $0.clips.contains { $0.id == clipID } }
    }

    func clip(_ id: UUID) -> AudioClip? {
        for t in tracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    var anySolo: Bool {
        tracks.contains(where: \.isSolo) || trackGroups.contains(where: \.isSolo)
    }

    /// Tracks audible given track-level and group-level mute/solo state.
    func isTrackAudible(_ track: AudioTrack) -> Bool {
        let group = track.groupID.flatMap { gid in trackGroups.first { $0.id == gid } }
        if anySolo {
            return track.isSolo || (group?.isSolo == true)
        }
        return !track.isMuted && !(group?.isMuted ?? false)
    }

    private static func alignTracksToProjectRate(_ tracks: [AudioTrack], projectRate: SampleRate) -> [AudioTrack] {
        tracks.map { track in
            var updatedTrack = track
            updatedTrack.clips = track.clips.map { clip in
                guard clip.projectRate != projectRate else { return clip }
                var updated = clip
                updated.timelineStartFrame = (try? SampleFrameTime.convertInt128(
                    Int128(clip.timelineStartFrame),
                    from: clip.projectRate,
                    to: projectRate
                )) ?? clip.timelineStartFrame
                updated.durationFrames = (try? SampleFrameTime.convertInt128(
                    Int128(clip.durationFrames),
                    from: clip.projectRate,
                    to: projectRate
                )) ?? clip.durationFrames
                if let fi = clip.fadeInFrames {
                    let f = (try? SampleFrameTime.convertInt128(Int128(fi.durationFrames), from: clip.projectRate, to: projectRate)) ?? fi.durationFrames
                    updated.fadeInFrames = ClipFadeSpecFrames(durationFrames: f, curve: fi.curve)
                }
                if let fo = clip.fadeOutFrames {
                    let f = (try? SampleFrameTime.convertInt128(Int128(fo.durationFrames), from: clip.projectRate, to: projectRate)) ?? fo.durationFrames
                    updated.fadeOutFrames = ClipFadeSpecFrames(durationFrames: f, curve: fo.curve)
                }
                updated.projectRate = projectRate
                return updated
            }
            return updatedTrack
        }
    }

    private static func alignMarkersToProjectRate(_ markers: [AudioMarker], projectRate: SampleRate) -> [AudioMarker] {
        markers.map { marker in
            guard marker.sampleRate != projectRate else { return marker }
            var updated = marker
            updated.frame = (try? SampleFrameTime.convertInt128(
                Int128(marker.frame),
                from: marker.sampleRate,
                to: projectRate
            )) ?? marker.frame
            updated.sampleRate = projectRate
            return updated
        }
    }
}

// MARK: - Private Legacy v1/v2 Migration Decoders

private struct LegacyAudioClip: Decodable {
    var id: UUID?
    var sourceAssetID: UUID?
    var name: String
    var timelineStart: Double
    var sourceStart: Double
    var duration: Double
    var gainDB: Double?
    var isMuted: Bool?
    var isLocked: Bool?
    var isReversed: Bool?
    var swapChannels: Bool?
    var channelMode: AudioEditorChannelMode?
    var fadeIn: ClipFadeSpec?
    var fadeOut: ClipFadeSpec?
    var crossfadeCurve: ClipFadeCurve?
    var effects: AudioEffectChainConfig?
    var effectSlots: [AudioEffectSlot]?

    func migrated(projectRate: SampleRate, assetRatesByID: [UUID: SampleRate]) throws -> AudioClip {
        let sRate = sourceAssetID.flatMap { assetRatesByID[$0] } ?? projectRate
        let tStart = try SampleFrameMigration.secondsToFrames(timelineStart, sampleRate: projectRate, field: "clip.timelineStart")
        let sStart = try SampleFrameMigration.secondsToFrames(sourceStart, sampleRate: sRate, field: "clip.sourceStart")
        let dur = try SampleFrameMigration.secondsToFrames(duration, sampleRate: projectRate, field: "clip.duration")
        if tStart.addingReportingOverflow(dur).overflow {
            throw AudioProjectMigrationError.integerOverflow(field: "clip.timelineEnd", value: timelineStart + duration)
        }
        let fi = try fadeIn.map { try ClipFadeSpecFrames(spec: $0, sampleRate: projectRate) }
        let fo = try fadeOut.map { try ClipFadeSpecFrames(spec: $0, sampleRate: projectRate) }

        return AudioClip(
            id: id ?? UUID(),
            sourceAssetID: sourceAssetID,
            name: name,
            timelineStartFrame: tStart,
            sourceStartFrame: sStart,
            durationFrames: dur,
            projectRate: projectRate,
            sourceRate: sRate,
            gainDB: gainDB ?? 0,
            isMuted: isMuted ?? false,
            isLocked: isLocked ?? false,
            isReversed: isReversed ?? false,
            swapChannels: swapChannels ?? false,
            channelMode: channelMode ?? .original,
            fadeInFrames: fi,
            fadeOutFrames: fo,
            crossfadeCurve: crossfadeCurve ?? .equalPower,
            effects: effects ?? AudioEffectChainConfig(),
            effectSlots: effectSlots ?? []
        )
    }
}

private struct LegacyAudioTrack: Decodable {
    var id: UUID?
    var name: String
    var clips: [LegacyAudioClip]?
    var volume: Double?
    var pan: Double?
    var isMuted: Bool?
    var isSolo: Bool?
    var isLocked: Bool?
    var effectSlots: [AudioEffectSlot]?
    var groupID: UUID?

    func migrated(projectRate: SampleRate, assetRatesByID: [UUID: SampleRate]) throws -> AudioTrack {
        let migratedClips = try (clips ?? []).map { try $0.migrated(projectRate: projectRate, assetRatesByID: assetRatesByID) }
        return AudioTrack(
            id: id ?? UUID(),
            name: name,
            clips: migratedClips,
            volume: volume ?? 1.0,
            pan: pan ?? 0,
            isMuted: isMuted ?? false,
            isSolo: isSolo ?? false,
            isLocked: isLocked ?? false,
            effectSlots: effectSlots ?? [],
            groupID: groupID
        )
    }
}

private struct LegacyAudioMarker: Decodable {
    var id: UUID?
    var time: Double
    var name: String

    func migrated(projectRate: SampleRate) throws -> AudioMarker {
        let f = try SampleFrameMigration.secondsToFrames(time, sampleRate: projectRate, field: "marker.time")
        return AudioMarker(id: id ?? UUID(), frame: f, sampleRate: projectRate, name: name)
    }
}

// MARK: - Timeline State (view/transport state: never dirties the project or pushes undo entries)

struct TimelineState: Equatable, Sendable {
    var playheadTime: TimeInterval = 0
    var selectionRange: ClosedRange<TimeInterval>? = nil
    var loopRange: ClosedRange<TimeInterval>? = nil
    var isLoopEnabled = false
    var pixelsPerSecond: Double = 80
    var scrollOffset: TimeInterval = 0   // seconds at the left edge of the viewport

    static let minPixelsPerSecond: Double = 2
    static let maxPixelsPerSecond: Double = 20_000

    func x(for time: TimeInterval) -> Double { (time - scrollOffset) * pixelsPerSecond }
    func time(forX x: Double) -> TimeInterval { max(0, x / pixelsPerSecond + scrollOffset) }

    /// Playhead moves are fully independent of the selection range.
    mutating func setPlayhead(_ t: TimeInterval, maxTime: TimeInterval? = nil) {
        var v = max(0, t)
        if let m = maxTime { v = min(v, max(m, 0)) }
        playheadTime = (v * 1000).rounded() / 1000   // millisecond precision
    }

    mutating func setSelection(from a: TimeInterval, to b: TimeInterval) {
        let lo = max(0, min(a, b)), hi = max(0, max(a, b))
        selectionRange = hi - lo < 0.001 ? nil : lo...hi
    }

    mutating func zoom(by factor: Double, anchorTime: TimeInterval) {
        let old = pixelsPerSecond
        let new = min(Self.maxPixelsPerSecond, max(Self.minPixelsPerSecond, old * factor))
        // Keep anchorTime at the same viewport x.
        let anchorX = (anchorTime - scrollOffset) * old
        pixelsPerSecond = new
        scrollOffset = max(0, anchorTime - anchorX / new)
    }

    mutating func fit(range: ClosedRange<TimeInterval>, viewportWidth: Double) {
        let span = max(0.05, range.upperBound - range.lowerBound)
        pixelsPerSecond = min(Self.maxPixelsPerSecond, max(Self.minPixelsPerSecond, (viewportWidth * 0.96) / span))
        scrollOffset = max(0, range.lowerBound - (span * 0.02))
    }

    mutating func scroll(toKeep time: TimeInterval, viewportWidth: Double) {
        let visible = viewportWidth / pixelsPerSecond
        if time < scrollOffset { scrollOffset = max(0, time - visible * 0.1) }
        else if time > scrollOffset + visible { scrollOffset = max(0, time - visible * 0.9) }
    }
}

// MARK: - Time formatting

enum AudioEditorTime {
    /// mm:ss.mmm (h:mm:ss.mmm for long timelines)
    static func format(_ t: TimeInterval) -> String {
        let total = max(0, t)
        let ms = Int((total * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, r = ms % 1000
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, r) : String(format: "%02d:%02d.%03d", m, s, r)
    }
}

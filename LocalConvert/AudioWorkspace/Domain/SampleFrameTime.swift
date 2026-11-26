import Foundation

// MARK: - Errors

enum SampleFrameError: Error, LocalizedError, Equatable, Sendable {
    case invalidSampleRate(Int32)
    case negativeFrameNotAllowed(Int64)
    case integerOverflow
    case integerUnderflow
    case invalidRangeLength(Int64)
    case emptyExportRange
    case nonFiniteLegacySeconds(Double)
    case lossyBoundaryExceedsInt64

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let hz):
            return "Invalid audio sample rate \(hz) Hz; expected 1...768000 Hz."
        case .negativeFrameNotAllowed(let frame):
            return "Negative sample frame \(frame) is not valid in this coordinate space."
        case .integerOverflow:
            return "Sample-frame arithmetic exceeded Int64.max."
        case .integerUnderflow:
            return "Sample-frame arithmetic fell below Int64.min."
        case .invalidRangeLength(let count):
            return "Sample-frame range length \(count) cannot be negative."
        case .emptyExportRange:
            return "Selection or timeline range contains zero audio frames and cannot be exported."
        case .nonFiniteLegacySeconds(let seconds):
            return "Legacy project time '\(seconds)' is non-finite and cannot be migrated."
        case .lossyBoundaryExceedsInt64:
            return "Legacy time value exceeds safe Int64 sample-frame representation."
        }
    }
}

// MARK: - SampleRate

/// Validated positive audio sample rate in Hertz (`1...768_000` Hz).
struct SampleRate: Codable, Hashable, Comparable, Sendable {
    static let validRange: ClosedRange<Int32> = 1...768_000

    static let rate44_1k = SampleRate(validatedUnchecked: 44_100)
    static let rate48k = SampleRate(validatedUnchecked: 48_000)
    static let rate88_2k = SampleRate(validatedUnchecked: 88_200)
    static let rate96k = SampleRate(validatedUnchecked: 96_000)
    static let rate192k = SampleRate(validatedUnchecked: 192_000)

    let hz: Int32

    private init(validatedUnchecked hz: Int32) {
        self.hz = hz
    }

    init(_ hz: Int32) throws {
        guard Self.validRange.contains(hz) else {
            throw SampleFrameError.invalidSampleRate(hz)
        }
        self.hz = hz
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode(Int32.self)
        try self.init(decoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hz)
    }

    static func < (lhs: SampleRate, rhs: SampleRate) -> Bool {
        lhs.hz < rhs.hz
    }
}

// MARK: - SampleFrameTime (Exact Integer Arithmetic Core)

/// Signed sample-frame instant paired with its validated sample rate.
/// Uses exact `Int128` rational arithmetic for cross-rate conversions and comparisons.
struct SampleFrameTime: Codable, Hashable, Comparable, Sendable {
    let frame: Int64
    let sampleRate: SampleRate

    init(frame: Int64, sampleRate: SampleRate) {
        self.frame = frame
        self.sampleRate = sampleRate
    }

    private enum CodingKeys: String, CodingKey {
        case frame
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let f = try container.decode(Int64.self, forKey: .frame)
        let r = try container.decode(SampleRate.self, forKey: .sampleRate)
        self.init(frame: f, sampleRate: r)
    }

    /// Display-only floating-point seconds helper (never used as editing source of truth).
    var derivedSeconds: Double {
        Double(frame) / Double(sampleRate.hz)
    }

    /// True only when both exact frame counts and sample rates match identically.
    func exactMatches(_ other: SampleFrameTime) -> Bool {
        frame == other.frame && sampleRate == other.sampleRate
    }

    /// Converts across sample rates using exact `Int128` rational arithmetic with deterministic
    /// round-half-away-from-zero ties and checked `Int64` bounds.
    func converted(to targetRate: SampleRate) throws -> SampleFrameTime {
        guard targetRate != sampleRate else {
            return self
        }
        let convertedFrame = try Self.convertInt128(
            Int128(frame),
            from: sampleRate,
            to: targetRate
        )
        return SampleFrameTime(frame: convertedFrame, sampleRate: targetRate)
    }

    func adding(_ delta: FrameDelta) throws -> SampleFrameTime {
        let alignedDelta = try delta.converted(to: sampleRate)
        let (sum, overflow) = frame.addingReportingOverflow(alignedDelta.frames)
        guard !overflow else {
            throw alignedDelta.frames >= 0 ? SampleFrameError.integerOverflow : SampleFrameError.integerUnderflow
        }
        return SampleFrameTime(frame: sum, sampleRate: sampleRate)
    }

    static func convertInt128(
        _ frame: Int128,
        from sourceRate: SampleRate,
        to targetRate: SampleRate
    ) throws -> Int64 {
        let scaled: Int128
        if sourceRate == targetRate {
            scaled = frame
        } else {
            let numerator = frame * Int128(targetRate.hz)
            let denominator = Int128(sourceRate.hz)
            let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
            var rounded = quotient
            // Deterministic round-half-away-from-zero tie policy
            if remainder.magnitude &* 2 >= denominator.magnitude {
                rounded += numerator >= 0 ? 1 : -1
            }
            scaled = rounded
        }
        guard let result = Int64(exactly: scaled) else {
            throw scaled >= 0 ? SampleFrameError.integerOverflow : SampleFrameError.integerUnderflow
        }
        return result
    }

    static func == (lhs: SampleFrameTime, rhs: SampleFrameTime) -> Bool {
        if lhs.sampleRate == rhs.sampleRate {
            return lhs.frame == rhs.frame
        }
        return Int128(lhs.frame) * Int128(rhs.sampleRate.hz) == Int128(rhs.frame) * Int128(lhs.sampleRate.hz)
    }

    static func < (lhs: SampleFrameTime, rhs: SampleFrameTime) -> Bool {
        if lhs.sampleRate == rhs.sampleRate {
            return lhs.frame < rhs.frame
        }
        return Int128(lhs.frame) * Int128(rhs.sampleRate.hz) < Int128(rhs.frame) * Int128(lhs.sampleRate.hz)
    }

    func hash(into hasher: inout Hasher) {
        if frame == 0 {
            hasher.combine(Int64(0))
            hasher.combine(UInt64(1))
            return
        }
        let numMag = frame.magnitude
        let denMag = UInt64(sampleRate.hz)
        let divisor = Self.gcd(numMag, denMag)
        hasher.combine(frame < 0)
        hasher.combine(numMag / divisor)
        hasher.combine(denMag / divisor)
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var x = a
        var y = b
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return max(1, x)
    }
}

// MARK: - Signed FrameDelta

/// Signed relative sample-frame offset in an explicit sample-rate clock domain.
struct FrameDelta: Codable, Hashable, Comparable, Sendable {
    let frames: Int64
    let sampleRate: SampleRate

    init(frames: Int64, sampleRate: SampleRate) {
        self.frames = frames
        self.sampleRate = sampleRate
    }

    private enum CodingKeys: String, CodingKey {
        case frames
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let f = try container.decode(Int64.self, forKey: .frames)
        let r = try container.decode(SampleRate.self, forKey: .sampleRate)
        self.init(frames: f, sampleRate: r)
    }

    func converted(to targetRate: SampleRate) throws -> FrameDelta {
        let raw = SampleFrameTime(frame: frames, sampleRate: sampleRate)
        let converted = try raw.converted(to: targetRate)
        return FrameDelta(frames: converted.frame, sampleRate: targetRate)
    }

    func adding(_ other: FrameDelta) throws -> FrameDelta {
        let aligned = try other.converted(to: sampleRate)
        let (sum, overflow) = frames.addingReportingOverflow(aligned.frames)
        guard !overflow else {
            throw aligned.frames >= 0 ? SampleFrameError.integerOverflow : SampleFrameError.integerUnderflow
        }
        return FrameDelta(frames: sum, sampleRate: sampleRate)
    }

    func negated() throws -> FrameDelta {
        guard frames != Int64.min else {
            throw SampleFrameError.integerOverflow
        }
        return FrameDelta(frames: -frames, sampleRate: sampleRate)
    }

    static func == (lhs: FrameDelta, rhs: FrameDelta) -> Bool {
        SampleFrameTime(frame: lhs.frames, sampleRate: lhs.sampleRate)
            == SampleFrameTime(frame: rhs.frames, sampleRate: rhs.sampleRate)
    }

    static func < (lhs: FrameDelta, rhs: FrameDelta) -> Bool {
        SampleFrameTime(frame: lhs.frames, sampleRate: lhs.sampleRate)
            < SampleFrameTime(frame: rhs.frames, sampleRate: rhs.sampleRate)
    }

    func hash(into hasher: inout Hasher) {
        SampleFrameTime(frame: frames, sampleRate: sampleRate).hash(into: &hasher)
    }
}

// MARK: - Domain-Typed Non-Negative Coordinate Spaces

/// Offset within an immutable source audio asset (`frame >= 0`).
struct SourceFrameTime: Codable, Hashable, Comparable, Sendable {
    let raw: SampleFrameTime

    var frame: Int64 { raw.frame }
    var sampleRate: SampleRate { raw.sampleRate }

    init(frame: Int64, sampleRate: SampleRate) throws {
        guard frame >= 0 else {
            throw SampleFrameError.negativeFrameNotAllowed(frame)
        }
        self.raw = SampleFrameTime(frame: frame, sampleRate: sampleRate)
    }

    private enum CodingKeys: String, CodingKey {
        case frame
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let frame = try c.decode(Int64.self, forKey: .frame)
        let rate = try c.decode(SampleRate.self, forKey: .sampleRate)
        try self.init(frame: frame, sampleRate: rate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(raw.frame, forKey: .frame)
        try c.encode(raw.sampleRate, forKey: .sampleRate)
    }

    func offset(by delta: FrameDelta) throws -> SourceFrameTime {
        let shifted = try raw.adding(delta)
        return try SourceFrameTime(frame: shifted.frame, sampleRate: shifted.sampleRate)
    }

    func converted(to targetRate: SampleRate) throws -> SourceFrameTime {
        let converted = try raw.converted(to: targetRate)
        return try SourceFrameTime(frame: converted.frame, sampleRate: targetRate)
    }

    func toTimeline(at projectRate: SampleRate) throws -> TimelineFrameTime {
        let converted = try raw.converted(to: projectRate)
        return try TimelineFrameTime(frame: converted.frame, sampleRate: projectRate)
    }

    static func == (lhs: SourceFrameTime, rhs: SourceFrameTime) -> Bool { lhs.raw == rhs.raw }
    static func < (lhs: SourceFrameTime, rhs: SourceFrameTime) -> Bool { lhs.raw < rhs.raw }
    func hash(into hasher: inout Hasher) { raw.hash(into: &hasher) }
}

/// Absolute non-negative position on an `AudioProject` timeline (`frame >= 0`).
struct TimelineFrameTime: Codable, Hashable, Comparable, Sendable {
    let raw: SampleFrameTime

    var frame: Int64 { raw.frame }
    var sampleRate: SampleRate { raw.sampleRate }

    init(frame: Int64, sampleRate: SampleRate) throws {
        guard frame >= 0 else {
            throw SampleFrameError.negativeFrameNotAllowed(frame)
        }
        self.raw = SampleFrameTime(frame: frame, sampleRate: sampleRate)
    }

    private enum CodingKeys: String, CodingKey {
        case frame
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let frame = try c.decode(Int64.self, forKey: .frame)
        let rate = try c.decode(SampleRate.self, forKey: .sampleRate)
        try self.init(frame: frame, sampleRate: rate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(raw.frame, forKey: .frame)
        try c.encode(raw.sampleRate, forKey: .sampleRate)
    }

    func offset(by delta: FrameDelta) throws -> TimelineFrameTime {
        let shifted = try raw.adding(delta)
        return try TimelineFrameTime(frame: shifted.frame, sampleRate: shifted.sampleRate)
    }

    func converted(to targetRate: SampleRate) throws -> TimelineFrameTime {
        let converted = try raw.converted(to: targetRate)
        return try TimelineFrameTime(frame: converted.frame, sampleRate: targetRate)
    }

    func toSource(at sourceRate: SampleRate) throws -> SourceFrameTime {
        let converted = try raw.converted(to: sourceRate)
        return try SourceFrameTime(frame: converted.frame, sampleRate: sourceRate)
    }

    func toRender(at renderRate: SampleRate) throws -> RenderFrameTime {
        let converted = try raw.converted(to: renderRate)
        return try RenderFrameTime(frame: converted.frame, sampleRate: renderRate)
    }

    static func == (lhs: TimelineFrameTime, rhs: TimelineFrameTime) -> Bool { lhs.raw == rhs.raw }
    static func < (lhs: TimelineFrameTime, rhs: TimelineFrameTime) -> Bool { lhs.raw < rhs.raw }
    func hash(into hasher: inout Hasher) { raw.hash(into: &hasher) }
}

/// Non-negative frame position in an export/render output stream (`frame >= 0`).
struct RenderFrameTime: Codable, Hashable, Comparable, Sendable {
    let raw: SampleFrameTime

    var frame: Int64 { raw.frame }
    var sampleRate: SampleRate { raw.sampleRate }

    init(frame: Int64, sampleRate: SampleRate) throws {
        guard frame >= 0 else {
            throw SampleFrameError.negativeFrameNotAllowed(frame)
        }
        self.raw = SampleFrameTime(frame: frame, sampleRate: sampleRate)
    }

    private enum CodingKeys: String, CodingKey {
        case frame
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let frame = try c.decode(Int64.self, forKey: .frame)
        let rate = try c.decode(SampleRate.self, forKey: .sampleRate)
        try self.init(frame: frame, sampleRate: rate)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(raw.frame, forKey: .frame)
        try c.encode(raw.sampleRate, forKey: .sampleRate)
    }

    func offset(by delta: FrameDelta) throws -> RenderFrameTime {
        let shifted = try raw.adding(delta)
        return try RenderFrameTime(frame: shifted.frame, sampleRate: shifted.sampleRate)
    }

    func converted(to targetRate: SampleRate) throws -> RenderFrameTime {
        let converted = try raw.converted(to: targetRate)
        return try RenderFrameTime(frame: converted.frame, sampleRate: targetRate)
    }

    static func == (lhs: RenderFrameTime, rhs: RenderFrameTime) -> Bool { lhs.raw == rhs.raw }
    static func < (lhs: RenderFrameTime, rhs: RenderFrameTime) -> Bool { lhs.raw < rhs.raw }
    func hash(into hasher: inout Hasher) { raw.hash(into: &hasher) }
}

// MARK: - SampleFrameRange

/// Half-open sample-frame interval `[startFrame, endFrame)` with validated non-negative start,
/// non-negative length, and overflow-checked exclusive end.
struct SampleFrameRange: Codable, Hashable, Sendable {
    let startFrame: Int64
    let frameCount: Int64
    let sampleRate: SampleRate

    init(startFrame: Int64, frameCount: Int64, sampleRate: SampleRate) throws {
        guard startFrame >= 0 else {
            throw SampleFrameError.negativeFrameNotAllowed(startFrame)
        }
        guard frameCount >= 0 else {
            throw SampleFrameError.invalidRangeLength(frameCount)
        }
        let (_, overflow) = startFrame.addingReportingOverflow(frameCount)
        guard !overflow else {
            throw SampleFrameError.integerOverflow
        }
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.sampleRate = sampleRate
    }

    private enum CodingKeys: String, CodingKey {
        case startFrame
        case frameCount
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Int64.self, forKey: .startFrame)
        let count = try container.decode(Int64.self, forKey: .frameCount)
        let rate = try container.decode(SampleRate.self, forKey: .sampleRate)
        try self.init(startFrame: start, frameCount: count, sampleRate: rate)
    }

    /// Guaranteed non-overflowing exclusive end frame.
    var endFrame: Int64 { startFrame + frameCount }

    /// Zero-length range is valid for an empty caret/selection and acts as a safe editing no-op.
    var isEmpty: Bool { frameCount == 0 }

    func validateNonEmptyForExport() throws {
        if isEmpty {
            throw SampleFrameError.emptyExportRange
        }
    }

    func offset(by delta: FrameDelta) throws -> SampleFrameRange {
        let aligned = try delta.converted(to: sampleRate)
        let (shiftedStart, overflow) = startFrame.addingReportingOverflow(aligned.frames)
        guard !overflow else {
            throw aligned.frames >= 0 ? SampleFrameError.integerOverflow : SampleFrameError.integerUnderflow
        }
        return try SampleFrameRange(startFrame: shiftedStart, frameCount: frameCount, sampleRate: sampleRate)
    }

    func converted(to targetRate: SampleRate) throws -> SampleFrameRange {
        guard targetRate != sampleRate else {
            return self
        }
        let newStart = try SampleFrameTime.convertInt128(Int128(startFrame), from: sampleRate, to: targetRate)
        let oldEnd = Int128(startFrame) + Int128(frameCount)
        let newEnd = try SampleFrameTime.convertInt128(oldEnd, from: sampleRate, to: targetRate)
        let (newCount, underflow) = newEnd.subtractingReportingOverflow(newStart)
        guard !underflow else {
            throw SampleFrameError.integerUnderflow
        }
        return try SampleFrameRange(startFrame: newStart, frameCount: newCount, sampleRate: targetRate)
    }
}

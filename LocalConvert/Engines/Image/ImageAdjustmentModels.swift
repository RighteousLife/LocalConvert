import Foundation
import CoreGraphics

// MARK: - Native Camera RAW Develop Model

struct ImageRAWDevelopConfig: Codable, Sendable, Equatable, Hashable {
    var enabled: Bool = true
    var useRAWFilter: Bool = true
    var exposureEV: Double = 0.0                  // -4.0 ... +4.0 EV delta
    var neutralTemperatureKelvin: Double? = nil   // 2000 ... 14000 K (nil = camera shot WB)
    var neutralTint: Double? = nil                // -150 ... +150 (nil = camera shot tint)
    var highlightRecovery: Double = 0.5           // 0.0 ... 1.0 (maps boost / highlight recovery)
    var shadowBias: Double = 0.0                  // -1.0 ... +1.0
    var boostAmount: Double = 1.0                 // 0.0 ... 1.0
    var lumaNoiseReduction: Double = 0.0          // 0.0 ... 1.0
    var colorNoiseReduction: Double = 0.0         // 0.0 ... 1.0
    var sharpnessAmount: Double = 0.0             // 0.0 ... 1.0
    var gamutMappingEnabled: Bool = true
    var lensCorrectionEnabled: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        useRAWFilter = try c.decodeIfPresent(Bool.self, forKey: .useRAWFilter) ?? true
        exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0.0
        neutralTemperatureKelvin = try c.decodeIfPresent(Double.self, forKey: .neutralTemperatureKelvin)
        neutralTint = try c.decodeIfPresent(Double.self, forKey: .neutralTint)
        highlightRecovery = try c.decodeIfPresent(Double.self, forKey: .highlightRecovery) ?? 0.5
        shadowBias = try c.decodeIfPresent(Double.self, forKey: .shadowBias) ?? 0.0
        boostAmount = try c.decodeIfPresent(Double.self, forKey: .boostAmount) ?? 1.0
        lumaNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .lumaNoiseReduction) ?? 0.0
        colorNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .colorNoiseReduction) ?? 0.0
        sharpnessAmount = try c.decodeIfPresent(Double.self, forKey: .sharpnessAmount) ?? 0.0
        gamutMappingEnabled = try c.decodeIfPresent(Bool.self, forKey: .gamutMappingEnabled) ?? true
        lensCorrectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .lensCorrectionEnabled) ?? false
        clamped()
    }

    var hasNonDefaultParameters: Bool {
        guard enabled else { return false }
        return abs(exposureEV) > 0.001
            || neutralTemperatureKelvin != nil
            || neutralTint != nil
            || abs(highlightRecovery - 0.5) > 0.001
            || abs(shadowBias) > 0.001
            || abs(boostAmount - 1.0) > 0.001
            || lumaNoiseReduction > 0.001
            || colorNoiseReduction > 0.001
            || sharpnessAmount > 0.001
            || !gamutMappingEnabled
            || lensCorrectionEnabled
    }

    mutating func clamped() {
        exposureEV = min(4.0, max(-4.0, exposureEV))
        if let k = neutralTemperatureKelvin {
            neutralTemperatureKelvin = min(14_000.0, max(2_000.0, k))
        }
        if let t = neutralTint {
            neutralTint = min(150.0, max(-150.0, t))
        }
        highlightRecovery = min(1.0, max(0.0, highlightRecovery))
        shadowBias = min(1.0, max(-1.0, shadowBias))
        boostAmount = min(1.0, max(0.0, boostAmount))
        lumaNoiseReduction = min(1.0, max(0.0, lumaNoiseReduction))
        colorNoiseReduction = min(1.0, max(0.0, colorNoiseReduction))
        sharpnessAmount = min(1.0, max(0.0, sharpnessAmount))
    }
}

// MARK: - Levels Model

enum ImageToneChannel: String, CaseIterable, Codable, Sendable, Identifiable {
    case master = "RGB"
    case red = "Red"
    case green = "Green"
    case blue = "Blue"

    var id: String { rawValue }
}

struct ImageChannelLevels: Codable, Sendable, Equatable, Hashable {
    var blackPoint: Double = 0.0     // 0.0 ... 0.98
    var gamma: Double = 1.0          // 0.1 ... 5.0 (midtone exponent; 1.0 = linear neutral)
    var whitePoint: Double = 1.0     // 0.02 ... 1.0 (> blackPoint)
    var outBlack: Double = 0.0       // 0.0 ... 0.99
    var outWhite: Double = 1.0       // 0.01 ... 1.0 (> outBlack)

    init(
        blackPoint: Double = 0.0,
        gamma: Double = 1.0,
        whitePoint: Double = 1.0,
        outBlack: Double = 0.0,
        outWhite: Double = 1.0
    ) {
        self.blackPoint = blackPoint
        self.gamma = gamma
        self.whitePoint = whitePoint
        self.outBlack = outBlack
        self.outWhite = outWhite
        clamped()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blackPoint = try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0.0
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1.0
        whitePoint = try c.decodeIfPresent(Double.self, forKey: .whitePoint) ?? 1.0
        outBlack = try c.decodeIfPresent(Double.self, forKey: .outBlack) ?? 0.0
        outWhite = try c.decodeIfPresent(Double.self, forKey: .outWhite) ?? 1.0
        clamped()
    }

    var isNeutral: Bool {
        abs(blackPoint) < 0.001
            && abs(gamma - 1.0) < 0.001
            && abs(whitePoint - 1.0) < 0.001
            && abs(outBlack) < 0.001
            && abs(outWhite - 1.0) < 0.001
    }

    mutating func clamped() {
        blackPoint = min(0.95, max(0.0, blackPoint))
        whitePoint = min(1.0, max(blackPoint + 0.02, whitePoint))
        gamma = min(5.0, max(0.1, gamma))
        outBlack = min(0.98, max(0.0, outBlack))
        outWhite = min(1.0, max(outBlack + 0.01, outWhite))
    }

    func evaluate(_ x: Double) -> Double {
        let clampedX = min(1.0, max(0.0, x))
        let span = max(0.02, whitePoint - blackPoint)
        let norm = min(1.0, max(0.0, (clampedX - blackPoint) / span))
        let mid = pow(norm, 1.0 / max(0.1, gamma))
        return outBlack + mid * (outWhite - outBlack)
    }
}

struct ImageLevelsConfig: Codable, Sendable, Equatable, Hashable {
    var master: ImageChannelLevels = ImageChannelLevels()
    var red: ImageChannelLevels = ImageChannelLevels()
    var green: ImageChannelLevels = ImageChannelLevels()
    var blue: ImageChannelLevels = ImageChannelLevels()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent(ImageChannelLevels.self, forKey: .master) ?? ImageChannelLevels()
        red = try c.decodeIfPresent(ImageChannelLevels.self, forKey: .red) ?? ImageChannelLevels()
        green = try c.decodeIfPresent(ImageChannelLevels.self, forKey: .green) ?? ImageChannelLevels()
        blue = try c.decodeIfPresent(ImageChannelLevels.self, forKey: .blue) ?? ImageChannelLevels()
    }

    var isNeutral: Bool {
        master.isNeutral && red.isNeutral && green.isNeutral && blue.isNeutral
    }

    subscript(channel: ImageToneChannel) -> ImageChannelLevels {
        get {
            switch channel {
            case .master: return master
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            var clean = newValue
            clean.clamped()
            switch channel {
            case .master: master = clean
            case .red: red = clean
            case .green: green = clean
            case .blue: blue = clean
            }
        }
    }

    mutating func clamped() {
        master.clamped()
        red.clamped()
        green.clamped()
        blue.clamped()
    }
}

// MARK: - Curves Model (Monotone Spline)

struct ImageCurvePoint: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var x: Double // 0.0 ... 1.0
    var y: Double // 0.0 ... 1.0

    init(id: UUID = UUID(), x: Double, y: Double) {
        self.id = id
        self.x = min(1.0, max(0.0, x))
        self.y = min(1.0, max(0.0, y))
    }
}

struct ImageCurvesConfig: Codable, Sendable, Equatable, Hashable {
    static let defaultPoints: [ImageCurvePoint] = [
        ImageCurvePoint(x: 0.0, y: 0.0),
        ImageCurvePoint(x: 1.0, y: 1.0)
    ]

    var master: [ImageCurvePoint] = ImageCurvesConfig.defaultPoints
    var red: [ImageCurvePoint] = ImageCurvesConfig.defaultPoints
    var green: [ImageCurvePoint] = ImageCurvesConfig.defaultPoints
    var blue: [ImageCurvePoint] = ImageCurvesConfig.defaultPoints

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = Self.normalizedPoints(try c.decodeIfPresent([ImageCurvePoint].self, forKey: .master) ?? Self.defaultPoints)
        red = Self.normalizedPoints(try c.decodeIfPresent([ImageCurvePoint].self, forKey: .red) ?? Self.defaultPoints)
        green = Self.normalizedPoints(try c.decodeIfPresent([ImageCurvePoint].self, forKey: .green) ?? Self.defaultPoints)
        blue = Self.normalizedPoints(try c.decodeIfPresent([ImageCurvePoint].self, forKey: .blue) ?? Self.defaultPoints)
    }

    subscript(channel: ImageToneChannel) -> [ImageCurvePoint] {
        get {
            switch channel {
            case .master: return master
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            let clean = Self.normalizedPoints(newValue)
            switch channel {
            case .master: master = clean
            case .red: red = clean
            case .green: green = clean
            case .blue: blue = clean
            }
        }
    }

    var isNeutral: Bool {
        Self.isLinearIdentity(master)
            && Self.isLinearIdentity(red)
            && Self.isLinearIdentity(green)
            && Self.isLinearIdentity(blue)
    }

    static func isLinearIdentity(_ pts: [ImageCurvePoint]) -> Bool {
        guard pts.count >= 2 else { return true }
        for p in pts where abs(p.y - p.x) > 0.002 {
            return false
        }
        return true
    }

    static func normalizedPoints(_ raw: [ImageCurvePoint]) -> [ImageCurvePoint] {
        let pts = raw
            .map { ImageCurvePoint(id: $0.id, x: min(1.0, max(0.0, $0.x)), y: min(1.0, max(0.0, $0.y))) }
            .sorted { $0.x < $1.x }
        if pts.count < 2 {
            return defaultPoints
        }
        // Prevent duplicate x-coordinates that cause division by zero in spline slopes
        var deduped: [ImageCurvePoint] = []
        deduped.reserveCapacity(pts.count)
        for p in pts {
            if let last = deduped.last, abs(p.x - last.x) < 0.008 {
                continue
            }
            deduped.append(p)
        }
        if deduped.count < 2 {
            return defaultPoints
        }
        if deduped.count > 16 {
            let first = deduped.first!
            let last = deduped.last!
            deduped = [first] + Array(deduped.dropFirst().dropLast().prefix(14)) + [last]
        }
        return deduped
    }

    /// Evaluates a smooth Fritsch-Carlson monotone cubic Hermite spline (never overshoots or rings).
    static func buildLUT(points: [ImageCurvePoint], sampleCount: Int = 256) -> [Double] {
        let pts = normalizedPoints(points)
        guard pts.count >= 2 else {
            return (0..<sampleCount).map { Double($0) / Double(max(1, sampleCount - 1)) }
        }
        let n = pts.count
        let x = pts.map(\.x)
        let y = pts.map(\.y)

        if n == 2 {
            return (0..<sampleCount).map { i in
                let t = Double(i) / Double(max(1, sampleCount - 1))
                if t <= x[0] { return y[0] }
                if t >= x[1] { return y[1] }
                let u = (t - x[0]) / max(0.0001, x[1] - x[0])
                return min(1.0, max(0.0, y[0] + u * (y[1] - y[0])))
            }
        }

        // Slopes between adjacent knots
        var h = [Double](repeating: 0, count: n - 1)
        var d = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            h[k] = max(0.0001, x[k + 1] - x[k])
            d[k] = (y[k + 1] - y[k]) / h[k]
        }

        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for k in 1..<(n - 1) {
            if d[k - 1] * d[k] <= 0 {
                m[k] = 0
            } else {
                let w1 = 2 * h[k] + h[k - 1]
                let w2 = h[k] + 2 * h[k - 1]
                m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
            }
        }

        // Constrain tangents to prevent overshoot when flat sections meet steep segments
        for k in 0..<(n - 1) {
            if abs(d[k]) < 1e-6 {
                m[k] = 0
                m[k + 1] = 0
            } else {
                let alpha = m[k] / d[k]
                let beta = m[k + 1] / d[k]
                let mag = alpha * alpha + beta * beta
                if mag > 9.0 {
                    let tau = 3.0 / sqrt(mag)
                    m[k] = tau * alpha * d[k]
                    m[k + 1] = tau * beta * d[k]
                }
            }
        }

        var result = [Double](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(max(1, sampleCount - 1))
            if t <= x[0] {
                result[i] = min(1.0, max(0.0, y[0]))
                continue
            }
            if t >= x[n - 1] {
                result[i] = min(1.0, max(0.0, y[n - 1]))
                continue
            }
            var seg = 0
            for k in 0..<(n - 1) where t >= x[k] && t <= x[k + 1] {
                seg = k
                break
            }
            let dt = (t - x[seg]) / h[seg]
            let dt2 = dt * dt
            let dt3 = dt2 * dt
            let h00 = 2 * dt3 - 3 * dt2 + 1
            let h10 = dt3 - 2 * dt2 + dt
            let h01 = -2 * dt3 + 3 * dt2
            let h11 = dt3 - dt2
            let val = h00 * y[seg] + h10 * h[seg] * m[seg] + h01 * y[seg + 1] + h11 * h[seg] * m[seg + 1]
            result[i] = min(1.0, max(0.0, val))
        }
        return result
    }
}

// MARK: - Color Balance Model

struct ImageRGBBalanceOffset: Codable, Sendable, Equatable, Hashable {
    var cyanRed: Double = 0.0        // -1.0 (Cyan) ... +1.0 (Red)
    var magentaGreen: Double = 0.0   // -1.0 (Magenta) ... +1.0 (Green)
    var yellowBlue: Double = 0.0     // -1.0 (Yellow) ... +1.0 (Blue)

    init(cyanRed: Double = 0.0, magentaGreen: Double = 0.0, yellowBlue: Double = 0.0) {
        self.cyanRed = min(1.0, max(-1.0, cyanRed))
        self.magentaGreen = min(1.0, max(-1.0, magentaGreen))
        self.yellowBlue = min(1.0, max(-1.0, yellowBlue))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cyanRed = min(1.0, max(-1.0, try c.decodeIfPresent(Double.self, forKey: .cyanRed) ?? 0.0))
        magentaGreen = min(1.0, max(-1.0, try c.decodeIfPresent(Double.self, forKey: .magentaGreen) ?? 0.0))
        yellowBlue = min(1.0, max(-1.0, try c.decodeIfPresent(Double.self, forKey: .yellowBlue) ?? 0.0))
    }

    var isNeutral: Bool {
        abs(cyanRed) < 0.001 && abs(magentaGreen) < 0.001 && abs(yellowBlue) < 0.001
    }

    mutating func clamped() {
        cyanRed = min(1.0, max(-1.0, cyanRed))
        magentaGreen = min(1.0, max(-1.0, magentaGreen))
        yellowBlue = min(1.0, max(-1.0, yellowBlue))
    }
}

enum ImageTonalRegion: String, CaseIterable, Codable, Sendable, Identifiable {
    case shadows = "Shadows"
    case midtones = "Midtones"
    case highlights = "Highlights"

    var id: String { rawValue }
}

struct ImageColorBalanceConfig: Codable, Sendable, Equatable, Hashable {
    var shadows: ImageRGBBalanceOffset = ImageRGBBalanceOffset()
    var midtones: ImageRGBBalanceOffset = ImageRGBBalanceOffset()
    var highlights: ImageRGBBalanceOffset = ImageRGBBalanceOffset()
    var preserveLuminance: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shadows = try c.decodeIfPresent(ImageRGBBalanceOffset.self, forKey: .shadows) ?? ImageRGBBalanceOffset()
        midtones = try c.decodeIfPresent(ImageRGBBalanceOffset.self, forKey: .midtones) ?? ImageRGBBalanceOffset()
        highlights = try c.decodeIfPresent(ImageRGBBalanceOffset.self, forKey: .highlights) ?? ImageRGBBalanceOffset()
        preserveLuminance = try c.decodeIfPresent(Bool.self, forKey: .preserveLuminance) ?? true
    }

    var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral
    }

    subscript(region: ImageTonalRegion) -> ImageRGBBalanceOffset {
        get {
            switch region {
            case .shadows: return shadows
            case .midtones: return midtones
            case .highlights: return highlights
            }
        }
        set {
            var clean = newValue
            clean.clamped()
            switch region {
            case .shadows: shadows = clean
            case .midtones: midtones = clean
            case .highlights: highlights = clean
            }
        }
    }

    mutating func clamped() {
        shadows.clamped()
        midtones.clamped()
        highlights.clamped()
    }
}

// MARK: - Unified Color & Tone Adjustments Model

struct ImageColorAdjustmentsConfig: Codable, Sendable, Equatable, Hashable {
    static let schemaVersion = 1

    var version: Int = ImageColorAdjustmentsConfig.schemaVersion
    var isEnabled: Bool = true

    // Basic Light
    var exposureEV: Double = 0.0           // -5.0 ... +5.0
    var brightness: Double = 0.0           // -0.5 ... +0.5
    var contrast: Double = 1.0             // 0.25 ... 2.5
    var gamma: Double = 1.0                // 0.25 ... 3.0
    var highlights: Double = 0.0           // -1.0 ... +1.0
    var shadows: Double = 0.0              // -1.0 ... +1.0
    var whites: Double = 0.0               // -1.0 ... +1.0
    var blacks: Double = 0.0               // -1.0 ... +1.0

    // Color
    var saturation: Double = 1.0           // 0.0 ... 2.0
    var vibrance: Double = 0.0             // -1.0 ... +1.0
    var hueDegrees: Double = 0.0           // -180.0 ... +180.0
    var temperatureOffset: Double = 0.0    // -100.0 (Cool) ... +100.0 (Warm)
    var tintOffset: Double = 0.0           // -100.0 (Green) ... +100.0 (Magenta)

    // Precision Tone Tools
    var levels: ImageLevelsConfig = ImageLevelsConfig()
    var curves: ImageCurvesConfig = ImageCurvesConfig()
    var colorBalance: ImageColorBalanceConfig = ImageColorBalanceConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.schemaVersion
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0.0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1.0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0.0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0.0
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0.0
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0.0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0.0
        hueDegrees = try c.decodeIfPresent(Double.self, forKey: .hueDegrees) ?? 0.0
        temperatureOffset = try c.decodeIfPresent(Double.self, forKey: .temperatureOffset) ?? 0.0
        tintOffset = try c.decodeIfPresent(Double.self, forKey: .tintOffset) ?? 0.0
        levels = try c.decodeIfPresent(ImageLevelsConfig.self, forKey: .levels) ?? ImageLevelsConfig()
        curves = try c.decodeIfPresent(ImageCurvesConfig.self, forKey: .curves) ?? ImageCurvesConfig()
        colorBalance = try c.decodeIfPresent(ImageColorBalanceConfig.self, forKey: .colorBalance) ?? ImageColorBalanceConfig()
        clamped()
    }

    var hasActiveAdjustments: Bool {
        guard isEnabled else { return false }
        return hasBasicOrColorAdjustments
            || !levels.isNeutral
            || !curves.isNeutral
            || !colorBalance.isNeutral
    }

    var hasBasicOrColorAdjustments: Bool {
        abs(exposureEV) > 0.001
            || abs(brightness) > 0.001
            || abs(contrast - 1.0) > 0.001
            || abs(gamma - 1.0) > 0.001
            || abs(highlights) > 0.001
            || abs(shadows) > 0.001
            || abs(whites) > 0.001
            || abs(blacks) > 0.001
            || abs(saturation - 1.0) > 0.001
            || abs(vibrance) > 0.001
            || abs(hueDegrees) > 0.001
            || abs(temperatureOffset) > 0.01
            || abs(tintOffset) > 0.01
    }

    mutating func clamped() {
        exposureEV = min(5.0, max(-5.0, exposureEV))
        brightness = min(0.5, max(-0.5, brightness))
        contrast = min(2.5, max(0.25, contrast))
        gamma = min(3.0, max(0.25, gamma))
        highlights = min(1.0, max(-1.0, highlights))
        shadows = min(1.0, max(-1.0, shadows))
        whites = min(1.0, max(-1.0, whites))
        blacks = min(1.0, max(-1.0, blacks))
        saturation = min(2.0, max(0.0, saturation))
        vibrance = min(1.0, max(-1.0, vibrance))
        hueDegrees = min(180.0, max(-180.0, hueDegrees))
        temperatureOffset = min(100.0, max(-100.0, temperatureOffset))
        tintOffset = min(100.0, max(-100.0, tintOffset))
        levels.clamped()
        colorBalance.clamped()
    }

    mutating func resetLight() {
        exposureEV = 0.0
        brightness = 0.0
        contrast = 1.0
        gamma = 1.0
        highlights = 0.0
        shadows = 0.0
        whites = 0.0
        blacks = 0.0
    }

    mutating func resetColor() {
        saturation = 1.0
        vibrance = 0.0
        hueDegrees = 0.0
        temperatureOffset = 0.0
        tintOffset = 0.0
    }

    mutating func resetAll() {
        isEnabled = true
        resetLight()
        resetColor()
        levels = ImageLevelsConfig()
        curves = ImageCurvesConfig()
        colorBalance = ImageColorBalanceConfig()
    }
}

// MARK: - Ordered Effects & Creative Filters

enum ImageEffectKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case gaussianBlur = "Gaussian Blur"
    case sharpen = "Sharpen"
    case unsharpMask = "Unsharp Mask"
    case noiseReduction = "Noise Reduction"
    case vignette = "Vignette"
    case filmGrain = "Film Grain"
    case monochrome = "Monochrome"
    case sepia = "Sepia"
    case photoFilter = "Color Look Filter"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .gaussianBlur: return "aqi.medium"
        case .sharpen: return "triangle"
        case .unsharpMask: return "sparkles"
        case .noiseReduction: return "wand.and.stars"
        case .vignette: return "circle.dashed"
        case .filmGrain: return "circle.grid.3x3.fill"
        case .monochrome: return "circle.lefthalf.filled"
        case .sepia: return "photo.artframe"
        case .photoFilter: return "camera.filters"
        }
    }
}

enum ImagePhotoFilterStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case chrome = "Vivid Chrome"
    case fade = "Cinematic Fade"
    case instant = "Vintage Instant"
    case mono = "Classic Mono"
    case noir = "High-Contrast Noir"
    case process = "Cross Process"
    case tonal = "Warm Tonal"
    case transfer = "Film Transfer"
    case warmAmber = "Warm Amber Wash"
    case coolAzure = "Cool Azure Wash"
    case emerald = "Emerald Cinema"

    var id: String { rawValue }

    var ciFilterName: String? {
        switch self {
        case .chrome: return "CIPhotoEffectChrome"
        case .fade: return "CIPhotoEffectFade"
        case .instant: return "CIPhotoEffectInstant"
        case .mono: return "CIPhotoEffectMono"
        case .noir: return "CIPhotoEffectNoir"
        case .process: return "CIPhotoEffectProcess"
        case .tonal: return "CIPhotoEffectTonal"
        case .transfer: return "CIPhotoEffectTransfer"
        case .warmAmber, .coolAzure, .emerald: return nil
        }
    }
}

struct ImageEffectSlot: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: ImageEffectKind
    var isEnabled: Bool = true
    var intensity: Double = 0.6      // 0.0 ... 2.0 (effect-dependent blend/strength)
    var radius: Double = 4.0         // 0.1 ... 60.0 px (Blur, Unsharp, Vignette)
    var sharpness: Double = 0.5      // 0.0 ... 2.0 (Sharpen / NR detail)
    var falloff: Double = 0.5        // 0.0 ... 1.0 (Vignette falloff)
    var grainSize: Double = 1.2      // 0.5 ... 3.0 px (Film Grain scale)
    var tintColor: CodableRGBAColor = CodableRGBAColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
    var photoStyle: ImagePhotoFilterStyle = .chrome

    init(
        id: UUID = UUID(),
        kind: ImageEffectKind,
        isEnabled: Bool = true,
        intensity: Double = 0.6,
        radius: Double = 4.0,
        sharpness: Double = 0.5,
        falloff: Double = 0.5,
        grainSize: Double = 1.2,
        tintColor: CodableRGBAColor = CodableRGBAColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0),
        photoStyle: ImagePhotoFilterStyle = .chrome
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.intensity = intensity
        self.radius = radius
        self.sharpness = sharpness
        self.falloff = falloff
        self.grainSize = grainSize
        self.tintColor = tintColor
        self.photoStyle = photoStyle
        clamped()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ImageEffectKind.self, forKey: .kind) ?? .sharpen
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.6
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 4.0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0.5
        falloff = try c.decodeIfPresent(Double.self, forKey: .falloff) ?? 0.5
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? 1.2
        tintColor = try c.decodeIfPresent(CodableRGBAColor.self, forKey: .tintColor) ?? CodableRGBAColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
        photoStyle = try c.decodeIfPresent(ImagePhotoFilterStyle.self, forKey: .photoStyle) ?? .chrome
        clamped()
    }

    static func makeDefault(kind: ImageEffectKind, id: UUID = UUID()) -> ImageEffectSlot {
        switch kind {
        case .gaussianBlur:
            return ImageEffectSlot(id: id, kind: kind, intensity: 1.0, radius: 6.0)
        case .sharpen:
            return ImageEffectSlot(id: id, kind: kind, intensity: 0.55, sharpness: 0.55)
        case .unsharpMask:
            return ImageEffectSlot(id: id, kind: kind, intensity: 0.65, radius: 2.2)
        case .noiseReduction:
            return ImageEffectSlot(id: id, kind: kind, intensity: 0.35, sharpness: 0.4)
        case .vignette:
            return ImageEffectSlot(id: id, kind: kind, intensity: 0.55, radius: 0.65, falloff: 0.6)
        case .filmGrain:
            return ImageEffectSlot(id: id, kind: kind, intensity: 0.28, grainSize: 1.3)
        case .monochrome:
            return ImageEffectSlot(id: id, kind: kind, intensity: 1.0, tintColor: CodableRGBAColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1.0))
        case .sepia:
            return ImageEffectSlot(id: id, kind: kind, intensity: 0.75)
        case .photoFilter:
            return ImageEffectSlot(id: id, kind: kind, intensity: 0.85, photoStyle: .chrome)
        }
    }

    mutating func resetParameters() {
        let fresh = Self.makeDefault(kind: kind, id: id)
        isEnabled = fresh.isEnabled
        intensity = fresh.intensity
        radius = fresh.radius
        sharpness = fresh.sharpness
        falloff = fresh.falloff
        grainSize = fresh.grainSize
        tintColor = fresh.tintColor
        photoStyle = fresh.photoStyle
    }

    mutating func clamped() {
        intensity = min(2.0, max(0.0, intensity))
        radius = min(60.0, max(0.1, radius))
        sharpness = min(2.0, max(0.0, sharpness))
        falloff = min(1.0, max(0.0, falloff))
        grainSize = min(3.0, max(0.5, grainSize))
    }
}

// MARK: - Image Editor Look Preset & .lcimg Project Document

struct ImageLookPreset: Identifiable, Codable, Sendable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var category: String
    var colorAdjustments: ImageColorAdjustmentsConfig
    var effectStack: [ImageEffectSlot]
    var isBuiltIn: Bool = false
}

struct ImageProjectDocument: Codable, Sendable, Equatable {
    static let fileExtension = "lcimg"
    static let currentSchemaVersion = 1

    var schemaVersion: Int = ImageProjectDocument.currentSchemaVersion
    var id: UUID = UUID()
    var sourcePath: String
    var sourceBookmarkData: Data? = nil
    var sourceFileSize: Int64? = nil
    var sourceModificationTime: TimeInterval? = nil
    var targetFormat: FileFormat
    var config: ImageToolboxConfig
    var savedAt: Date = Date()

    init(
        id: UUID = UUID(),
        sourcePath: String,
        sourceBookmarkData: Data? = nil,
        sourceFileSize: Int64? = nil,
        sourceModificationTime: TimeInterval? = nil,
        targetFormat: FileFormat = .jxl,
        config: ImageToolboxConfig,
        savedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.sourcePath = sourcePath
        self.sourceBookmarkData = sourceBookmarkData
        self.sourceFileSize = sourceFileSize
        self.sourceModificationTime = sourceModificationTime
        self.targetFormat = targetFormat
        self.config = config
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        sourceBookmarkData = try c.decodeIfPresent(Data.self, forKey: .sourceBookmarkData)
        sourceFileSize = try c.decodeIfPresent(Int64.self, forKey: .sourceFileSize)
        sourceModificationTime = try c.decodeIfPresent(TimeInterval.self, forKey: .sourceModificationTime)
        targetFormat = try c.decodeIfPresent(FileFormat.self, forKey: .targetFormat) ?? .jxl
        config = try c.decodeIfPresent(ImageToolboxConfig.self, forKey: .config) ?? ImageToolboxConfig()
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }
}

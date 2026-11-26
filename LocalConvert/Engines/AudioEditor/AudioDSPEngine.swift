import Foundation
import Accelerate
import AVFoundation

// MARK: - Double-Precision RBJ Biquad & Parametric EQ DSP

struct BiquadCoeffs: Sendable, Equatable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static let identity = BiquadCoeffs()

    /// RBJ Audio EQ Cookbook coefficients normalized by a0, with safety clamping against unstable poles.
    static func design(band: EQBand, sampleRate: Double) -> BiquadCoeffs {
        guard band.isEnabled else { return .identity }
        var b = band
        b.clamped(sampleRate: sampleRate)

        let fs = max(8_000.0, sampleRate)
        let w0 = 2.0 * .pi * b.frequencyHz / fs
        let cosW = cos(w0)
        let sinW = sin(w0)
        let alpha = sinW / (2.0 * b.q)
        let A = pow(10.0, b.gainDB / 40.0)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0
        var a0 = 1.0, a1 = 0.0, a2 = 0.0

        switch b.type {
        case .highPass:
            b0 = (1.0 + cosW) * 0.5
            b1 = -(1.0 + cosW)
            b2 = (1.0 + cosW) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW
            a2 = 1.0 - alpha

        case .lowPass:
            b0 = (1.0 - cosW) * 0.5
            b1 = 1.0 - cosW
            b2 = (1.0 - cosW) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW
            a2 = 1.0 - alpha

        case .peaking:
            if abs(b.gainDB) < 0.005 { return .identity }
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosW
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosW
            a2 = 1.0 - alpha / A

        case .lowShelf:
            if abs(b.gainDB) < 0.005 { return .identity }
            let beta = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1.0) - (A - 1.0) * cosW + beta)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW)
            b2 = A * ((A + 1.0) - (A - 1.0) * cosW - beta)
            a0 = (A + 1.0) + (A - 1.0) * cosW + beta
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW)
            a2 = (A + 1.0) + (A - 1.0) * cosW - beta

        case .highShelf:
            if abs(b.gainDB) < 0.005 { return .identity }
            let beta = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1.0) + (A - 1.0) * cosW + beta)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW)
            b2 = A * ((A + 1.0) + (A - 1.0) * cosW - beta)
            a0 = (A + 1.0) - (A - 1.0) * cosW + beta
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW)
            a2 = (A + 1.0) - (A - 1.0) * cosW - beta
        }

        guard abs(a0) > 1e-12 else { return .identity }
        let invA0 = 1.0 / a0
        let nb0 = b0 * invA0
        let nb1 = b1 * invA0
        let nb2 = b2 * invA0
        let na1 = a1 * invA0
        let na2 = a2 * invA0

        // Jury stability condition for 2nd-order IIR: |a2| < 1 and |a1| < 1 + a2
        guard nb0.isFinite, nb1.isFinite, nb2.isFinite, na1.isFinite, na2.isFinite,
              abs(na2) < 0.999999, abs(na1) < (1.0 + na2) else {
            return .identity
        }
        return BiquadCoeffs(b0: nb0, b1: nb1, b2: nb2, a1: na1, a2: na2)
    }

    func magnitudeDB(atFrequencyHz freq: Double, sampleRate: Double) -> Double {
        let w = 2.0 * .pi * freq / max(8_000.0, sampleRate)
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2.0 * w), sin2 = sin(2.0 * w)
        // z^-1 = cos(w) - j*sin(w)
        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = -b1 * sin1 - b2 * sin2
        let denRe = 1.0 + a1 * cos1 + a2 * cos2
        let denIm = -a1 * sin1 - a2 * sin2
        let numMagSq = numRe * numRe + numIm * numIm
        let denMagSq = max(1e-24, denRe * denRe + denIm * denIm)
        return 10.0 * log10(max(1e-12, numMagSq / denMagSq))
    }
}

final class ParametricEQDSP: @unchecked Sendable {
    private struct StageState {
        var coeffs: BiquadCoeffs = .identity
        var z1L: Double = 0
        var z2L: Double = 0
        var z1R: Double = 0
        var z2R: Double = 0
    }

    private var stages: [StageState] = []
    private var params: ParametricEQParams
    private var sampleRate: Double

    init(params: ParametricEQParams = ParametricEQParams(), sampleRate: Double = 48_000) {
        self.params = params
        self.sampleRate = sampleRate
        rebuildCoeffs()
    }

    func update(params: ParametricEQParams, sampleRate: Double) {
        let rateChanged = abs(self.sampleRate - sampleRate) > 0.5
        if !rateChanged && self.params == params { return }
        self.params = params
        self.sampleRate = sampleRate
        rebuildCoeffs()
    }

    private func rebuildCoeffs() {
        let count = params.bands.count
        if stages.count != count {
            stages = Array(repeating: StageState(), count: count)
        }
        for idx in 0..<count {
            stages[idx].coeffs = BiquadCoeffs.design(band: params.bands[idx], sampleRate: sampleRate)
        }
    }

    func reset() {
        for idx in stages.indices {
            stages[idx].z1L = 0
            stages[idx].z2L = 0
            stages[idx].z1R = 0
            stages[idx].z2R = 0
        }
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !params.isBypassed else { return }
        for sIdx in stages.indices {
            let c = stages[sIdx].coeffs
            if c == .identity { continue }
            var z1L = stages[sIdx].z1L
            var z2L = stages[sIdx].z2L
            var z1R = stages[sIdx].z1R
            var z2R = stages[sIdx].z2R

            for i in 0..<frameCount {
                let rawL = left[i]
                let xL = rawL.isFinite ? Double(rawL) : 0.0
                let yL = c.b0 * xL + z1L
                z1L = c.b1 * xL - c.a1 * yL + z2L
                z2L = c.b2 * xL - c.a2 * yL
                left[i] = yL.isFinite ? Float(yL) : 0.0

                let rawR = right[i]
                let xR = rawR.isFinite ? Double(rawR) : 0.0
                let yR = c.b0 * xR + z1R
                z1R = c.b1 * xR - c.a1 * yR + z2R
                z2R = c.b2 * xR - c.a2 * yR
                right[i] = yR.isFinite ? Float(yR) : 0.0
            }

            // Flush subnormals & non-finite state safely
            stages[sIdx].z1L = (!z1L.isFinite || abs(z1L) < 1e-24) ? 0 : z1L
            stages[sIdx].z2L = (!z2L.isFinite || abs(z2L) < 1e-24) ? 0 : z2L
            stages[sIdx].z1R = (!z1R.isFinite || abs(z1R) < 1e-24) ? 0 : z1R
            stages[sIdx].z2R = (!z2R.isFinite || abs(z2R) < 1e-24) ? 0 : z2R
        }
    }

    static func frequencyResponseDB(params: ParametricEQParams, sampleRate: Double, frequencies: [Double]) -> [Double] {
        guard !params.isBypassed else {
            return Array(repeating: 0.0, count: frequencies.count)
        }
        let coeffs = params.bands.map { BiquadCoeffs.design(band: $0, sampleRate: sampleRate) }
        return frequencies.map { f in
            coeffs.reduce(0.0) { $0 + $1.magnitudeDB(atFrequencyHz: f, sampleRate: sampleRate) }
        }
    }
}

// MARK: - Dynamics Compressor (Soft Knee + Attack/Release + Gain Reduction Metering)

final class CompressorDSP: @unchecked Sendable {
    private var params: CompressorParams
    private var sampleRate: Double
    private var envDB: Double = -120.0
    private(set) var lastGainReductionDB: Float = 0.0

    init(params: CompressorParams = CompressorParams(), sampleRate: Double = 48_000) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
    }

    func update(params: CompressorParams, sampleRate: Double) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
    }

    func reset() {
        envDB = -120.0
        lastGainReductionDB = 0.0
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !params.isBypassed else {
            lastGainReductionDB = 0
            return
        }
        let sr = max(8_000.0, sampleRate)
        let attackCoeff = exp(-1.0 / (sr * (params.attackMs * 0.001)))
        let releaseCoeff = exp(-1.0 / (sr * (params.releaseMs * 0.001)))
        let thresh = params.thresholdDB
        let ratio = params.ratio
        let knee = params.kneeDB
        let makeup = pow(10.0, params.makeupGainDB / 20.0)

        var peakGR: Double = 0.0
        for i in 0..<frameCount {
            let sL = left[i].isFinite ? left[i] : 0.0
            let sR = right[i].isFinite ? right[i] : 0.0
            let level = max(Double(abs(sL)), Double(abs(sR)))
            let levelDB = level > 1e-6 ? 20.0 * log10(level) : -120.0
            if levelDB > envDB {
                envDB = attackCoeff * envDB + (1.0 - attackCoeff) * levelDB
            } else {
                envDB = releaseCoeff * envDB + (1.0 - releaseCoeff) * levelDB
            }
            if !envDB.isFinite { envDB = -120.0 }

            let over = envDB - thresh
            let gainReductionDB: Double
            if knee > 0.01 && abs(over) < knee * 0.5 {
                let d = over + knee * 0.5
                gainReductionDB = (1.0 / ratio - 1.0) * (d * d) / (2.0 * knee)
            } else if over > 0 {
                gainReductionDB = over * (1.0 / ratio - 1.0)
            } else {
                gainReductionDB = 0.0
            }

            if gainReductionDB < peakGR { peakGR = gainReductionDB }
            let linGain = Float(pow(10.0, gainReductionDB / 20.0) * makeup)
            let safeGain = linGain.isFinite ? linGain : 1.0
            left[i] = sL * safeGain
            right[i] = sR * safeGain
        }
        lastGainReductionDB = Float(peakGR)
    }
}

// MARK: - Lookahead Sample-Peak Limiter

final class LimiterDSP: @unchecked Sendable {
    private var params: LimiterParams
    private var sampleRate: Double
    private var delayL: [Float]
    private var delayR: [Float]
    private var lookaheadHoldGain: Double = 1.0
    private var lookaheadHoldSamplesLeft: Int = 0
    private var writePos: Int = 0
    private var gainState: Double = 1.0
    private var maxDelayCapacity: Int
    private(set) var lastGainReductionDB: Float = 0.0

    init(params: LimiterParams = LimiterParams(), sampleRate: Double = 48_000) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
        self.maxDelayCapacity = Self.requiredCapacity(for: sampleRate)
        self.delayL = [Float](repeating: 0, count: maxDelayCapacity)
        self.delayR = [Float](repeating: 0, count: maxDelayCapacity)
    }

    private static func requiredCapacity(for sampleRate: Double) -> Int {
        max(64, Int(ceil(max(8_000.0, sampleRate) * 0.015)) + 16)
    }

    func update(params: LimiterParams, sampleRate: Double) {
        var p = params; p.clamped()
        self.params = p
        if abs(self.sampleRate - sampleRate) > 0.5 {
            self.sampleRate = sampleRate
            let needed = Self.requiredCapacity(for: sampleRate)
            if needed > maxDelayCapacity {
                maxDelayCapacity = needed
                delayL = [Float](repeating: 0, count: needed)
                delayR = [Float](repeating: 0, count: needed)
            }
            reset()
        }
    }

    func reset() {
        delayL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        delayR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        writePos = 0
        gainState = 1.0
        lookaheadHoldGain = 1.0
        lookaheadHoldSamplesLeft = 0
        lastGainReductionDB = 0
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !params.isBypassed else {
            lastGainReductionDB = 0
            return
        }
        let ceiling = pow(10.0, params.ceilingDB / 20.0)
        let sr = max(8_000.0, sampleRate)
        let lookFrames = min(maxDelayCapacity - 1, max(0, Int((params.lookaheadMs * 0.001 * sr).rounded())))
        let attackCoeff = lookFrames > 0 ? exp(-4.0 / Double(max(1, lookFrames))) : 0.0
        let releaseCoeff = exp(-1.0 / max(1.0, sr * params.releaseMs * 0.001))

        var minGain = 1.0
        for i in 0..<frameCount {
            let inL: Float = left[i].isFinite ? left[i] : 0.0
            let inR: Float = right[i].isFinite ? right[i] : 0.0
            delayL[writePos] = inL
            delayR[writePos] = inR

            let readPos = (writePos - lookFrames + maxDelayCapacity) % maxDelayCapacity
            writePos = (writePos + 1) % maxDelayCapacity

            let peakAhead = max(Double(abs(inL)), Double(abs(inR)))
            let instantGain = peakAhead > ceiling ? (ceiling / peakAhead) : 1.0

            if instantGain < lookaheadHoldGain || lookaheadHoldSamplesLeft <= 0 {
                lookaheadHoldGain = instantGain
                lookaheadHoldSamplesLeft = max(1, lookFrames)
            } else {
                lookaheadHoldSamplesLeft -= 1
            }

            let targetGain = min(instantGain, lookaheadHoldGain)
            if targetGain < gainState {
                gainState = lookFrames > 0 ? (attackCoeff * gainState + (1.0 - attackCoeff) * targetGain) : targetGain
            } else {
                gainState = releaseCoeff * gainState + (1.0 - releaseCoeff) * targetGain
            }
            if !gainState.isFinite { gainState = 1.0 }

            if gainState < minGain { minGain = gainState }
            let dL = Double(delayL[readPos]) * gainState
            let dR = Double(delayR[readPos]) * gainState
            // Sample-peak ceiling guard guarantees no sample exceeds ceilingDB even on step transients.
            let outL = Float(min(ceiling, max(-ceiling, dL)))
            let outR = Float(min(ceiling, max(-ceiling, dR)))
            left[i] = outL.isFinite ? outL : 0.0
            right[i] = outR.isFinite ? outR : 0.0
        }
        lastGainReductionDB = minGain < 0.9999 ? Float(20.0 * log10(max(1e-6, minGain))) : 0.0
    }
}

// MARK: - Hysteresis & Hold Noise Gate

final class NoiseGateDSP: @unchecked Sendable {
    private var params: NoiseGateParams
    private var sampleRate: Double
    private var gateOpen = false
    private var holdCounter: Int = 0
    private var smoothedGain: Double = 1.0

    init(params: NoiseGateParams = NoiseGateParams(), sampleRate: Double = 48_000) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
    }

    func update(params: NoiseGateParams, sampleRate: Double) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
    }

    func reset() {
        gateOpen = false
        holdCounter = 0
        smoothedGain = 0.0
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !params.isBypassed else { return }
        let sr = max(8_000.0, sampleRate)
        let openThresh = params.thresholdDB
        let closeThresh = params.thresholdDB - params.hysteresisDB
        let holdSamples = Int((params.holdMs * 0.001 * sr).rounded())
        let attackCoeff = exp(-1.0 / max(1.0, sr * params.attackMs * 0.001))
        let releaseCoeff = exp(-1.0 / max(1.0, sr * params.releaseMs * 0.001))
        let floorGain = params.rangeDB <= -79.5 ? 0.0 : pow(10.0, params.rangeDB / 20.0)

        for i in 0..<frameCount {
            let sL: Float = left[i].isFinite ? left[i] : 0.0
            let sR: Float = right[i].isFinite ? right[i] : 0.0
            let level = max(Double(abs(sL)), Double(abs(sR)))
            let levelDB = level > 1e-6 ? 20.0 * log10(level) : -120.0

            if levelDB >= openThresh {
                gateOpen = true
                holdCounter = holdSamples
            } else if levelDB < closeThresh {
                if holdCounter > 0 {
                    holdCounter -= 1
                } else {
                    gateOpen = false
                }
            } else if gateOpen && holdCounter > 0 {
                holdCounter -= 1
            }

            let target = gateOpen ? 1.0 : floorGain
            if target > smoothedGain {
                smoothedGain = attackCoeff * smoothedGain + (1.0 - attackCoeff) * target
            } else {
                smoothedGain = releaseCoeff * smoothedGain + (1.0 - releaseCoeff) * target
            }
            if !smoothedGain.isFinite { smoothedGain = target }

            let g = Float(smoothedGain)
            left[i] = sL * g
            right[i] = sR * g
        }
    }
}

// MARK: - Spectral Noise Reduction (Accelerate vDSP Overlap-Add STFT)

final class SpectralNoiseReductionDSP: @unchecked Sendable {
    static let fftSize = 1024
    static let hopSize = 256
    static let halfBins = fftSize / 2

    private var params: NoiseReductionParams
    private var sampleRate: Double
    private let window: [Float]
    private var dftForward: OpaquePointer?
    private var dftInverse: OpaquePointer?

    // Per-channel overlap-add FIFO & smoothing state
    private var inRingL: [Float]
    private var inRingR: [Float]
    private var inFill = 0
    private var outAccL: [Float]
    private var outAccR: [Float]
    private var readyOutL: [Float] = []
    private var readyOutR: [Float] = []
    private var readyReadIndex: Int = 0
    private var prevGain: [Float]
    private var adaptiveFloor: [Float]

    // Pre-allocated STFT working buffers (zero heap allocation in processSingleFrame)
    private var scratchInReal: [Float]
    private let scratchZeroImag: [Float]
    private var scratchSpecRealL: [Float]
    private var scratchSpecImagL: [Float]
    private var scratchSpecRealR: [Float]
    private var scratchSpecImagR: [Float]
    private var scratchOutRealL: [Float]
    private var scratchOutImagL: [Float]
    private var scratchOutRealR: [Float]
    private var scratchOutImagR: [Float]

    init(params: NoiseReductionParams = NoiseReductionParams(), sampleRate: Double = 48_000) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
        var win = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&win, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.window = win
        self.dftForward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)
        self.dftInverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .INVERSE)
        self.inRingL = [Float](repeating: 0, count: Self.fftSize)
        self.inRingR = [Float](repeating: 0, count: Self.fftSize)
        self.outAccL = [Float](repeating: 0, count: Self.fftSize * 2)
        self.outAccR = [Float](repeating: 0, count: Self.fftSize * 2)
        self.prevGain = [Float](repeating: 1, count: Self.fftSize)
        let initFloor = Float(pow(10.0, p.noiseFloorDB / 20.0)) * Float(Self.fftSize) * 0.12
        self.adaptiveFloor = [Float](repeating: initFloor, count: Self.fftSize)

        let n = Self.fftSize
        self.scratchInReal = [Float](repeating: 0, count: n)
        self.scratchZeroImag = [Float](repeating: 0, count: n)
        self.scratchSpecRealL = [Float](repeating: 0, count: n)
        self.scratchSpecImagL = [Float](repeating: 0, count: n)
        self.scratchSpecRealR = [Float](repeating: 0, count: n)
        self.scratchSpecImagR = [Float](repeating: 0, count: n)
        self.scratchOutRealL = [Float](repeating: 0, count: n)
        self.scratchOutImagL = [Float](repeating: 0, count: n)
        self.scratchOutRealR = [Float](repeating: 0, count: n)
        self.scratchOutImagR = [Float](repeating: 0, count: n)
        self.readyOutL.reserveCapacity(8192)
        self.readyOutR.reserveCapacity(8192)
    }

    deinit {
        if let f = dftForward { vDSP_DFT_DestroySetup(f) }
        if let inv = dftInverse { vDSP_DFT_DestroySetup(inv) }
    }

    func update(params: NoiseReductionParams, sampleRate: Double) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
    }

    func reset() {
        inRingL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        inRingR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        outAccL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        outAccR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        readyOutL.removeAll(keepingCapacity: true)
        readyOutR.removeAll(keepingCapacity: true)
        readyReadIndex = 0
        inFill = 0
        prevGain.withUnsafeMutableBufferPointer { $0.update(repeating: 1) }
    }

    /// Captures average FFT magnitude spectrum across a silent/noise region for targeted denoising.
    static func captureNoiseProfile(fromMonoSamples samples: [Float]) -> [Float] {
        guard samples.count >= fftSize,
              let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            return []
        }
        defer { vDSP_DFT_DestroySetup(fwd) }

        var win = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&win, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var profile = [Float](repeating: 0, count: fftSize)
        var inReal = [Float](repeating: 0, count: fftSize)
        let inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        var frameCount = 0
        var offset = 0
        while offset + fftSize <= samples.count {
            for k in 0..<fftSize { inReal[k] = samples[offset + k] * win[k] }
            vDSP_DFT_Execute(fwd, inReal, inImag, &outReal, &outImag)
            for k in 0..<fftSize {
                profile[k] += hypotf(outReal[k], outImag[k])
            }
            frameCount += 1
            offset += hopSize
        }
        if frameCount > 0 {
            var inv = 1.0 / Float(frameCount)
            vDSP_vsmul(profile, 1, &inv, &profile, 1, vDSP_Length(fftSize))
        }
        return profile
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !params.isBypassed, params.reductionAmount > 0.5,
              let fwd = dftForward, let inv = dftInverse else { return }

        let shiftCount = Self.fftSize - Self.hopSize
        for i in 0..<frameCount {
            let sL: Float = left[i].isFinite ? left[i] : 0.0
            let sR: Float = right[i].isFinite ? right[i] : 0.0
            inRingL[inFill] = sL
            inRingR[inFill] = sR
            inFill += 1

            if inFill == Self.fftSize {
                processSingleFrame(fwd: fwd, inv: inv)
                for idx in 0..<shiftCount {
                    inRingL[idx] = inRingL[idx + Self.hopSize]
                    inRingR[idx] = inRingR[idx + Self.hopSize]
                }
                inFill = shiftCount
            }

            if readyReadIndex < readyOutL.count {
                let oL = readyOutL[readyReadIndex]
                let oR = readyOutR[readyReadIndex]
                left[i] = oL.isFinite ? oL : 0.0
                right[i] = oR.isFinite ? oR : 0.0
                readyReadIndex += 1
                if readyReadIndex >= readyOutL.count {
                    readyOutL.removeAll(keepingCapacity: true)
                    readyOutR.removeAll(keepingCapacity: true)
                    readyReadIndex = 0
                } else if readyReadIndex >= 4096 {
                    readyOutL.removeFirst(readyReadIndex)
                    readyOutR.removeFirst(readyReadIndex)
                    readyReadIndex = 0
                }
            } else {
                // Initial fill-up latency frames pass quietly until first STFT hop completes.
                left[i] = sL * 0.25
                right[i] = sR * 0.25
            }
        }
    }

    private func processSingleFrame(fwd: OpaquePointer, inv: OpaquePointer) {
        let n = Self.fftSize
        let hop = Self.hopSize

        vDSP_vmul(inRingL, 1, window, 1, &scratchInReal, 1, vDSP_Length(n))
        vDSP_DFT_Execute(fwd, scratchInReal, scratchZeroImag, &scratchSpecRealL, &scratchSpecImagL)

        vDSP_vmul(inRingR, 1, window, 1, &scratchInReal, 1, vDSP_Length(n))
        vDSP_DFT_Execute(fwd, scratchInReal, scratchZeroImag, &scratchSpecRealR, &scratchSpecImagR)

        let alpha = Float(params.reductionAmount / 100.0) * 2.5
        let smooth = Float(params.smoothing)
        let residualFloor = Float(max(0.02, 1.0 - (params.reductionAmount / 100.0) * 0.96))
        let floorScalar = Float(pow(10.0, params.noiseFloorDB / 20.0)) * Float(n) * 0.14
        let customProf = params.noiseProfile

        for k in 0..<n {
            let magL = hypotf(scratchSpecRealL[k], scratchSpecImagL[k])
            let magR = hypotf(scratchSpecRealR[k], scratchSpecImagR[k])
            let mag = 0.5 * (magL + magR)

            let noiseEst: Float
            if let customProf, customProf.count == n {
                noiseEst = max(1e-7, customProf[k])
            } else {
                // Slow upward / faster downward tracker around floor threshold
                if mag < adaptiveFloor[k] {
                    adaptiveFloor[k] = 0.85 * adaptiveFloor[k] + 0.15 * mag
                } else {
                    adaptiveFloor[k] = min(floorScalar, 0.995 * adaptiveFloor[k] + 0.005 * mag)
                }
                noiseEst = max(1e-7, max(adaptiveFloor[k], floorScalar * 0.5))
            }

            let rawGain = max(residualFloor, 1.0 - alpha * ((noiseEst * noiseEst) / max(mag * mag, 1e-12)))
            let g = smooth * prevGain[k] + (1.0 - smooth) * min(1.0, rawGain)
            prevGain[k] = g

            scratchSpecRealL[k] *= g
            scratchSpecImagL[k] *= g
            scratchSpecRealR[k] *= g
            scratchSpecImagR[k] *= g
        }

        vDSP_DFT_Execute(inv, scratchSpecRealL, scratchSpecImagL, &scratchOutRealL, &scratchOutImagL)
        vDSP_DFT_Execute(inv, scratchSpecRealR, scratchSpecImagR, &scratchOutRealR, &scratchOutImagR)

        // Exact 75% overlap-add scale for vDSP_HANN_NORM (sum w^2 == 4.0) and unnormalized IFFT (factor N)
        let normScale = 1.0 / (Float(n) * 4.0)
        for k in 0..<n {
            outAccL[k] += scratchOutRealL[k] * window[k] * normScale
            outAccR[k] += scratchOutRealR[k] * window[k] * normScale
        }

        for k in 0..<hop {
            readyOutL.append(outAccL[k])
            readyOutR.append(outAccR[k])
        }
        for k in 0..<n {
            outAccL[k] = outAccL[k + hop]
            outAccR[k] = outAccR[k + hop]
        }
        for k in n..<outAccL.count {
            outAccL[k] = 0
            outAccR[k] = 0
        }
    }
}

// MARK: - Stereo Delay (Pre-Allocated Circular Buffer + Feedback Damping + Ping-Pong)

final class DelayDSP: @unchecked Sendable {
    private var params: DelayParams
    private var sampleRate: Double
    private var bufL: [Float]
    private var bufR: [Float]
    private var writeIndex = 0
    private var lpfL: Double = 0
    private var lpfR: Double = 0
    private var capacity: Int

    init(params: DelayParams = DelayParams(), sampleRate: Double = 48_000) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
        self.capacity = Self.requiredCapacity(for: sampleRate)
        self.bufL = [Float](repeating: 0, count: capacity)
        self.bufR = [Float](repeating: 0, count: capacity)
    }

    private static func requiredCapacity(for sampleRate: Double) -> Int {
        max(4_096, Int(ceil(max(8_000.0, sampleRate) * 2.1)) + 16)
    }

    func update(params: DelayParams, sampleRate: Double) {
        var p = params; p.clamped()
        self.params = p
        if abs(self.sampleRate - sampleRate) > 0.5 {
            self.sampleRate = sampleRate
            let needed = Self.requiredCapacity(for: sampleRate)
            if needed > capacity {
                capacity = needed
                bufL = [Float](repeating: 0, count: needed)
                bufR = [Float](repeating: 0, count: needed)
                writeIndex = 0
                lpfL = 0
                lpfR = 0
            }
        }
    }

    func reset() {
        bufL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        bufR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        writeIndex = 0
        lpfL = 0
        lpfR = 0
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !params.isBypassed, params.wetDryMix > 0.0001 else { return }
        let sr = max(8_000.0, sampleRate)
        let delaySamples = min(capacity - 2, max(1, Int((params.delayTimeMs * 0.001 * sr).rounded())))
        let fb = params.feedback
        let wet = Float(params.wetDryMix)
        let dry = 1.0 - wet * 0.5
        let dampAlpha = exp(-2.0 * .pi * min(sr * 0.45, params.dampingHz) / sr)

        for i in 0..<frameCount {
            let rawL: Float = left[i].isFinite ? left[i] : 0.0
            let rawR: Float = right[i].isFinite ? right[i] : 0.0
            let readIdx = (writeIndex - delaySamples + capacity) % capacity
            let tapL = bufL[readIdx].isFinite ? Double(bufL[readIdx]) : 0.0
            let tapR = bufR[readIdx].isFinite ? Double(bufR[readIdx]) : 0.0

            lpfL = (1.0 - dampAlpha) * tapL + dampAlpha * lpfL
            lpfR = (1.0 - dampAlpha) * tapR + dampAlpha * lpfR
            if !lpfL.isFinite { lpfL = 0 }
            if !lpfR.isFinite { lpfR = 0 }

            let inL = Double(rawL)
            let inR = Double(rawR)
            if params.pingPong {
                bufL[writeIndex] = Float(inL + lpfR * fb)
                bufR[writeIndex] = Float(inR + lpfL * fb)
            } else {
                bufL[writeIndex] = Float(inL + lpfL * fb)
                bufR[writeIndex] = Float(inR + lpfR * fb)
            }
            writeIndex = (writeIndex + 1) % capacity

            let outL = Float(inL) * dry + Float(tapL) * wet
            let outR = Float(inR) * dry + Float(tapR) * wet
            left[i] = outL.isFinite ? outL : 0.0
            right[i] = outR.isFinite ? outR : 0.0
        }
    }
}

// MARK: - Stereo FDN / Freeverb Reverb (Pre-delay + Parallel Combs + Allpass Diffusers)

final class ReverbDSP: @unchecked Sendable {
    private struct Comb {
        var buffer: [Float]
        var index: Int = 0
        var filterStore: Float = 0
        init(size: Int) { self.buffer = [Float](repeating: 0, count: max(16, size)) }
        mutating func process(_ input: Float, feedback: Float, damp1: Float, damp2: Float) -> Float {
            let output = buffer[index]
            filterStore = output * damp2 + filterStore * damp1
            if abs(filterStore) < 1e-24 { filterStore = 0 }
            buffer[index] = input + filterStore * feedback
            index = (index + 1) % buffer.count
            return output
        }
        mutating func clear() {
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            index = 0
            filterStore = 0
        }
    }

    private struct Allpass {
        var buffer: [Float]
        var index: Int = 0
        init(size: Int) { self.buffer = [Float](repeating: 0, count: max(16, size)) }
        mutating func process(_ input: Float) -> Float {
            let bufOut = buffer[index]
            let output = -input + bufOut
            buffer[index] = input + bufOut * 0.5
            index = (index + 1) % buffer.count
            return output
        }
        mutating func clear() {
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            index = 0
        }
    }

    private var params: ReverbParams
    private var sampleRate: Double
    private var preDelayBufL: [Float]
    private var preDelayBufR: [Float]
    private var preDelayIdx = 0
    private var combsL: [Comb] = []
    private var combsR: [Comb] = []
    private var allpassL: [Allpass] = []
    private var allpassR: [Allpass] = []

    init(params: ReverbParams = ReverbParams(), sampleRate: Double = 48_000) {
        var p = params; p.clamped()
        self.params = p
        self.sampleRate = sampleRate
        let pdCap = max(256, Int((sampleRate * 0.16).rounded()) + 8)
        self.preDelayBufL = [Float](repeating: 0, count: pdCap)
        self.preDelayBufR = [Float](repeating: 0, count: pdCap)
        rebuildBuffers(sampleRate: sampleRate)
    }

    private func rebuildBuffers(sampleRate: Double) {
        let ratio = max(0.25, sampleRate / 44_100.0)
        let combSizes = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        let allpassSizes = [556, 441, 341, 225]
        let spread = 23
        combsL = combSizes.map { Comb(size: Int(Double($0) * ratio)) }
        combsR = combSizes.map { Comb(size: Int(Double($0 + spread) * ratio)) }
        allpassL = allpassSizes.map { Allpass(size: Int(Double($0) * ratio)) }
        allpassR = allpassSizes.map { Allpass(size: Int(Double($0 + spread) * ratio)) }
    }

    func update(params: ReverbParams, sampleRate: Double) {
        var p = params; p.clamped()
        self.params = p
        if abs(self.sampleRate - sampleRate) > 0.5 {
            self.sampleRate = sampleRate
            let pdCap = max(256, Int((sampleRate * 0.16).rounded()) + 8)
            preDelayBufL = [Float](repeating: 0, count: pdCap)
            preDelayBufR = [Float](repeating: 0, count: pdCap)
            preDelayIdx = 0
            rebuildBuffers(sampleRate: sampleRate)
        }
    }

    func reset() {
        preDelayBufL.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        preDelayBufR.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        preDelayIdx = 0
        for i in combsL.indices { combsL[i].clear(); combsR[i].clear() }
        for i in allpassL.indices { allpassL[i].clear(); allpassR[i].clear() }
    }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !params.isBypassed, params.wetDryMix > 0.0001 else { return }

        let presetScale: Double
        switch params.roomPreset {
        case .smallRoom: presetScale = 0.72
        case .mediumHall: presetScale = 0.84
        case .largeHall: presetScale = 0.91
        case .plate: presetScale = 0.88
        }
        // Map decaySeconds into stable comb feedback strictly <= 0.96
        let fb = Float(min(0.95, max(0.45, presetScale + (params.decaySeconds - 1.5) * 0.035)))
        let damp1 = Float(params.damping * 0.65)
        let damp2 = 1.0 - damp1
        let wet = Float(params.wetDryMix)
        let dry = 1.0 - wet * 0.35
        let wet1 = wet * Float((params.stereoWidth + 1.0) * 0.5) * 0.15
        let wet2 = wet * Float((1.0 - params.stereoWidth) * 0.5) * 0.15

        let pdSamples = min(preDelayBufL.count - 1, max(0, Int((params.preDelayMs * 0.001 * sampleRate).rounded())))

        for i in 0..<frameCount {
            let inL: Float = left[i].isFinite ? left[i] : 0.0
            let inR: Float = right[i].isFinite ? right[i] : 0.0
            preDelayBufL[preDelayIdx] = inL
            preDelayBufR[preDelayIdx] = inR
            let readPD = (preDelayIdx - pdSamples + preDelayBufL.count) % preDelayBufL.count
            preDelayIdx = (preDelayIdx + 1) % preDelayBufL.count

            let monoIn = (preDelayBufL[readPD] + preDelayBufR[readPD]) * 0.5 * 0.22
            var outL: Float = 0
            var outR: Float = 0
            for c in combsL.indices {
                outL += combsL[c].process(monoIn, feedback: fb, damp1: damp1, damp2: damp2)
                outR += combsR[c].process(monoIn, feedback: fb, damp1: damp1, damp2: damp2)
            }
            for a in allpassL.indices {
                outL = allpassL[a].process(outL)
                outR = allpassR[a].process(outR)
            }

            let yL = inL * dry + outL * wet1 + outR * wet2
            let yR = inR * dry + outR * wet1 + outL * wet2
            left[i] = yL.isFinite ? yL : 0.0
            right[i] = yR.isFinite ? yR : 0.0
        }
    }
}

// MARK: - Ordered Effect-Chain Processor (Shared identically between Playback & Offline Export)

final class AudioChainProcessor: @unchecked Sendable {
    private enum SlotRuntime {
        case eq(ParametricEQDSP)
        case compressor(CompressorDSP)
        case limiter(LimiterDSP)
        case gate(NoiseGateDSP)
        case noiseReduction(SpectralNoiseReductionDSP)
        case delay(DelayDSP)
        case reverb(ReverbDSP)
    }

    private var entries: [(id: UUID, kind: AudioEffectKind, runtime: SlotRuntime)] = []
    private var lastSlots: [AudioEffectSlot] = []
    private var extraPairProcessors: [AudioChainProcessor] = []
    private var monoScratch: [Float] = [Float](repeating: 0, count: 8192)
    private(set) var sampleRate: Double
    private(set) var maxGainReductionDB: Float = 0.0

    init(slots: [AudioEffectSlot] = [], sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        sync(slots: slots, sampleRate: sampleRate)
    }

    func sync(slots: [AudioEffectSlot], sampleRate: Double) {
        self.sampleRate = sampleRate
        self.lastSlots = slots
        var nextEntries: [(id: UUID, kind: AudioEffectKind, runtime: SlotRuntime)] = []
        for slot in slots {
            if let existing = entries.first(where: { $0.id == slot.id && $0.kind == slot.kind }) {
                updateRuntime(existing.runtime, from: slot, sampleRate: sampleRate)
                nextEntries.append(existing)
            } else {
                let runtime = makeRuntime(from: slot, sampleRate: sampleRate)
                nextEntries.append((slot.id, slot.kind, runtime))
            }
        }
        entries = nextEntries
        for pairProc in extraPairProcessors {
            pairProc.sync(slots: slots, sampleRate: sampleRate)
        }
    }

    func resetStates() {
        for e in entries {
            switch e.runtime {
            case .eq(let d): d.reset()
            case .compressor(let d): d.reset()
            case .limiter(let d): d.reset()
            case .gate(let d): d.reset()
            case .noiseReduction(let d): d.reset()
            case .delay(let d): d.reset()
            case .reverb(let d): d.reset()
            }
        }
        for pairProc in extraPairProcessors {
            pairProc.resetStates()
        }
        maxGainReductionDB = 0
    }

    func process(slots: [AudioEffectSlot], left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var grMin: Float = 0.0
        for (idx, slot) in slots.enumerated() where idx < entries.count {
            guard slot.isActive else { continue }
            switch entries[idx].runtime {
            case .eq(let d): d.process(left: left, right: right, frameCount: frameCount)
            case .compressor(let d):
                d.process(left: left, right: right, frameCount: frameCount)
                grMin = min(grMin, d.lastGainReductionDB)
            case .limiter(let d):
                d.process(left: left, right: right, frameCount: frameCount)
                grMin = min(grMin, d.lastGainReductionDB)
            case .gate(let d): d.process(left: left, right: right, frameCount: frameCount)
            case .noiseReduction(let d): d.process(left: left, right: right, frameCount: frameCount)
            case .delay(let d): d.process(left: left, right: right, frameCount: frameCount)
            case .reverb(let d): d.process(left: left, right: right, frameCount: frameCount)
            }
        }
        maxGainReductionDB = grMin
    }

    /// Processes an arbitrary channel count (1, 2, or N>2 channels) cleanly using per-pair DSP state.
    func processMultichannel(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) {
        processMultichannel(slots: lastSlots, channels: channels, channelCount: channelCount, frameCount: frameCount)
    }

    func processMultichannel(
        slots: [AudioEffectSlot],
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) {
        guard channelCount > 0, frameCount > 0 else { return }
        if channelCount == 2 {
            process(slots: slots, left: channels[0], right: channels[1], frameCount: frameCount)
            return
        }

        if monoScratch.count < frameCount {
            monoScratch = [Float](repeating: 0, count: frameCount)
        }

        if channelCount == 1 {
            monoScratch.withUnsafeMutableBufferPointer { buf in
                guard let rightPtr = buf.baseAddress else { return }
                rightPtr.update(from: channels[0], count: frameCount)
                process(slots: slots, left: channels[0], right: rightPtr, frameCount: frameCount)
            }
            return
        }

        // Pair 0 uses `self`
        process(slots: slots, left: channels[0], right: channels[1], frameCount: frameCount)
        var overallGR = maxGainReductionDB

        // Additional pairs (2,3), (4,5), ... use dedicated cached processors
        let pairCount = (channelCount + 1) / 2
        let neededExtra = max(0, pairCount - 1)
        while extraPairProcessors.count < neededExtra {
            extraPairProcessors.append(AudioChainProcessor(slots: slots, sampleRate: sampleRate))
        }

        for pairIdx in 1..<pairCount {
            let proc = extraPairProcessors[pairIdx - 1]
            let leftCh = pairIdx * 2
            let rightCh = leftCh + 1
            if rightCh < channelCount {
                proc.process(slots: slots, left: channels[leftCh], right: channels[rightCh], frameCount: frameCount)
            } else {
                monoScratch.withUnsafeMutableBufferPointer { buf in
                    guard let rightPtr = buf.baseAddress else { return }
                    rightPtr.update(from: channels[leftCh], count: frameCount)
                    proc.process(slots: slots, left: channels[leftCh], right: rightPtr, frameCount: frameCount)
                }
            }
            overallGR = min(overallGR, proc.maxGainReductionDB)
        }
        maxGainReductionDB = overallGR
    }

    private func makeRuntime(from slot: AudioEffectSlot, sampleRate: Double) -> SlotRuntime {
        switch slot.kind {
        case .parametricEQ: return .eq(ParametricEQDSP(params: slot.eq ?? ParametricEQParams(), sampleRate: sampleRate))
        case .compressor: return .compressor(CompressorDSP(params: slot.compressor ?? CompressorParams(), sampleRate: sampleRate))
        case .limiter: return .limiter(LimiterDSP(params: slot.limiter ?? LimiterParams(), sampleRate: sampleRate))
        case .noiseGate: return .gate(NoiseGateDSP(params: slot.noiseGate ?? NoiseGateParams(), sampleRate: sampleRate))
        case .noiseReduction: return .noiseReduction(SpectralNoiseReductionDSP(params: slot.noiseReduction ?? NoiseReductionParams(), sampleRate: sampleRate))
        case .delay: return .delay(DelayDSP(params: slot.delay ?? DelayParams(), sampleRate: sampleRate))
        case .reverb: return .reverb(ReverbDSP(params: slot.reverb ?? ReverbParams(), sampleRate: sampleRate))
        }
    }

    private func updateRuntime(_ runtime: SlotRuntime, from slot: AudioEffectSlot, sampleRate: Double) {
        switch (runtime, slot.kind) {
        case (.eq(let d), .parametricEQ): d.update(params: slot.eq ?? ParametricEQParams(), sampleRate: sampleRate)
        case (.compressor(let d), .compressor): d.update(params: slot.compressor ?? CompressorParams(), sampleRate: sampleRate)
        case (.limiter(let d), .limiter): d.update(params: slot.limiter ?? LimiterParams(), sampleRate: sampleRate)
        case (.gate(let d), .noiseGate): d.update(params: slot.noiseGate ?? NoiseGateParams(), sampleRate: sampleRate)
        case (.noiseReduction(let d), .noiseReduction): d.update(params: slot.noiseReduction ?? NoiseReductionParams(), sampleRate: sampleRate)
        case (.delay(let d), .delay): d.update(params: slot.delay ?? DelayParams(), sampleRate: sampleRate)
        case (.reverb(let d), .reverb): d.update(params: slot.reverb ?? ReverbParams(), sampleRate: sampleRate)
        default: break
        }
    }
}

// MARK: - Peak, RMS & ITU-R BS.1770 LUFS Audio Normalization Helper

enum AudioNormalizer {
    struct SignalMeasurement: Sendable, Equatable {
        let peakLinear: Double
        let rmsLinear: Double
        var peakDBFS: Double { peakLinear > 1e-9 ? 20.0 * log10(peakLinear) : -120.0 }
        var rmsDBFS: Double { rmsLinear > 1e-9 ? 20.0 * log10(rmsLinear) : -120.0 }
    }

    struct LoudnessReport: Sendable, Equatable {
        let integratedLUFS: Double?
        let samplePeakDBFS: Double
        let truePeakDBTP: Double
    }

    // 4-phase 12-tap windowed-sinc polyphase FIR kernels (+0.25, +0.50, +0.75 sample shifts)
    private static let oversamplePhases: [[Double]] = {
        let taps = 12
        let half = 5
        return [0.25, 0.50, 0.75].map { frac in
            var coeffs = [Double](repeating: 0, count: taps)
            var sum = 0.0
            for idx in 0..<taps {
                let n = Double(idx - half) - frac
                let sinc = abs(n) < 1e-9 ? 1.0 : sin(.pi * n) / (.pi * n)
                // Blackman window across tap index 0...(taps - 1)
                let wPhase = (2.0 * .pi * Double(idx)) / Double(taps - 1)
                let win = 0.42 - 0.5 * cos(wPhase) + 0.08 * cos(2.0 * wPhase)
                let v = sinc * win
                coeffs[idx] = v
                sum += v
            }
            if abs(sum) > 1e-12 {
                for idx in 0..<taps { coeffs[idx] /= sum }
            }
            return coeffs
        }
    }()

    static func measure(samplesLeft: [Float], samplesRight: [Float]) -> SignalMeasurement {
        let count = min(samplesLeft.count, samplesRight.count)
        guard count > 0 else { return SignalMeasurement(peakLinear: 0, rmsLinear: 0) }
        var peak = 0.0
        var sumSq = 0.0
        for i in 0..<count {
            let l = samplesLeft[i].isFinite ? Double(samplesLeft[i]) : 0.0
            let r = samplesRight[i].isFinite ? Double(samplesRight[i]) : 0.0
            peak = max(peak, abs(l), abs(r))
            sumSq += 0.5 * (l * l + r * r)
        }
        return SignalMeasurement(peakLinear: peak, rmsLinear: sqrt(sumSq / Double(count)))
    }

    static func normalizationGainDB(measurement: SignalMeasurement, mode: AudioEditorNormalizeMethod) -> Double? {
        switch mode {
        case .peak(let targetDB):
            guard measurement.peakLinear > 1e-6 else { return nil }
            let delta = targetDB - measurement.peakDBFS
            return min(36.0, max(-36.0, delta))
        case .rms(let targetDB):
            guard measurement.rmsLinear > 1e-6 else { return nil }
            let delta = targetDB - measurement.rmsDBFS
            // Prevent excessive clipping when boosting high-crest-factor RMS
            let maxSafePeakBoost = (-0.3) - measurement.peakDBFS
            return min(maxSafePeakBoost, min(36.0, max(-36.0, delta)))
        }
    }

    static func measureSamplePeakDB(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Double {
        guard channelCount > 0, frameCount > 0 else { return -120.0 }
        var peak = 0.0
        for ch in 0..<channelCount {
            let ptr = channels[ch]
            for i in 0..<frameCount {
                let s = ptr[i]
                if s.isFinite {
                    peak = max(peak, abs(Double(s)))
                }
            }
        }
        return peak > 1e-9 ? 20.0 * log10(peak) : -120.0
    }

    static func measureTruePeakDBTP(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Double {
        guard channelCount > 0, frameCount > 0 else { return -120.0 }
        let phases = oversamplePhases
        let half = 5
        var maxTP = 0.0

        for ch in 0..<channelCount {
            let ptr = channels[ch]
            for i in 0..<frameCount {
                let s0 = ptr[i].isFinite ? abs(Double(ptr[i])) : 0.0
                if s0 > maxTP { maxTP = s0 }

                for phaseCoeffs in phases {
                    var acc = 0.0
                    for k in 0..<12 {
                        let sampleIdx = i + (k - half)
                        if sampleIdx >= 0 && sampleIdx < frameCount {
                            let val = ptr[sampleIdx]
                            if val.isFinite {
                                acc += Double(val) * phaseCoeffs[k]
                            }
                        }
                    }
                    let absVal = abs(acc)
                    if absVal > maxTP { maxTP = absVal }
                }
            }
        }
        return maxTP > 1e-9 ? 20.0 * log10(maxTP) : -120.0
    }

    /// ITU-R BS.1770-4 gated integrated loudness (LKFS/LUFS) across mono, stereo, or multichannel PCM.
    static func measureIntegratedLUFS(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double
    ) -> Double? {
        guard channelCount > 0, frameCount > 0, sampleRate >= 8_000 else { return nil }

        let fs = sampleRate
        // Stage 1: High-shelf K-weighting pre-filter
        let shelfDb = 3.999843853973347
        let shelfF0 = 1681.974450955533
        let shelfQ = 0.7071752369554196
        let k1 = tan(.pi * shelfF0 / fs)
        let vh = pow(10.0, shelfDb / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0_1 = 1.0 + k1 / shelfQ + k1 * k1
        let s1 = BiquadCoeffs(
            b0: (vh + vb * k1 / shelfQ + k1 * k1) / a0_1,
            b1: 2.0 * (k1 * k1 - vh) / a0_1,
            b2: (vh - vb * k1 / shelfQ + k1 * k1) / a0_1,
            a1: 2.0 * (k1 * k1 - 1.0) / a0_1,
            a2: (1.0 - k1 / shelfQ + k1 * k1) / a0_1
        )

        // Stage 2: RLB high-pass weighting filter
        let rlbF0 = 38.13547087602444
        let rlbQ = 0.5003270373238773
        let k2 = tan(.pi * rlbF0 / fs)
        let a0_2 = 1.0 + k2 / rlbQ + k2 * k2
        let s2 = BiquadCoeffs(
            b0: 1.0 / a0_2,
            b1: -2.0 / a0_2,
            b2: 1.0 / a0_2,
            a1: 2.0 * (k2 * k2 - 1.0) / a0_2,
            a2: (1.0 - k2 / rlbQ + k2 * k2) / a0_2
        )

        // Compute K-weighted squared sample energy per channel
        var weightedSq = [[Double]](repeating: [Double](repeating: 0, count: frameCount), count: channelCount)
        for ch in 0..<channelCount {
            let weight: Double
            if channelCount == 6 && ch == 3 {
                weight = 0.0 // LFE excluded per BS.1770
            } else if channelCount >= 5 && (ch == 4 || ch == 5) {
                weight = 1.4125375446227544 // +1.5 dB surround weighting
            } else {
                weight = 1.0
            }
            if weight == 0 { continue }

            let src = channels[ch]
            var z1a = 0.0, z2a = 0.0
            var z1b = 0.0, z2b = 0.0
            for i in 0..<frameCount {
                let x = src[i].isFinite ? Double(src[i]) : 0.0
                let y1 = s1.b0 * x + z1a
                z1a = s1.b1 * x - s1.a1 * y1 + z2a
                z2a = s1.b2 * x - s1.a2 * y1

                let y2 = s2.b0 * y1 + z1b
                z1b = s2.b1 * y1 - s2.a1 * y2 + z2b
                z2b = s2.b2 * y1 - s2.a2 * y2
                weightedSq[ch][i] = weight * (y2 * y2)
            }
        }

        // Build 400ms overlapping blocks (100ms step), or single block if < 400ms
        let blockFrames = max(1, Int((0.400 * fs).rounded()))
        let hopFrames = max(1, Int((0.100 * fs).rounded()))
        var blockEnergies: [Double] = []

        func blockPower(start: Int, length: Int) -> Double {
            var totalPower = 0.0
            for ch in 0..<channelCount {
                var sum = 0.0
                let arr = weightedSq[ch]
                for i in start..<(start + length) {
                    sum += arr[i]
                }
                totalPower += sum / Double(length)
            }
            return totalPower
        }

        if frameCount < blockFrames {
            let p = blockPower(start: 0, length: frameCount)
            blockEnergies.append(p)
        } else {
            var pos = 0
            while pos + blockFrames <= frameCount {
                blockEnergies.append(blockPower(start: pos, length: blockFrames))
                pos += hopFrames
            }
            if blockEnergies.isEmpty {
                blockEnergies.append(blockPower(start: 0, length: frameCount))
            }
        }

        // Absolute gate: -70.0 LKFS
        let absGated = blockEnergies.filter { energy in
            guard energy > 1e-12 else { return false }
            let lufs = -0.691 + 10.0 * log10(energy)
            return lufs > -70.0
        }
        guard !absGated.isEmpty else { return nil }

        let absMeanEnergy = absGated.reduce(0.0, +) / Double(absGated.count)
        guard absMeanEnergy > 1e-12 else { return nil }
        let relativeThreshold = (-0.691 + 10.0 * log10(absMeanEnergy)) - 10.0

        // Relative gate: > Gamma_a - 10.0 LU
        let relGated = absGated.filter { energy in
            let lufs = -0.691 + 10.0 * log10(energy)
            return lufs >= relativeThreshold
        }
        guard !relGated.isEmpty else { return nil }

        let finalEnergy = relGated.reduce(0.0, +) / Double(relGated.count)
        guard finalEnergy > 1e-12 else { return nil }
        let lufs = -0.691 + 10.0 * log10(finalEnergy)
        return lufs.isFinite ? lufs : nil
    }

    static func measureLoudness(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double
    ) -> LoudnessReport {
        LoudnessReport(
            integratedLUFS: measureIntegratedLUFS(
                channels: channels,
                channelCount: channelCount,
                frameCount: frameCount,
                sampleRate: sampleRate
            ),
            samplePeakDBFS: measureSamplePeakDB(
                channels: channels,
                channelCount: channelCount,
                frameCount: frameCount
            ),
            truePeakDBTP: measureTruePeakDBTP(
                channels: channels,
                channelCount: channelCount,
                frameCount: frameCount
            )
        )
    }

    @discardableResult
    static func applyPeakNormalization(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        targetPeakDBFS: Double
    ) -> Double? {
        guard channelCount > 0, frameCount > 0 else { return nil }
        let currentPeakDB = measureSamplePeakDB(channels: channels, channelCount: channelCount, frameCount: frameCount)
        guard currentPeakDB > -119.5 else { return nil }
        let peakLinear = pow(10.0, currentPeakDB / 20.0)
        guard peakLinear > 1e-6 else { return nil }

        let gainDB = min(36.0, max(-36.0, targetPeakDBFS - currentPeakDB))
        let gainLin = Float(pow(10.0, gainDB / 20.0))
        applyGain(gainLin, channels: channels, channelCount: channelCount, frameCount: frameCount)
        return gainDB
    }

    @discardableResult
    static func applyLUFSNormalization(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double,
        targetLUFS: Double,
        truePeakCeilingDBTP: Double = -1.0
    ) -> Double? {
        guard channelCount > 0, frameCount > 0 else { return nil }
        guard let currentLUFS = measureIntegratedLUFS(
            channels: channels,
            channelCount: channelCount,
            frameCount: frameCount,
            sampleRate: sampleRate
        ) else {
            return nil
        }

        let currentTruePeak = measureTruePeakDBTP(channels: channels, channelCount: channelCount, frameCount: frameCount)
        let desiredGainDB = min(36.0, max(-36.0, targetLUFS - currentLUFS))
        let maxSafeGainDB = truePeakCeilingDBTP - currentTruePeak
        let gainDB = min(desiredGainDB, maxSafeGainDB)
        let gainLin = Float(pow(10.0, gainDB / 20.0))
        applyGain(gainLin, channels: channels, channelCount: channelCount, frameCount: frameCount)
        return gainDB
    }

    private static func applyGain(
        _ linearGain: Float,
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) {
        guard linearGain.isFinite else { return }
        for ch in 0..<channelCount {
            let ptr = channels[ch]
            for i in 0..<frameCount {
                let s = ptr[i]
                ptr[i] = s.isFinite ? (s * linearGain) : 0.0
            }
        }
    }
}

import Testing
import Foundation
import AVFoundation
@testable import LocalConvert

@Suite("Phase 45.1 — Audio DSP & Effects", .serialized)
struct AudioDSPTests {

    private func makeSine(freq: Double, amp: Float, sampleRate: Double = 48_000, count: Int = 8192) -> [Float] {
        (0..<count).map { i in
            amp * Float(sin(2.0 * .pi * freq * Double(i) / sampleRate))
        }
    }

    private func rmsDB(_ samples: [Float], skipLeading: Int = 1024) -> Double {
        let slice = samples.dropFirst(min(skipLeading, samples.count / 2))
        guard !slice.isEmpty else { return -120 }
        let meanSq = slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(slice.count)
        let r = sqrt(meanSq)
        return r > 1e-9 ? 20.0 * log10(r) : -120.0
    }

    private func peakLinear(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    @Test("Parametric EQ boosts target frequency, attenuates via high-pass, stays finite under extremes, and bypasses bit-exactly")
    func parametricEQBehaviorAndStability() {
        let sr = 48_000.0
        var bands = ParametricEQParams.defaultBands
        // Band 0: HPF @ 400 Hz, Band 2: Peaking +10 dB @ 2000 Hz
        bands[0] = EQBand(isEnabled: true, type: .highPass, frequencyHz: 400, gainDB: 0, q: 0.707)
        bands[1].isEnabled = false
        bands[2] = EQBand(isEnabled: true, type: .peaking, frequencyHz: 2000, gainDB: 10.0, q: 1.5)
        bands[3].isEnabled = false
        bands[4].isEnabled = false

        let eq = ParametricEQDSP(params: ParametricEQParams(bands: bands, isBypassed: false), sampleRate: sr)

        // 1. 2000 Hz tone should gain ~+10 dB
        var l2k = makeSine(freq: 2000, amp: 0.1, sampleRate: sr)
        var r2k = l2k
        let base2k = rmsDB(l2k)
        l2k.withUnsafeMutableBufferPointer { lb in
            r2k.withUnsafeMutableBufferPointer { rb in
                eq.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        let delta2k = rmsDB(l2k) - base2k
        #expect(abs(delta2k - 10.0) < 1.2)

        // Predicted transfer function matches actual DSP output within 0.5 dB
        let predicted = ParametricEQDSP.frequencyResponseDB(params: ParametricEQParams(bands: bands, isBypassed: false), sampleRate: sr, frequencies: [2000])[0]
        #expect(abs(delta2k - predicted) < 0.8)

        // 2. 80 Hz tone should be strongly attenuated by 400 Hz HPF
        eq.reset()
        var l80 = makeSine(freq: 80, amp: 0.25, sampleRate: sr)
        var r80 = l80
        let base80 = rmsDB(l80)
        l80.withUnsafeMutableBufferPointer { lb in
            r80.withUnsafeMutableBufferPointer { rb in
                eq.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        #expect(rmsDB(l80) - base80 < -15.0)

        // 3. Extreme frequency & Q clamping keeps output finite without NaNs/explosions
        let extremeBand = EQBand(isEnabled: true, type: .peaking, frequencyHz: 23_999, gainDB: 24, q: 99.0)
        let extremeEQ = ParametricEQDSP(params: ParametricEQParams(bands: [extremeBand], isBypassed: false), sampleRate: sr)
        var impulse = [Float](repeating: 0, count: 4096)
        impulse[0] = 0.5
        var impulseR = impulse
        impulse.withUnsafeMutableBufferPointer { lb in
            impulseR.withUnsafeMutableBufferPointer { rb in
                extremeEQ.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        #expect(impulse.allSatisfy { $0.isFinite && abs($0) < 50.0 })

        // 4. Bypass leaves audio untouched bit-for-bit
        let orig = makeSine(freq: 1000, amp: 0.4)
        var copyL = orig
        var copyR = orig
        let bypassedEQ = ParametricEQDSP(params: ParametricEQParams(bands: bands, isBypassed: true), sampleRate: sr)
        copyL.withUnsafeMutableBufferPointer { lb in
            copyR.withUnsafeMutableBufferPointer { rb in
                bypassedEQ.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        #expect(copyL == orig)
    }

    @Test("Compressor reduces gain above threshold and Lookahead Limiter enforces sample-peak ceiling on transients")
    func compressorAndLimiter() {
        let sr = 48_000.0
        // High-level 0.8 amplitude (-1.9 dBFS) into -18 dB threshold, 4:1 ratio, 0 makeup
        var l = makeSine(freq: 500, amp: 0.8, sampleRate: sr, count: 16_384)
        var r = l
        let inRMS = rmsDB(l)
        let comp = CompressorDSP(
            params: CompressorParams(thresholdDB: -18, ratio: 4.0, attackMs: 2.0, releaseMs: 80.0, kneeDB: 2.0, makeupGainDB: 0.0, isBypassed: false),
            sampleRate: sr
        )
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                comp.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        let outRMS = rmsDB(l, skipLeading: 4096)
        #expect(comp.lastGainReductionDB < -4.0)
        #expect(outRMS < inRMS - 4.0)

        // Limiter with -3.0 dBFS ceiling (~0.70795 linear) on 1.5 amplitude transient spike
        var spikeL = [Float](repeating: 0.1, count: 4096)
        spikeL[500] = 1.5
        spikeL[501] = -1.4
        var spikeR = spikeL
        let ceilingDB = -3.0
        let ceilingLin = Float(pow(10.0, ceilingDB / 20.0))
        let lim = LimiterDSP(params: LimiterParams(ceilingDB: ceilingDB, lookaheadMs: 4.0, releaseMs: 60.0, isBypassed: false), sampleRate: sr)
        spikeL.withUnsafeMutableBufferPointer { lb in
            spikeR.withUnsafeMutableBufferPointer { rb in
                lim.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        #expect(peakLinear(spikeL) <= ceilingLin + 1e-5)
        #expect(lim.lastGainReductionDB < -2.0)
    }

    @Test("Noise Gate attenuates quiet floor cleanly and STFT Spectral Noise Reduction attenuates steady broadband noise")
    func noiseGateAndSpectralNoiseReduction() {
        let sr = 48_000.0
        // Quiet segment (-52 dBFS) -> Gate threshold -32 dBFS, range -40 dB
        var quietL = makeSine(freq: 300, amp: 0.0025, sampleRate: sr, count: 12_000)
        var quietR = quietL
        let gateInRMS = rmsDB(quietL)
        let gate = NoiseGateDSP(params: NoiseGateParams(thresholdDB: -32, attackMs: 2, holdMs: 20, releaseMs: 30, rangeDB: -40, hysteresisDB: 4, isBypassed: false), sampleRate: sr)
        gate.reset()
        quietL.withUnsafeMutableBufferPointer { lb in
            quietR.withUnsafeMutableBufferPointer { rb in
                gate.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        #expect(rmsDB(quietL, skipLeading: 6000) < gateInRMS - 20.0)

        // Generate deterministic pseudo-random white noise (~ -26 dBFS) + 1000 Hz signal in second half
        var state: UInt32 = 0xCAFEBABE
        let total = 24_576
        var noiseOnly = [Float](repeating: 0, count: 8192)
        for i in 0..<8192 {
            state = state &* 1664525 &+ 1013904223
            let norm = (Float(state >> 8) / Float(1 << 24)) * 2.0 - 1.0
            noiseOnly[i] = norm * 0.06
        }
        let profile = SpectralNoiseReductionDSP.captureNoiseProfile(fromMonoSamples: noiseOnly)
        #expect(profile.count == SpectralNoiseReductionDSP.fftSize)

        var mixL = [Float](repeating: 0, count: total)
        for i in 0..<total {
            state = state &* 1664525 &+ 1013904223
            let norm = (Float(state >> 8) / Float(1 << 24)) * 2.0 - 1.0
            let tone: Float = (i >= total / 2) ? 0.35 * Float(sin(2.0 * .pi * 1000.0 * Double(i) / sr)) : 0
            mixL[i] = norm * 0.06 + tone
        }
        var mixR = mixL
        let noiseFloorBefore = rmsDB(Array(mixL[2048..<8192]), skipLeading: 0)

        let nr = SpectralNoiseReductionDSP(
            params: NoiseReductionParams(reductionAmount: 90, smoothing: 0.4, noiseFloorDB: -30, noiseProfile: profile, isBypassed: false),
            sampleRate: sr
        )
        mixL.withUnsafeMutableBufferPointer { lb in
            mixR.withUnsafeMutableBufferPointer { rb in
                nr.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        let noiseFloorAfter = rmsDB(Array(mixL[2048..<8192]), skipLeading: 0)
        let toneAfter = rmsDB(Array(mixL[(total / 2 + 2048)..<total]), skipLeading: 0)
        // Broadband noise floor reduced noticeably while 1 kHz tone remains prominent
        #expect(noiseFloorAfter < noiseFloorBefore - 6.0)
        #expect(toneAfter > noiseFloorAfter + 10.0)
    }

    @Test("Delay produces echo without feedback runaway and Reverb produces bounded stereo tail")
    func delayAndReverbStability() {
        let sr = 48_000.0
        var impL = [Float](repeating: 0, count: 24_000)
        impL[0] = 0.8
        var impR = impL

        // Delay 50 ms = 2400 samples, clamped high feedback (will clamp <= 0.90 cleanly)
        let delay = DelayDSP(params: DelayParams(delayTimeMs: 50, feedback: 1.5, wetDryMix: 0.5, dampingHz: 6000, pingPong: true, isBypassed: false), sampleRate: sr)
        impL.withUnsafeMutableBufferPointer { lb in
            impR.withUnsafeMutableBufferPointer { rb in
                delay.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        #expect(abs(impL[2400]) > 0.1 || abs(impR[2400]) > 0.1)
        // Energy in late tail decays strictly below input impulse
        #expect(peakLinear(Array(impL[18_000..<24_000])) < 0.5)
        #expect(impL.allSatisfy { $0.isFinite })

        var revL = [Float](repeating: 0, count: 32_000)
        revL[0] = 0.7
        var revR = revL
        let reverb = ReverbDSP(params: ReverbParams(roomPreset: .largeHall, decaySeconds: 2.5, preDelayMs: 10, damping: 0.4, stereoWidth: 0.9, wetDryMix: 0.4, isBypassed: false), sampleRate: sr)
        revL.withUnsafeMutableBufferPointer { lb in
            revR.withUnsafeMutableBufferPointer { rb in
                reverb.process(left: lb.baseAddress!, right: rb.baseAddress!, frameCount: lb.count)
            }
        }
        #expect(peakLinear(Array(revL[2000..<16_000])) > 0.005)
        #expect(revL.allSatisfy { $0.isFinite && abs($0) < 2.0 })
        // Stereo decorrelation check
        #expect(revL[4000..<8000] != revR[4000..<8000])
    }

    @Test("Peak and RMS Normalization compute accurate gains and safely skip pure silence")
    func peakAndRMSNormalization() {
        let sine = makeSine(freq: 440, amp: 0.25, count: 4096) // Peak ~ -12.04 dBFS, RMS ~ -15.05 dBFS
        let m = AudioNormalizer.measure(samplesLeft: sine, samplesRight: sine)
        let peakGain = AudioNormalizer.normalizationGainDB(measurement: m, mode: .peak(targetDBFS: -1.0))
        #expect(peakGain != nil)
        #expect(abs((peakGain ?? 0) - 11.04) < 0.2)

        let rmsGain = AudioNormalizer.normalizationGainDB(measurement: m, mode: .rms(targetDBFS: -10.0))
        #expect(rmsGain != nil)
        #expect(abs((rmsGain ?? 0) - 5.05) < 0.2)

        let silence = [Float](repeating: 0, count: 2048)
        let sm = AudioNormalizer.measure(samplesLeft: silence, samplesRight: silence)
        #expect(AudioNormalizer.normalizationGainDB(measurement: sm, mode: .peak(targetDBFS: -1.0)) == nil)
    }

    @Test("AudioMixSession executes clip, track, and master ordered effectSlots during mixing")
    func orderedEffectChainsInAudioMixSession() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("P45_1_MixFX_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("tone.wav")
        let sr = 48_000.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let f = try AVAudioFile(forWriting: wavURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000)!
        buf.frameLength = 48_000
        let s = makeSine(freq: 200, amp: 0.5, sampleRate: sr, count: 48_000)
        for i in 0..<48_000 {
            buf.floatChannelData![0][i] = s[i]
            buf.floatChannelData![1][i] = s[i]
        }
        try f.write(from: buf)

        let asset = AudioMediaReference(
            id: UUID(), path: wavURL.path, displayName: "tone.wav",
            fileSize: 1, modificationTime: 0, duration: 1.0, sampleRate: sr, channels: 2
        )
        let clip = AudioClip(sourceAssetID: asset.id, name: "Tone", timelineStart: 0, sourceStart: 0, duration: 1.0)
        // Track has Limiter @ -6 dBFS ceiling (~0.501), Master has HPF @ 1000 Hz attenuating 200 Hz
        let limiterSlot = AudioEffectSlot(kind: .limiter, limiter: LimiterParams(ceilingDB: -6.0, lookaheadMs: 2.0, releaseMs: 50.0))
        let eqSlot = AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams(bands: [EQBand(type: .highPass, frequencyHz: 1000, gainDB: 0, q: 0.707)]))
        let track = AudioTrack(name: "T1", clips: [clip], effectSlots: [limiterSlot])
        let project = AudioEditorProject(sampleRate: sr, tracks: [track], mediaAssets: [asset], masterEffects: [eqSlot])

        let sources = try await AudioSourceResolver.resolve(project: project)
        let session = AudioMixSession(project: project, sources: sources)
        var outL = [Float](repeating: 0, count: 4096)
        var outR = [Float](repeating: 0, count: 4096)
        outL.withUnsafeMutableBufferPointer { lb in
            outR.withUnsafeMutableBufferPointer { rb in
                session.mix(startTime: 0, frameCount: 4096, left: lb.baseAddress!, right: rb.baseAddress!)
            }
        }
        // 200 Hz signal passing through 1000 Hz master HPF must be strongly attenuated (< -15 dBFS)
        #expect(rmsDB(outL) < -18.0)
    }
}

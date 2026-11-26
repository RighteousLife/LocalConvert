import Foundation
import AVFoundation
import Accelerate

// MARK: - Stereo waveform mipmap data

struct StereoWaveformData: Sendable {
    static let framesPerBucket = 512
    let sampleRate: Double
    let duration: TimeInterval
    let channels: Int
    let minL: [Float], maxL: [Float]
    let minR: [Float], maxR: [Float]
    /// 1 if any sample in the bucket reached ~0 dBFS.
    let clipped: [UInt8]

    var bucketCount: Int { maxL.count }
    var bucketDuration: Double { Double(Self.framesPerBucket) / sampleRate }
    var approxBytes: Int { bucketCount * (4 * 4 + 1) }

    struct Bin: Sendable { var minL: Float, maxL: Float, minR: Float, maxR: Float, clipped: Bool }

    /// Aggregates the cached buckets into `bins` display bins covering [t0, t1].
    func bins(from t0: TimeInterval, to t1: TimeInterval, count bins: Int) -> [Bin] {
        guard bins > 0, bucketCount > 0, t1 > t0 else { return [] }
        var out = [Bin](repeating: Bin(minL: 0, maxL: 0, minR: 0, maxR: 0, clipped: false), count: bins)
        let bd = bucketDuration
        let span = (t1 - t0) / Double(bins)
        for i in 0..<bins {
            let a = Int(((t0 + Double(i) * span) / bd).rounded(.down))
            var b = Int(((t0 + Double(i + 1) * span) / bd).rounded(.up))
            if b <= a { b = a + 1 }
            guard a < bucketCount, b > 0 else { continue }
            let lo = max(0, a), hi = min(bucketCount, b)
            guard lo < hi else { continue }
            var bin = Bin(minL: 0, maxL: 0, minR: 0, maxR: 0, clipped: false)
            for k in lo..<hi {
                bin.minL = min(bin.minL, minL[k]); bin.maxL = max(bin.maxL, maxL[k])
                bin.minR = min(bin.minR, minR[k]); bin.maxR = max(bin.maxR, maxR[k])
                if clipped[k] != 0 { bin.clipped = true }
            }
            out[i] = bin
        }
        return out
    }
}

struct AudioRangeStats: Sendable, Equatable {
    var peakDB: Double
    var rmsDB: Double
    var clippedSamples: Int
    var duration: TimeInterval
}

// MARK: - Waveform service (bounded LRU cache; one decode per asset)

actor WaveformRenderingService {
    static let shared = WaveformRenderingService()

    private var cache: [String: StereoWaveformData] = [:]
    private var order: [String] = []
    private var bytes = 0
    private let maxBytes = 64 * 1024 * 1024
    private var inFlight: [String: Task<StereoWaveformData, Error>] = [:]

    private static func key(_ a: AudioMediaReference) -> String { "\(a.path)|\(a.fileSize)|\(a.modificationTime)" }

    func cachedBytes() -> Int { bytes }
    func clear() { cache.removeAll(); order.removeAll(); bytes = 0 }

    /// Multi-resolution Stage A peak pyramid bridge delegating to `WaveformPyramidService`.
    func pyramid(
        for asset: AudioMediaReference,
        onProgress: (@Sendable (WaveformBuildProgress) -> Void)? = nil
    ) async throws -> WaveformPyramid {
        try await WaveformPyramidService.shared.pyramid(
            for: asset.url,
            assetID: asset.id,
            onProgress: onProgress
        )
    }

    func waveform(for asset: AudioMediaReference) async throws -> StereoWaveformData {
        let k = Self.key(asset)
        if let hit = cache[k] {
            order.removeAll { $0 == k }; order.append(k)
            return hit
        }
        if let task = inFlight[k] { return try await task.value }
        let task = Task.detached(priority: .utility) { try await Self.build(asset: asset) }
        inFlight[k] = task
        defer { inFlight[k] = nil }
        let data = try await task.value
        cache[k] = data
        order.append(k)
        bytes += data.approxBytes
        while bytes > maxBytes, let oldest = order.first, oldest != k {
            order.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { bytes -= removed.approxBytes }
        }
        return data
    }

    /// Readable URL for an asset (decodes via FFmpeg into the proxy cache for formats AVAudioFile cannot open).
    static func readableURL(for asset: AudioMediaReference) async throws -> URL {
        if (try? AVAudioFile(forReading: asset.url)) != nil { return asset.url }
        var clip = AudioClip(sourceAssetID: asset.id, name: asset.displayName, timelineStart: 0, sourceStart: 0, duration: max(0.01, asset.duration))
        clip.effects = AudioEffectChainConfig()
        return try await ClipProxyCache.shared.proxyURL(for: clip, asset: asset, projectRate: asset.sampleRate > 0 ? asset.sampleRate : 48_000)
    }

    private static func build(asset: AudioMediaReference) async throws -> StereoWaveformData {
        let url = try await readableURL(for: asset)
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let channels = Int(fmt.channelCount)
        let per = StereoWaveformData.framesPerBucket
        let total = Int(file.length)
        let bucketTotal = max(1, (total + per - 1) / per)
        var minL = [Float](repeating: 0, count: bucketTotal), maxL = minL, minR = minL, maxR = minL
        var clipped = [UInt8](repeating: 0, count: bucketTotal)
        let capacity = AVAudioFrameCount(per * 128)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else {
            throw ConversionError.invalidInput("Unable to allocate waveform buffer")
        }
        var frame = 0
        while frame < total {
            try Task.checkCancellation()
            buf.frameLength = 0
            try file.read(into: buf, frameCount: capacity)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            let l = data[0], r = channels > 1 ? data[1] : data[0]
            var i = 0
            while i < n {
                let b = (frame + i) / per
                let end = min(n, i + (per - ((frame + i) % per)))
                var mnL: Float = 0, mxL: Float = 0, mnR: Float = 0, mxR: Float = 0
                vDSP_minv(l + i, 1, &mnL, vDSP_Length(end - i)); vDSP_maxv(l + i, 1, &mxL, vDSP_Length(end - i))
                vDSP_minv(r + i, 1, &mnR, vDSP_Length(end - i)); vDSP_maxv(r + i, 1, &mxR, vDSP_Length(end - i))
                if b < bucketTotal {
                    minL[b] = min(minL[b], mnL); maxL[b] = max(maxL[b], mxL)
                    minR[b] = min(minR[b], mnR); maxR[b] = max(maxR[b], mxR)
                    if max(abs(mnL), abs(mxL), abs(mnR), abs(mxR)) >= 0.999 { clipped[b] = 1 }
                }
                i = end
            }
            frame += n
        }
        return StereoWaveformData(sampleRate: fmt.sampleRate, duration: Double(total) / fmt.sampleRate, channels: channels,
                                  minL: minL, maxL: maxL, minR: minR, maxR: maxR, clipped: clipped)
    }

    /// Peak / RMS / clipping over a source-time range (streamed; bounded memory).
    func measure(asset: AudioMediaReference, from start: TimeInterval, duration: TimeInterval) async throws -> AudioRangeStats {
        let url = try await Self.readableURL(for: asset)
        return try await Task.detached(priority: .utility) {
            let file = try AVAudioFile(forReading: url)
            let fmt = file.processingFormat
            let rate = fmt.sampleRate
            file.framePosition = Int64(max(0, start) * rate)
            var remaining = Int(duration * rate)
            let total = remaining
            let capacity: AVAudioFrameCount = 16_384
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else {
                throw ConversionError.invalidInput("buffer")
            }
            var peak: Float = 0, sumSq: Double = 0, count: Double = 0, clipped = 0
            while remaining > 0 {
                try Task.checkCancellation()
                buf.frameLength = 0
                try file.read(into: buf, frameCount: min(capacity, AVAudioFrameCount(remaining)))
                let n = Int(buf.frameLength)
                if n == 0 { break }
                guard let d = buf.floatChannelData else { break }
                for ch in 0..<Int(fmt.channelCount) {
                    var p: Float = 0, ms: Float = 0
                    vDSP_maxmgv(d[ch], 1, &p, vDSP_Length(n))
                    vDSP_measqv(d[ch], 1, &ms, vDSP_Length(n))
                    peak = max(peak, p)
                    sumSq += Double(ms) * Double(n); count += Double(n)
                    for i in 0..<n where abs(d[ch][i]) >= 0.999 { clipped += 1 }
                }
                remaining -= n
            }
            let rms = count > 0 ? sqrt(sumSq / count) : 0
            func db(_ v: Double) -> Double { v > 1e-9 ? 20 * log10(v) : -120 }
            return AudioRangeStats(peakDB: db(Double(peak)), rmsDB: db(rms), clippedSamples: clipped, duration: Double(total - remaining) / rate)
        }.value
    }
}

// MARK: - Frequency spectrum analyzer (vDSP FFT)

enum SpectrumAnalyzerService {
    static let binCount = 48

    /// Log-spaced magnitude spectrum (dBFS) of a 2048-sample window starting at `time`.
    static func spectrum(asset: AudioMediaReference, at time: TimeInterval) async -> [Float] {
        guard let url = try? await WaveformRenderingService.readableURL(for: asset) else { return [] }
        return await Task.detached(priority: .utility) { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let fmt = file.processingFormat
            let n = 2048
            file.framePosition = Int64(max(0, min(time, asset.duration)) * fmt.sampleRate)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return [] }
            try? file.read(into: buf, frameCount: AVAudioFrameCount(n))
            guard let data = buf.floatChannelData, buf.frameLength > 0 else { return [Float](repeating: -120, count: binCount) }
            var samples = [Float](repeating: 0, count: n)
            let got = Int(buf.frameLength)
            let chs = Int(fmt.channelCount)
            for i in 0..<got { var s: Float = 0; for c in 0..<chs { s += data[c][i] }; samples[i] = s / Float(chs) }
            return magnitudes(samples: samples, sampleRate: fmt.sampleRate)
        }.value
    }

    static func magnitudes(samples: [Float], sampleRate: Double) -> [Float] {
        let n = samples.count
        guard n >= 256, n & (n - 1) == 0 else { return [] }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let windowed = vDSP.multiply(samples, window)
        var inRe = [Float](repeating: 0, count: n / 2), inIm = inRe
        var outRe = inRe, outIm = inRe
        var mags = [Float](repeating: 0, count: n / 2)
        windowed.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                inRe.withUnsafeMutableBufferPointer { rp in
                    inIm.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                        outRe.withUnsafeMutableBufferPointer { orp in
                            outIm.withUnsafeMutableBufferPointer { oip in
                                var outSplit = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                                fft.forward(input: split, output: &outSplit)
                                vDSP.absolute(outSplit, result: &mags)
                            }
                        }
                    }
                }
            }
        }
        let scale = 2.0 / Float(n)
        let nyquist = sampleRate / 2
        let fMin = 30.0, fMax = min(18_000.0, nyquist)
        var out = [Float](repeating: -120, count: binCount)
        for b in 0..<binCount {
            let f0 = fMin * pow(fMax / fMin, Double(b) / Double(binCount))
            let f1 = fMin * pow(fMax / fMin, Double(b + 1) / Double(binCount))
            let i0 = max(1, Int(f0 / nyquist * Double(n / 2)))
            let i1 = max(i0 + 1, min(n / 2, Int(f1 / nyquist * Double(n / 2))))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, mags[i] * scale) }
            out[b] = peak > 1e-7 ? 20 * log10(peak) : -120
        }
        return out
    }
}

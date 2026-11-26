import Foundation

// MARK: - Multi-Resolution Peak Pyramid Domain Model

/// A single summary bucket representing `[min, max, rms, clipped]` across `framesPerBucket` frames of one audio channel.
struct WaveformBucket: Sendable, Equatable, Hashable {
    var minSample: Float
    var maxSample: Float
    var rms: Float
    var clipped: Bool

    static let zero = WaveformBucket(minSample: 0, maxSample: 0, rms: 0, clipped: false)

    init(minSample: Float, maxSample: Float, rms: Float, clipped: Bool) {
        self.minSample = minSample
        self.maxSample = maxSample
        self.rms = rms
        self.clipped = clipped
    }
}

/// Bucket series for a single channel at a specific mipmap resolution.
struct WaveformChannelLevel: Sendable, Equatable {
    let channelIndex: Int
    let buckets: [WaveformBucket]

    init(channelIndex: Int, buckets: [WaveformBucket]) {
        self.channelIndex = channelIndex
        self.buckets = buckets
    }
}

/// One resolution tier in a `WaveformPyramid`, holding per-channel bucket arrays.
struct WaveformMipLevel: Sendable, Equatable {
    let framesPerBucket: Int
    let channels: [WaveformChannelLevel]

    var bucketCount: Int {
        channels.first?.buckets.count ?? 0
    }

    init(framesPerBucket: Int, channels: [WaveformChannelLevel]) {
        self.framesPerBucket = framesPerBucket
        self.channels = channels
    }
}

/// Progressive build notification emitted while streaming long audio files into a `WaveformPyramid`.
struct WaveformBuildProgress: Sendable, Equatable {
    let completedFrames: Int64
    let totalFrames: Int64
    let isComplete: Bool
    let pyramid: WaveformPyramid

    init(completedFrames: Int64, totalFrames: Int64, isComplete: Bool, pyramid: WaveformPyramid) {
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
        self.isComplete = isComplete
        self.pyramid = pyramid
    }
}

/// Multi-resolution 5-level peak pyramid (`64 / 256 / 1024 / 4096 / 16384` frames/bucket) with per-channel fidelity.
struct WaveformPyramid: Sendable, Equatable {
    static let standardBucketSizes: [Int] = [64, 256, 1024, 4096, 16_384]

    let assetID: UUID?
    let cacheKey: String
    let sampleRate: Int32
    let channelCount: Int
    let totalFrames: Int64
    let duration: TimeInterval
    /// Levels ordered from finest (`64`) to coarsest (`16_384`).
    let levels: [WaveformMipLevel]
    let isPartial: Bool
    let completedFrames: Int64

    init(
        assetID: UUID? = nil,
        cacheKey: String,
        sampleRate: Int32,
        channelCount: Int,
        totalFrames: Int64,
        duration: TimeInterval,
        levels: [WaveformMipLevel],
        isPartial: Bool,
        completedFrames: Int64
    ) {
        self.assetID = assetID
        self.cacheKey = cacheKey
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.totalFrames = totalFrames
        self.duration = duration
        self.levels = levels
        self.isPartial = isPartial
        self.completedFrames = completedFrames
    }

    /// Selects the coarsest mip level whose `framesPerBucket <= samplesPerPixel` (preventing undersampling).
    /// Handles invalid (`<= 0`, `NaN`) values by returning the finest level, `+Inf` by returning the coarsest,
    /// and returns `nil` when `levels` is empty.
    func bestLevel(forSamplesPerPixel spp: Double) -> WaveformMipLevel? {
        guard !levels.isEmpty else { return nil }
        if spp.isNaN || spp <= 0 {
            return levels.first
        }
        if !spp.isFinite {
            return levels.last
        }
        var selected = levels[0]
        for level in levels where Double(level.framesPerBucket) <= spp {
            if level.framesPerBucket >= selected.framesPerBucket {
                selected = level
            }
        }
        return selected
    }

    /// Estimated RAM footprint in bytes (`16` bytes per bucket across all levels and channels + fixed header overhead).
    var estimatedMemoryBytes: Int {
        var bucketTotal = 0
        for level in levels {
            for ch in level.channels {
                bucketTotal += ch.buckets.count
            }
        }
        return 128 + (bucketTotal * 16)
    }

    /// Returns a valid empty pyramid containing all 5 standard mip levels with zero buckets per channel.
    static func empty(
        assetID: UUID? = nil,
        cacheKey: String,
        sampleRate: Int32,
        channelCount: Int
    ) -> WaveformPyramid {
        let clampedChannels = max(1, channelCount)
        let emptyLevels = standardBucketSizes.map { size in
            let chLevels = (0..<clampedChannels).map { ch in
                WaveformChannelLevel(channelIndex: ch, buckets: [])
            }
            return WaveformMipLevel(framesPerBucket: size, channels: chLevels)
        }
        return WaveformPyramid(
            assetID: assetID,
            cacheKey: cacheKey,
            sampleRate: sampleRate,
            channelCount: clampedChannels,
            totalFrames: 0,
            duration: 0,
            levels: emptyLevels,
            isPartial: false,
            completedFrames: 0
        )
    }
}

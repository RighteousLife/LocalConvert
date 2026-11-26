import SwiftUI

// MARK: - Canvas Mipmap Sampling Plan (Pure & Testable)

struct WaveformCanvasSamplingPlan: Equatable, Sendable {
    let mipLevelIndex: Int
    let framesPerBucket: Int
    let channelCount: Int
    let startBucketIndex: Int
    let endBucketIndex: Int
    let drawnBucketCount: Int
    let channelSlices: [[WaveformBucket]]
    let clippedBucketCount: Int
}

enum WaveformCanvasRenderer {
    /// Selects the optimal `.lcwave` mip level and folds buckets only when necessary
    /// so rendered bucket count stays strictly `<= Int(ceil(max(1, viewportWidth))) * 2`.
    static func makeSamplingPlan(
        pyramid: WaveformPyramid,
        clipSourceStartFrame: Int64,
        clipSourceSpanFrames: Int64,
        sampleRate: Int32,
        pixelsPerSecond: Double,
        viewportWidth: Double
    ) -> WaveformCanvasSamplingPlan {
        let clampedViewport = max(1.0, viewportWidth.isFinite ? viewportWidth : 720.0)
        let maxAllowedBuckets = max(1, Int(ceil(clampedViewport)) * 2)

        guard !pyramid.levels.isEmpty,
              clipSourceSpanFrames > 0,
              sampleRate > 0 else {
            return WaveformCanvasSamplingPlan(
                mipLevelIndex: 0,
                framesPerBucket: 64,
                channelCount: max(1, pyramid.channelCount),
                startBucketIndex: 0,
                endBucketIndex: 0,
                drawnBucketCount: 0,
                channelSlices: [],
                clippedBucketCount: 0
            )
        }

        let safePPS = max(0.001, pixelsPerSecond.isFinite ? pixelsPerSecond : 80.0)
        let samplesPerPixel = Double(sampleRate) / safePPS
        let selectedLevel = pyramid.bestLevel(forSamplesPerPixel: samplesPerPixel) ?? pyramid.levels[0]
        let selectedIndex = pyramid.levels.firstIndex(where: { $0.framesPerBucket == selectedLevel.framesPerBucket }) ?? 0

        let rawChannelCount = selectedLevel.channels.count
        guard rawChannelCount > 0 else {
            return WaveformCanvasSamplingPlan(
                mipLevelIndex: selectedIndex,
                framesPerBucket: selectedLevel.framesPerBucket,
                channelCount: max(1, pyramid.channelCount),
                startBucketIndex: 0,
                endBucketIndex: 0,
                drawnBucketCount: 0,
                channelSlices: [],
                clippedBucketCount: 0
            )
        }

        let totalBuckets = selectedLevel.channels[0].buckets.count
        guard totalBuckets > 0 else {
            return WaveformCanvasSamplingPlan(
                mipLevelIndex: selectedIndex,
                framesPerBucket: selectedLevel.framesPerBucket,
                channelCount: rawChannelCount,
                startBucketIndex: 0,
                endBucketIndex: 0,
                drawnBucketCount: 0,
                channelSlices: Array(repeating: [], count: rawChannelCount),
                clippedBucketCount: 0
            )
        }

        let fpb = Int64(max(1, selectedLevel.framesPerBucket))
        let startBucket = max(0, min(totalBuckets - 1, Int(max(0, clipSourceStartFrame) / fpb)))
        let endFrame = max(clipSourceStartFrame + 1, clipSourceStartFrame + clipSourceSpanFrames)
        let endBucket = max(startBucket + 1, min(totalBuckets, Int((endFrame + fpb - 1) / fpb)))
        let rawCount = max(1, endBucket - startBucket)

        // Downsample consecutive buckets only if raw mip slice still exceeds `<= viewportWidth * 2`.
        let outCount = min(rawCount, maxAllowedBuckets)
        var channelSlices: [[WaveformBucket]] = []
        channelSlices.reserveCapacity(rawChannelCount)
        var clippedTotal = 0

        for ch in 0..<rawChannelCount {
            let src = selectedLevel.channels[ch].buckets
            var outBuckets: [WaveformBucket] = []
            outBuckets.reserveCapacity(outCount)

            if rawCount <= maxAllowedBuckets {
                let slice = Array(src[startBucket..<endBucket])
                if ch == 0 {
                    clippedTotal += slice.filter(\.clipped).count
                }
                outBuckets = slice
            } else {
                for i in 0..<outCount {
                    let lo = startBucket + (i * rawCount) / outCount
                    let hi = max(lo + 1, startBucket + ((i + 1) * rawCount) / outCount)
                    var minV: Float = 1.0
                    var maxV: Float = -1.0
                    var sumSq: Float = 0.0
                    var clipped = false
                    var count = 0
                    for idx in lo..<min(hi, src.count) {
                        let b = src[idx]
                        minV = min(minV, b.minSample)
                        maxV = max(maxV, b.maxSample)
                        sumSq += b.rms * b.rms
                        clipped = clipped || b.clipped
                        count += 1
                    }
                    let rms = count > 0 ? sqrt(max(0, sumSq / Float(count))) : 0
                    let merged = WaveformBucket(
                        minSample: count > 0 ? minV : 0,
                        maxSample: count > 0 ? maxV : 0,
                        rms: rms,
                        clipped: clipped
                    )
                    if ch == 0 && clipped { clippedTotal += 1 }
                    outBuckets.append(merged)
                }
            }
            channelSlices.append(outBuckets)
        }

        return WaveformCanvasSamplingPlan(
            mipLevelIndex: selectedIndex,
            framesPerBucket: selectedLevel.framesPerBucket,
            channelCount: rawChannelCount,
            startBucketIndex: startBucket,
            endBucketIndex: endBucket,
            drawnBucketCount: outCount,
            channelSlices: channelSlices,
            clippedBucketCount: clippedTotal
        )
    }
}

// MARK: - Isolated Equatable Canvas View (Immune to Playhead Ticks)

struct WaveformClipCanvasView: View, Equatable {
    let pyramid: WaveformPyramid?
    let hasSourceAsset: Bool
    let clipSourceStartFrame: Int64
    let clipSourceSpanFrames: Int64
    let clipDurationSeconds: Double
    let isMuted: Bool
    let isReversed: Bool
    let expandMultichannel: Bool
    let fadeIn: ClipFadeSpec?
    let fadeOut: ClipFadeSpec?
    let pixelsPerSecond: Double
    let viewportWidth: Double
    let precomputedPlan: WaveformCanvasSamplingPlan?
    let onPlanComputed: ((WaveformCanvasSamplingPlan) -> Void)?

    init(
        pyramid: WaveformPyramid?,
        hasSourceAsset: Bool,
        clipSourceStartFrame: Int64,
        clipSourceSpanFrames: Int64,
        clipDurationSeconds: Double,
        isMuted: Bool,
        isReversed: Bool,
        expandMultichannel: Bool,
        fadeIn: ClipFadeSpec?,
        fadeOut: ClipFadeSpec?,
        pixelsPerSecond: Double,
        viewportWidth: Double,
        precomputedPlan: WaveformCanvasSamplingPlan? = nil,
        onPlanComputed: ((WaveformCanvasSamplingPlan) -> Void)?
    ) {
        self.pyramid = pyramid
        self.hasSourceAsset = hasSourceAsset
        self.clipSourceStartFrame = clipSourceStartFrame
        self.clipSourceSpanFrames = clipSourceSpanFrames
        self.clipDurationSeconds = clipDurationSeconds
        self.isMuted = isMuted
        self.isReversed = isReversed
        self.expandMultichannel = expandMultichannel
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.pixelsPerSecond = pixelsPerSecond
        self.viewportWidth = viewportWidth
        self.precomputedPlan = precomputedPlan
        self.onPlanComputed = onPlanComputed
    }

    nonisolated static func == (lhs: WaveformClipCanvasView, rhs: WaveformClipCanvasView) -> Bool {
        lhs.pyramid == rhs.pyramid
            && lhs.hasSourceAsset == rhs.hasSourceAsset
            && lhs.clipSourceStartFrame == rhs.clipSourceStartFrame
            && lhs.clipSourceSpanFrames == rhs.clipSourceSpanFrames
            && lhs.clipDurationSeconds == rhs.clipDurationSeconds
            && lhs.isMuted == rhs.isMuted
            && lhs.isReversed == rhs.isReversed
            && lhs.expandMultichannel == rhs.expandMultichannel
            && lhs.fadeIn == rhs.fadeIn
            && lhs.fadeOut == rhs.fadeOut
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
            && lhs.viewportWidth == rhs.viewportWidth
            && lhs.precomputedPlan == rhs.precomputedPlan
    }

    var body: some View {
        Canvas { ctx, size in
            drawCanvas(ctx: ctx, size: size)
        }
        .allowsHitTesting(false)
    }

    private func drawCanvas(ctx: GraphicsContext, size: CGSize) {
        if !hasSourceAsset {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(p, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            return
        }

        guard let pyramid else {
            // Progressive placeholder while streaming analysis runs
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height / 2))
            p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(p, with: .color(AppTheme.Colors.accent.opacity(0.28)), lineWidth: 1)
            return
        }

        let plan = precomputedPlan ?? WaveformCanvasRenderer.makeSamplingPlan(
            pyramid: pyramid,
            clipSourceStartFrame: clipSourceStartFrame,
            clipSourceSpanFrames: clipSourceSpanFrames,
            sampleRate: pyramid.sampleRate,
            pixelsPerSecond: pixelsPerSecond,
            viewportWidth: viewportWidth
        )
        onPlanComputed?(plan)

        guard plan.drawnBucketCount > 0, !plan.channelSlices.isEmpty else { return }

        let renderedChannelIndices: [Int]
        if plan.channelCount <= 2 || expandMultichannel {
            renderedChannelIndices = Array(0..<plan.channelCount)
        } else {
            // Compact summary shows ch 0 + ch 1 lanes when collapsed.
            renderedChannelIndices = [0, 1]
        }

        let laneCount = max(1, renderedChannelIndices.count)
        let laneHeight = size.height / CGFloat(laneCount)
        let dx = size.width / CGFloat(plan.drawnBucketCount)
        let peakColor = isMuted ? Color.secondary.opacity(0.38) : AppTheme.Colors.accent.opacity(0.84)
        let rmsColor = isMuted ? Color.secondary.opacity(0.55) : AppTheme.Colors.accent.opacity(0.98)

        var peakPath = Path()
        var rmsPath = Path()
        var clipPath = Path()

        for (laneOffset, chIndex) in renderedChannelIndices.enumerated() {
            let rawBuckets = plan.channelSlices[chIndex]
            let ordered = isReversed ? Array(rawBuckets.reversed()) : rawBuckets
            let midY = (CGFloat(laneOffset) + 0.5) * laneHeight
            let ampH = laneHeight * (laneCount == 1 ? 0.42 : 0.40)

            for (i, bin) in ordered.enumerated() {
                let x = CGFloat(i) * dx
                let w = max(1, dx)
                let yTop = midY - CGFloat(bin.maxSample) * ampH
                let yBot = midY - CGFloat(bin.minSample) * ampH
                let peakRect = CGRect(x: x, y: min(yTop, yBot), width: w, height: max(1, abs(yBot - yTop)))
                if bin.clipped {
                    clipPath.addRect(peakRect)
                } else {
                    peakPath.addRect(peakRect)
                }

                let rmsHalf = CGFloat(min(1.0, max(0.0, bin.rms))) * ampH
                if rmsHalf > 0.5 {
                    let rmsRect = CGRect(x: x, y: midY - rmsHalf, width: w, height: max(1, rmsHalf * 2))
                    rmsPath.addRect(rmsRect)
                }
            }
        }

        ctx.fill(peakPath, with: .color(peakColor))
        ctx.fill(rmsPath, with: .color(rmsColor))
        if !clipPath.isEmpty {
            ctx.fill(clipPath, with: .color(AppTheme.Colors.error))
        }

        // Curve-accurate fade-in / fade-out overlays
        if let fi = fadeIn, fi.duration > 0 {
            let fw = min(size.width, CGFloat(fi.duration * pixelsPerSecond))
            var fade = Path()
            fade.move(to: CGPoint(x: 0, y: 0))
            fade.addLine(to: CGPoint(x: fw, y: 0))
            let steps = 12
            for s in stride(from: steps, through: 0, by: -1) {
                let u = Double(s) / Double(steps)
                let gain = fi.curve.fadeIn(u)
                fade.addLine(to: CGPoint(x: CGFloat(u) * fw, y: CGFloat(1.0 - gain) * size.height))
            }
            fade.closeSubpath()
            ctx.fill(fade, with: .color(.black.opacity(0.24)))
        }

        if let fo = fadeOut, fo.duration > 0 {
            let fw = min(size.width, CGFloat(fo.duration * pixelsPerSecond))
            var fade = Path()
            fade.move(to: CGPoint(x: size.width - fw, y: 0))
            fade.addLine(to: CGPoint(x: size.width, y: 0))
            let steps = 12
            for s in stride(from: steps, through: 0, by: -1) {
                let u = Double(s) / Double(steps)
                let gain = fo.curve.fadeOut(u)
                fade.addLine(to: CGPoint(x: (size.width - fw) + CGFloat(u) * fw, y: CGFloat(1.0 - gain) * size.height))
            }
            fade.closeSubpath()
            ctx.fill(fade, with: .color(.black.opacity(0.24)))
        }
    }
}

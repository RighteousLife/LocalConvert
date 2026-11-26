import Foundation
import AVFoundation
import CryptoKit

// MARK: - Gain automation (shared by playback and export so preview == render)

enum AudioGainAutomation {

    static func dbToLinear(_ db: Double) -> Double { pow(10.0, db / 20.0) }

    /// Sample-accurate linear gain of a clip at project timeline `frame` (clip gain + fades + automatic same-track crossfades).
    /// Track volume/pan/mute/solo are applied separately by the mixer.
    static func clipGain(track: AudioTrack, clip: AudioClip, atFrame frame: Int64) -> Double {
        var g = dbToLinear(clip.gainDB)
        let localFrame = frame - clip.timelineStartFrame
        if let fi = clip.fadeInFrames, fi.durationFrames > 0, localFrame >= 0, localFrame < fi.durationFrames {
            g *= fi.curve.fadeIn(Double(localFrame) / Double(fi.durationFrames))
        }
        if let fo = clip.fadeOutFrames, fo.durationFrames > 0 {
            let remaining = clip.durationFrames - localFrame
            if remaining < fo.durationFrames {
                let x = max(0.0, min(1.0, 1.0 - (Double(remaining) / Double(fo.durationFrames))))
                g *= fo.curve.fadeOut(x)
            }
        }
        // Crossfades with overlapping clips on the same track (exact sample-frame intervals).
        for other in track.clips where other.id != clip.id && !other.isMuted {
            let oStart = other.timelineStartFrame
            let oEnd = other.timelineEndFrame
            let overlapStart = max(clip.timelineStartFrame, oStart)
            let overlapEnd = min(clip.timelineEndFrame, oEnd)
            guard overlapEnd > overlapStart, frame >= overlapStart, frame <= overlapEnd else { continue }
            let len = overlapEnd - overlapStart
            let x = Double(frame - overlapStart) / Double(len)
            // The clip that starts later fades IN; the earlier one fades OUT. Ties broken by id for determinism.
            let clipIsLater = clip.timelineStartFrame > oStart || (clip.timelineStartFrame == oStart && clip.id.uuidString > other.id.uuidString)
            let curve = clipIsLater ? clip.crossfadeCurve : other.crossfadeCurve
            // Ignore containment overlaps — only true crossfades where later clip extends past earlier clip's end.
            let isTrueCrossfade = (clip.timelineStartFrame < oStart && clip.timelineEndFrame < oEnd)
                || (clip.timelineStartFrame > oStart && clip.timelineEndFrame > oEnd)
            guard isTrueCrossfade else { continue }
            g *= clipIsLater ? curve.fadeIn(x) : curve.fadeOut(x)
        }
        return g
    }

    /// Time-based convenience wrapper delegating to exact sample-frame `clipGain(track:clip:atFrame:)`.
    static func clipGain(track: AudioTrack, clip: AudioClip, at t: TimeInterval) -> Double {
        guard t.isFinite else { return dbToLinear(clip.gainDB) }
        let frame = (try? SampleFrameMigration.secondsToFrames(t, sampleRate: clip.projectRate, field: "at", allowNegative: true))
            ?? Int64((t * Double(clip.projectRate.hz)).rounded())
        return clipGain(track: track, clip: clip, atFrame: frame)
    }

    /// Simple stereo balance law: centered tracks stay at unity.
    static func balance(pan: Double) -> (l: Float, r: Float) {
        let p = min(1, max(-1, pan))
        return (Float(p > 0 ? 1 - p : 1), Float(p < 0 ? 1 + p : 1))
    }
}

// MARK: - FFmpeg access for clip proxies / export

enum AudioEditorFFmpeg {
    static func path() async -> String? {
        await BundledFFmpegProvider().findFFmpegPath()
    }

    @discardableResult
    static func run(
        arguments: [String],
        timeout: TimeInterval? = BaseFFmpegProvider.defaultConversionTimeoutSeconds
    ) async throws -> String {
        guard let exe = await path() else { throw ConversionError.engineNotAvailable("Bundled FFmpeg") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = arguments
        do {
            let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: timeout)
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            guard output.terminationStatus == 0 else {
                throw ConversionError.engineExecutionFailed("Audio Editor FFmpeg step failed (exit \(output.terminationStatus)).", underlyingError: err)
            }
            return err
        } catch is CancellationError {
            throw ConversionError.cancelled
        }
    }
}

// MARK: - Effect chain → FFmpeg filter graph

enum AudioEffectFilterBuilder {
    static func atempoChain(_ tempo: Double) -> [String] {
        var t = max(0.1, min(10, tempo))
        var out: [String] = []
        while t < 0.5 { out.append("atempo=0.5"); t /= 0.5 }
        while t > 2.0 { out.append("atempo=2.0"); t /= 2.0 }
        if abs(t - 1.0) > 0.00001 { out.append(String(format: "atempo=%.6f", t)) }
        return out
    }

    static func chain(for clip: AudioClip, sampleRate: Double, targetChannels: Int = 2) -> String {
        let formatFilter: String
        if targetChannels == 1 {
            formatFilter = "aformat=sample_fmts=fltp:channel_layouts=mono"
        } else if targetChannels == 2 {
            formatFilter = "aformat=sample_fmts=fltp:channel_layouts=stereo"
        } else {
            formatFilter = "aformat=sample_fmts=fltp"
        }
        var f: [String] = [formatFilter]
        let e = clip.effects
        if let hp = e.highPassHz { f.append(String(format: "highpass=f=%.1f", hp)) }
        if let lp = e.lowPassHz { f.append(String(format: "lowpass=f=%.1f", lp)) }
        if e.eqEnabled {
            if abs(e.eqLowDB) > 0.01 { f.append(String(format: "equalizer=f=120:t=h:width=200:g=%.2f", e.eqLowDB)) }
            if abs(e.eqMidDB) > 0.01 { f.append(String(format: "equalizer=f=1000:t=q:w=1:g=%.2f", e.eqMidDB)) }
            if abs(e.eqHighDB) > 0.01 { f.append(String(format: "equalizer=f=8000:t=h:width=2000:g=%.2f", e.eqHighDB)) }
        }
        if let gate = e.gateThresholdDB {
            f.append(String(format: "agate=threshold=%.6f:ratio=6:attack=5:release=120", AudioGainAutomation.dbToLinear(gate)))
        }
        if let nr = e.noiseReductionDB { f.append(String(format: "afftdn=nr=%.1f:nf=-40", min(40, max(1, nr)))) }
        if e.compressorEnabled {
            f.append(String(format: "acompressor=threshold=%.6f:ratio=%.2f:attack=10:release=200", AudioGainAutomation.dbToLinear(e.compressorThresholdDB), max(1, e.compressorRatio)))
        }
        if let ceil = e.limiterCeilingDB {
            f.append(String(format: "alimiter=limit=%.6f:level=disabled", AudioGainAutomation.dbToLinear(min(0, ceil))))
        }
        // Pitch (rate-shift + tempo compensation) combined with time stretch.
        let pitchRatio = pow(2.0, e.pitchSemitones / 12.0)
        if abs(e.pitchSemitones) > 0.001 {
            f.append(String(format: "asetrate=%.3f", sampleRate * pitchRatio))
            f.append(String(format: "aresample=%.0f", sampleRate))
        }
        f += atempoChain(clip.stretch / pitchRatio)
        if targetChannels == 2 {
            if clip.swapChannels { f.append("pan=stereo|c0=c1|c1=c0") }
            switch clip.channelMode {
            case .mono: f.append("pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1")
            case .stereo, .original: break
            }
        }
        if clip.isReversed { f.append("areverse") }
        return f.joined(separator: ",")
    }
}

// MARK: - Proxy cache (non-destructive: processed/decoded clip audio lives in Caches, never beside sources)

actor ClipProxyCache {
    static let shared = ClipProxyCache()
    static let proxyVersion = 2

    private let directory: URL
    private let maxBytes: Int64
    private var inFlightTasks: [String: Task<URL, Error>] = [:]
    private var inFlightWaiters: [String: Int] = [:]

    init(directory: URL = AppStoragePaths.audioEditorProxiesDirectory, maxBytes: Int64 = 1_500_000_000) {
        self.directory = directory
        self.maxBytes = max(1, maxBytes)
    }

    /// Whether the clip can be read directly from its source (no proxy needed).
    nonisolated static func canReadDirectly(
        clip: AudioClip,
        asset: AudioMediaReference,
        projectRate: Double,
        targetChannels: Int = 2
    ) -> Bool {
        guard !clip.needsProcessedProxy,
              abs(asset.sampleRate - projectRate) < 0.5,
              asset.channels <= max(2, targetChannels) else {
            return false
        }
        return (try? AVAudioFile(forReading: asset.url)) != nil
    }

    func proxyURL(
        for clip: AudioClip,
        asset: AudioMediaReference,
        projectRate: Double,
        targetChannels: Int = 2
    ) async throws -> URL {
        try Task.checkCancellation()
        let resolvedChannels = max(1, targetChannels)
        let key = Self.cacheKey(clip: clip, asset: asset, rate: projectRate, channelCount: resolvedChannels)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent("\(key).caf")
        if FileManager.default.fileExists(atPath: out.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: out.path)
            return out
        }

        let task: Task<URL, Error>
        if let existing = inFlightTasks[key] {
            task = existing
            inFlightWaiters[key, default: 0] += 1
        } else {
            let dir = self.directory
            let created = Task<URL, Error> {
                let tmp = dir.appendingPathComponent(".\(key).\(UUID().uuidString).tmp.caf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                let args: [String] = [
                    "-hide_banner", "-nostats", "-y",
                    "-ss", String(format: "%.6f", clip.sourceStart),
                    "-t", String(format: "%.6f", clip.sourceSpan),
                    "-i", asset.path,
                    "-vn",
                    "-af", AudioEffectFilterBuilder.chain(for: clip, sampleRate: projectRate, targetChannels: resolvedChannels),
                    "-ar", String(Int(projectRate)), "-ac", String(resolvedChannels),
                    "-c:a", "pcm_f32le", "-f", "caf", tmp.path
                ]
                try await AudioEditorFFmpeg.run(arguments: args)
                try Task.checkCancellation()
                return try self.commitRenderedProxy(tmp: tmp, destination: out)
            }
            inFlightTasks[key] = created
            inFlightWaiters[key] = 1
            task = created
        }

        defer { releaseWaiter(key: key) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.cancelWaiter(key: key) }
        }
    }

    private func commitRenderedProxy(tmp: URL, destination: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: destination)
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        evictIfNeeded(excluding: destination)
        return destination
    }

    private func cancelWaiter(key: String) {
        let count = inFlightWaiters[key] ?? 0
        if count <= 1 {
            inFlightTasks[key]?.cancel()
        }
    }

    private func releaseWaiter(key: String) {
        let remaining = (inFlightWaiters[key] ?? 1) - 1
        if remaining <= 0 {
            inFlightWaiters[key] = nil
            inFlightTasks[key] = nil
        } else {
            inFlightWaiters[key] = remaining
        }
    }

    func removeAll() {
        for (_, t) in inFlightTasks { t.cancel() }
        inFlightTasks.removeAll()
        inFlightWaiters.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    func currentBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func cachedFileCount() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        return files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension.lowercased() == "caf" }.count
    }

    private func evictIfNeeded(excluding protectedURL: URL? = nil) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        let protectedPath = protectedURL?.standardizedFileURL.path
        var entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  !url.lastPathComponent.hasPrefix(".") else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for e in entries where total > maxBytes {
            if let protectedPath, e.0.standardizedFileURL.path == protectedPath {
                continue
            }
            try? FileManager.default.removeItem(at: e.0)
            total -= e.1
        }
    }

    nonisolated static func cacheKey(
        clip: AudioClip,
        asset: AudioMediaReference,
        rate: Double,
        channelCount: Int = 2
    ) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var s = "v\(proxyVersion)|\(asset.path)|\(asset.contentSHA256 ?? "")|\(asset.fileSize)|\(asset.modificationTime)|"
        s += "\(Int(asset.sampleRate.rounded()))|\(asset.channels)|"
        s += "\(clip.sourceStartFrame)|\(clip.durationFrames)|\(clip.sourceSpanFrames)|"
        s += "\(clip.sourceRate.hz)|\(clip.projectRate.hz)|\(Int(rate.rounded()))|\(channelCount)|"
        s += "\(clip.isReversed)|\(clip.swapChannels)|\(clip.channelMode.rawValue)|\(clip.stretch)|"
        if let d = try? enc.encode(clip.effects) { s += String(decoding: d, as: UTF8.self) }
        s += "|"
        if let slotsData = try? enc.encode(clip.effectSlots) { s += String(decoding: slotsData, as: UTF8.self) }
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40).description
    }
}

// MARK: - Source resolution (project → readable audio files)

struct ResolvedClipSource: Sendable {
    let clipID: UUID
    let url: URL
    /// Frame in `url` that corresponds to clip-local time 0.
    let baseFrame: Int64
}

enum AudioSourceResolver {
    /// Builds the proxies needed for a project and returns readable sources by clip id.
    static func resolve(
        project: AudioEditorProject,
        onlyClips: Set<UUID>? = nil,
        targetChannels: Int = 2
    ) async throws -> [UUID: ResolvedClipSource] {
        var result: [UUID: ResolvedClipSource] = [:]
        for track in project.tracks {
            for clip in track.clips {
                if let only = onlyClips, !only.contains(clip.id) { continue }
                guard let asset = project.asset(clip.sourceAssetID) else { continue }
                try Task.checkCancellation()
                if ClipProxyCache.canReadDirectly(
                    clip: clip,
                    asset: asset,
                    projectRate: project.sampleRate,
                    targetChannels: targetChannels
                ) {
                    let directBase: Int64
                    if clip.sourceRate == project.projectSampleRate {
                        directBase = clip.sourceStartFrame
                    } else {
                        directBase = (try? SampleFrameTime.convertInt128(
                            Int128(clip.sourceStartFrame),
                            from: clip.sourceRate,
                            to: project.projectSampleRate
                        )) ?? Int64((clip.sourceStart * project.sampleRate).rounded())
                    }
                    result[clip.id] = ResolvedClipSource(clipID: clip.id, url: asset.url, baseFrame: directBase)
                } else {
                    let proxyChannels = (asset.channels > 2 && targetChannels > 2) ? targetChannels : 2
                    let url = try await ClipProxyCache.shared.proxyURL(
                        for: clip,
                        asset: asset,
                        projectRate: project.sampleRate,
                        targetChannels: proxyChannels
                    )
                    result[clip.id] = ResolvedClipSource(clipID: clip.id, url: url, baseFrame: 0)
                }
            }
        }
        return result
    }
}

// MARK: - Mixer (pull-based, single-threaded owner; used by realtime producer and offline export)

final class AudioMixSession: @unchecked Sendable {
    private struct Reader {
        let sourceURL: URL
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var nextFrame: Int64
        let channels: Int
        let rate: Double
    }

    private(set) var project: AudioEditorProject
    private var sources: [UUID: ResolvedClipSource]
    private var readers: [UUID: Reader] = [:]
    let sampleRate: Double
    private let chunkCapacity: AVAudioFrameCount = 8192

    // Pre-allocated single-owner scratch buffers (no heap allocations in real-time producer mix)
    private var trackScratchL: [Float]
    private var trackScratchR: [Float]
    private var clipScratchL: [Float]
    private var clipScratchR: [Float]
    private var multiTrackFlatScratch: [Float] = []
    private var multiClipFlatScratch: [Float] = []
    private var multiChannelPtrs: [UnsafeMutablePointer<Float>] = []
    private var clipProcessors: [UUID: AudioChainProcessor] = [:]
    private var trackProcessors: [UUID: AudioChainProcessor] = [:]
    private let masterProcessor: AudioChainProcessor

    /// Track filter for stem/track export (nil = all). When set, mute/solo are ignored for included tracks.
    var includedTrackIDs: Set<UUID>?
    var includedClipIDs: Set<UUID>?
    private(set) var peakL: Float = 0
    private(set) var peakR: Float = 0
    private(set) var gainReductionDB: Float = 0

    init(project: AudioEditorProject, sources: [UUID: ResolvedClipSource]) {
        self.project = project
        self.sources = sources
        self.sampleRate = project.sampleRate
        let cap = Int(chunkCapacity)
        self.trackScratchL = [Float](repeating: 0, count: cap)
        self.trackScratchR = [Float](repeating: 0, count: cap)
        self.clipScratchL = [Float](repeating: 0, count: cap)
        self.clipScratchR = [Float](repeating: 0, count: cap)
        self.masterProcessor = AudioChainProcessor(slots: project.masterEffects, sampleRate: project.sampleRate)
        syncProcessors(with: project)
    }

    func update(project: AudioEditorProject, sources: [UUID: ResolvedClipSource]) {
        self.project = project
        self.sources = sources
        for clipID in Array(readers.keys) {
            if let newSrc = sources[clipID], readers[clipID]?.sourceURL == newSrc.url {
                continue
            }
            readers[clipID] = nil
        }
        syncProcessors(with: project)
    }

    private func syncProcessors(with project: AudioEditorProject) {
        var activeTracks = Set<UUID>()
        var activeClips = Set<UUID>()
        for track in project.tracks {
            activeTracks.insert(track.id)
            if track.effectSlots.contains(where: \.isActive) {
                if let p = trackProcessors[track.id] {
                    p.sync(slots: track.effectSlots, sampleRate: sampleRate)
                } else {
                    trackProcessors[track.id] = AudioChainProcessor(slots: track.effectSlots, sampleRate: sampleRate)
                }
            }
            for clip in track.clips {
                activeClips.insert(clip.id)
                if clip.effectSlots.contains(where: \.isActive) {
                    if let p = clipProcessors[clip.id] {
                        p.sync(slots: clip.effectSlots, sampleRate: sampleRate)
                    } else {
                        clipProcessors[clip.id] = AudioChainProcessor(slots: clip.effectSlots, sampleRate: sampleRate)
                    }
                }
            }
        }
        for id in Array(trackProcessors.keys) where !activeTracks.contains(id) { trackProcessors[id] = nil }
        for id in Array(clipProcessors.keys) where !activeClips.contains(id) { clipProcessors[id] = nil }
        masterProcessor.sync(slots: project.masterEffects, sampleRate: sampleRate)
    }

    func resetEffectStates() {
        for p in clipProcessors.values { p.resetStates() }
        for p in trackProcessors.values { p.resetStates() }
        masterProcessor.resetStates()
        gainReductionDB = 0
    }

    func activeReaderURL(for clipID: UUID) -> URL? {
        readers[clipID]?.sourceURL
    }

    func resetPeaks() { peakL = 0; peakR = 0 }

    private func reader(for clipID: UUID) -> Reader? {
        if let r = readers[clipID] { return r }
        guard let src = sources[clipID], let file = try? AVAudioFile(forReading: src.url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkCapacity) else { return nil }
        let r = Reader(sourceURL: src.url, file: file, buffer: buf, nextFrame: -1, channels: Int(file.processingFormat.channelCount), rate: file.processingFormat.sampleRate)
        readers[clipID] = r
        return r
    }

    /// Mixes `frameCount` frames starting at timeline frame `startFrame` into `left`/`right` (overwrites).
    func mix(startFrame: Int64, frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard frameCount > 0 else { return }
        left.update(repeating: 0, count: frameCount)
        right.update(repeating: 0, count: frameCount)
        let n = min(frameCount, Int(chunkCapacity))
        let chunkEndFrame = startFrame + Int64(n)
        let projectRate = project.projectSampleRate
        var minGR: Float = 0.0

        for track in project.tracks {
            if let inc = includedTrackIDs { guard inc.contains(track.id) else { continue } }
            else if !project.isTrackAudible(track) { continue }
            let bal = AudioGainAutomation.balance(pan: track.pan)
            let trackVol = Float(track.volume)
            let trackGainL = trackVol * bal.l
            let trackGainR = trackVol * bal.r

            let hasActiveTrackFX = track.effectSlots.contains(where: \.isActive)
            trackScratchL.withUnsafeMutableBufferPointer { tLBuf in
                trackScratchR.withUnsafeMutableBufferPointer { tRBuf in
                    guard let tL = tLBuf.baseAddress, let tR = tRBuf.baseAddress else { return }
                    tL.update(repeating: 0, count: n)
                    tR.update(repeating: 0, count: n)

                    for clip in track.clips {
                        if clip.isMuted && includedClipIDs == nil { continue }
                        if let inc = includedClipIDs, !inc.contains(clip.id) { continue }
                        let (clipStart, clipEnd) = clipBoundsInProjectFrames(clip, projectRate: projectRate)
                        guard clipEnd > startFrame, clipStart < chunkEndFrame else { continue }

                        if clip.effectSlots.contains(where: \.isActive), let cProc = clipProcessors[clip.id] {
                            clipScratchL.withUnsafeMutableBufferPointer { cLBuf in
                                clipScratchR.withUnsafeMutableBufferPointer { cRBuf in
                                    guard let cL = cLBuf.baseAddress, let cR = cRBuf.baseAddress else { return }
                                    cL.update(repeating: 0, count: n)
                                    cR.update(repeating: 0, count: n)
                                    mixClip(
                                        track: track,
                                        clip: clip,
                                        clipStartFrame: clipStart,
                                        clipEndFrame: clipEnd,
                                        startFrame: startFrame,
                                        frameCount: n,
                                        trackGainL: 1.0,
                                        trackGainR: 1.0,
                                        left: cL,
                                        right: cR
                                    )
                                    cProc.process(slots: clip.effectSlots, left: cL, right: cR, frameCount: n)
                                    minGR = min(minGR, cProc.maxGainReductionDB)
                                    for i in 0..<n { tL[i] += cL[i]; tR[i] += cR[i] }
                                }
                            }
                        } else {
                            mixClip(
                                track: track,
                                clip: clip,
                                clipStartFrame: clipStart,
                                clipEndFrame: clipEnd,
                                startFrame: startFrame,
                                frameCount: n,
                                trackGainL: 1.0,
                                trackGainR: 1.0,
                                left: tL,
                                right: tR
                            )
                        }
                    }

                    if hasActiveTrackFX, let tProc = trackProcessors[track.id] {
                        tProc.process(slots: track.effectSlots, left: tL, right: tR, frameCount: n)
                        minGR = min(minGR, tProc.maxGainReductionDB)
                    }

                    for i in 0..<n {
                        left[i] += tL[i] * trackGainL
                        right[i] += tR[i] * trackGainR
                    }
                }
            }
        }

        if project.masterEffects.contains(where: \.isActive) {
            masterProcessor.process(slots: project.masterEffects, left: left, right: right, frameCount: n)
            minGR = min(minGR, masterProcessor.maxGainReductionDB)
        }
        gainReductionDB = minGR

        // Peak tracking
        var pl: Float = peakL, pr: Float = peakR
        for i in 0..<n {
            pl = max(pl, abs(left[i])); pr = max(pr, abs(right[i]))
        }
        peakL = pl; peakR = pr
    }

    /// Mixes `frameCount` frames starting at timeline time `startTime` into `left`/`right` (overwrites).
    func mix(startTime: TimeInterval, frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let startFrame = (try? SampleFrameMigration.secondsToFrames(
            startTime,
            sampleRate: project.projectSampleRate,
            field: "mix.startTime",
            allowNegative: true
        )) ?? Int64((startTime * sampleRate).rounded())
        mix(startFrame: startFrame, frameCount: frameCount, left: left, right: right)
    }

    /// Mixes arbitrary channel count (1, 2, or multichannel) starting at exact `startFrame`.
    func mixMultichannel(
        startFrame: Int64,
        frameCount: Int,
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int
    ) {
        guard channelCount > 0, frameCount > 0 else { return }
        if channelCount == 2 {
            mix(startFrame: startFrame, frameCount: frameCount, left: channels[0], right: channels[1])
            return
        }

        let n = min(frameCount, Int(chunkCapacity))
        let stride = Int(chunkCapacity)
        for ch in 0..<channelCount {
            channels[ch].update(repeating: 0, count: frameCount)
        }

        ensureMultiScratch(channelCount: channelCount, stride: stride)
        let chunkEndFrame = startFrame + Int64(n)
        let projectRate = project.projectSampleRate
        var minGR: Float = 0.0

        for track in project.tracks {
            if let inc = includedTrackIDs { guard inc.contains(track.id) else { continue } }
            else if !project.isTrackAudible(track) { continue }
            let bal = AudioGainAutomation.balance(pan: track.pan)
            let trackVol = Float(track.volume)
            let hasActiveTrackFX = track.effectSlots.contains(where: \.isActive)

            multiTrackFlatScratch.withUnsafeMutableBufferPointer { tFlatBuf in
                guard let tFlatBase = tFlatBuf.baseAddress else { return }
                for ch in 0..<channelCount {
                    tFlatBase.advanced(by: ch * stride).update(repeating: 0, count: n)
                }

                for clip in track.clips {
                    if clip.isMuted && includedClipIDs == nil { continue }
                    if let inc = includedClipIDs, !inc.contains(clip.id) { continue }
                    let (clipStart, clipEnd) = clipBoundsInProjectFrames(clip, projectRate: projectRate)
                    guard clipEnd > startFrame, clipStart < chunkEndFrame else { continue }

                    if clip.effectSlots.contains(where: \.isActive), let cProc = clipProcessors[clip.id] {
                        multiClipFlatScratch.withUnsafeMutableBufferPointer { cFlatBuf in
                            guard let cFlatBase = cFlatBuf.baseAddress else { return }
                            for ch in 0..<channelCount {
                                cFlatBase.advanced(by: ch * stride).update(repeating: 0, count: n)
                            }
                            mixClipMultichannel(
                                track: track,
                                clip: clip,
                                clipStartFrame: clipStart,
                                clipEndFrame: clipEnd,
                                startFrame: startFrame,
                                frameCount: n,
                                channelCount: channelCount,
                                stride: stride,
                                destBase: cFlatBase
                            )
                            prepareChannelPointers(base: cFlatBase, channelCount: channelCount, stride: stride)
                            multiChannelPtrs.withUnsafeBufferPointer { ptrBuf in
                                if let ptrs = ptrBuf.baseAddress {
                                    cProc.processMultichannel(slots: clip.effectSlots, channels: ptrs, channelCount: channelCount, frameCount: n)
                                }
                            }
                            minGR = min(minGR, cProc.maxGainReductionDB)
                            for ch in 0..<channelCount {
                                let dst = tFlatBase.advanced(by: ch * stride)
                                let src = cFlatBase.advanced(by: ch * stride)
                                for i in 0..<n { dst[i] += src[i] }
                            }
                        }
                    } else {
                        mixClipMultichannel(
                            track: track,
                            clip: clip,
                            clipStartFrame: clipStart,
                            clipEndFrame: clipEnd,
                            startFrame: startFrame,
                            frameCount: n,
                            channelCount: channelCount,
                            stride: stride,
                            destBase: tFlatBase
                        )
                    }
                }

                if hasActiveTrackFX, let tProc = trackProcessors[track.id] {
                    prepareChannelPointers(base: tFlatBase, channelCount: channelCount, stride: stride)
                    multiChannelPtrs.withUnsafeBufferPointer { ptrBuf in
                        if let ptrs = ptrBuf.baseAddress {
                            tProc.processMultichannel(slots: track.effectSlots, channels: ptrs, channelCount: channelCount, frameCount: n)
                        }
                    }
                    minGR = min(minGR, tProc.maxGainReductionDB)
                }

                for ch in 0..<channelCount {
                    let g: Float
                    if channelCount == 1 {
                        g = trackVol
                    } else if ch == 0 {
                        g = trackVol * bal.l
                    } else if ch == 1 {
                        g = trackVol * bal.r
                    } else {
                        g = trackVol
                    }
                    let src = tFlatBase.advanced(by: ch * stride)
                    let dst = channels[ch]
                    for i in 0..<n {
                        dst[i] += src[i] * g
                    }
                }
            }
        }

        if project.masterEffects.contains(where: \.isActive) {
            masterProcessor.processMultichannel(
                slots: project.masterEffects,
                channels: channels,
                channelCount: channelCount,
                frameCount: n
            )
            minGR = min(minGR, masterProcessor.maxGainReductionDB)
        }
        gainReductionDB = minGR

        var pl: Float = peakL, pr: Float = peakR
        for i in 0..<n {
            pl = max(pl, abs(channels[0][i]))
            let rVal = channelCount > 1 ? channels[1][i] : channels[0][i]
            pr = max(pr, abs(rVal))
        }
        peakL = pl; peakR = pr
    }

    private func ensureMultiScratch(channelCount: Int, stride: Int) {
        let needed = channelCount * stride
        if multiTrackFlatScratch.count < needed {
            multiTrackFlatScratch = [Float](repeating: 0, count: needed)
        }
        if multiClipFlatScratch.count < needed {
            multiClipFlatScratch = [Float](repeating: 0, count: needed)
        }
    }

    private func prepareChannelPointers(base: UnsafeMutablePointer<Float>, channelCount: Int, stride: Int) {
        multiChannelPtrs.removeAll(keepingCapacity: true)
        for ch in 0..<channelCount {
            multiChannelPtrs.append(base.advanced(by: ch * stride))
        }
    }

    private func clipBoundsInProjectFrames(_ clip: AudioClip, projectRate: SampleRate) -> (start: Int64, end: Int64) {
        if clip.projectRate == projectRate {
            return (clip.timelineStartFrame, clip.timelineEndFrame)
        }
        let s = (try? SampleFrameTime.convertInt128(Int128(clip.timelineStartFrame), from: clip.projectRate, to: projectRate))
            ?? clip.timelineStartFrame
        let d = (try? SampleFrameTime.convertInt128(Int128(clip.durationFrames), from: clip.projectRate, to: projectRate))
            ?? clip.durationFrames
        return (s, s + d)
    }

    private func mixClip(
        track: AudioTrack,
        clip: AudioClip,
        clipStartFrame: Int64,
        clipEndFrame: Int64,
        startFrame: Int64,
        frameCount: Int,
        trackGainL: Float,
        trackGainR: Float,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        guard clip.sourceAssetID != nil, var rd = reader(for: clip.id), let src = sources[clip.id] else { return }
        let chunkEndFrame = startFrame + Int64(frameCount)
        let overlapStart = max(startFrame, clipStartFrame)
        let overlapEnd = min(chunkEndFrame, clipEndFrame)
        let count = Int(overlapEnd - overlapStart)
        guard count > 0 else { return }

        let outStart = Int(overlapStart - startFrame)
        let localStartFrame = overlapStart - clipStartFrame
        let fileFrame = src.baseFrame + max(0, localStartFrame)
        guard fileFrame < rd.file.length else { return }

        let step = 32
        let projectRate = project.projectSampleRate
        var remaining = count
        var outIndex = outStart
        var position = fileFrame
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(remaining, Int(chunkCapacity)))
            if rd.nextFrame != position {
                rd.file.framePosition = position
            }
            rd.buffer.frameLength = 0
            do { try rd.file.read(into: rd.buffer, frameCount: toRead) } catch { break }
            let got = Int(rd.buffer.frameLength)
            if got == 0 { break }
            position += Int64(got)
            rd.nextFrame = position
            guard let data = rd.buffer.floatChannelData else { break }
            let l = data[0]
            let r = rd.channels > 1 ? data[1] : data[0]

            var i = 0
            while i < got {
                let n = min(step, got - i)
                let projFrame0 = startFrame + Int64(outIndex + i)
                let projFrame1 = projFrame0 + Int64(n)
                let clipFrame0: Int64
                let clipFrame1: Int64
                if clip.projectRate == projectRate {
                    clipFrame0 = projFrame0
                    clipFrame1 = projFrame1
                } else {
                    clipFrame0 = (try? SampleFrameTime.convertInt128(Int128(projFrame0), from: projectRate, to: clip.projectRate)) ?? projFrame0
                    clipFrame1 = (try? SampleFrameTime.convertInt128(Int128(projFrame1), from: projectRate, to: clip.projectRate)) ?? projFrame1
                }
                let g0 = Float(AudioGainAutomation.clipGain(track: track, clip: clip, atFrame: clipFrame0))
                let g1 = Float(AudioGainAutomation.clipGain(track: track, clip: clip, atFrame: clipFrame1))
                let inc = (g1 - g0) / Float(n)
                var g = g0
                for k in 0..<n {
                    left[outIndex + i + k] += l[i + k] * g * trackGainL
                    right[outIndex + i + k] += r[i + k] * g * trackGainR
                    g += inc
                }
                i += n
            }
            outIndex += got
            remaining -= got
        }
        readers[clip.id] = rd
    }

    private func mixClipMultichannel(
        track: AudioTrack,
        clip: AudioClip,
        clipStartFrame: Int64,
        clipEndFrame: Int64,
        startFrame: Int64,
        frameCount: Int,
        channelCount: Int,
        stride: Int,
        destBase: UnsafeMutablePointer<Float>
    ) {
        guard clip.sourceAssetID != nil, var rd = reader(for: clip.id), let src = sources[clip.id] else { return }
        let chunkEndFrame = startFrame + Int64(frameCount)
        let overlapStart = max(startFrame, clipStartFrame)
        let overlapEnd = min(chunkEndFrame, clipEndFrame)
        let count = Int(overlapEnd - overlapStart)
        guard count > 0 else { return }

        let outStart = Int(overlapStart - startFrame)
        let localStartFrame = overlapStart - clipStartFrame
        let fileFrame = src.baseFrame + max(0, localStartFrame)
        guard fileFrame < rd.file.length else { return }

        let step = 32
        let projectRate = project.projectSampleRate
        var remaining = count
        var outIndex = outStart
        var position = fileFrame
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(remaining, Int(chunkCapacity)))
            if rd.nextFrame != position {
                rd.file.framePosition = position
            }
            rd.buffer.frameLength = 0
            do { try rd.file.read(into: rd.buffer, frameCount: toRead) } catch { break }
            let got = Int(rd.buffer.frameLength)
            if got == 0 { break }
            position += Int64(got)
            rd.nextFrame = position
            guard let data = rd.buffer.floatChannelData else { break }

            var i = 0
            while i < got {
                let n = min(step, got - i)
                let projFrame0 = startFrame + Int64(outIndex + i)
                let projFrame1 = projFrame0 + Int64(n)
                let clipFrame0 = clip.projectRate == projectRate ? projFrame0
                    : ((try? SampleFrameTime.convertInt128(Int128(projFrame0), from: projectRate, to: clip.projectRate)) ?? projFrame0)
                let clipFrame1 = clip.projectRate == projectRate ? projFrame1
                    : ((try? SampleFrameTime.convertInt128(Int128(projFrame1), from: projectRate, to: clip.projectRate)) ?? projFrame1)
                let g0 = Float(AudioGainAutomation.clipGain(track: track, clip: clip, atFrame: clipFrame0))
                let g1 = Float(AudioGainAutomation.clipGain(track: track, clip: clip, atFrame: clipFrame1))
                let inc = (g1 - g0) / Float(n)

                if channelCount == 1 {
                    let lPtr = data[0]
                    let rPtr = rd.channels > 1 ? data[1] : nil
                    let dst = destBase
                    var g = g0
                    for k in 0..<n {
                        let sample: Float = rPtr != nil ? 0.5 * (lPtr[i + k] + rPtr![i + k]) : lPtr[i + k]
                        dst[outIndex + i + k] += sample * g
                        g += inc
                    }
                } else {
                    for ch in 0..<channelCount {
                        let chPtr: UnsafeMutablePointer<Float>?
                        if ch < rd.channels {
                            chPtr = data[ch]
                        } else if rd.channels == 1 {
                            chPtr = data[0]
                        } else {
                            chPtr = nil
                        }
                        guard let srcPtr = chPtr else { continue }
                        let dst = destBase.advanced(by: ch * stride)
                        var g = g0
                        for k in 0..<n {
                            dst[outIndex + i + k] += srcPtr[i + k] * g
                            g += inc
                        }
                    }
                }
                i += n
            }
            outIndex += got
            remaining -= got
        }
        readers[clip.id] = rd
    }
}

import Foundation

/// Clipboard payload: clips relative to the earliest copied clip start (stored in project sample frames).
struct AudioClipboardItem: Sendable, Equatable {
    var clip: AudioClip
    var trackOffset: Int
    var frameOffset: Int64

    var timeOffset: TimeInterval {
        get { SampleFrameMigration.framesToSeconds(frameOffset, sampleRate: clip.projectRate) }
        set {
            if let f = try? SampleFrameMigration.secondsToFrames(newValue, sampleRate: clip.projectRate, field: "clipboard.timeOffset", allowNegative: true) {
                frameOffset = f
            }
        }
    }

    init(clip: AudioClip, trackOffset: Int, frameOffset: Int64) {
        self.clip = clip
        self.trackOffset = trackOffset
        self.frameOffset = frameOffset
    }

    init(clip: AudioClip, trackOffset: Int, timeOffset: TimeInterval) {
        self.clip = clip
        self.trackOffset = trackOffset
        self.frameOffset = (try? SampleFrameMigration.secondsToFrames(timeOffset, sampleRate: clip.projectRate, field: "clipboard.timeOffset", allowNegative: true)) ?? 0
    }
}

/// Pure, sample-accurate value-based editing operations operating in checked `Int64` sample frames.
/// Locked clips/tracks are never modified. Zero-length ranges act as safe no-ops returning `false`.
/// None of these operations mutate source media files on disk.
enum AudioEditingService {

    // MARK: Lookup & Rate Helpers

    private static func locate(_ project: AudioEditorProject, clip id: UUID) -> (t: Int, c: Int)? {
        for (ti, t) in project.tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    private static func isEditable(_ project: AudioEditorProject, _ loc: (t: Int, c: Int)) -> Bool {
        !project.tracks[loc.t].isLocked && !project.tracks[loc.t].clips[loc.c].isLocked
    }

    private static func frameFromSeconds(_ seconds: TimeInterval, rate: SampleRate, allowNegative: Bool = false) -> Int64? {
        try? SampleFrameMigration.secondsToFrames(seconds, sampleRate: rate, field: "time", allowNegative: allowNegative)
    }

    private static func sourceAdvanceFrames(
        timelineFrames: Int64,
        stretch: Double,
        projectRate: SampleRate,
        sourceRate: SampleRate
    ) -> Int64 {
        guard timelineFrames > 0 else { return 0 }
        if abs(stretch - 1.0) <= 0.00001 {
            if sourceRate == projectRate {
                return timelineFrames
            }
            return (try? SampleFrameTime.convertInt128(Int128(timelineFrames), from: projectRate, to: sourceRate)) ?? timelineFrames
        }
        let sec = (Double(timelineFrames) / Double(projectRate.hz)) * stretch
        return (try? SampleFrameMigration.secondsToFrames(max(0, sec), sampleRate: sourceRate, field: "sourceAdvance")) ?? 0
    }

    // MARK: Split (Sample-Accurate)

    /// Splits one clip at an exact project timeline frame. Returns the ID of the new right-hand clip, or `nil` on boundary/no-op.
    @discardableResult
    static func split(_ project: inout AudioEditorProject, clipID: UUID, atFrame frame: Int64) -> UUID? {
        guard let loc = locate(project, clip: clipID), isEditable(project, loc) else { return nil }
        let c = project.tracks[loc.t].clips[loc.c]
        guard frame > c.timelineStartFrame, frame < c.timelineEndFrame else { return nil }

        let leftDurFrames = frame - c.timelineStartFrame
        let rightDurFrames = c.durationFrames - leftDurFrames
        guard leftDurFrames > 0, rightDurFrames > 0 else { return nil }

        var left = c
        var right = c
        right.id = UUID()
        left.durationFrames = leftDurFrames
        right.timelineStartFrame = frame
        right.durationFrames = rightDurFrames

        if c.isReversed {
            let rightSpan = sourceAdvanceFrames(
                timelineFrames: rightDurFrames,
                stretch: c.stretch,
                projectRate: c.projectRate,
                sourceRate: c.sourceRate
            )
            left.sourceStartFrame = c.sourceStartFrame + rightSpan
            right.sourceStartFrame = c.sourceStartFrame
        } else {
            let leftSpan = sourceAdvanceFrames(
                timelineFrames: leftDurFrames,
                stretch: c.stretch,
                projectRate: c.projectRate,
                sourceRate: c.sourceRate
            )
            right.sourceStartFrame = c.sourceStartFrame + leftSpan
        }

        left.fadeOutFrames = nil
        right.fadeInFrames = nil
        if let fi = c.fadeInFrames {
            left.fadeInFrames = ClipFadeSpecFrames(durationFrames: min(fi.durationFrames, leftDurFrames), curve: fi.curve)
        }
        if let fo = c.fadeOutFrames {
            right.fadeOutFrames = ClipFadeSpecFrames(durationFrames: min(fo.durationFrames, rightDurFrames), curve: fo.curve)
        }

        project.tracks[loc.t].clips[loc.c] = left
        project.tracks[loc.t].clips.insert(right, at: loc.c + 1)
        return right.id
    }

    /// Splits one clip at a timeline time (converted deterministically to project sample frames).
    @discardableResult
    static func split(_ project: inout AudioEditorProject, clipID: UUID, at time: TimeInterval) -> UUID? {
        guard let frame = frameFromSeconds(time, rate: project.projectSampleRate) else { return nil }
        return split(&project, clipID: clipID, atFrame: frame)
    }

    /// Splits every editable clip on the given tracks (all tracks if nil) that strictly spans `frame`.
    @discardableResult
    static func splitAll(_ project: inout AudioEditorProject, atFrame frame: Int64, trackIDs: Set<UUID>? = nil) -> Bool {
        var changed = false
        let ids = project.tracks
            .filter { trackIDs == nil || trackIDs!.contains($0.id) }
            .flatMap(\.clips)
            .filter { frame > $0.timelineStartFrame && frame < $0.timelineEndFrame }
            .map(\.id)
        for id in ids where split(&project, clipID: id, atFrame: frame) != nil {
            changed = true
        }
        return changed
    }

    @discardableResult
    static func splitAll(_ project: inout AudioEditorProject, at time: TimeInterval, trackIDs: Set<UUID>? = nil) -> Bool {
        guard let frame = frameFromSeconds(time, rate: project.projectSampleRate) else { return false }
        return splitAll(&project, atFrame: frame, trackIDs: trackIDs)
    }

    /// Splits editable clips at both selection edges. Zero-length ranges act as a safe no-op.
    @discardableResult
    static func splitAtSelection(_ project: inout AudioEditorProject, range: SampleFrameRange, trackIDs: Set<UUID>? = nil) -> Bool {
        guard !range.isEmpty,
              let aligned = try? range.converted(to: project.projectSampleRate),
              !aligned.isEmpty else {
            return false
        }
        let a = splitAll(&project, atFrame: aligned.startFrame, trackIDs: trackIDs)
        let b = splitAll(&project, atFrame: aligned.endFrame, trackIDs: trackIDs)
        return a || b
    }

    @discardableResult
    static func splitAtSelection(_ project: inout AudioEditorProject, range: ClosedRange<TimeInterval>, trackIDs: Set<UUID>? = nil) -> Bool {
        let rate = project.projectSampleRate
        guard let lo = frameFromSeconds(range.lowerBound, rate: rate),
              let hi = frameFromSeconds(range.upperBound, rate: rate),
              hi > lo,
              let frameRange = try? SampleFrameRange(startFrame: lo, frameCount: hi - lo, sampleRate: rate) else {
            return false
        }
        return splitAtSelection(&project, range: frameRange, trackIDs: trackIDs)
    }

    // MARK: Trim (Sample-Accurate)

    /// Keeps only the `[startFrame, endFrame)` portion of a clip in project frames.
    /// Zero-length ranges and empty intersections act as safe no-ops returning `false`.
    @discardableResult
    static func trimClip(_ project: inout AudioEditorProject, clipID: UUID, to range: SampleFrameRange) -> Bool {
        guard !range.isEmpty,
              let loc = locate(project, clip: clipID),
              isEditable(project, loc),
              let aligned = try? range.converted(to: project.projectSampleRate),
              !aligned.isEmpty else {
            return false
        }
        var c = project.tracks[loc.t].clips[loc.c]
        let lo = max(aligned.startFrame, c.timelineStartFrame)
        let hi = min(aligned.endFrame, c.timelineEndFrame)
        guard hi > lo else { return false }

        let leftCut = lo - c.timelineStartFrame
        let rightCut = c.timelineEndFrame - hi
        guard leftCut > 0 || rightCut > 0 else { return false }

        if c.isReversed {
            c.sourceStartFrame += sourceAdvanceFrames(
                timelineFrames: rightCut,
                stretch: c.stretch,
                projectRate: c.projectRate,
                sourceRate: c.sourceRate
            )
        } else {
            c.sourceStartFrame += sourceAdvanceFrames(
                timelineFrames: leftCut,
                stretch: c.stretch,
                projectRate: c.projectRate,
                sourceRate: c.sourceRate
            )
        }
        c.timelineStartFrame = lo
        c.durationFrames = hi - lo

        if let fi = c.fadeInFrames {
            c.fadeInFrames = ClipFadeSpecFrames(durationFrames: min(fi.durationFrames, c.durationFrames), curve: fi.curve)
        }
        if let fo = c.fadeOutFrames {
            c.fadeOutFrames = ClipFadeSpecFrames(durationFrames: min(fo.durationFrames, c.durationFrames), curve: fo.curve)
        }
        if leftCut > 0 { c.fadeInFrames = nil }
        if rightCut > 0 { c.fadeOutFrames = nil }

        project.tracks[loc.t].clips[loc.c] = c
        return true
    }

    @discardableResult
    static func trimClip(_ project: inout AudioEditorProject, clipID: UUID, to range: ClosedRange<TimeInterval>) -> Bool {
        let rate = project.projectSampleRate
        guard let lo = frameFromSeconds(range.lowerBound, rate: rate),
              let hi = frameFromSeconds(range.upperBound, rate: rate),
              hi > lo,
              let frameRange = try? SampleFrameRange(startFrame: lo, frameCount: hi - lo, sampleRate: rate) else {
            return false
        }
        return trimClip(&project, clipID: clipID, to: frameRange)
    }

    /// Trims clip edges via handle drags using exact project sample frames (minimum 1 frame).
    @discardableResult
    static func trimEdges(
        _ project: inout AudioEditorProject,
        clipID: UUID,
        newStartFrame: Int64,
        newEndFrame: Int64,
        sourceDurationFrames: Int64?
    ) -> Bool {
        guard let loc = locate(project, clip: clipID), isEditable(project, loc) else { return false }
        let c = project.tracks[loc.t].clips[loc.c]
        let minDurationFrames = max(1, Int64(c.projectRate.hz / 100))
        var s = max(0, newStartFrame)
        var e = max(newEndFrame, s + minDurationFrames)

        if let sdFrames = sourceDurationFrames, sdFrames > 0, c.sourceAssetID != nil {
            let maxAvailSourceTimeline: Int64
            let consumedSourceTimeline: Int64
            if abs(c.stretch - 1.0) <= 0.00001 && c.sourceRate == c.projectRate {
                maxAvailSourceTimeline = sdFrames
                consumedSourceTimeline = c.sourceStartFrame
            } else {
                let sdProj = (try? SampleFrameTime.convertInt128(Int128(sdFrames), from: c.sourceRate, to: c.projectRate)) ?? sdFrames
                let ssProj = (try? SampleFrameTime.convertInt128(Int128(c.sourceStartFrame), from: c.sourceRate, to: c.projectRate)) ?? c.sourceStartFrame
                maxAvailSourceTimeline = Int64(Double(sdProj) / c.stretch)
                consumedSourceTimeline = Int64(Double(ssProj) / c.stretch)
            }

            if c.isReversed {
                let minStart = c.timelineEndFrame - max(0, maxAvailSourceTimeline - consumedSourceTimeline)
                s = max(0, max(s, minStart))
                let maxEnd = c.timelineEndFrame + consumedSourceTimeline
                e = min(e, maxEnd)
            } else {
                let minStart = c.timelineStartFrame - consumedSourceTimeline
                s = max(0, max(s, minStart))
                let maxEnd = c.timelineStartFrame + max(0, maxAvailSourceTimeline - consumedSourceTimeline)
                e = min(e, maxEnd)
            }
        }

        guard e - s >= minDurationFrames else { return false }
        var out = c
        if c.isReversed {
            let deltaTimeline = max(0, c.timelineEndFrame - e)
            out.sourceStartFrame = max(0, c.sourceStartFrame + sourceAdvanceFrames(
                timelineFrames: deltaTimeline,
                stretch: c.stretch,
                projectRate: c.projectRate,
                sourceRate: c.sourceRate
            ))
        } else {
            let deltaTimeline = s - c.timelineStartFrame
            if deltaTimeline >= 0 {
                out.sourceStartFrame = c.sourceStartFrame + sourceAdvanceFrames(
                    timelineFrames: deltaTimeline,
                    stretch: c.stretch,
                    projectRate: c.projectRate,
                    sourceRate: c.sourceRate
                )
            } else {
                let rewind = sourceAdvanceFrames(
                    timelineFrames: -deltaTimeline,
                    stretch: c.stretch,
                    projectRate: c.projectRate,
                    sourceRate: c.sourceRate
                )
                out.sourceStartFrame = max(0, c.sourceStartFrame - rewind)
            }
        }

        out.timelineStartFrame = s
        out.durationFrames = e - s
        if let fi = out.fadeInFrames {
            out.fadeInFrames = ClipFadeSpecFrames(durationFrames: min(fi.durationFrames, out.durationFrames), curve: fi.curve)
        }
        if let fo = out.fadeOutFrames {
            out.fadeOutFrames = ClipFadeSpecFrames(durationFrames: min(fo.durationFrames, out.durationFrames), curve: fo.curve)
        }
        project.tracks[loc.t].clips[loc.c] = out
        return true
    }

    @discardableResult
    static func trimEdges(
        _ project: inout AudioEditorProject,
        clipID: UUID,
        newStart: TimeInterval,
        newEnd: TimeInterval,
        sourceDuration: TimeInterval?
    ) -> Bool {
        let rate = project.projectSampleRate
        guard let loc = locate(project, clip: clipID) else { return false }
        let clip = project.tracks[loc.t].clips[loc.c]
        guard let ns = frameFromSeconds(max(0, newStart), rate: rate),
              let ne = frameFromSeconds(max(0, newEnd), rate: rate) else {
            return false
        }
        let sdFrames = sourceDuration.flatMap { try? SampleFrameMigration.secondsToFrames(max(0, $0), sampleRate: clip.sourceRate, field: "sourceDuration") }
        return trimEdges(&project, clipID: clipID, newStartFrame: ns, newEndFrame: ne, sourceDurationFrames: sdFrames)
    }

    /// Deletes everything outside `range` on the given tracks (all tracks if `nil`). Zero-length ranges act as no-ops.
    @discardableResult
    static func trimToSelection(_ project: inout AudioEditorProject, range: SampleFrameRange, trackIDs: Set<UUID>? = nil) -> Bool {
        guard !range.isEmpty,
              let aligned = try? range.converted(to: project.projectSampleRate),
              !aligned.isEmpty else {
            return false
        }
        var changed = false
        for ti in project.tracks.indices {
            guard trackIDs == nil || trackIDs!.contains(project.tracks[ti].id), !project.tracks[ti].isLocked else { continue }
            let ids = project.tracks[ti].clips.map(\.id)
            for id in ids {
                guard let loc = locate(project, clip: id), !project.tracks[loc.t].clips[loc.c].isLocked else { continue }
                let c = project.tracks[loc.t].clips[loc.c]
                if c.timelineEndFrame <= aligned.startFrame || c.timelineStartFrame >= aligned.endFrame {
                    project.tracks[loc.t].clips.remove(at: loc.c)
                    changed = true
                } else if c.timelineStartFrame < aligned.startFrame || c.timelineEndFrame > aligned.endFrame {
                    if trimClip(&project, clipID: id, to: aligned) {
                        changed = true
                    }
                }
            }
        }
        return changed
    }

    @discardableResult
    static func trimToSelection(_ project: inout AudioEditorProject, range: ClosedRange<TimeInterval>, trackIDs: Set<UUID>? = nil) -> Bool {
        let rate = project.projectSampleRate
        guard let lo = frameFromSeconds(range.lowerBound, rate: rate),
              let hi = frameFromSeconds(range.upperBound, rate: rate),
              hi > lo,
              let frameRange = try? SampleFrameRange(startFrame: lo, frameCount: hi - lo, sampleRate: rate) else {
            return false
        }
        return trimToSelection(&project, range: frameRange, trackIDs: trackIDs)
    }

    // MARK: Delete / Ripple Delete / Cut

    @discardableResult
    static func deleteClips(_ project: inout AudioEditorProject, ids: Set<UUID>, ripple: Bool) -> Bool {
        guard !ids.isEmpty else { return false }
        var changed = false
        for ti in project.tracks.indices where !project.tracks[ti].isLocked {
            let removed = project.tracks[ti].clips.filter { ids.contains($0.id) && !$0.isLocked }
            guard !removed.isEmpty else { continue }
            project.tracks[ti].clips.removeAll { ids.contains($0.id) && !$0.isLocked }
            changed = true
            if ripple {
                // Close each gap from latest to earliest in exact integer frames.
                for r in removed.sorted(by: { $0.timelineStartFrame > $1.timelineStartFrame }) {
                    for ci in project.tracks[ti].clips.indices
                    where project.tracks[ti].clips[ci].timelineStartFrame >= r.timelineEndFrame && !project.tracks[ti].clips[ci].isLocked {
                        project.tracks[ti].clips[ci].timelineStartFrame = max(0, project.tracks[ti].clips[ci].timelineStartFrame - r.durationFrames)
                    }
                }
            }
        }
        return changed
    }

    /// Removes a sample-frame range from editable tracks, optionally rippling later clips left by exact frame count.
    /// Zero-length ranges act as a safe no-op returning `false`.
    @discardableResult
    static func deleteRange(
        _ project: inout AudioEditorProject,
        range: SampleFrameRange,
        trackIDs: Set<UUID>? = nil,
        ripple: Bool
    ) -> Bool {
        guard !range.isEmpty,
              let aligned = try? range.converted(to: project.projectSampleRate),
              !aligned.isEmpty else {
            return false
        }
        let len = aligned.frameCount
        var changed = splitAtSelection(&project, range: aligned, trackIDs: trackIDs)
        for ti in project.tracks.indices {
            guard trackIDs == nil || trackIDs!.contains(project.tracks[ti].id), !project.tracks[ti].isLocked else { continue }
            let before = project.tracks[ti].clips.count
            project.tracks[ti].clips.removeAll {
                !$0.isLocked && $0.timelineStartFrame >= aligned.startFrame && $0.timelineEndFrame <= aligned.endFrame
            }
            if project.tracks[ti].clips.count != before { changed = true }
            if ripple {
                for ci in project.tracks[ti].clips.indices
                where project.tracks[ti].clips[ci].timelineStartFrame >= aligned.endFrame && !project.tracks[ti].clips[ci].isLocked {
                    project.tracks[ti].clips[ci].timelineStartFrame = max(0, project.tracks[ti].clips[ci].timelineStartFrame - len)
                    changed = true
                }
            }
        }
        return changed
    }

    @discardableResult
    static func deleteRange(
        _ project: inout AudioEditorProject,
        range: ClosedRange<TimeInterval>,
        trackIDs: Set<UUID>? = nil,
        ripple: Bool
    ) -> Bool {
        let rate = project.projectSampleRate
        guard let lo = frameFromSeconds(range.lowerBound, rate: rate),
              let hi = frameFromSeconds(range.upperBound, rate: rate),
              hi > lo,
              let frameRange = try? SampleFrameRange(startFrame: lo, frameCount: hi - lo, sampleRate: rate) else {
            return false
        }
        return deleteRange(&project, range: frameRange, trackIDs: trackIDs, ripple: ripple)
    }

    /// Copies selected unlocked clips to clipboard payload and removes them from the project.
    static func cut(_ project: inout AudioEditorProject, ids: Set<UUID>, ripple: Bool = false) -> [AudioClipboardItem] {
        guard !ids.isEmpty else { return [] }
        let editableIDs = Set(project.tracks.filter { !$0.isLocked }.flatMap(\.clips).filter { ids.contains($0.id) && !$0.isLocked }.map(\.id))
        guard !editableIDs.isEmpty else { return [] }
        let copied = copy(project, ids: editableIDs)
        _ = deleteClips(&project, ids: editableIDs, ripple: ripple)
        return copied
    }

    /// Splits at `range`, copies editable slices strictly inside `range`, and removes them.
    static func cut(
        _ project: inout AudioEditorProject,
        range: SampleFrameRange,
        trackIDs: Set<UUID>? = nil,
        ripple: Bool = false
    ) -> [AudioClipboardItem] {
        guard !range.isEmpty,
              let aligned = try? range.converted(to: project.projectSampleRate),
              !aligned.isEmpty else {
            return []
        }
        _ = splitAtSelection(&project, range: aligned, trackIDs: trackIDs)
        var targetIDs = Set<UUID>()
        for track in project.tracks where (trackIDs == nil || trackIDs!.contains(track.id)) && !track.isLocked {
            for clip in track.clips where !clip.isLocked && clip.timelineStartFrame >= aligned.startFrame && clip.timelineEndFrame <= aligned.endFrame {
                targetIDs.insert(clip.id)
            }
        }
        guard !targetIDs.isEmpty else { return [] }
        let copied = copy(project, ids: targetIDs)
        _ = deleteRange(&project, range: aligned, trackIDs: trackIDs, ripple: ripple)
        return copied
    }

    // MARK: Move / Nudge / Duplicate

    @discardableResult
    static func moveClip(_ project: inout AudioEditorProject, clipID: UUID, toStartFrame frame: Int64, toTrack: UUID? = nil) -> Bool {
        guard let loc = locate(project, clip: clipID), isEditable(project, loc) else { return false }
        var c = project.tracks[loc.t].clips[loc.c]
        c.timelineStartFrame = max(0, frame)
        if let dest = toTrack, let di = project.tracks.firstIndex(where: { $0.id == dest }), di != loc.t {
            guard !project.tracks[di].isLocked else { return false }
            project.tracks[loc.t].clips.remove(at: loc.c)
            project.tracks[di].clips.append(c)
        } else {
            project.tracks[loc.t].clips[loc.c] = c
        }
        return true
    }

    @discardableResult
    static func moveClip(_ project: inout AudioEditorProject, clipID: UUID, toStart: TimeInterval, toTrack: UUID? = nil) -> Bool {
        guard let frame = frameFromSeconds(max(0, toStart), rate: project.projectSampleRate) else { return false }
        return moveClip(&project, clipID: clipID, toStartFrame: frame, toTrack: toTrack)
    }

    @discardableResult
    static func nudge(_ project: inout AudioEditorProject, ids: Set<UUID>, byFrames deltaFrames: Int64) -> Bool {
        guard deltaFrames != 0 else { return false }
        var changed = false
        for id in ids {
            if let loc = locate(project, clip: id), isEditable(project, loc) {
                let s = project.tracks[loc.t].clips[loc.c].timelineStartFrame
                let (sum, ov) = s.addingReportingOverflow(deltaFrames)
                let clamped = ov ? (deltaFrames > 0 ? Int64.max : 0) : max(0, sum)
                if clamped != s {
                    project.tracks[loc.t].clips[loc.c].timelineStartFrame = clamped
                    changed = true
                }
            }
        }
        return changed
    }

    @discardableResult
    static func nudge(_ project: inout AudioEditorProject, ids: Set<UUID>, by delta: TimeInterval) -> Bool {
        guard let deltaFrames = frameFromSeconds(delta, rate: project.projectSampleRate, allowNegative: true) else { return false }
        return nudge(&project, ids: ids, byFrames: deltaFrames)
    }

    @discardableResult
    static func duplicate(_ project: inout AudioEditorProject, ids: Set<UUID>) -> [UUID] {
        var newIDs: [UUID] = []
        for ti in project.tracks.indices where !project.tracks[ti].isLocked {
            for c in project.tracks[ti].clips where ids.contains(c.id) {
                var d = c
                d.id = UUID()
                d.timelineStartFrame = c.timelineEndFrame
                d.isLocked = false
                project.tracks[ti].clips.append(d)
                newIDs.append(d.id)
            }
        }
        return newIDs
    }

    // MARK: Clipboard

    static func copy(_ project: AudioEditorProject, ids: Set<UUID>) -> [AudioClipboardItem] {
        var items: [(Int, AudioClip)] = []
        for (ti, t) in project.tracks.enumerated() {
            for c in t.clips where ids.contains(c.id) { items.append((ti, c)) }
        }
        guard let firstStart = items.map({ $0.1.timelineStartFrame }).min(),
              let firstTrack = items.map({ $0.0 }).min() else {
            return []
        }
        return items.map { AudioClipboardItem(clip: $0.1, trackOffset: $0.0 - firstTrack, frameOffset: $0.1.timelineStartFrame - firstStart) }
    }

    @discardableResult
    static func paste(_ project: inout AudioEditorProject, items: [AudioClipboardItem], atFrame frame: Int64, startTrackIndex: Int) -> [UUID] {
        guard !items.isEmpty, !project.tracks.isEmpty else { return [] }
        let targetRate = project.projectSampleRate
        var ids: [UUID] = []
        for item in items {
            let ti = min(project.tracks.count - 1, max(0, startTrackIndex + item.trackOffset))
            guard !project.tracks[ti].isLocked else { continue }
            var c = item.clip
            c.id = UUID()
            c.isLocked = false
            let alignedOffset: Int64
            if c.projectRate == targetRate {
                alignedOffset = item.frameOffset
            } else {
                alignedOffset = (try? SampleFrameTime.convertInt128(Int128(item.frameOffset), from: c.projectRate, to: targetRate)) ?? item.frameOffset
                c.durationFrames = (try? SampleFrameTime.convertInt128(Int128(c.durationFrames), from: c.projectRate, to: targetRate)) ?? c.durationFrames
                c.projectRate = targetRate
            }
            let (destStart, ov) = max(0, frame).addingReportingOverflow(alignedOffset)
            c.timelineStartFrame = ov ? Int64.max : max(0, destStart)
            project.tracks[ti].clips.append(c)
            ids.append(c.id)
        }
        return ids
    }

    @discardableResult
    static func paste(_ project: inout AudioEditorProject, items: [AudioClipboardItem], at time: TimeInterval, startTrackIndex: Int) -> [UUID] {
        guard let frame = frameFromSeconds(max(0, time), rate: project.projectSampleRate) else { return [] }
        return paste(&project, items: items, atFrame: frame, startTrackIndex: startTrackIndex)
    }

    // MARK: Silence / Join (Sample-Adjacent Heal)

    @discardableResult
    static func insertSilence(_ project: inout AudioEditorProject, trackID: UUID, atFrame frame: Int64, durationFrames: Int64) -> UUID? {
        guard durationFrames > 0,
              let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              !project.tracks[ti].isLocked else {
            return nil
        }
        let c = AudioClip(
            sourceAssetID: nil,
            name: "Silence",
            timelineStartFrame: max(0, frame),
            sourceStartFrame: 0,
            durationFrames: durationFrames,
            projectRate: project.projectSampleRate,
            sourceRate: project.projectSampleRate
        )
        project.tracks[ti].clips.append(c)
        return c.id
    }

    @discardableResult
    static func insertSilence(_ project: inout AudioEditorProject, trackID: UUID, at time: TimeInterval, duration: TimeInterval) -> UUID? {
        let rate = project.projectSampleRate
        guard let startF = frameFromSeconds(max(0, time), rate: rate),
              let durF = frameFromSeconds(max(0, duration), rate: rate),
              durF > 0 else {
            return nil
        }
        return insertSilence(&project, trackID: trackID, atFrame: startF, durationFrames: durF)
    }

    /// Heals exact sample-adjacent clips (`a.timelineEndFrame == b.timelineStartFrame` and contiguous source frames)
    /// into single non-destructive clips with zero drift. Returns the number of joins performed.
    @discardableResult
    static func join(_ project: inout AudioEditorProject, ids: Set<UUID>) -> Int {
        var merges = 0
        for ti in project.tracks.indices where !project.tracks[ti].isLocked {
            var clips = project.tracks[ti].clips.sorted { $0.timelineStartFrame < $1.timelineStartFrame }
            var i = 0
            while i < clips.count - 1 {
                let a = clips[i], b = clips[i + 1]
                if ids.contains(a.id), ids.contains(b.id), !a.isLocked, !b.isLocked,
                   a.sourceAssetID == b.sourceAssetID,
                   a.projectRate == b.projectRate,
                   a.sourceRate == b.sourceRate,
                   a.isReversed == b.isReversed,
                   a.gainDB == b.gainDB,
                   a.effects == b.effects,
                   a.effectSlots == b.effectSlots,
                   a.channelMode == b.channelMode,
                   a.swapChannels == b.swapChannels,
                   a.isMuted == b.isMuted,
                   a.timelineEndFrame == b.timelineStartFrame,
                   (a.sourceAssetID == nil || contiguousSourceFrames(a, b)) {
                    var m = a
                    let (sumDur, ov) = a.durationFrames.addingReportingOverflow(b.durationFrames)
                    guard !ov else {
                        i += 1
                        continue
                    }
                    m.durationFrames = sumDur
                    if a.isReversed { m.sourceStartFrame = b.sourceStartFrame }
                    m.fadeOutFrames = b.fadeOutFrames
                    clips[i] = m
                    clips.remove(at: i + 1)
                    merges += 1
                } else {
                    i += 1
                }
            }
            project.tracks[ti].clips = clips
        }
        return merges
    }

    /// Backward-compatible alias for `join(_:ids:)`.
    @discardableResult
    static func consolidate(_ project: inout AudioEditorProject, ids: Set<UUID>) -> Int {
        join(&project, ids: ids)
    }

    private static func contiguousSourceFrames(_ a: AudioClip, _ b: AudioClip) -> Bool {
        if a.isReversed {
            return b.sourceStartFrame + b.sourceSpanFrames == a.sourceStartFrame
        }
        return a.sourceStartFrame + a.sourceSpanFrames == b.sourceStartFrame
    }

    // MARK: Tracks / Import / Clip Attributes

    @discardableResult
    static func addTrack(_ project: inout AudioEditorProject, name: String? = nil) -> UUID {
        let t = AudioTrack(name: name ?? "Track \(project.tracks.count + 1)")
        project.tracks.append(t)
        return t.id
    }

    @discardableResult
    static func removeTrack(_ project: inout AudioEditorProject, trackID: UUID) -> Bool {
        guard let i = project.tracks.firstIndex(where: { $0.id == trackID }), !project.tracks[i].isLocked else { return false }
        project.tracks.remove(at: i)
        return true
    }

    @discardableResult
    static func moveTrack(_ project: inout AudioEditorProject, from: Int, to: Int) -> Bool {
        guard project.tracks.indices.contains(from), to >= 0, to < project.tracks.count, from != to else { return false }
        let t = project.tracks.remove(at: from)
        project.tracks.insert(t, at: to)
        return true
    }

    @discardableResult
    static func addClip(_ project: inout AudioEditorProject, asset: AudioMediaReference, trackID: UUID, atFrame frame: Int64) -> UUID? {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }), !project.tracks[ti].isLocked else { return nil }
        if !project.mediaAssets.contains(where: { $0.id == asset.id }) { project.mediaAssets.append(asset) }

        let projRate = project.projectSampleRate
        let srcRate = (try? SampleFrameMigration.validatedSampleRate(asset.sampleRate)) ?? projRate
        let durFrames: Int64
        if let assetFrames = asset.durationFrames, assetFrames > 0 {
            durFrames = (try? SampleFrameTime.convertInt128(Int128(assetFrames), from: srcRate, to: projRate)) ?? assetFrames
        } else {
            durFrames = max(1, (try? SampleFrameMigration.secondsToFrames(max(0.01, asset.duration), sampleRate: projRate, field: "asset.duration")) ?? Int64(projRate.hz / 100))
        }

        let c = AudioClip(
            sourceAssetID: asset.id,
            name: asset.displayName,
            timelineStartFrame: max(0, frame),
            sourceStartFrame: 0,
            durationFrames: durFrames,
            projectRate: projRate,
            sourceRate: srcRate
        )
        project.tracks[ti].clips.append(c)
        return c.id
    }

    @discardableResult
    static func addClip(_ project: inout AudioEditorProject, asset: AudioMediaReference, trackID: UUID, at time: TimeInterval) -> UUID? {
        guard let frame = frameFromSeconds(max(0, time), rate: project.projectSampleRate) else { return nil }
        return addClip(&project, asset: asset, trackID: trackID, atFrame: frame)
    }

    /// Replaces a clip's source audio with another asset, keeping its timeline slot and processing.
    @discardableResult
    static func replaceClip(_ project: inout AudioEditorProject, clipID: UUID, with asset: AudioMediaReference) -> Bool {
        guard let loc = locate(project, clip: clipID), isEditable(project, loc) else { return false }
        if !project.mediaAssets.contains(where: { $0.id == asset.id }) { project.mediaAssets.append(asset) }
        var c = project.tracks[loc.t].clips[loc.c]
        let srcRate = (try? SampleFrameMigration.validatedSampleRate(asset.sampleRate)) ?? project.projectSampleRate
        let availProjFrames: Int64
        if let assetFrames = asset.durationFrames, assetFrames > 0 {
            availProjFrames = (try? SampleFrameTime.convertInt128(Int128(assetFrames), from: srcRate, to: c.projectRate)) ?? assetFrames
        } else {
            availProjFrames = max(1, (try? SampleFrameMigration.secondsToFrames(max(0.01, asset.duration / c.stretch), sampleRate: c.projectRate, field: "asset.duration")) ?? 1)
        }
        c.sourceAssetID = asset.id
        c.name = asset.displayName
        c.sourceStartFrame = 0
        c.sourceRate = srcRate
        c.durationFrames = min(c.durationFrames, max(1, availProjFrames))
        project.tracks[loc.t].clips[loc.c] = c
        return true
    }

    /// Removes unreferenced media references.
    static func pruneUnusedAssets(_ project: inout AudioEditorProject) {
        let used = Set(project.tracks.flatMap(\.clips).compactMap(\.sourceAssetID))
        project.mediaAssets.removeAll { !used.contains($0.id) }
    }

    // MARK: Clip Property Mutation & Typed Operations

    @discardableResult
    static func mutateClip(_ project: inout AudioEditorProject, clipID: UUID, allowWhenLocked: Bool = false, _ body: (inout AudioClip) -> Void) -> Bool {
        guard let loc = locate(project, clip: clipID) else { return false }
        if !allowWhenLocked && !isEditable(project, loc) { return false }
        body(&project.tracks[loc.t].clips[loc.c])
        return true
    }

    @discardableResult
    static func setGain(_ project: inout AudioEditorProject, clipID: UUID, gainDB: Double) -> Bool {
        guard gainDB.isFinite else { return false }
        return mutateClip(&project, clipID: clipID) { clip in
            clip.gainDB = min(24.0, max(-36.0, gainDB))
        }
    }

    @discardableResult
    static func setFadeIn(_ project: inout AudioEditorProject, clipID: UUID, fade: ClipFadeSpecFrames?) -> Bool {
        mutateClip(&project, clipID: clipID) { clip in
            if let fade, fade.durationFrames > 0 {
                clip.fadeInFrames = ClipFadeSpecFrames(durationFrames: min(fade.durationFrames, clip.durationFrames), curve: fade.curve)
            } else {
                clip.fadeInFrames = nil
            }
        }
    }

    @discardableResult
    static func setFadeOut(_ project: inout AudioEditorProject, clipID: UUID, fade: ClipFadeSpecFrames?) -> Bool {
        mutateClip(&project, clipID: clipID) { clip in
            if let fade, fade.durationFrames > 0 {
                clip.fadeOutFrames = ClipFadeSpecFrames(durationFrames: min(fade.durationFrames, clip.durationFrames), curve: fade.curve)
            } else {
                clip.fadeOutFrames = nil
            }
        }
    }

    @discardableResult
    static func setChannelMode(
        _ project: inout AudioEditorProject,
        clipID: UUID,
        mode: AudioEditorChannelMode,
        swapChannels: Bool? = nil
    ) -> Bool {
        mutateClip(&project, clipID: clipID) { clip in
            clip.channelMode = mode
            if let swapChannels {
                clip.swapChannels = swapChannels
            }
        }
    }

    // MARK: Crossfade Between Adjacent / Overlapping Clips

    @discardableResult
    static func applyCrossfade(
        _ project: inout AudioEditorProject,
        leftClipID: UUID,
        rightClipID: UUID,
        duration: TimeInterval,
        curve: ClipFadeCurve = .equalPower
    ) -> Bool {
        guard leftClipID != rightClipID,
              let locL = locate(project, clip: leftClipID),
              let locR = locate(project, clip: rightClipID),
              locL.t == locR.t,
              isEditable(project, locL), isEditable(project, locR) else {
            return false
        }
        let ti = locL.t
        let leftClip = project.tracks[ti].clips[locL.c]
        var rightClip = project.tracks[ti].clips[locR.c]

        guard leftClip.timelineStartFrame <= rightClip.timelineStartFrame else {
            return applyCrossfade(&project, leftClipID: rightClipID, rightClipID: leftClipID, duration: duration, curve: curve)
        }

        guard let targetFrames = frameFromSeconds(max(0.02, duration), rate: project.projectSampleRate) else { return false }
        let minAllowed = max(Int64(1), Int64(project.projectSampleRate.hz / 100))
        let maxAllowed = max(minAllowed, min((leftClip.durationFrames * 48) / 100, (rightClip.durationFrames * 48) / 100))
        let targetOverlap = min(maxAllowed, max(minAllowed, targetFrames))
        let desiredRightStart = max(0, leftClip.timelineEndFrame - targetOverlap)
        rightClip.timelineStartFrame = desiredRightStart
        rightClip.crossfadeCurve = curve
        project.tracks[ti].clips[locR.c] = rightClip
        return true
    }

    @discardableResult
    static func applyCrossfadeNearClip(
        _ project: inout AudioEditorProject,
        clipID: UUID,
        duration: TimeInterval,
        curve: ClipFadeCurve = .equalPower
    ) -> Bool {
        guard let loc = locate(project, clip: clipID) else { return false }
        let trackClips = project.tracks[loc.t].clips.sorted { $0.timelineStartFrame < $1.timelineStartFrame }
        guard let sortedIdx = trackClips.firstIndex(where: { $0.id == clipID }) else { return false }
        if sortedIdx > 0 {
            let prev = trackClips[sortedIdx - 1]
            return applyCrossfade(&project, leftClipID: prev.id, rightClipID: clipID, duration: duration, curve: curve)
        } else if sortedIdx + 1 < trackClips.count {
            let next = trackClips[sortedIdx + 1]
            return applyCrossfade(&project, leftClipID: clipID, rightClipID: next.id, duration: duration, curve: curve)
        }
        return false
    }

    // MARK: Track Grouping

    @discardableResult
    static func createTrackGroup(_ project: inout AudioEditorProject, name: String, trackIDs: [UUID]) -> UUID? {
        let validIDs = trackIDs.filter { tid in project.tracks.contains { $0.id == tid } }
        guard !validIDs.isEmpty else { return nil }
        let gid = UUID()
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = AudioTrackGroup(id: gid, name: cleaned.isEmpty ? "Group \(project.trackGroups.count + 1)" : cleaned, trackIDs: validIDs)
        project.trackGroups.append(group)
        for tid in validIDs {
            if let ti = project.tracks.firstIndex(where: { $0.id == tid }) {
                if let oldGID = project.tracks[ti].groupID,
                   let oldIdx = project.trackGroups.firstIndex(where: { $0.id == oldGID }) {
                    project.trackGroups[oldIdx].trackIDs.removeAll { $0 == tid }
                }
                project.tracks[ti].groupID = gid
            }
        }
        project.trackGroups.removeAll { $0.trackIDs.isEmpty }
        return gid
    }

    @discardableResult
    static func assignTrack(_ project: inout AudioEditorProject, trackID: UUID, toGroupID groupID: UUID?) -> Bool {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }) else { return false }
        if let gid = groupID, !project.trackGroups.contains(where: { $0.id == gid }) { return false }
        if project.tracks[ti].groupID == groupID { return false }

        if let oldGID = project.tracks[ti].groupID,
           let oldIdx = project.trackGroups.firstIndex(where: { $0.id == oldGID }) {
            project.trackGroups[oldIdx].trackIDs.removeAll { $0 == trackID }
        }
        project.tracks[ti].groupID = groupID
        if let gid = groupID, let newIdx = project.trackGroups.firstIndex(where: { $0.id == gid }) {
            if !project.trackGroups[newIdx].trackIDs.contains(trackID) {
                project.trackGroups[newIdx].trackIDs.append(trackID)
            }
        }
        project.trackGroups.removeAll { $0.trackIDs.isEmpty }
        return true
    }

    @discardableResult
    static func toggleGroupMute(_ project: inout AudioEditorProject, groupID: UUID) -> Bool {
        guard let idx = project.trackGroups.firstIndex(where: { $0.id == groupID }) else { return false }
        project.trackGroups[idx].isMuted.toggle()
        return true
    }

    @discardableResult
    static func toggleGroupSolo(_ project: inout AudioEditorProject, groupID: UUID) -> Bool {
        guard let idx = project.trackGroups.firstIndex(where: { $0.id == groupID }) else { return false }
        project.trackGroups[idx].isSolo.toggle()
        return true
    }

    @discardableResult
    static func moveGroupClips(_ project: inout AudioEditorProject, groupID: UUID, by delta: TimeInterval) -> Bool {
        guard let deltaFrames = frameFromSeconds(delta, rate: project.projectSampleRate, allowNegative: true),
              deltaFrames != 0,
              project.trackGroups.contains(where: { $0.id == groupID }) else {
            return false
        }
        let editableTrackIndices = project.tracks.indices.filter {
            project.tracks[$0].groupID == groupID && !project.tracks[$0].isLocked
        }
        let editableStarts = editableTrackIndices.flatMap { ti in
            project.tracks[ti].clips.filter { !$0.isLocked }.map(\.timelineStartFrame)
        }
        guard let earliest = editableStarts.min() else { return false }
        let effectiveDelta = deltaFrames < 0 ? max(-earliest, deltaFrames) : deltaFrames
        guard effectiveDelta != 0 else { return false }

        var changed = false
        for ti in editableTrackIndices {
            for ci in project.tracks[ti].clips.indices where !project.tracks[ti].clips[ci].isLocked {
                let s = project.tracks[ti].clips[ci].timelineStartFrame
                project.tracks[ti].clips[ci].timelineStartFrame = max(0, s + effectiveDelta)
                changed = true
            }
        }
        return changed
    }

    // MARK: - Timeline Markers (Sample-Accurate Pure Value Mutations)

    static func clampMarkerFrame(_ frame: Int64, projectDurationFrames: Int64) -> Int64 {
        let nonNegative = max(0, frame)
        if projectDurationFrames > 0 {
            return min(nonNegative, projectDurationFrames)
        }
        return nonNegative
    }

    static func clampMarkerTime(_ time: TimeInterval, projectDuration: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        let nonNegative = max(0, (time * 1000).rounded() / 1000)
        if projectDuration > 0 {
            let maxBound = (projectDuration * 1000).rounded() / 1000
            return min(nonNegative, maxBound)
        }
        return nonNegative
    }

    @discardableResult
    static func addMarker(
        _ project: inout AudioEditorProject,
        id: UUID = UUID(),
        atFrame frame: Int64,
        name: String? = nil
    ) -> AudioMarker {
        let resolvedID = project.markers.contains(where: { $0.id == id }) ? UUID() : id
        let clampedFrame = clampMarkerFrame(frame, projectDurationFrames: project.durationFrames)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = trimmed.isEmpty ? "Marker \(project.markers.count + 1)" : trimmed
        let marker = AudioMarker(id: resolvedID, frame: clampedFrame, sampleRate: project.projectSampleRate, name: resolvedName)
        project.markers.append(marker)
        project.markers.sort {
            if $0.frame != $1.frame { return $0.frame < $1.frame }
            return $0.id.uuidString < $1.id.uuidString
        }
        return marker
    }

    @discardableResult
    static func addMarker(
        _ project: inout AudioEditorProject,
        id: UUID = UUID(),
        at time: TimeInterval,
        name: String? = nil
    ) -> AudioMarker {
        let rate = project.projectSampleRate
        let f = (try? SampleFrameMigration.secondsToFrames(max(0, time.isFinite ? time : 0), sampleRate: rate, field: "marker.time")) ?? 0
        return addMarker(&project, id: id, atFrame: f, name: name)
    }

    @discardableResult
    static func renameMarker(
        _ project: inout AudioEditorProject,
        id: UUID,
        newName: String
    ) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = project.markers.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard project.markers[idx].name != trimmed else { return false }
        project.markers[idx].name = trimmed
        return true
    }

    @discardableResult
    static func moveMarker(
        _ project: inout AudioEditorProject,
        id: UUID,
        toFrame newFrame: Int64
    ) -> Bool {
        guard let idx = project.markers.firstIndex(where: { $0.id == id }) else { return false }
        let clamped = clampMarkerFrame(newFrame, projectDurationFrames: project.durationFrames)
        guard project.markers[idx].frame != clamped else { return false }
        project.markers[idx].frame = clamped
        project.markers.sort {
            if $0.frame != $1.frame { return $0.frame < $1.frame }
            return $0.id.uuidString < $1.id.uuidString
        }
        return true
    }

    @discardableResult
    static func moveMarker(
        _ project: inout AudioEditorProject,
        id: UUID,
        to newTime: TimeInterval
    ) -> Bool {
        guard newTime.isFinite else { return false }
        let f = (try? SampleFrameMigration.secondsToFrames(max(0, newTime), sampleRate: project.projectSampleRate, field: "marker.time")) ?? 0
        return moveMarker(&project, id: id, toFrame: f)
    }

    @discardableResult
    static func deleteMarker(
        _ project: inout AudioEditorProject,
        id: UUID
    ) -> Bool {
        guard let idx = project.markers.firstIndex(where: { $0.id == id }) else { return false }
        project.markers.remove(at: idx)
        return true
    }
}

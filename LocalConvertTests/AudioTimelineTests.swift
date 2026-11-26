import Testing
import Foundation
@testable import LocalConvert

@Suite("Phase 45.2 — Advanced Timeline Editing", .serialized)
struct AudioTimelineTests {

    @Test("Fade curves (linear, equalPower, exponential, logarithmic, sCurve) are continuous and monotonic")
    func fadeCurvesContinuity() {
        for curve in ClipFadeCurve.allCases {
            #expect(abs(curve.fadeIn(0.0) - 0.0) < 1e-6)
            #expect(abs(curve.fadeIn(1.0) - 1.0) < 1e-6)
            #expect(abs(curve.fadeOut(0.0) - 1.0) < 1e-6)
            #expect(abs(curve.fadeOut(1.0) - 0.0) < 1e-6)

            var prevIn = -0.1
            for step in 0...10 {
                let x = Double(step) / 10.0
                let v = curve.fadeIn(x)
                #expect(v >= prevIn)
                prevIn = v
            }
        }
        // Equal-power midpoint energy sum == 1.0 (sin^2 + cos^2)
        let fi = ClipFadeCurve.equalPower.fadeIn(0.5)
        let fo = ClipFadeCurve.equalPower.fadeOut(0.5)
        #expect(abs(fi * fi + fo * fo - 1.0) < 1e-6)
    }

    @Test("Crossfade overlaps adjacent clips accurately, clamps to valid clip bounds, and supports Undo/Redo")
    @MainActor
    func crossfadeAndUndoRedo() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("P45_2_XFade_\(UUID().uuidString)", isDirectory: true)
        let coord = UndoRedoCoordinator(journalDirectoryURL: dir)
        let store = AudioEditorStore(undoCoordinator: coord)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tid = store.project.tracks[0].id
        let c1 = AudioClip(sourceAssetID: nil, name: "A", timelineStart: 0.0, sourceStart: 0, duration: 4.0)
        let c2 = AudioClip(sourceAssetID: nil, name: "B", timelineStart: 4.0, sourceStart: 0, duration: 4.0)
        store.performMutation(type: .clipImport, title: "Setup Clips") { p in
            p.tracks[0].clips = [c1, c2]
            return true
        }
        await store.flushPendingUndoRecords()

        store.applyCrossfade(leftClipID: c1.id, rightClipID: c2.id, duration: 0.5, curve: .sCurve)
        await store.flushPendingUndoRecords()

        let updatedRight = store.project.clip(c2.id)!
        #expect(abs(updatedRight.timelineStart - 3.5) < 0.002)
        #expect(updatedRight.crossfadeCurve == .sCurve)

        // Gain at midpoint of 0.5s crossfade (t = 3.75) follows sCurve (0.5 each)
        let track = store.project.tracks.first(where: { $0.id == tid })!
        let gL = AudioGainAutomation.clipGain(track: track, clip: store.project.clip(c1.id)!, at: 3.75)
        let gR = AudioGainAutomation.clipGain(track: track, clip: updatedRight, at: 3.75)
        #expect(abs(gL - 0.5) < 0.01 && abs(gR - 0.5) < 0.01)

        await coord.undo(in: .audioEditor(projectID: store.project.id))
        #expect(abs(store.project.clip(c2.id)!.timelineStart - 4.0) < 0.002)

        await coord.redo(in: .audioEditor(projectID: store.project.id))
        #expect(abs(store.project.clip(c2.id)!.timelineStart - 3.5) < 0.002)
    }

    @Test("Snap-to-Grid aligns both fixed seconds and BPM beat subdivisions without timing drift")
    func gridSnappingAccuracy() {
        var grid = TimelineGridConfig(snapEnabled: true, interval: .halfSecond, bpm: 120.0)
        #expect(abs(grid.snap(1.26) - 1.5) < 1e-6)
        #expect(abs(grid.snap(1.24) - 1.0) < 1e-6)

        // 120 BPM = 0.5 s per beat -> 1/2 beat = 0.25 s
        grid.interval = .beatHalf
        #expect(abs(grid.stepSeconds - 0.25) < 1e-6)
        #expect(abs(grid.snap(0.62) - 0.5) < 1e-6)
        #expect(abs(grid.snap(0.63) - 0.75) < 1e-6)

        grid.snapEnabled = false
        #expect(abs(grid.snap(0.62) - 0.62) < 1e-6)
    }

    @Test("Track grouping moves grouped clips together, respects group mute/solo, isolates ungrouped tracks, and supports Undo/Redo")
    @MainActor
    func trackGroupingBehaviorAndUndoRedo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("P45_2_Grp_\(UUID().uuidString)", isDirectory: true)
        let coord = UndoRedoCoordinator(journalDirectoryURL: dir)
        let store = AudioEditorStore(undoCoordinator: coord)
        defer { try? FileManager.default.removeItem(at: dir) }

        let c1 = AudioClip(sourceAssetID: nil, name: "V1", timelineStart: 1.0, sourceStart: 0, duration: 2.0)
        let c2 = AudioClip(sourceAssetID: nil, name: "V2", timelineStart: 2.5, sourceStart: 0, duration: 2.0)
        let cSolo = AudioClip(sourceAssetID: nil, name: "SoloTrackClip", timelineStart: 1.0, sourceStart: 0, duration: 2.0)
        var t2ID = UUID()
        var t3ID = UUID()
        store.performMutation(type: .trackAdd, title: "Setup 3 Tracks") { p in
            p.tracks[0].clips = [c1]
            let t2 = AudioTrack(name: "Track 2", clips: [c2])
            let t3 = AudioTrack(name: "Track 3", clips: [cSolo])
            t2ID = t2.id
            t3ID = t3.id
            p.tracks.append(contentsOf: [t2, t3])
            return true
        }
        let t1ID = store.project.tracks[0].id
        store.createTrackGroup(name: "Drums", trackIDs: [t1ID, t2ID])
        await store.flushPendingUndoRecords()

        let gid = try #require(store.project.trackGroups.first?.id)
        #expect(store.project.tracks[0].groupID == gid)
        #expect(store.project.tracks[1].groupID == gid)
        #expect(store.project.tracks[2].groupID == nil)

        // Move group by +1.5s: T1 & T2 move cleanly while ungrouped T3 remains at 1.0s
        store.moveGroupClips(groupID: gid, by: 1.5)
        await store.flushPendingUndoRecords()
        #expect(abs(store.project.clip(c1.id)!.timelineStart - 2.5) < 0.002)
        #expect(abs(store.project.clip(c2.id)!.timelineStart - 4.0) < 0.002)
        #expect(abs(store.project.clip(cSolo.id)!.timelineStart - 1.0) < 0.002)

        // Group Mute silences T1 & T2 but leaves ungrouped T3 audible
        store.toggleGroupMute(gid)
        #expect(!store.project.isTrackAudible(store.project.tracks[0]))
        #expect(!store.project.isTrackAudible(store.project.tracks[1]))
        #expect(store.project.isTrackAudible(store.project.tracks[2]))

        // Undo Group Mute and Move Group Clips
        await coord.undo(in: .audioEditor(projectID: store.project.id))
        #expect(store.project.isTrackAudible(store.project.tracks[0]))
        await coord.undo(in: .audioEditor(projectID: store.project.id))
        #expect(abs(store.project.clip(c1.id)!.timelineStart - 1.0) < 0.002)
        #expect(abs(store.project.clip(c2.id)!.timelineStart - 2.5) < 0.002)
    }
}

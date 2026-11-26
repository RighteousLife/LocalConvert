import Testing
import Foundation
@testable import LocalConvert

@Suite("Audio Editor 2.0 Core & Persistence Tests")
struct AudioEditorCoreTests {

    private func makeProject(clipDur: Double = 10.0) -> (AudioEditorProject, UUID, UUID, AudioMediaReference) {
        let assetID = UUID()
        let asset = AudioMediaReference(
            id: assetID,
            path: "/tmp/nonexistent-source-\(assetID.uuidString).wav",
            displayName: "sample.wav",
            fileSize: 1024,
            modificationTime: 0,
            duration: 20.0,
            sampleRate: 48_000,
            channels: 2
        )
        let clip = AudioClip(
            sourceAssetID: assetID,
            name: "sample.wav",
            timelineStart: 0,
            sourceStart: 0,
            duration: clipDur
        )
        let track = AudioTrack(name: "Track 1", clips: [clip])
        let proj = AudioEditorProject(name: "Test", tracks: [track], mediaAssets: [asset])
        return (proj, track.id, clip.id, asset)
    }

    @Test("Split at timeline position creates two contiguous non-destructive clips")
    func testSplitClip() {
        var (proj, _, clipID, _) = makeProject(clipDur: 10.0)
        let rightID = AudioEditingService.split(&proj, clipID: clipID, at: 4.0)
        #expect(rightID != nil)
        #expect(proj.tracks[0].clips.count == 2)
        let left = proj.tracks[0].clips[0]
        let right = proj.tracks[0].clips[1]
        #expect(abs(left.duration - 4.0) < 0.001)
        #expect(abs(right.timelineStart - 4.0) < 0.001)
        #expect(abs(right.sourceStart - 4.0) < 0.001)
        #expect(abs(right.duration - 6.0) < 0.001)
    }

    @Test("Ripple delete shifts subsequent clips left by removed duration")
    func testRippleDelete() {
        var (proj, trackID, clipID, asset) = makeProject(clipDur: 5.0)
        let secondID = AudioEditingService.addClip(&proj, asset: asset, trackID: trackID, at: 6.0)!
        let changed = AudioEditingService.deleteClips(&proj, ids: [clipID], ripple: true)
        #expect(changed)
        #expect(proj.tracks[0].clips.count == 1)
        let remaining = proj.clip(secondID)!
        #expect(abs(remaining.timelineStart - 1.0) < 0.001)
    }

    @Test("Copy, paste, and consolidate restore contiguous clips")
    func testCopyPasteConsolidate() {
        var (proj, _, clipID, _) = makeProject(clipDur: 10.0)
        let rightID = AudioEditingService.split(&proj, clipID: clipID, at: 4.0)!
        let merges = AudioEditingService.consolidate(&proj, ids: [clipID, rightID])
        #expect(merges == 1)
        #expect(proj.tracks[0].clips.count == 1)
        #expect(abs(proj.tracks[0].clips[0].duration - 10.0) < 0.001)

        let copied = AudioEditingService.copy(proj, ids: [proj.tracks[0].clips[0].id])
        let pasted = AudioEditingService.paste(&proj, items: copied, at: 12.0, startTrackIndex: 0)
        #expect(pasted.count == 1)
        #expect(abs(proj.clip(pasted[0])!.timelineStart - 12.0) < 0.001)
    }

    @Test("Locked clip cannot be split, moved, or deleted")
    func testLockedClipProtection() {
        var (proj, _, clipID, _) = makeProject(clipDur: 10.0)
        _ = AudioEditingService.mutateClip(&proj, clipID: clipID) { $0.isLocked = true }
        #expect(AudioEditingService.split(&proj, clipID: clipID, at: 5.0) == nil)
        #expect(AudioEditingService.moveClip(&proj, clipID: clipID, toStart: 3.0) == false)
        #expect(AudioEditingService.deleteClips(&proj, ids: [clipID], ripple: false) == false)
    }

    @Test("Equal-power crossfade preserves energy at midpoint")
    func testCrossfadeMidpoint() {
        let a = AudioClip(sourceAssetID: UUID(), name: "A", timelineStart: 0, sourceStart: 0, duration: 4.0, crossfadeCurve: .equalPower)
        let b = AudioClip(sourceAssetID: UUID(), name: "B", timelineStart: 2.0, sourceStart: 0, duration: 4.0, crossfadeCurve: .equalPower)
        let track = AudioTrack(name: "T", clips: [a, b])
        let gA = AudioGainAutomation.clipGain(track: track, clip: a, at: 3.0)
        let gB = AudioGainAutomation.clipGain(track: track, clip: b, at: 3.0)
        #expect(abs((gA * gA + gB * gB) - 1.0) < 0.01)
    }

    @Test("Project save, load, missing-source detection, relinking, and autosave recovery")
    func testProjectPersistenceAndRecovery() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-proj-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let srcURL = tmpDir.appendingPathComponent("tone.wav")
        try Data("RIFFtest".utf8).write(to: srcURL)
        let fp = AudioMediaReference.fingerprint(of: srcURL)
        let asset = AudioMediaReference(
            id: UUID(), path: srcURL.path, displayName: "tone.wav",
            fileSize: fp.size, modificationTime: fp.mtime, duration: 5.0, sampleRate: 48_000, channels: 2
        )
        let clip = AudioClip(sourceAssetID: asset.id, name: "tone.wav", timelineStart: 1.0, sourceStart: 0, duration: 5.0)
        let proj = AudioEditorProject(name: "MyMix", tracks: [AudioTrack(name: "Main", clips: [clip])], mediaAssets: [asset])

        let projURL = tmpDir.appendingPathComponent("MyMix.lcproject")
        _ = try ProjectPersistenceService.save(project: proj, to: projURL)
        try FileManager.default.removeItem(at: srcURL)

        let (loaded, missing) = try ProjectPersistenceService.load(from: projURL)
        #expect(loaded.name == "MyMix")
        #expect(missing.count == 1)

        let relinkURL = tmpDir.appendingPathComponent("tone-relinked.wav")
        try Data("RIFFrelinked".utf8).write(to: relinkURL)
        var mutableLoaded = loaded
        #expect(ProjectPersistenceService.relinkAsset(in: &mutableLoaded, assetID: asset.id, newURL: relinkURL))
        #expect(ProjectPersistenceService.missingAssets(in: mutableLoaded).isEmpty)

        // Autosave + recovery
        try ProjectPersistenceService.writeAutosave(project: proj, projectFileURL: projURL, directory: tmpDir)
        let snap = ProjectPersistenceService.latestRecoverableAutosave(directory: tmpDir)
        #expect(snap?.project.id == proj.id)
        ProjectPersistenceService.clearAutosave(for: proj.id, directory: tmpDir)
        #expect(ProjectPersistenceService.latestRecoverableAutosave(directory: tmpDir) == nil)
    }

    @Test("TimelineState playhead moves remain independent of selectionRange")
    func testPlayheadSelectionIndependence() {
        var timeline = TimelineState()
        timeline.setSelection(from: 2.0, to: 6.0)
        timeline.setPlayhead(8.5)
        #expect(timeline.selectionRange == 2.0...6.0)
        #expect(abs(timeline.playheadTime - 8.5) < 0.001)
    }

    @MainActor
    @Test("AudioEditorStore Undo and Redo restore project state cleanly")
    func testStoreUndoRedo() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-undo-test-\(UUID().uuidString)")
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("journal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AudioEditorStore(undoCoordinator: coordinator)
        let initialCount = store.project.tracks.count
        store.addTrack()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.project.tracks.count == initialCount + 1)

        await coordinator.undo(in: .audioEditor(projectID: store.project.id))
        #expect(store.project.tracks.count == initialCount)

        await coordinator.redo(in: .audioEditor(projectID: store.project.id))
        #expect(store.project.tracks.count == initialCount + 1)
    }
}

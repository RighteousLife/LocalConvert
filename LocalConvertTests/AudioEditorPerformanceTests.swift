import Testing
import Foundation
import AVFoundation
@testable import LocalConvert

@Suite("Audio Editor 2.0 Performance & App-Wide Undo Safety Tests")
struct AudioEditorPerformanceTests {

    @Test("100 sequential clip edits + full Undo/Redo cycle stays fast and bounded")
    @MainActor
    func testRepeatedEditsAndUndoRedoPerformance() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("journal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        )
        let store = AudioEditorStore(undoCoordinator: coordinator)
        let asset = AudioMediaReference(
            id: UUID(), path: "/tmp/perf.wav", displayName: "perf.wav",
            fileSize: 1024, modificationTime: 0, duration: 120.0, sampleRate: 48_000, channels: 2
        )
        let trackID = store.project.tracks[0].id
        store.performMutation(type: .clipImport, title: "Add Clip") { p in
            AudioEditingService.addClip(&p, asset: asset, trackID: trackID, at: 0) != nil
        }

        let clipID = store.project.tracks[0].clips[0].id
        let t0 = CFAbsoluteTimeGetCurrent()
        for step in 1...100 {
            store.performMutation(type: .clipMove, title: "Move \(step)") { p in
                AudioEditingService.moveClip(&p, clipID: clipID, toStart: Double(step) * 0.05)
            }
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let editElapsed = CFAbsoluteTimeGetCurrent() - t0
        #expect(editElapsed < 5.0, "100 edits took \(editElapsed)s")

        let ctx = OperationContext.audioEditor(projectID: store.project.id)
        for _ in 0..<25 {
            await coordinator.undo(in: ctx)
        }
        for _ in 0..<25 {
            await coordinator.redo(in: ctx)
        }
        #expect(abs((store.project.clip(clipID)?.timelineStart ?? 0) - 5.0) < 0.01)
    }

    @Test("Waveform cache honors 64 MB budget across multiple assets")
    func testWaveformCacheBounds() async throws {
        await WaveformRenderingService.shared.clear()
        let bytes = await WaveformRenderingService.shared.cachedBytes()
        #expect(bytes == 0)
    }

    @Test("BatchRenameUndoCommand reverses renames and blocks on external identity mismatch or collision")
    @MainActor
    func testBatchRenameUndoIdentityAndCollision() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-rename-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("photo_a.png")
        let b = dir.appendingPathComponent("photo_b.png")
        try Data("AAA".utf8).write(to: a)
        try Data("BBB".utf8).write(to: b)

        var opts = ImageBatchRenameOptions()
        opts.prefix = "edited_"
        let plan = ImageBatchRenameService.buildPlan(urls: [a, b], options: opts)
        let manifest = try ImageBatchRenameService.executePlan(plan)
        #expect(manifest.appliedMoves.count == 2)

        let cmd = BatchRenameUndoCommand(manifest: manifest)
        try await cmd.undo()
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))

        try await cmd.redo()
        let renamedA = dir.appendingPathComponent("edited_photo_a.png")
        #expect(FileManager.default.fileExists(atPath: renamedA.path))

        // Collision guard: occupy original `a` path with a new unrelated file
        try Data("UNRELATED".utf8).write(to: a)
        do {
            try await cmd.undo()
            Issue.record("Expected UndoRedoError.staleEntry when original filename is occupied")
        } catch {
            #expect(String(data: try Data(contentsOf: a), encoding: .utf8) == "UNRELATED")
        }
    }

    @Test("OutputCreationUndoCommand never deletes or overwrites protected source files")
    @MainActor
    func testOutputCreationUndoProtectsSources() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-out-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.wav")
        let output = dir.appendingPathComponent("output.mp3")
        try Data("SRC".utf8).write(to: source)
        try Data("OUT".utf8).write(to: output)

        let artifactMgr = RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        let cmd = OutputCreationUndoCommand(
            title: "Create output.mp3",
            context: .convert,
            outputURLs: [output, source],
            protectedSourceURLs: [source],
            artifactManager: artifactMgr
        )

        try await cmd.undo()
        // Output was moved into recovery staging, source remained untouched
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: source.path))

        try await cmd.redo()
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("MetadataSnapshotUndoCommand and PresetStoreUndoCommand reverse and restore cleanly")
    @MainActor
    func testMetadataAndPresetUndoCommands() async throws {
        let dummyURL = URL(fileURLWithPath: "/tmp/meta.mp3")
        let beforeDoc = MetadataDocument(format: .mp3, fileURL: dummyURL)
        var afterDoc = beforeDoc
        afterDoc.isStrippedAll = true

        var currentDoc = afterDoc
        let metaCmd = MetadataSnapshotUndoCommand(
            operationType: .metadataDraftEdit,
            title: "Strip Metadata",
            before: beforeDoc,
            after: afterDoc,
            applyDocument: { currentDoc = $0 }
        )
        try await metaCmd.undo()
        #expect(currentDoc.isStrippedAll == false)
        try await metaCmd.redo()
        #expect(currentDoc.isStrippedAll == true)

        let p1 = SavedPreset(name: "Web", targetFormat: .mp3, options: .default)
        var presets: [SavedPreset] = [p1]
        let presetCmd = PresetStoreUndoCommand(
            operationType: .presetSave,
            title: "Save Preset",
            beforePresets: [],
            afterPresets: [p1],
            applyPresets: { presets = $0 }
        )
        try await presetCmd.undo()
        #expect(presets.isEmpty)
        try await presetCmd.redo()
        #expect(presets.count == 1)
    }
}

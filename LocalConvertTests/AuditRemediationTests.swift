import Testing
import Foundation
import AVFoundation
@testable import LocalConvert

@Suite("M2–M7 Hardening Audit Remediation Regression Tests")
struct AuditRemediationTests {

    private func writeWAV(to url: URL, duration: Double, sampleRate: Double, channels: Int) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else { return }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = Int(duration * sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return }
        for c in 0..<channels {
            for i in 0..<frames {
                ch[c][i] = 0.25 * Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate))
            }
        }
        buf.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buf)
    }

    @Test("H1: App startup bootstrap registers AudioEditorUndoRehydrator before restoring persisted history")
    @MainActor
    func testH1StartupRehydrationOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-h1-\(UUID().uuidString)")
        let journalDir = dir.appendingPathComponent("journal")
        let artifactsDir = dir.appendingPathComponent("artifacts")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Session 1: record an Audio Editor mutation and flush journal.json
        let coord1 = UndoRedoCoordinator(
            journalDirectoryURL: journalDir,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir)
        )
        let store1 = AudioEditorStore(undoCoordinator: coord1)
        let projectID = store1.project.id
        store1.addTrack()
        await store1.flushPendingUndoRecords()
        coord1.flushPersistence()
        #expect(coord1.canUndo(in: .audioEditor(projectID: projectID)))

        // Session 2: fresh AppState + fresh Coordinator bootstrapped via LocalConvertApp startup path
        let coord2 = UndoRedoCoordinator(
            journalDirectoryURL: journalDir,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir)
        )
        let appState2 = AppState(undoCoordinator: coord2)
        await LocalConvertApp.bootstrapUndoCoordinator(appState: appState2, undoCoordinator: coord2)

        let ctx = OperationContext.audioEditor(projectID: projectID)
        #expect(coord2.canUndo(in: ctx) == true)
        await coord2.undo(in: ctx)
        #expect(appState2.audioEditorStore.project.tracks.count == 1)
    }

    @Test("H2: Continuous effect slider drag coalesces into 1 undo step without leaking group state")
    @MainActor
    func testH2ContinuousSliderCoalescingNoLeak() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-h2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let coord = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("journal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        )
        let store = AudioEditorStore(undoCoordinator: coord)
        let clipID = UUID()
        let clip = AudioClip(id: clipID, sourceAssetID: nil, name: "C", timelineStart: 0, sourceStart: 0, duration: 2)
        store.project.tracks[0].clips = [clip]

        // Simulate continuous HPF cutoff slider drag (10 ticks -> 1 undo step)
        store.beginContinuousMutation()
        for hz in stride(from: 100.0, through: 1000.0, by: 100.0) {
            store.updateContinuousMutation(type: .clipEffectChange, title: "High-Pass Cutoff") { p in
                _ = AudioEditingService.mutateClip(&p, clipID: clipID) { $0.effects.highPassHz = hz }
            }
        }
        store.endContinuousMutation(type: .clipEffectChange, title: "High-Pass Cutoff")

        // Subsequent unrelated gain drag must form a SECOND distinct undo step
        store.beginContinuousMutation()
        for db in [-2.0, -4.0, -6.0] {
            store.updateContinuousMutation(type: .clipGainPanChange, title: "Clip Gain") { p in
                _ = AudioEditingService.mutateClip(&p, clipID: clipID) { $0.gainDB = db }
            }
        }
        store.endContinuousMutation(type: .clipGainPanChange, title: "Clip Gain")
        await store.flushPendingUndoRecords()

        let ctx = OperationContext.audioEditor(projectID: store.project.id)
        #expect(coord.undoEntries(for: ctx).count == 2)

        await coord.undo(in: ctx)
        #expect(abs((store.project.clip(clipID)?.gainDB ?? 99) - 0.0) < 0.001)
        #expect(store.project.clip(clipID)?.effects.highPassHz == 1000.0)

        await coord.undo(in: ctx)
        #expect(store.project.clip(clipID)?.effects.highPassHz == nil)
    }

    @Test("H3: AudioMixSession.update invalidates cached reader when source URL changes under same clip ID")
    func testH3AudioMixSessionReaderInvalidation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-h3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url1 = dir.appendingPathComponent("src1.wav")
        let url2 = dir.appendingPathComponent("src2.wav")
        try writeWAV(to: url1, duration: 0.5, sampleRate: 48_000, channels: 2)
        try writeWAV(to: url2, duration: 0.5, sampleRate: 48_000, channels: 2)

        let clipID = UUID()
        let clip = AudioClip(id: clipID, sourceAssetID: UUID(), name: "Clip", timelineStart: 0, sourceStart: 0, duration: 0.5)
        let project = AudioEditorProject(tracks: [AudioTrack(name: "T1", clips: [clip])])

        let session = AudioMixSession(
            project: project,
            sources: [clipID: ResolvedClipSource(clipID: clipID, url: url1, baseFrame: 0)]
        )
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { l.deallocate(); r.deallocate() }
        session.mix(startTime: 0, frameCount: 256, left: l, right: r)
        #expect(session.activeReaderURL(for: clipID) == url1)

        // Update with a new proxy/source URL under the same clipID
        session.update(
            project: project,
            sources: [clipID: ResolvedClipSource(clipID: clipID, url: url2, baseFrame: 0)]
        )
        #expect(session.activeReaderURL(for: clipID) == nil)
        session.mix(startTime: 0, frameCount: 256, left: l, right: r)
        #expect(session.activeReaderURL(for: clipID) == url2)
    }

    @Test("H4: AudioEditorKeyMonitor ignores keystrokes when modal sheet/popover, text input, or other window is active")
    @MainActor
    func testH4KeyMonitorModalAndWindowGuard() {
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: false, isModalPresented: false, eventMatchesHostWindow: true) == true)
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: true, isModalPresented: false, eventMatchesHostWindow: true) == false)
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: false, isModalPresented: true, eventMatchesHostWindow: true) == false)
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: false, isModalPresented: false, eventMatchesHostWindow: false) == false)
    }

    @Test("M5: .lcprojpkg save/load/re-save preserves single prefix and rejects traversal & symlink escapes")
    func testM5PackageSafetyTraversalAndResave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-m5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("voice.wav")
        try writeWAV(to: src, duration: 0.5, sampleRate: 48_000, channels: 2)
        let fp = AudioMediaReference.fingerprint(of: src)
        let asset = AudioMediaReference(
            id: UUID(), path: src.path, displayName: "voice.wav",
            fileSize: fp.size, modificationTime: fp.mtime, duration: 0.5, sampleRate: 48_000, channels: 2
        )
        let clip = AudioClip(sourceAssetID: asset.id, name: "voice", timelineStart: 0, sourceStart: 0, duration: 0.5)
        let proj = AudioEditorProject(name: "Pkg", tracks: [AudioTrack(name: "T1", clips: [clip])], mediaAssets: [asset])

        // 1. Canonical URL normalization & re-save without double prefix
        let rawPkgURL = dir.appendingPathComponent("MyPkg")
        let (_, canonicalPkgURL) = try ProjectPersistenceService.saveReturningURL(project: proj, to: rawPkgURL, selfContainedPackage: true)
        #expect(canonicalPkgURL.pathExtension == ProjectPersistenceService.packageExtension)

        let (loaded1, missing1) = try ProjectPersistenceService.load(from: canonicalPkgURL)
        #expect(missing1.isEmpty)

        // Re-save the loaded package: must NOT create double prefix or duplicate file in Media/
        _ = try ProjectPersistenceService.saveReturningURL(project: loaded1, to: canonicalPkgURL, selfContainedPackage: true)
        let mediaFiles = try FileManager.default.contentsOfDirectory(atPath: canonicalPkgURL.appendingPathComponent("Media").path)
        #expect(mediaFiles.count == 1)

        // 2. Path traversal via ../ must be rejected
        var evilProj = proj
        let outsideFile = dir.appendingPathComponent("secret.wav")
        try Data("SECRET".utf8).write(to: outsideFile)
        evilProj.mediaAssets[0].path = "Media/../../secret.wav"
        let pkgJSON = canonicalPkgURL.appendingPathComponent("project.lcproject")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(AudioProjectDocument(isSelfContainedPackage: true, project: evilProj)).write(to: pkgJSON)

        #expect(throws: Error.self) {
            _ = try ProjectPersistenceService.load(from: canonicalPkgURL)
        }

        // 3. Symlink inside Media/ pointing outside package must be rejected
        let symlinkURL = canonicalPkgURL.appendingPathComponent("Media/escape.wav")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)
        evilProj.mediaAssets[0].path = "Media/escape.wav"
        try enc.encode(AudioProjectDocument(isSelfContainedPackage: true, project: evilProj)).write(to: pkgJSON)

        #expect(throws: Error.self) {
            _ = try ProjectPersistenceService.load(from: canonicalPkgURL)
        }
    }

    @Test("M3: Reversed clip trimEdges updates sourceStart and clamps within sourceDuration")
    func testM3ReversedClipTrimEdges() {
        let assetID = UUID()
        let clip = AudioClip(
            sourceAssetID: assetID, name: "Rev", timelineStart: 2.0, sourceStart: 1.0, duration: 4.0, isReversed: true
        )
        var proj = AudioEditorProject(tracks: [AudioTrack(name: "T1", clips: [clip])])

        // Trim right edge inward by 1s (timelineEnd 6.0 -> 5.0): reversed sourceStart advances 1.0 -> 2.0
        #expect(AudioEditingService.trimEdges(&proj, clipID: clip.id, newStart: 2.0, newEnd: 5.0, sourceDuration: 10.0))
        let updated = proj.clip(clip.id)!
        #expect(abs(updated.sourceStart - 2.0) < 0.001)
        #expect(abs(updated.duration - 3.0) < 0.001)

        // Clamp left/right extension past available source duration
        #expect(AudioEditingService.trimEdges(&proj, clipID: clip.id, newStart: -5.0, newEnd: 50.0, sourceDuration: 10.0))
        let clamped = proj.clip(clip.id)!
        #expect(clamped.timelineStart >= 0)
        #expect(clamped.sourceStart + clamped.sourceSpan <= 10.001)
    }

    @Test("M1: Image Toolbox Batch Rename undoes and redoes directly through activeContext Cmd+Z path")
    @MainActor
    func testM1ImageToolboxBatchRenameActiveContextUndo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-m1-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let orig = dir.appendingPathComponent("pic.png")
        try Data("PNG".utf8).write(to: orig)
        var opts = ImageBatchRenameOptions()
        opts.prefix = "new_"
        let plan = ImageBatchRenameService.buildPlan(urls: [orig], options: opts)
        let manifest = try ImageBatchRenameService.executePlan(plan)

        let coord = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("journal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        )
        let appState = AppState(undoCoordinator: coord)
        appState.selectedTab = .imageToolbox
        coord.bind(to: appState)

        let cmd = BatchRenameUndoCommand(title: "Batch Rename", context: .imageToolbox, manifest: manifest)
        await coord.record(cmd)

        #expect(coord.activeContext == .imageToolbox)
        #expect(coord.canUndo == true)
        await coord.undo()
        #expect(FileManager.default.fileExists(atPath: orig.path))
        await coord.redo()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new_pic.png").path))
    }

    @Test("M7: Relinking missing asset with different real WAV refreshes duration, sampleRate, and channels")
    @MainActor
    func testM7RelinkRefreshesAudioProperties() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-m7-relink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldAsset = AudioMediaReference(
            id: UUID(), path: dir.appendingPathComponent("missing.wav").path, displayName: "missing.wav",
            fileSize: 0, modificationTime: 0, duration: 5.0, sampleRate: 48_000, channels: 2
        )
        let newWAV = dir.appendingPathComponent("replacement.wav")
        try writeWAV(to: newWAV, duration: 1.5, sampleRate: 44_100, channels: 1)

        let store = AudioEditorStore(undoCoordinator: UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("journal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        ))
        store.project.mediaAssets = [oldAsset]

        await store.relinkMissingAssetAsync(assetID: oldAsset.id, newURL: newWAV)
        let relinked = store.project.asset(oldAsset.id)!
        #expect(relinked.sampleRate == 44_100)
        #expect(relinked.channels == 1)
        #expect(abs(relinked.duration - 1.5) < 0.05)
    }

    @Test("M6: AppState addFiles/removeAllFiles undo cleanly and MetadataManager coalesces typing")
    @MainActor
    func testM6AppStateAndMetadataCoalescing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-m6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("tone.wav")
        try writeWAV(to: fileURL, duration: 0.5, sampleRate: 48_000, channels: 2)

        let coord = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("journal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        )
        let appState = AppState(undoCoordinator: coord)
        appState.handleDroppedURLs([fileURL])
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(appState.droppedFiles.count == 1)
        await coord.undo(in: .convert)
        #expect(appState.droppedFiles.isEmpty)

        await coord.redo(in: .convert)
        #expect(appState.droppedFiles.count == 1)
        appState.removeAllFiles()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(appState.droppedFiles.isEmpty)
        await coord.undo(in: .convert)
        #expect(appState.droppedFiles.count == 1)

        // MetadataManager typing coalescing
        let metaCoord = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("mjournal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("martifacts"))
        )
        let metaMgr = MetadataManager(undoCoordinator: metaCoord)
        await metaMgr.load(url: fileURL)
        metaMgr.updateField(id: "title", value: .string("A"))
        metaMgr.updateField(id: "title", value: .string("AB"))
        metaMgr.updateField(id: "title", value: .string("ABC"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(metaCoord.undoEntries(for: .metadata).count == 1)
        await metaCoord.undo(in: .metadata)
        #expect(metaMgr.document?.value(for: "title") == nil)
    }

    @Test("L3: newProject and openProject clear stale statusMessage and errorMessage")
    @MainActor
    func testL3StatusAndErrorReset() {
        let store = AudioEditorStore()
        store.statusMessage = "Old Status"
        store.errorMessage = "Old Error"
        store.newProject()
        #expect(store.statusMessage == nil)
        #expect(store.errorMessage == nil)
    }
}

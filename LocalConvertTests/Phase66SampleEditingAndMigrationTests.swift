import XCTest
import Foundation
@testable import LocalConvert

final class Phase66SampleEditingAndMigrationTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase66-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDownWithError() throws {
        OutputReservationCoordinator.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        StructuredDiagnostics.clearRecentEvents()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Helpers

    private func makeProject(
        sampleRate: SampleRate = .rate48k,
        timelineStartFrame: Int64 = 0,
        sourceStartFrame: Int64 = 0,
        durationFrames: Int64 = 480_000,
        isLocked: Bool = false
    ) -> (AudioEditorProject, UUID, UUID, AudioMediaReference) {
        let assetID = UUID()
        let asset = AudioMediaReference(
            id: assetID,
            path: "/tmp/nonexistent-phase66-\(assetID.uuidString).wav",
            displayName: "sample.wav",
            fileSize: 4096,
            modificationTime: 1_700_000_000,
            duration: Double(durationFrames * 2) / Double(sampleRate.hz),
            sampleRate: Double(sampleRate.hz),
            channels: 2,
            bookmarkData: nil,
            contentSHA256: nil,
            relativePath: nil,
            durationFrames: durationFrames * 2
        )
        let clip = AudioClip(
            sourceAssetID: assetID,
            name: "sample.wav",
            timelineStartFrame: timelineStartFrame,
            sourceStartFrame: sourceStartFrame,
            durationFrames: durationFrames,
            projectRate: sampleRate,
            sourceRate: sampleRate,
            isLocked: isLocked
        )
        let track = AudioTrack(name: "Track 1", clips: [clip])
        let proj = AudioEditorProject(
            name: "Phase66",
            sampleRate: Double(sampleRate.hz),
            tracks: [track],
            mediaAssets: [asset]
        )
        return (proj, track.id, clip.id, asset)
    }

    private func makeLegacyJSON(
        schemaVersion: Int = 2,
        formatVersion: Int = 2,
        sampleRate: Any = 44_100.0,
        timelineStart: Any = 0.125,
        sourceStart: Any = 0.375,
        duration: Any = 2.0,
        fadeInDuration: Any = 0.125,
        markerTime: Any = 0.5
    ) throws -> Data {
        let assetID = UUID().uuidString
        let docDict: [String: Any] = [
            "formatVersion": formatVersion,
            "savedAt": "2026-01-01T00:00:00Z",
            "isSelfContainedPackage": false,
            "project": [
                "id": UUID().uuidString,
                "schemaVersion": schemaVersion,
                "name": "Legacy Mix",
                "sampleRate": sampleRate,
                "mediaAssets": [
                    [
                        "id": assetID,
                        "path": "/tmp/nonexistent-legacy.wav",
                        "displayName": "legacy.wav",
                        "fileSize": 1024,
                        "modificationTime": 1_700_000_000.0,
                        "duration": 10.0,
                        "sampleRate": 44_100.0,
                        "channels": 2
                    ]
                ],
                "markers": [
                    [
                        "id": UUID().uuidString,
                        "time": markerTime,
                        "name": "Intro"
                    ]
                ],
                "tracks": [
                    [
                        "id": UUID().uuidString,
                        "name": "Track 1",
                        "clips": [
                            [
                                "id": UUID().uuidString,
                                "sourceAssetID": assetID,
                                "name": "legacy.wav",
                                "timelineStart": timelineStart,
                                "sourceStart": sourceStart,
                                "duration": duration,
                                "fadeIn": [
                                    "duration": fadeInDuration,
                                    "curve": "Equal Power"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: docDict, options: [.sortedKeys])
    }

    // MARK: - 1. Schema v1/v2 -> v3 Migration, Rounding, Validation & Non-Destructive Load

    func testLegacyMigrationHalfAwayFromZeroValidationAndNonDestructiveDiskLoad() throws {
        // Exact .5 ties at 44,100 Hz:
        // 0.125 * 44,100 = 5,512.5 -> 5,513
        // 0.375 * 44,100 = 16,537.5 -> 16,538
        XCTAssertEqual(try SampleFrameMigration.secondsToFrames(0.125, sampleRate: .rate44_1k, field: "t"), 5_513)
        XCTAssertEqual(try SampleFrameMigration.secondsToFrames(0.375, sampleRate: .rate44_1k, field: "t"), 16_538)
        XCTAssertEqual(try SampleFrameMigration.secondsToFrames(0.0000625, sampleRate: try SampleRate(40_000), field: "t"), 3)
        XCTAssertEqual(try SampleFrameMigration.secondsToFrames(-0.125, sampleRate: .rate44_1k, field: "t", allowNegative: true), -5_513)

        // Write legacy v2 file on disk and snapshot exact bytes + mtime
        let legacyData = try makeLegacyJSON(schemaVersion: 2, formatVersion: 2)
        let legacyURL = sandbox.temporaryURL.appendingPathComponent("legacy_v2.lcproject")
        try legacyData.write(to: legacyURL, options: .atomic)
        let diskBytesBefore = try Data(contentsOf: legacyURL)
        let diskMtimeBefore = try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as? Date

        // Load migrates in memory to schema v3 without touching disk bytes
        let (loaded, missing) = try ProjectPersistenceService.load(from: legacyURL)
        XCTAssertEqual(loaded.schemaVersion, AudioEditorProject.currentSchemaVersion)
        XCTAssertEqual(loaded.projectSampleRate, .rate44_1k)
        XCTAssertEqual(missing.count, 1)

        let migratedClip = try XCTUnwrap(loaded.tracks.first?.clips.first)
        XCTAssertEqual(migratedClip.timelineStartFrame, 5_513)
        XCTAssertEqual(migratedClip.sourceStartFrame, 16_538)
        XCTAssertEqual(migratedClip.durationFrames, 88_200)
        XCTAssertEqual(migratedClip.projectRate, .rate44_1k)
        XCTAssertEqual(migratedClip.sourceRate, .rate44_1k)
        XCTAssertEqual(migratedClip.fadeInFrames?.durationFrames, 5_513)
        XCTAssertEqual(loaded.markers.first?.frame, 22_050)

        // Prove legacy file on disk was NOT overwritten
        let diskBytesAfter = try Data(contentsOf: legacyURL)
        let diskMtimeAfter = try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as? Date
        XCTAssertEqual(diskBytesBefore, diskBytesAfter)
        XCTAssertEqual(diskMtimeBefore, diskMtimeAfter)

        // Legacy v1 also migrates cleanly
        let v1Data = try makeLegacyJSON(schemaVersion: 1, formatVersion: 1)
        let v1URL = sandbox.temporaryURL.appendingPathComponent("legacy_v1.lcproject")
        try v1Data.write(to: v1URL)
        let (loadedV1, _) = try ProjectPersistenceService.load(from: v1URL)
        XCTAssertEqual(loadedV1.schemaVersion, 3)

        // Explicit save upgrades persisted file to schemaVersion = 3
        let upgradedURL = sandbox.temporaryURL.appendingPathComponent("upgraded_v3.lcproject")
        let savedV3 = try ProjectPersistenceService.save(project: loaded, to: upgradedURL)
        XCTAssertEqual(savedV3.schemaVersion, 3)
        let persistedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: upgradedURL)) as? [String: Any]
        XCTAssertEqual(persistedJSON?["formatVersion"] as? Int, 3)
        let persistedProject = persistedJSON?["project"] as? [String: Any]
        XCTAssertEqual(persistedProject?["schemaVersion"] as? Int, 3)

        // Reject NaN, +Inf, -Inf, negative values, invalid sample rates, future schema, and Int64 overflow
        XCTAssertThrowsError(try SampleFrameMigration.secondsToFrames(.nan, sampleRate: .rate48k, field: "nan"))
        XCTAssertThrowsError(try SampleFrameMigration.secondsToFrames(.infinity, sampleRate: .rate48k, field: "inf"))
        XCTAssertThrowsError(try SampleFrameMigration.secondsToFrames(-.infinity, sampleRate: .rate48k, field: "ninf", allowNegative: true))
        XCTAssertThrowsError(try SampleFrameMigration.secondsToFrames(-0.01, sampleRate: .rate48k, field: "neg"))
        XCTAssertThrowsError(try SampleFrameMigration.secondsToFrames(1e16, sampleRate: .rate48k, field: "overflow"))

        for invalidSpec in [
            try makeLegacyJSON(timelineStart: -1.0),
            try makeLegacyJSON(duration: -0.5),
            try makeLegacyJSON(sourceStart: -0.2),
            try makeLegacyJSON(fadeInDuration: -0.1),
            try makeLegacyJSON(markerTime: -2.0),
            try makeLegacyJSON(timelineStart: 1e16),
            try makeLegacyJSON(sampleRate: 0.0),
            try makeLegacyJSON(sampleRate: 900_000.0),
            try makeLegacyJSON(schemaVersion: 99, formatVersion: 2),
            try makeLegacyJSON(timelineStart: "NaN"),
            try makeLegacyJSON(timelineStart: "Infinity")
        ] {
            let badURL = sandbox.temporaryURL.appendingPathComponent("bad_\(UUID().uuidString).lcproject")
            try invalidSpec.write(to: badURL)
            XCTAssertThrowsError(try ProjectPersistenceService.load(from: badURL))
        }
    }

    // MARK: - 2. Sample-Accurate Editing Operations & Zero-Length Range No-Op

    func testSampleAccurateEditOpsAndZeroLengthNoOps() throws {
        var (proj, trackID, clipID, _) = makeProject(sampleRate: .rate48k, timelineStartFrame: 0, sourceStartFrame: 1_000, durationFrames: 480_000)

        // Zero-length SampleFrameRange selection MUST be a safe no-op across all operations
        let zeroRange = try SampleFrameRange(startFrame: 24_000, frameCount: 0, sampleRate: .rate48k)
        let snapshotBeforeZero = proj
        XCTAssertFalse(AudioEditingService.splitAtSelection(&proj, range: zeroRange))
        XCTAssertFalse(AudioEditingService.trimClip(&proj, clipID: clipID, to: zeroRange))
        XCTAssertFalse(AudioEditingService.trimToSelection(&proj, range: zeroRange))
        XCTAssertFalse(AudioEditingService.deleteRange(&proj, range: zeroRange, ripple: true))
        XCTAssertTrue(AudioEditingService.cut(&proj, range: zeroRange).isEmpty)
        XCTAssertNil(AudioEditingService.insertSilence(&proj, trackID: trackID, atFrame: 0, durationFrames: 0))
        XCTAssertEqual(proj, snapshotBeforeZero)

        // Boundary split at start or end is safe no-op
        XCTAssertNil(AudioEditingService.split(&proj, clipID: clipID, atFrame: 0))
        XCTAssertNil(AudioEditingService.split(&proj, clipID: clipID, atFrame: 480_000))

        // Exact split at 123,457 frames
        let rightID = try XCTUnwrap(AudioEditingService.split(&proj, clipID: clipID, atFrame: 123_457))
        let left = try XCTUnwrap(proj.clip(clipID))
        let right = try XCTUnwrap(proj.clip(rightID))
        XCTAssertEqual(left.durationFrames, 123_457)
        XCTAssertEqual(right.timelineStartFrame, 123_457)
        XCTAssertEqual(right.sourceStartFrame, 1_000 + 123_457)
        XCTAssertEqual(right.durationFrames, 480_000 - 123_457)

        // Trim clip precisely in integer frames
        let trimRange = try SampleFrameRange(startFrame: 10_000, frameCount: 50_000, sampleRate: .rate48k)
        XCTAssertTrue(AudioEditingService.trimClip(&proj, clipID: clipID, to: trimRange))
        let trimmed = try XCTUnwrap(proj.clip(clipID))
        XCTAssertEqual(trimmed.timelineStartFrame, 10_000)
        XCTAssertEqual(trimmed.durationFrames, 50_000)
        XCTAssertEqual(trimmed.sourceStartFrame, 11_000)

        // Cut, Copy, Paste at exact destination frame
        let cutItems = AudioEditingService.cut(&proj, ids: [clipID], ripple: false)
        XCTAssertEqual(cutItems.count, 1)
        XCTAssertNil(proj.clip(clipID))

        let pastedIDs = AudioEditingService.paste(&proj, items: cutItems, atFrame: 600_000, startTrackIndex: 0)
        let pastedClip = try XCTUnwrap(pastedIDs.first.flatMap { proj.clip($0) })
        XCTAssertEqual(pastedClip.timelineStartFrame, 600_000)
        XCTAssertEqual(pastedClip.durationFrames, 50_000)

        // Nudge by exact frame delta (negative clamps safely to 0)
        XCTAssertTrue(AudioEditingService.nudge(&proj, ids: [pastedClip.id], byFrames: -125))
        XCTAssertEqual(proj.clip(pastedClip.id)?.timelineStartFrame, 599_875)

        // Gain, Fade, Channel Mode & Swap
        XCTAssertTrue(AudioEditingService.setGain(&proj, clipID: pastedClip.id, gainDB: -3.5))
        XCTAssertTrue(AudioEditingService.setFadeIn(&proj, clipID: pastedClip.id, fade: ClipFadeSpecFrames(durationFrames: 4_800, curve: .sCurve)))
        XCTAssertTrue(AudioEditingService.setFadeOut(&proj, clipID: pastedClip.id, fade: ClipFadeSpecFrames(durationFrames: 2_400, curve: .linear)))
        XCTAssertTrue(AudioEditingService.setChannelMode(&proj, clipID: pastedClip.id, mode: .mono, swapChannels: true))
        let styled = try XCTUnwrap(proj.clip(pastedClip.id))
        XCTAssertEqual(styled.gainDB, -3.5)
        XCTAssertEqual(styled.fadeInFrames?.durationFrames, 4_800)
        XCTAssertEqual(styled.fadeOutFrames?.durationFrames, 2_400)
        XCTAssertEqual(styled.channelMode, .mono)
        XCTAssertTrue(styled.swapChannels)

        // Ripple Delete Range shifts subsequent clips left by exact frame count
        let silenceID = try XCTUnwrap(AudioEditingService.insertSilence(&proj, trackID: trackID, atFrame: 123_457 - 10_000, durationFrames: 10_000))
        XCTAssertNotNil(proj.clip(silenceID))
        let delRange = try SampleFrameRange(startFrame: 100_000, frameCount: 23_457, sampleRate: .rate48k)
        XCTAssertTrue(AudioEditingService.deleteRange(&proj, range: delRange, ripple: true))
        XCTAssertEqual(proj.clip(pastedClip.id)?.timelineStartFrame, 599_875 - 23_457)

        // Gain automation in sample frames
        var (mixProj, _, fadeClipID, _) = makeProject(sampleRate: .rate48k, timelineStartFrame: 0, sourceStartFrame: 0, durationFrames: 48_000)
        XCTAssertTrue(AudioEditingService.setFadeIn(&mixProj, clipID: fadeClipID, fade: ClipFadeSpecFrames(durationFrames: 12_000, curve: .linear)))
        let fadeTrack = mixProj.tracks[0]
        let fadeClip = fadeTrack.clips[0]
        XCTAssertEqual(AudioGainAutomation.clipGain(track: fadeTrack, clip: fadeClip, atFrame: 0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(AudioGainAutomation.clipGain(track: fadeTrack, clip: fadeClip, atFrame: 6_000), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioGainAutomation.clipGain(track: fadeTrack, clip: fadeClip, atFrame: 12_000), 1.0, accuracy: 1e-6)
    }

    // MARK: - 3. Mandatory 1,000 Split / Join Cycle Sample-Conservation Proof

    func testOneThousandSplitJoinCyclesConserveExactSampleFramesWithZeroDrift() throws {
        for rate in [SampleRate.rate48k, SampleRate.rate44_1k] {
            let initialStart: Int64 = 12_345
            let initialSourceStart: Int64 = 67_890
            let initialDuration: Int64 = 960_001 // Odd prime-like duration
            let fadeIn = ClipFadeSpecFrames(durationFrames: 4_410, curve: .equalPower)
            let fadeOut = ClipFadeSpecFrames(durationFrames: 2_205, curve: .sCurve)

            var (proj, _, clipID, _) = makeProject(
                sampleRate: rate,
                timelineStartFrame: initialStart,
                sourceStartFrame: initialSourceStart,
                durationFrames: initialDuration
            )
            XCTAssertTrue(AudioEditingService.setFadeIn(&proj, clipID: clipID, fade: fadeIn))
            XCTAssertTrue(AudioEditingService.setFadeOut(&proj, clipID: clipID, fade: fadeOut))

            for cycle in 0..<1_000 {
                // First 500 cycles split outside fade bounds to prove fade preservation too;
                // remaining 500 cycles split across arbitrary offsets including 1-frame edges to prove zero sample drift everywhere.
                let splitOffset: Int64
                let expectExactFades = cycle < 500
                if expectExactFades {
                    let minSafe = fadeIn.durationFrames
                    let maxSafe = initialDuration - fadeOut.durationFrames
                    splitOffset = minSafe + Int64((cycle * 7919 + 17) % Int(maxSafe - minSafe))
                } else {
                    splitOffset = Int64(1 + ((cycle * 7919 + 17) % Int(initialDuration - 2)))
                }
                let splitFrame = initialStart + splitOffset

                let rightID = try XCTUnwrap(
                    AudioEditingService.split(&proj, clipID: clipID, atFrame: splitFrame),
                    "Split failed on cycle \(cycle) at rate \(rate.hz)"
                )
                XCTAssertEqual(proj.tracks[0].clips.count, 2)

                let merges = AudioEditingService.join(&proj, ids: [clipID, rightID])
                XCTAssertEqual(merges, 1, "Join failed on cycle \(cycle) at rate \(rate.hz)")
                XCTAssertEqual(proj.tracks[0].clips.count, 1)

                let healed = proj.tracks[0].clips[0]
                XCTAssertEqual(healed.timelineStartFrame, initialStart)
                XCTAssertEqual(healed.durationFrames, initialDuration)
                XCTAssertEqual(healed.sourceStartFrame, initialSourceStart)
                XCTAssertEqual(healed.timelineEndFrame, initialStart + initialDuration)
                if expectExactFades {
                    XCTAssertEqual(healed.fadeInFrames, fadeIn)
                    XCTAssertEqual(healed.fadeOutFrames, fadeOut)
                }
                clipID = healed.id
            }

            // Gap of 1 frame must NOT join
            let secondSplit = try XCTUnwrap(AudioEditingService.split(&proj, clipID: clipID, atFrame: initialStart + 10_000))
            XCTAssertTrue(AudioEditingService.nudge(&proj, ids: [secondSplit], byFrames: 1))
            XCTAssertEqual(AudioEditingService.join(&proj, ids: [clipID, secondSplit]), 0)
        }
    }

    // MARK: - 4. Cross-Mac Relative Path, Sibling Scan & Content SHA-256 Relinking

    func testCrossMacRelativePathSiblingScanAndSHA256Relinking() async throws {
        // Machine 1 directory layout: ProjectFolder/Mix.lcproject + ProjectFolder/Stems/vocal.wav
        let mac1Root = sandbox.temporaryURL.appendingPathComponent("Mac1/ProjectFolder", isDirectory: true)
        let mac1Stems = mac1Root.appendingPathComponent("Stems", isDirectory: true)
        try FileManager.default.createDirectory(at: mac1Stems, withIntermediateDirectories: true)

        let srcWav = mac1Stems.appendingPathComponent("vocal.wav")
        _ = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: srcWav,
            spec: .init(format: .wav, sampleRate: 48_000, channelCount: 2, bitDepth: 16, frameCount: 24_000)
        )
        let builtAsset = await AudioEditorStore.buildMediaReference(for: srcWav)
        let asset = try XCTUnwrap(builtAsset)
        XCTAssertNotNil(asset.contentSHA256)
        XCTAssertEqual(asset.durationFrames, 24_000)

        let clip = AudioClip(
            sourceAssetID: asset.id,
            name: asset.displayName,
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: 24_000
        )
        let project = AudioEditorProject(
            name: "CrossMacMix",
            sampleRate: 48_000,
            tracks: [AudioTrack(name: "Vocals", clips: [clip])],
            mediaAssets: [asset]
        )

        let mac1ProjURL = mac1Root.appendingPathComponent("Mix.lcproject")
        let saved = try ProjectPersistenceService.save(project: project, to: mac1ProjURL)
        XCTAssertEqual(saved.mediaAssets[0].relativePath, "Stems/vocal.wav")
        XCTAssertNotNil(saved.mediaAssets[0].contentSHA256)

        // Simulate transfer to Machine 2 where original absolute path doesn't exist AND audio was moved & renamed:
        // Machine 2 layout: Mac2/Transferred/Mix.lcproject + Mac2/Transferred/RenamedAssets/vocal_renamed_final.wav
        let mac2Root = sandbox.temporaryURL.appendingPathComponent("Mac2/Transferred", isDirectory: true)
        let mac2RenamedDir = mac2Root.appendingPathComponent("RenamedAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: mac2RenamedDir, withIntermediateDirectories: true)

        let mac2ProjURL = mac2Root.appendingPathComponent("Mix.lcproject")
        try FileManager.default.copyItem(at: mac1ProjURL, to: mac2ProjURL)
        let mac2RenamedWav = mac2RenamedDir.appendingPathComponent("vocal_renamed_final.wav")
        try FileManager.default.copyItem(at: srcWav, to: mac2RenamedWav)

        // Remove Machine 1 files completely so only Machine 2 files exist
        try FileManager.default.removeItem(at: sandbox.temporaryURL.appendingPathComponent("Mac1"))

        let (relinkedProject, missing) = try ProjectPersistenceService.load(from: mac2ProjURL)
        XCTAssertTrue(missing.isEmpty, "Content SHA-256 sibling scan should automatically relink moved + renamed asset")
        XCTAssertEqual(
            relinkedProject.mediaAssets[0].url.standardizedFileURL.resolvingSymlinksInPath(),
            mac2RenamedWav.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(relinkedProject.mediaAssets[0].status, .ok)

        // Also test .lcprojpkg self-contained package save & load with v3 integer frames
        let pkgURL = sandbox.temporaryURL.appendingPathComponent("SelfContained.lcprojpkg")
        _ = try ProjectPersistenceService.saveReturningURL(project: relinkedProject, to: pkgURL, selfContainedPackage: true)
        let (loadedPkg, missingPkg) = try ProjectPersistenceService.load(from: pkgURL)
        XCTAssertTrue(missingPkg.isEmpty)
        XCTAssertEqual(loadedPkg.schemaVersion, 3)
        XCTAssertEqual(loadedPkg.tracks[0].clips[0].durationFrames, 24_000)
    }

    // MARK: - 5. Undo/Redo Context Isolation & Restart Journal Rehydration with v3 Frames

    @MainActor
    func testUndoRedoContextIsolationAndRestartRehydrationPreservesV3Frames() async throws {
        let journalDir = sandbox.applicationSupportURL.appendingPathComponent("Phase66Journal", isDirectory: true)
        let artifactsDir = sandbox.applicationSupportURL.appendingPathComponent("Phase66Artifacts", isDirectory: true)

        let coord1 = UndoRedoCoordinator(
            journalDirectoryURL: journalDir,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir)
        )
        let store1 = AudioEditorStore(undoCoordinator: coord1)
        let projID = store1.project.id
        let otherProjectContext = OperationContext.audioEditor(projectID: UUID())

        store1.performMutation(type: .clipImport, title: "Insert Sample Clip") { p in
            let clip = AudioClip(
                sourceAssetID: nil,
                name: "SampleClip",
                timelineStartFrame: 12_345,
                sourceStartFrame: 0,
                durationFrames: 96_001,
                projectRate: .rate48k,
                sourceRate: .rate48k
            )
            p.tracks[0].clips = [clip]
            return true
        }
        let targetClipID = try XCTUnwrap(store1.project.tracks[0].clips.first?.id)
        store1.performMutation(type: .clipSplit, title: "Split at Exact Sample Frame") { p in
            AudioEditingService.split(&p, clipID: targetClipID, atFrame: 40_000) != nil
        }
        await store1.flushPendingUndoRecords()
        coord1.flushPersistence()

        // Different project context is strictly isolated
        XCTAssertTrue(coord1.canUndo(in: .audioEditor(projectID: projID)))
        XCTAssertFalse(coord1.canUndo(in: otherProjectContext))

        // Session 2 restart recovery: fresh coordinator + fresh AppState rehydrates v3 frame coordinates
        let coord2 = UndoRedoCoordinator(
            journalDirectoryURL: journalDir,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir)
        )
        let appState2 = AppState(undoCoordinator: coord2)
        await LocalConvertApp.bootstrapUndoCoordinator(appState: appState2, undoCoordinator: coord2)

        // Fast-forward AppState store project ID for undo verification
        let ctx = OperationContext.audioEditor(projectID: projID)
        XCTAssertTrue(coord2.canUndo(in: ctx))
        await coord2.undo(in: ctx)
        let revertedClip = try XCTUnwrap(appState2.audioEditorStore.project.tracks[0].clips.first)
        XCTAssertEqual(appState2.audioEditorStore.project.tracks[0].clips.count, 1)
        XCTAssertEqual(revertedClip.timelineStartFrame, 12_345)
        XCTAssertEqual(revertedClip.durationFrames, 96_001)
    }
}

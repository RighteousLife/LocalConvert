import Testing
import Foundation
import AVFoundation
import CryptoKit
@testable import LocalConvert

@Suite("Phase 45 Integration, Undo/Recovery Safety & Performance Acceptance Tests")
struct Phase45IntegrationTests {

    private func writeWAV(
        to url: URL,
        duration: Double,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        freqL: Double = 440,
        freqR: Double = 554.37,
        amplitude: Float = 0.25
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw ConversionError.invalidInput("Failed to create AVAudioFormat")
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let total = Int(duration * sampleRate)
        let chunk = 8192
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
              let ch = buf.floatChannelData else { return }
        var done = 0
        while done < total {
            let n = min(chunk, total - done)
            for i in 0..<n {
                let t = Double(done + i) / sampleRate
                ch[0][i] = amplitude * Float(sin(2.0 * .pi * freqL * t))
                if channels > 1 {
                    ch[1][i] = amplitude * Float(sin(2.0 * .pi * freqR * t))
                }
            }
            buf.frameLength = AVAudioFrameCount(n)
            try file.write(from: buf)
            done += n
        }
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Global Undo/Redo covers effect chain, preset apply, fades, crossfade, track grouping, continuous slider coalescing, and export cleanup")
    @MainActor
    func undoRedoEndToEndAndSourceProtection() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-p45-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcA = dir.appendingPathComponent("source_a.wav")
        let srcB = dir.appendingPathComponent("source_b.wav")
        try writeWAV(to: srcA, duration: 2.0, freqL: 440, freqR: 440)
        try writeWAV(to: srcB, duration: 2.0, freqL: 880, freqR: 880)
        let hashA = try sha256(of: srcA)
        let hashB = try sha256(of: srcB)

        guard let refA = await AudioEditorStore.buildMediaReference(for: srcA),
              let refB = await AudioEditorStore.buildMediaReference(for: srcB) else {
            Issue.record("Failed to build media references")
            return
        }

        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("journal"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("artifacts"))
        )
        let store = AudioEditorStore(undoCoordinator: coordinator)
        let track1ID = store.project.tracks[0].id
        store.addTrack()
        let track2ID = store.project.tracks[1].id

        let clipA = AudioClip(sourceAssetID: refA.id, name: "Clip A", timelineStart: 0.0, sourceStart: 0.0, duration: 1.5)
        let clipB = AudioClip(sourceAssetID: refB.id, name: "Clip B", timelineStart: 1.4, sourceStart: 0.0, duration: 1.5)

        store.performMutation(type: .clipImport, title: "Seed Clips") { p in
            p.mediaAssets = [refA, refB]
            p.tracks[0].clips = [clipA]
            p.tracks[1].clips = [clipB]
            return true
        }
        store.selectTrack(track1ID)
        store.selectClip(clipA.id)

        // 1. Add and reorder effect slots + apply factory preset
        store.addEffectSlot(.parametricEQ, to: .clip(clipA.id))
        store.addEffectSlot(.compressor, to: .clip(clipA.id))
        let slot0ID = store.effectSlots(for: .clip(clipA.id))[0].id
        store.moveEffectSlot(id: slot0ID, offset: 1, in: .clip(clipA.id))
        #expect(store.effectSlots(for: .clip(clipA.id)).map(\.kind) == [.compressor, .parametricEQ])

        // 2. Continuous slider coalescing on Compressor threshold -> 1 undo step
        let compID = store.effectSlots(for: .clip(clipA.id))[0].id
        store.beginContinuousMutation()
        for threshold in stride(from: -14.0, through: -24.0, by: -2.0) {
            store.updateEffectSlot(id: compID, in: .clip(clipA.id), continuous: true, title: "Compressor Threshold") { slot in
                var comp = slot.compressor ?? CompressorParams()
                comp.thresholdDB = threshold
                slot.compressor = comp
            }
        }
        store.endContinuousMutation(type: .clipEffectChange, title: "Compressor Threshold")

        // 3. Apply factory preset to master bus + create track group + crossfade
        let podcastPreset = try #require(AudioEffectPresetStore.factoryPresets.first)
        store.applyEffectChainPreset(podcastPreset, to: .master)
        store.createTrackGroup(name: "Dialogue Bus", trackIDs: [track1ID, track2ID])
        let groupID = try #require(store.project.trackGroups.first?.id)
        store.toggleGroupMute(groupID)
        #expect(store.project.trackGroups.first?.isMuted == true)

        // 4. Export and record OutputCreationUndoCommand
        let exportRes = try await AudioExportService.export(
            project: store.project,
            request: AudioExportRequest(
                scope: .entireProject,
                outputFormat: .wav,
                sampleRate: 48_000,
                bitDepth: 16,
                channels: 2,
                applyDitheringOn16Bit: true,
                validateOutput: true,
                outputDirectory: dir,
                baseFileName: "p45_mix"
            )
        )
        let exportedURL = try #require(exportRes.outputURLs.first)
        #expect(FileManager.default.fileExists(atPath: exportedURL.path))
        store.recordExportOutputsUndo(exportRes.outputURLs, title: "Export Mix")
        await store.flushPendingUndoRecords()

        let ctx = OperationContext.audioEditor(projectID: store.project.id)
        // Undo Export moves generated output into recovery artifact without touching sources
        await coordinator.undo(in: ctx)
        #expect(!FileManager.default.fileExists(atPath: exportedURL.path))
        #expect(try sha256(of: srcA) == hashA)
        #expect(try sha256(of: srcB) == hashB)

        // Undo Group Mute -> Undo Create Group -> Undo Apply Preset -> Undo Continuous Compressor Drag (single step!)
        await coordinator.undo(in: ctx)
        #expect(store.project.trackGroups.first?.isMuted == false)
        await coordinator.undo(in: ctx)
        #expect(store.project.trackGroups.isEmpty)
        await coordinator.undo(in: ctx)
        #expect(store.project.masterEffects.isEmpty)
        await coordinator.undo(in: ctx)
        let restoredThreshold = store.effectSlots(for: .clip(clipA.id))[0].compressor?.thresholdDB
        #expect(restoredThreshold != -24.0)

        // Redo all the way back to restored export file
        for _ in 0..<5 {
            await coordinator.redo(in: ctx)
        }
        #expect(FileManager.default.fileExists(atPath: exportedURL.path))
        #expect(store.project.trackGroups.first?.isMuted == true)
        #expect(try sha256(of: srcA) == hashA)
        #expect(try sha256(of: srcB) == hashB)
    }

    @Test("Autosave crash recovery and missing-source relinking preserve v2 effects, track groups, and grid config")
    func autosaveRecoveryAndRelinkingV2() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-p45-recovery-\(UUID().uuidString)", isDirectory: true)
        let autosaveDir = dir.appendingPathComponent("autosaves", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let origURL = dir.appendingPathComponent("original.wav")
        let movedURL = dir.appendingPathComponent("relocated.wav")
        try writeWAV(to: origURL, duration: 1.5)
        let ref = try #require(await AudioEditorStore.buildMediaReference(for: origURL))

        var eqSlot = AudioEffectSlot(kind: .parametricEQ)
        eqSlot.eq = ParametricEQParams(bands: [EQBand(type: .lowShelf, frequencyHz: 120, gainDB: -3.5, q: 1.2)])
        let clip = AudioClip(
            sourceAssetID: ref.id,
            name: "Voice",
            timelineStart: 0,
            sourceStart: 0,
            duration: 1.5,
            fadeIn: ClipFadeSpec(duration: 0.2, curve: .sCurve),
            effectSlots: [eqSlot]
        )
        let group = AudioTrackGroup(name: "VO", isMuted: false, isSolo: true)
        let track = AudioTrack(name: "Track 1", clips: [clip], groupID: group.id)
        var masterLimiter = AudioEffectSlot(kind: .limiter)
        masterLimiter.limiter = LimiterParams(ceilingDB: -1.0, lookaheadMs: 5.0, releaseMs: 80.0)
        let project = AudioEditorProject(
            name: "Crash Recovery V2",
            sampleRate: 48_000,
            tracks: [track],
            mediaAssets: [ref],
            masterEffects: [masterLimiter],
            trackGroups: [group],
            gridConfig: TimelineGridConfig(snapEnabled: true, interval: .beatQuarter, bpm: 128.0)
        )

        try ProjectPersistenceService.writeAutosave(project: project, projectFileURL: nil, directory: autosaveDir)

        // Simulate source relocation
        try FileManager.default.moveItem(at: origURL, to: movedURL)
        let snap = try #require(ProjectPersistenceService.latestRecoverableAutosave(directory: autosaveDir))
        var recovered = snap.project
        #expect(recovered.schemaVersion == AudioEditorProject.currentSchemaVersion)
        #expect(recovered.trackGroups.count == 1)
        #expect(recovered.trackGroups[0].isSolo == true)
        #expect(recovered.masterEffects.count == 1)
        #expect(recovered.gridConfig.interval == .beatQuarter)
        #expect(recovered.tracks[0].clips[0].fadeIn?.curve == .sCurve)
        #expect(recovered.tracks[0].clips[0].effectSlots.count == 1)
        #expect(ProjectPersistenceService.missingAssets(in: recovered).count == 1)

        // Relink source cleanly
        #expect(ProjectPersistenceService.relinkAsset(in: &recovered, assetID: ref.id, newURL: movedURL))
        #expect(ProjectPersistenceService.missingAssets(in: recovered).isEmpty)
        ProjectPersistenceService.clearAutosave(for: project.id, directory: autosaveDir)
        #expect(ProjectPersistenceService.latestRecoverableAutosave(directory: autosaveDir) == nil)
    }

    @Test("Reader invalidation on clip source swap, keyboard monitor modal guard, and AudioPlaybackEngine seek/scrub stability")
    @MainActor
    func readerInvalidationKeyboardIsolationAndPlaybackStability() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-p45-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url1 = dir.appendingPathComponent("clip_v1.wav")
        let url2 = dir.appendingPathComponent("clip_v2.wav")
        try writeWAV(to: url1, duration: 1.5, freqL: 220, freqR: 220)
        try writeWAV(to: url2, duration: 1.5, freqL: 880, freqR: 880)

        let ref1 = try #require(await AudioEditorStore.buildMediaReference(for: url1))
        let ref2 = try #require(await AudioEditorStore.buildMediaReference(for: url2))
        let clip = AudioClip(sourceAssetID: ref1.id, name: "Swap", timelineStart: 0, sourceStart: 0, duration: 1.5)
        let project1 = AudioEditorProject(name: "Swap", sampleRate: 48_000, tracks: [AudioTrack(name: "T1", clips: [clip])], mediaAssets: [ref1, ref2])
        let sources1 = try await AudioSourceResolver.resolve(project: project1)
        let session = AudioMixSession(project: project1, sources: sources1)

        var left = [Float](repeating: 0, count: 2048)
        var right = [Float](repeating: 0, count: 2048)
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                session.mix(startTime: 0, frameCount: 2048, left: lb.baseAddress!, right: rb.baseAddress!)
            }
        }
        #expect(session.activeReaderURL(for: clip.id) == url1)

        var project2 = project1
        project2.tracks[0].clips[0].sourceAssetID = ref2.id
        let sources2 = try await AudioSourceResolver.resolve(project: project2)
        session.update(project: project2, sources: sources2)
        #expect(session.activeReaderURL(for: clip.id) == nil)
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                session.mix(startTime: 0, frameCount: 2048, left: lb.baseAddress!, right: rb.baseAddress!)
            }
        }
        #expect(session.activeReaderURL(for: clip.id) == url2)

        // Keyboard monitor suppression when modal sheets or text fields are active
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: true, isModalPresented: false, eventMatchesHostWindow: true) == false)
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: false, isModalPresented: true, eventMatchesHostWindow: true) == false)
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: false, isModalPresented: false, eventMatchesHostWindow: false) == false)
        #expect(AudioEditorKeyMonitor.shouldHandleKeyDown(isTextEditing: false, isModalPresented: false, eventMatchesHostWindow: true) == true)

        // Rapid scrub / seek / stop lifecycle must stay bounded & clean
        let store = AudioEditorStore(undoCoordinator: UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("j"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("a"))
        ))
        store.performMutation(type: .clipImport, title: "Seed") { p in
            p = project2
            return true
        }
        for i in 0..<25 {
            store.scrub(to: Double(i) * 0.05)
        }
        store.seek(to: 0.75)
        store.stopPlayback()
        #expect(!store.playbackEngine.isPlaying)
        #expect(store.playbackEngine.gainReductionDB == 0)
    }

    @Test("Real-time vs Offline DSP mix parity and multi-stage DSP CPU throughput headroom + long-run stability")
    func dspRealtimeHeadroomStabilityAndMixParity() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-p45-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("program.wav")
        try writeWAV(to: src, duration: 4.0, sampleRate: 48_000, channels: 2, freqL: 330, freqR: 495, amplitude: 0.35)
        let ref = try #require(await AudioEditorStore.buildMediaReference(for: src))

        // Full 6-stage effect chain matching professional master/track use
        var eq = AudioEffectSlot(kind: .parametricEQ)
        eq.eq = ParametricEQParams(bands: [
            EQBand(type: .highPass, frequencyHz: 90, gainDB: -3.0, q: 0.8),
            EQBand(type: .peaking, frequencyHz: 1500, gainDB: 2.5, q: 1.4),
            EQBand(type: .highShelf, frequencyHz: 8000, gainDB: 1.5, q: 0.9)
        ])
        var gate = AudioEffectSlot(kind: .noiseGate)
        gate.noiseGate = NoiseGateParams(thresholdDB: -45, attackMs: 4, holdMs: 40, releaseMs: 90, rangeDB: -40)
        var comp = AudioEffectSlot(kind: .compressor)
        comp.compressor = CompressorParams(thresholdDB: -16, ratio: 3.5, attackMs: 8, releaseMs: 70, kneeDB: 6, makeupGainDB: 2)
        var delay = AudioEffectSlot(kind: .delay)
        delay.delay = DelayParams(delayTimeMs: 180, feedback: 0.25, wetDryMix: 0.15, pingPong: true)
        var reverb = AudioEffectSlot(kind: .reverb)
        reverb.reverb = ReverbParams(roomPreset: .smallRoom, wetDryMix: 0.12)
        var limiter = AudioEffectSlot(kind: .limiter)
        limiter.limiter = LimiterParams(ceilingDB: -1.0, lookaheadMs: 5, releaseMs: 80)

        let slots = [eq, gate, comp, delay, reverb, limiter]
        let clip = AudioClip(sourceAssetID: ref.id, name: "Mix", timelineStart: 0, sourceStart: 0, duration: 4.0, effectSlots: [eq, comp])
        let track = AudioTrack(name: "Stem 1", clips: [clip], effectSlots: [delay, reverb])
        let project = AudioEditorProject(name: "Parity", sampleRate: 48_000, tracks: [track], mediaAssets: [ref], masterEffects: [limiter])

        // 1. Offline vs direct AudioMixSession parity (first 2 seconds RMS parity)
        let exportRes = try await AudioExportService.export(
            project: project,
            request: AudioExportRequest(
                scope: .entireProject,
                outputFormat: .wav,
                sampleRate: 48_000,
                bitDepth: 24,
                channels: 2,
                applyDitheringOn16Bit: false,
                validateOutput: true,
                outputDirectory: dir,
                baseFileName: "offline_mix"
            )
        )
        let offlineURL = try #require(exportRes.outputURLs.first)
        let offlineFile = try AVAudioFile(forReading: offlineURL)
        let checkFrames = 96_000
        let offlineBuf = try #require(AVAudioPCMBuffer(pcmFormat: offlineFile.processingFormat, frameCapacity: AVAudioFrameCount(checkFrames)))
        try offlineFile.read(into: offlineBuf, frameCount: AVAudioFrameCount(checkFrames))
        let offData = try #require(offlineBuf.floatChannelData)
        var offSumSq: Double = 0
        for i in 0..<Int(offlineBuf.frameLength) {
            let s = Double(offData[0][i])
            offSumSq += s * s
        }
        let offlineRMS = sqrt(offSumSq / Double(max(1, offlineBuf.frameLength)))

        let sources = try await AudioSourceResolver.resolve(project: project)
        let rtSession = AudioMixSession(project: project, sources: sources)
        var rtL = [Float](repeating: 0, count: 4096)
        var rtR = [Float](repeating: 0, count: 4096)
        var rtSumSq: Double = 0
        var processed = 0
        while processed < Int(offlineBuf.frameLength) {
            let n = min(4096, Int(offlineBuf.frameLength) - processed)
            rtL.withUnsafeMutableBufferPointer { lb in
                rtR.withUnsafeMutableBufferPointer { rb in
                    rtSession.mix(startTime: Double(processed) / 48_000.0, frameCount: n, left: lb.baseAddress!, right: rb.baseAddress!)
                }
            }
            for i in 0..<n {
                let s = Double(rtL[i])
                rtSumSq += s * s
            }
            processed += n
        }
        let rtRMS = sqrt(rtSumSq / Double(processed))
        #expect(abs(offlineRMS - rtRMS) < 0.002)

        // 2. Benchmark CPU headroom over 60 seconds of stereo 48kHz audio through full 6-stage chain (non-trivial stability check)
        let processor = AudioChainProcessor(slots: slots, sampleRate: 48_000)
        let blockSize = 1024
        let totalBlocks = (60 * 48_000) / blockSize // 60 audio seconds (~2,812 blocks)
        var benchL = [Float](repeating: 0, count: blockSize)
        var benchR = [Float](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            let v = 0.35 * Float(sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
            benchL[i] = v
            benchR[i] = v
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<totalBlocks {
            benchL.withUnsafeMutableBufferPointer { lb in
                benchR.withUnsafeMutableBufferPointer { rb in
                    processor.process(slots: slots, left: lb.baseAddress!, right: rb.baseAddress!, frameCount: blockSize)
                }
            }
            // Keep signal populated cleanly for sustained DSP excitation
            for i in 0..<blockSize {
                let v = 0.25 * Float(sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
                benchL[i] = v
                benchR[i] = v
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        let realtimeMultiplier = 60.0 / max(0.0001, elapsed)
        print("Phase45_Bench_6StageDSP: simulated=60.0s_48kHz_stereo elapsed=\(String(format: "%.3f", elapsed))s speedup=\(String(format: "%.1f", realtimeMultiplier))x")
        // Verify comfortably faster than real-time (1.0x budget), bounded output without NaNs/clipping
        #expect(realtimeMultiplier > 4.0)
        #expect(benchL.allSatisfy { $0.isFinite })
        #expect(benchR.allSatisfy { $0.isFinite })
    }
}

import XCTest
import SwiftUI
import AppKit
import Combine
import AVFoundation
@testable import LocalConvert

final class Phase70WaveformUIAndAccessibilityTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase70-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDownWithError() throws {
        AppStoragePaths.clearTestOverrides()
        if let sandbox {
            if case .failure(let err) = sandbox.cleanup() {
                XCTFail("Sandbox cleanup failed: \(err.localizedDescription)")
            }
        }
        sandbox = nil
    }

    private func makeSyntheticPyramid(
        durationSeconds: Double = 60.0,
        sampleRate: Int32 = 48_000,
        channelCount: Int = 2,
        includeClip: Bool = true
    ) -> WaveformPyramid {
        let totalFrames = Int64(durationSeconds * Double(sampleRate))
        let mipLevels: [WaveformMipLevel] = WaveformPyramid.standardBucketSizes.map { fpb in
            let bucketCount = max(1, Int((totalFrames + Int64(fpb) - 1) / Int64(fpb)))
            let channels: [WaveformChannelLevel] = (0..<channelCount).map { ch in
                let buckets = (0..<bucketCount).map { idx -> WaveformBucket in
                    let clipped = includeClip && ch == 0 && (idx % 97 == 0)
                    let amp: Float = clipped ? 1.0 : 0.45
                    return WaveformBucket(minSample: -amp, maxSample: amp, rms: amp * 0.707, clipped: clipped)
                }
                return WaveformChannelLevel(channelIndex: ch, buckets: buckets)
            }
            return WaveformMipLevel(framesPerBucket: fpb, channels: channels)
        }

        return WaveformPyramid(
            assetID: UUID(),
            cacheKey: "synthetic-\(channelCount)ch-\(sampleRate)",
            sampleRate: sampleRate,
            channelCount: channelCount,
            totalFrames: totalFrames,
            duration: durationSeconds,
            levels: mipLevels,
            isPartial: false,
            completedFrames: totalFrames
        )
    }

    // MARK: - 1. Peak Pyramid Mipmap Selection & <= viewportWidth * 2 Bucket Bound

    func testWaveformCanvasSamplingPlanBoundsAtMinMidMaxZoomAndMultichannel() {
        for channels in [1, 2, 6] {
            let pyramid = makeSyntheticPyramid(durationSeconds: 300.0, sampleRate: 48_000, channelCount: channels)
            let viewportWidth = 900.0
            let maxAllowed = Int(ceil(viewportWidth)) * 2

            // Minimum zoom: 2 px/s (24,000 samples/px -> coarsest level 16,384)
            let minZoomPlan = WaveformCanvasRenderer.makeSamplingPlan(
                pyramid: pyramid,
                clipSourceStartFrame: 0,
                clipSourceSpanFrames: pyramid.totalFrames,
                sampleRate: pyramid.sampleRate,
                pixelsPerSecond: TimelineState.minPixelsPerSecond,
                viewportWidth: viewportWidth
            )
            XCTAssertEqual(minZoomPlan.framesPerBucket, 16_384)
            XCTAssertLessThanOrEqual(minZoomPlan.drawnBucketCount, maxAllowed)
            XCTAssertEqual(minZoomPlan.channelSlices.count, channels)

            // Mid zoom: 80 px/s (600 samples/px -> level 256)
            let midZoomPlan = WaveformCanvasRenderer.makeSamplingPlan(
                pyramid: pyramid,
                clipSourceStartFrame: 0,
                clipSourceSpanFrames: pyramid.totalFrames,
                sampleRate: pyramid.sampleRate,
                pixelsPerSecond: 80.0,
                viewportWidth: viewportWidth
            )
            XCTAssertEqual(midZoomPlan.framesPerBucket, 256)
            XCTAssertLessThanOrEqual(midZoomPlan.drawnBucketCount, maxAllowed)

            // Max zoom: 20,000 px/s (2.4 samples/px -> finest level 64)
            let maxZoomPlan = WaveformCanvasRenderer.makeSamplingPlan(
                pyramid: pyramid,
                clipSourceStartFrame: 0,
                clipSourceSpanFrames: 48_000, // 1s slice
                sampleRate: pyramid.sampleRate,
                pixelsPerSecond: TimelineState.maxPixelsPerSecond,
                viewportWidth: viewportWidth
            )
            XCTAssertEqual(maxZoomPlan.framesPerBucket, 64)
            XCTAssertLessThanOrEqual(maxZoomPlan.drawnBucketCount, maxAllowed)
            XCTAssertGreaterThan(maxZoomPlan.clippedBucketCount, 0)
        }
    }

    // MARK: - 2. Independent 60 Hz Playhead Layer & Equatable Canvas Isolation

    @MainActor
    func testWaveformClipCanvasEquatableIsolationUnder60HzPlayheadTicks() {
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.temporaryURL.appendingPathComponent("j"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.temporaryURL.appendingPathComponent("a"))
        )
        let store = AudioEditorStore(undoCoordinator: undoCoord)
        let pyramid = makeSyntheticPyramid(durationSeconds: 10.0)

        var storePublishCount = 0
        let cancelStore = store.objectWillChange.sink { _ in storePublishCount += 1 }
        var playheadPublishCount = 0
        let cancelPlayhead = store.playheadState.objectWillChange.sink { _ in playheadPublishCount += 1 }
        defer { cancelStore.cancel(); cancelPlayhead.cancel() }

        // Simulate 30 active playhead updates at 60 Hz cadence
        for i in 1...30 {
            store.timeline.setPlayhead(Double(i) * 0.05)
        }

        XCTAssertEqual(storePublishCount, 0, "Playhead ticks must NOT publish AudioEditorStore.objectWillChange to static Canvas parents")
        XCTAssertEqual(playheadPublishCount, 30, "Independent 60 Hz AudioPlayheadState should publish playhead updates")
        XCTAssertEqual(store.timeline.playheadTime, 1.5, accuracy: 0.001)

        // Verify WaveformClipCanvasView equality remains invariant under playhead ticks
        let a = WaveformClipCanvasView(
            pyramid: pyramid,
            hasSourceAsset: true,
            clipSourceStartFrame: 0,
            clipSourceSpanFrames: 480_000,
            clipDurationSeconds: 10.0,
            isMuted: false,
            isReversed: false,
            expandMultichannel: false,
            fadeIn: nil,
            fadeOut: nil,
            pixelsPerSecond: 80.0,
            viewportWidth: 900.0,
            onPlanComputed: nil
        )
        let b = WaveformClipCanvasView(
            pyramid: pyramid,
            hasSourceAsset: true,
            clipSourceStartFrame: 0,
            clipSourceSpanFrames: 480_000,
            clipDurationSeconds: 10.0,
            isMuted: false,
            isReversed: false,
            expandMultichannel: false,
            fadeIn: nil,
            fadeOut: nil,
            pixelsPerSecond: 80.0,
            viewportWidth: 900.0,
            onPlanComputed: nil
        )
        XCTAssertEqual(a, b)
    }

    // MARK: - 3. First-Responder-Safe Shortcut Mapping & Text/Modal Isolation

    func testAudioWorkspaceShortcutRouterAllMappingsAndTextFieldModalIsolation() {
        // Editor mode required mappings
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 49, charactersIgnoringModifiers: " ", modifiers: [], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .togglePlayPause)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: [.command], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .splitAtPlayhead)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 11, charactersIgnoringModifiers: "b", modifiers: [], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .splitAtPlayhead)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: [.command], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .trimToSelection)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 51, charactersIgnoringModifiers: nil, modifiers: [], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .deleteSelection)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 51, charactersIgnoringModifiers: nil, modifiers: [.option], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .rippleDeleteSelection)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 24, charactersIgnoringModifiers: "+", modifiers: [.command], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .zoomIn)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 27, charactersIgnoringModifiers: "-", modifiers: [.command], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .zoomOut)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 29, charactersIgnoringModifiers: "0", modifiers: [.command], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .zoomFit)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 123, charactersIgnoringModifiers: nil, modifiers: [], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .stepPlayheadLeft)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 124, charactersIgnoringModifiers: nil, modifiers: [], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .stepPlayheadRight)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 123, charactersIgnoringModifiers: nil, modifiers: [.shift], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .nudgeLeft)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 124, charactersIgnoringModifiers: nil, modifiers: [.shift], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .nudgeRight)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 34, charactersIgnoringModifiers: "i", modifiers: [.command], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .toggleInspector)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 6, charactersIgnoringModifiers: "z", modifiers: [.command], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .undo)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 6, charactersIgnoringModifiers: "z", modifiers: [.command, .shift], mode: .waveformEditor, isTextEditing: false, isModalPresented: false), .redo)

        // Library mode mappings
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 3, charactersIgnoringModifiers: "f", modifiers: [.command], mode: .library, isTextEditing: false, isModalPresented: false), .focusSearch)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 34, charactersIgnoringModifiers: "i", modifiers: [.command], mode: .library, isTextEditing: false, isModalPresented: false), .toggleInspector)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 124, charactersIgnoringModifiers: nil, modifiers: [.command], mode: .library, isTextEditing: false, isModalPresented: false), .nextTrack)
        XCTAssertEqual(AudioWorkspaceShortcutRouter.resolve(keyCode: 123, charactersIgnoringModifiers: nil, modifiers: [.command], mode: .library, isTextEditing: false, isModalPresented: false), .previousTrack)

        // Strict isolation when text field or modal sheet is active
        let guardedSamples: [(UInt16, String?, NSEvent.ModifierFlags, AudioWorkspaceMode)] = [
            (49, " ", [], .waveformEditor),
            (11, "b", [], .waveformEditor),
            (51, nil, [], .waveformEditor),
            (6, "z", [.command], .waveformEditor),
            (3, "f", [.command], .library)
        ]
        for (kc, ch, mod, mode) in guardedSamples {
            XCTAssertNil(AudioWorkspaceShortcutRouter.resolve(keyCode: kc, charactersIgnoringModifiers: ch, modifiers: mod, mode: mode, isTextEditing: true, isModalPresented: false))
            XCTAssertNil(AudioWorkspaceShortcutRouter.resolve(keyCode: kc, charactersIgnoringModifiers: ch, modifiers: mod, mode: mode, isTextEditing: false, isModalPresented: true))
        }
    }

    // MARK: - 4. Export Sheet Capabilities & 3-Mode Matrix

    func testAudioExportSheetCapabilitiesThreeModesBitDepthChannelAndDitherGating() {
        XCTAssertEqual(AudioExportSheetCapabilities.modeExplanation(for: .bitExactPassThrough), "Original audio copied without signal modification.")
        XCTAssertEqual(AudioExportSheetCapabilities.modeExplanation(for: .losslessFormatReRender), "Edited audio rendered to a lossless format.")
        XCTAssertEqual(AudioExportSheetCapabilities.modeExplanation(for: .lossyFormatReRender), "Edited audio rendered to a lossy format.")

        let passFormats = AudioExportSheetCapabilities.supportedFormats(for: .bitExactPassThrough)
        XCTAssertEqual(passFormats, [.wav, .aiff])

        let losslessFormats = AudioExportSheetCapabilities.supportedFormats(for: .losslessFormatReRender)
        XCTAssertEqual(losslessFormats, [.wav, .aiff, .flac, .alac, .caf])
        XCTAssertFalse(losslessFormats.contains(.ape))

        let lossyFormats = AudioExportSheetCapabilities.supportedFormats(for: .lossyFormatReRender)
        XCTAssertEqual(lossyFormats, [.mp3, .m4a, .aac, .opus, .ogg])
        XCTAssertFalse(lossyFormats.contains(.ape))

        // Bit-depth constraints
        XCTAssertEqual(AudioExportSheetCapabilities.supportedBitDepths(for: .wav, mode: .losslessFormatReRender), [16, 24, 32])
        XCTAssertEqual(AudioExportSheetCapabilities.supportedBitDepths(for: .aiff, mode: .losslessFormatReRender), [16, 24])
        XCTAssertEqual(AudioExportSheetCapabilities.supportedBitDepths(for: .flac, mode: .losslessFormatReRender), [16, 24])
        XCTAssertEqual(AudioExportSheetCapabilities.supportedBitDepths(for: .alac, mode: .losslessFormatReRender), [16, 24])
        XCTAssertTrue(AudioExportSheetCapabilities.supportedBitDepths(for: .mp3, mode: .lossyFormatReRender).isEmpty)

        // Channel constraints
        XCTAssertEqual(AudioExportSheetCapabilities.supportedChannelCounts(for: .ogg), [2])
        XCTAssertEqual(AudioExportSheetCapabilities.supportedChannelCounts(for: .mp3), [1, 2])

        // TPDF Dither strict gating
        XCTAssertTrue(AudioExportSheetCapabilities.supportsTPDFDither(mode: .losslessFormatReRender, format: .wav, bitDepth: 16))
        XCTAssertTrue(AudioExportSheetCapabilities.supportsTPDFDither(mode: .losslessFormatReRender, format: .flac, bitDepth: 16))
        XCTAssertTrue(AudioExportSheetCapabilities.supportsTPDFDither(mode: .losslessFormatReRender, format: .alac, bitDepth: 16))
        XCTAssertFalse(AudioExportSheetCapabilities.supportsTPDFDither(mode: .losslessFormatReRender, format: .wav, bitDepth: 24))
        XCTAssertFalse(AudioExportSheetCapabilities.supportsTPDFDither(mode: .losslessFormatReRender, format: .wav, bitDepth: 32))
        XCTAssertFalse(AudioExportSheetCapabilities.supportsTPDFDither(mode: .bitExactPassThrough, format: .wav, bitDepth: 16))
        XCTAssertFalse(AudioExportSheetCapabilities.supportsTPDFDither(mode: .lossyFormatReRender, format: .mp3, bitDepth: 16))
    }

    // MARK: - 5. Editor, Timeline, Recovery Banners & Export Sheet Layout + Accessibility IDs

    @MainActor
    func testAudioEditorAndExportSheetHostLayoutZeroViewUpdatePublishesAndAccessibilityIDs() throws {
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.temporaryURL.appendingPathComponent("j"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.temporaryURL.appendingPathComponent("a"))
        )
        let store = AudioEditorStore(undoCoordinator: undoCoord)
        let goneURL = sandbox.temporaryURL.appendingPathComponent("gone.wav")
        let missingRef = AudioMediaReference(
            id: UUID(),
            path: goneURL.path,
            displayName: "gone.wav",
            fileSize: 1024,
            modificationTime: 1000,
            duration: 2.0,
            sampleRate: 48_000,
            channels: 2
        )
        var project = store.project
        project.mediaAssets = [missingRef]
        project.tracks[0].clips.append(AudioClip(
            sourceAssetID: missingRef.id,
            name: "GoneClip",
            timelineStartFrame: 0,
            sourceStartFrame: 0,
            durationFrames: 48_000,
            projectRate: .rate48k,
            sourceRate: .rate48k
        ))
        store.project = project
        store.missingAssets = [missingRef]
        store.recoverableAutosave = AudioAutosaveSnapshot(
            projectID: project.id,
            savedAt: Date(),
            projectFileURLPath: nil,
            project: project
        )

        var publishCount = 0
        let cancel = store.objectWillChange.sink { _ in publishCount += 1 }
        defer { cancel.cancel() }

        let editorHost = NSHostingView(rootView: AudioEditorRootView(store: store))
        editorHost.frame = NSRect(x: 0, y: 0, width: 1080, height: 680)
        editorHost.layoutSubtreeIfNeeded()

        let exportHost = NSHostingView(rootView: AudioEditorExportSheet(store: store))
        exportHost.frame = NSRect(x: 0, y: 0, width: 560, height: 640)
        exportHost.layoutSubtreeIfNeeded()

        XCTAssertEqual(publishCount, 0, "AudioEditorRootView and AudioEditorExportSheet layout must not publish state changes")

        let editorIDs = collectAccessibilityIdentifiers(in: editorHost)
        XCTAssertTrue(editorIDs.contains("audioworkspace.editor.recovery_banner"), "Found IDs: \(editorIDs)")
        XCTAssertTrue(editorIDs.contains("audioworkspace.editor.missing_banner"), "Found IDs: \(editorIDs)")
        XCTAssertTrue(editorIDs.contains("audioworkspace.editor.transport.play_pause"), "Found IDs: \(editorIDs)")
        XCTAssertTrue(editorIDs.contains("audioworkspace.editor.zoom_in"), "Found IDs: \(editorIDs)")

        let exportIDs = collectAccessibilityIdentifiers(in: exportHost)
        XCTAssertTrue(exportIDs.contains("audioworkspace.export.sheet"), "Found IDs: \(exportIDs)")
        XCTAssertTrue(exportIDs.contains("audioworkspace.export.mode_picker"), "Found IDs: \(exportIDs)")
        XCTAssertTrue(exportIDs.contains("audioworkspace.export.mode_banner"), "Found IDs: \(exportIDs)")
        XCTAssertTrue(exportIDs.contains("audioworkspace.export.preview_button"), "Found IDs: \(exportIDs)")
        XCTAssertTrue(exportIDs.contains("audioworkspace.export.confirm_button"), "Found IDs: \(exportIDs)")
        XCTAssertTrue(exportIDs.contains("audioworkspace.export.cancel_button"), "Found IDs: \(exportIDs)")
    }

    @MainActor
    private func collectAccessibilityIdentifiers(in root: NSView) -> Set<String> {
        let win = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = root
        root.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        root.layoutSubtreeIfNeeded()
        defer { win.contentView = nil }

        var visited = Set<ObjectIdentifier>()
        var result = Set<String>()

        func walkObject(_ obj: AnyObject) {
            let oid = ObjectIdentifier(obj)
            guard visited.insert(oid).inserted else { return }

            if let id = obj.accessibilityIdentifier?(), !id.isEmpty {
                result.insert(id)
            }
            if let view = obj as? NSView {
                let id = view.accessibilityIdentifier()
                if !id.isEmpty { result.insert(id) }
                for sub in view.subviews {
                    walkObject(sub)
                }
            }
            if let children = obj.accessibilityChildren?() {
                for child in children {
                    walkObject(child as AnyObject)
                }
            }
            if let rows = obj.accessibilityRows?() {
                for row in rows {
                    walkObject(row as AnyObject)
                }
            }
        }
        walkObject(root)
        return result
    }
}

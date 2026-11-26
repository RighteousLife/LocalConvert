import XCTest
import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import LocalConvert

@MainActor
final class Phase50CoreFeatureUndoTests: XCTestCase {

    // MARK: - Sandbox & Fixture Helpers

    private struct TestSandbox {
        let root: URL
        let journalDir: URL
        let artifactsDir: URL
        let workDir: URL
        let logsDir: URL
    }

    private func makeSandbox(prefix: String = "Phase50") throws -> TestSandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let journalDir = root.appendingPathComponent("journal", isDirectory: true)
        let artifactsDir = root.appendingPathComponent("artifacts", isDirectory: true)
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        let logsDir = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return TestSandbox(
            root: root,
            journalDir: journalDir,
            artifactsDir: artifactsDir,
            workDir: workDir,
            logsDir: logsDir
        )
    }

    private func makeCoordinator(sandbox: TestSandbox) -> (UndoRedoCoordinator, RecoveryArtifactManager) {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 100 },
            storageBudgetBytesProvider: { 64_000_000 }
        )
        return (coordinator, artifacts)
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writePNG(to url: URL, width: Int = 32, height: Int = 32, red: UInt8 = 40, green: UInt8 = 120, blue: UInt8 = 220) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            pixels[idx] = red
            pixels[idx + 1] = green
            pixels[idx + 2] = blue
            pixels[idx + 3] = 255
        }
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Phase50Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG fixture"])
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Phase50Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG fixture"])
        }
    }

    private func makeEditorProject(clipDuration: Double = 10.0) -> AudioEditorProject {
        let assetID = UUID()
        let asset = AudioMediaReference(
            id: assetID,
            path: "/tmp/nonexistent-phase50-\(assetID.uuidString).wav",
            displayName: "sample.wav",
            fileSize: 2048,
            modificationTime: 0,
            duration: clipDuration,
            sampleRate: 48_000,
            channels: 2
        )
        let clip = AudioClip(
            sourceAssetID: assetID,
            name: "sample.wav",
            timelineStart: 0,
            sourceStart: 0,
            duration: clipDuration
        )
        let track = AudioTrack(name: "Track 1", clips: [clip])
        return AudioEditorProject(name: "Phase50Project", tracks: [track], mediaAssets: [asset])
    }

    // MARK: - GAP-04: Image Toolbox Per-File Target Format & Undo/Redo

    func testGAP04_ImageToolboxPerFileTargetFormatUndoRedoIsolationAndRenameMigration() async throws {
        let sandbox = try makeSandbox(prefix: "P50-GAP04")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (coordinator, _) = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coordinator)

        let fileA = sandbox.workDir.appendingPathComponent("alpha.png")
        let fileB = sandbox.workDir.appendingPathComponent("beta.jxl")
        try writePNG(to: fileA, red: 200, green: 60, blue: 60)
        try Data("JXLStub".utf8).write(to: fileB)

        // Default target format logic: non-JXL defaults to .jxl; JXL input defaults to .png
        XCTAssertEqual(store.targetFormat(for: fileA), .jxl)
        XCTAssertEqual(store.targetFormat(for: fileB), .png)

        // Change file A format to .webp and file B format to .avif
        store.setTargetFormat(.webp, for: fileA)
        store.setTargetFormat(.avif, for: fileB)
        await store.flushPendingUndoRecords()

        XCTAssertEqual(store.targetFormat(for: fileA), .webp)
        XCTAssertEqual(store.targetFormat(for: fileB), .avif)

        // Duplicate / no-op assignment produces no extra undo entry
        let countBeforeNoOp = coordinator.undoEntries(for: .imageToolbox).count
        store.setTargetFormat(.avif, for: fileB)
        await store.flushPendingUndoRecords()
        XCTAssertEqual(coordinator.undoEntries(for: .imageToolbox).count, countBeforeNoOp)

        // Undo 1: reverts file B (.avif -> .png) without altering file A (.webp)
        await coordinator.undo(in: .imageToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(store.targetFormat(for: fileB), .png)
        XCTAssertEqual(store.targetFormat(for: fileA), .webp)

        // Undo 2: reverts file A (.webp -> .jxl)
        await coordinator.undo(in: .imageToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(store.targetFormat(for: fileA), .jxl)

        // Redo 1 & Redo 2 restore file A (.webp) and file B (.avif)
        await coordinator.redo(in: .imageToolbox)
        XCTAssertEqual(store.targetFormat(for: fileA), .webp)
        await coordinator.redo(in: .imageToolbox)
        XCTAssertEqual(store.targetFormat(for: fileB), .avif)

        // Batch rename URL migration preserves per-file targetFormat and config
        store.updateConfig(for: fileA) { $0.quality = 0.72 }
        await store.flushPendingUndoRecords()
        let renamedA = sandbox.workDir.appendingPathComponent("alpha_renamed.png")
        store.migrateURLs([(from: fileA, to: renamedA)])

        XCTAssertEqual(store.targetFormat(for: renamedA), .webp)
        XCTAssertEqual(store.config(for: renamedA).quality, 0.72, accuracy: 0.001)
        XCTAssertNil(store.targetFormatByURL[fileA.standardizedFileURL])
    }

    // MARK: - GAP-07: Inactive Application Settings (rememberLastUsedOptions & verboseLogging)

    func testGAP07_RememberLastUsedOptionsEnabledDisabledSanitizationAndReset() async throws {
        let sandbox = try makeSandbox(prefix: "P50-GAP07A")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let settings = AppSettings.shared
        let savedRememberFlag = settings.rememberLastUsedOptions
        let savedExistingHandling = settings.existingFileHandling
        let savedImageQuality = settings.defaultImageQuality
        let savedPreserveMeta = settings.preserveMetadataByDefault
        defer {
            settings.rememberLastUsedOptions = savedRememberFlag
            settings.existingFileHandling = savedExistingHandling
            settings.defaultImageQuality = savedImageQuality
            settings.preserveMetadataByDefault = savedPreserveMeta
            settings.clearRememberedOptions()
        }

        settings.clearRememberedOptions()
        settings.existingFileHandling = .createUnique
        settings.defaultImageQuality = 0.90
        settings.preserveMetadataByDefault = true

        // 1. When rememberLastUsedOptions == true, custom format options are persisted and sanitized
        settings.rememberLastUsedOptions = true
        var customWebPOptions = ConversionOptions(
            preserveMetadata: false,
            overwriteExisting: true, // destructive flag must NEVER be persisted
            imageQuality: 0.64,
            webpLossless: true,
            imageOptimizationMode: .quality,
            customOptions: [
                "jxl_effort": "8",
                "image_toolbox_config": "{\"transient\":true}",
                "existing_file_handling": "Overwrite"
            ]
        )
        customWebPOptions.preset = .custom
        settings.recordLastUsedOptions(customWebPOptions, for: .webp)

        let recalled = try XCTUnwrap(settings.rememberedOptions(for: .webp, inputFormat: .png))
        XCTAssertEqual(recalled.preserveMetadata, false)
        XCTAssertEqual(recalled.overwriteExisting, false, "Destructive overwriteExisting must be sanitized on persistence")
        XCTAssertEqual(recalled.effectiveImageQuality, 0.64, accuracy: 0.001)
        XCTAssertEqual(recalled.webpLossless, true)
        XCTAssertEqual(recalled.customOptions["jxl_effort"], "8")
        XCTAssertNil(recalled.customOptions["image_toolbox_config"], "Transient toolbox payloads must not be remembered")

        // New file added to AppState withrememberLastUsedOptions == true receives remembered options
        let initialForWebP = settings.initialOptionsForNewFile(inputFormat: .png, outputFormat: .webp)
        XCTAssertEqual(initialForWebP.effectiveImageQuality, 0.64, accuracy: 0.001)
        XCTAssertEqual(initialForWebP.webpLossless, true)

        // 2. When rememberLastUsedOptions == false, factory/default conversion options are returned
        settings.rememberLastUsedOptions = false
        XCTAssertNil(settings.rememberedOptions(for: .webp, inputFormat: .png))
        let initialWhenDisabled = settings.initialOptionsForNewFile(inputFormat: .png, outputFormat: .webp)
        XCTAssertEqual(initialWhenDisabled.effectiveImageQuality, 0.90, accuracy: 0.001)
        XCTAssertEqual(initialWhenDisabled.preserveMetadata, true)
        XCTAssertEqual(initialWhenDisabled.webpLossless, false)

        // 3. clearRememberedOptions() wipes remembered state
        settings.rememberLastUsedOptions = true
        settings.clearRememberedOptions()
        XCTAssertNil(settings.rememberedOptions(for: .webp, inputFormat: .png))
    }

    func testGAP07_VerboseLoggingGatesDiagnosticFileWritesAndSanitizesPaths() throws {
        let sandbox = try makeSandbox(prefix: "P50-GAP07B")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let logDir = sandbox.logsDir

        // 1. When verboseLogging is false, logVerbose writes nothing to localconvert.log
        DiagnosticLogManager.logVerbose(
            category: "ConversionManager",
            message: "Starting job at /Users/alice/SecretProject/input.png",
            isVerboseEnabled: false,
            directoryOverride: logDir
        )
        let contentsWhenDisabled = DiagnosticLogManager.readDiagnosticLogContents(in: logDir)
        XCTAssertTrue(contentsWhenDisabled.isEmpty, "Verbose diagnostics must not write to disk when verboseLogging is false")

        // 2. When verboseLogging is true, logVerbose and logError write sanitized entries to localconvert.log
        DiagnosticLogManager.logVerbose(
            category: "ConversionManager",
            message: "Starting job at \(NSHomeDirectory())/Desktop/private_sample.png",
            isVerboseEnabled: true,
            directoryOverride: logDir
        )
        DiagnosticLogManager.logError(
            category: "ConversionManager",
            message: "Engine failed for /Users/testuser/Documents/file.pdf with token=my_secret_token_123",
            isVerboseEnabled: true,
            directoryOverride: logDir
        )

        let contentsWhenEnabled = DiagnosticLogManager.readDiagnosticLogContents(in: logDir)
        XCTAssertTrue(contentsWhenEnabled.contains("[VERBOSE] [ConversionManager]"))
        XCTAssertTrue(contentsWhenEnabled.contains("[ERROR] [ConversionManager]"))
        XCTAssertFalse(contentsWhenEnabled.contains(NSHomeDirectory()), "Home directory paths must be sanitized to ~")
        XCTAssertFalse(contentsWhenEnabled.contains("/Users/testuser"), "User home paths must be sanitized to ~")
        XCTAssertTrue(contentsWhenEnabled.contains("~/Desktop/private_sample.png"))
        XCTAssertTrue(contentsWhenEnabled.contains("~/Documents/file.pdf"))
        XCTAssertFalse(contentsWhenEnabled.contains("my_secret_token_123"), "Tokens/secrets must be redacted")
        XCTAssertTrue(contentsWhenEnabled.contains("token=[REDACTED]"))

        // 3. clearDiagnosticLogs removes log files cleanly
        DiagnosticLogManager.clearDiagnosticLogs(in: logDir)
        XCTAssertTrue(DiagnosticLogManager.readDiagnosticLogContents(in: logDir).isEmpty)
    }

    // MARK: - GAP-08: Audio Editor Marker Management & Undo/Redo

    func testGAP08_AudioEditorMarkerAddRenameMoveCoalescedDragDeleteSeekAndPersistence() async throws {
        let sandbox = try makeSandbox(prefix: "P50-GAP08")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (coordinator, _) = makeCoordinator(sandbox: sandbox)
        let store = AudioEditorStore(undoCoordinator: coordinator)
        store.project = makeEditorProject(clipDuration: 12.0)
        let context = OperationContext.audioEditor(projectID: store.project.id)

        // 1. Add Marker at playhead (2.5s)
        store.seek(to: 2.5)
        let addedMarker = try XCTUnwrap(store.addMarkerAtPlayhead(name: "Intro"))
        let markerID = addedMarker.id
        await store.flushPendingUndoRecords()

        XCTAssertEqual(store.project.markers.count, 1)
        XCTAssertEqual(store.project.markers.first?.id, markerID)
        XCTAssertEqual(store.project.markers.first?.name, "Intro")
        XCTAssertEqual(store.project.markers.first?.time ?? -1, 2.5, accuracy: 0.001)
        XCTAssertEqual(store.selectedMarkerID, markerID)

        // 2. Rename Marker -> "Verse 1" (and verify empty/same-name no-op prevention)
        store.renameMarker(id: markerID, newName: "   ")
        store.renameMarker(id: markerID, newName: "Intro")
        await store.flushPendingUndoRecords()
        XCTAssertEqual(coordinator.undoEntries(for: context).count, 1, "Empty or identical marker rename must not record duplicate undo entries")

        store.renameMarker(id: markerID, newName: "Verse 1")
        await store.flushPendingUndoRecords()
        XCTAssertEqual(store.project.markers.first?.name, "Verse 1")
        XCTAssertEqual(coordinator.undoEntries(for: context).count, 2)

        // 3. Coalesced drag move (2.5s -> 4.0s -> 6.25s -> 25.0s clamped to 12.0s -> 5.5s)
        store.beginMarkerDrag(id: markerID)
        store.updateMarkerDrag(id: markerID, to: 4.0, snapToGrid: false)
        store.updateMarkerDrag(id: markerID, to: 6.25, snapToGrid: false)
        store.updateMarkerDrag(id: markerID, to: 25.0, snapToGrid: false)
        XCTAssertEqual(store.project.markers.first?.time ?? -1, 12.0, accuracy: 0.001, "Marker time must clamp to project duration")
        store.updateMarkerDrag(id: markerID, to: -3.0, snapToGrid: false)
        XCTAssertEqual(store.project.markers.first?.time ?? -1, 0.0, accuracy: 0.001, "Marker time must clamp to >= 0")
        store.updateMarkerDrag(id: markerID, to: 5.5, snapToGrid: false)
        store.endMarkerDrag(id: markerID)
        await store.flushPendingUndoRecords()

        XCTAssertEqual(store.project.markers.first?.time ?? -1, 5.5, accuracy: 0.001)
        XCTAssertEqual(coordinator.undoEntries(for: context).count, 3, "Continuous marker drag must coalesce into a single undo entry")

        // 4. Seek to marker
        store.seek(to: 0.0)
        store.selectAndSeekToMarker(id: markerID)
        XCTAssertEqual(store.timeline.playheadTime, 5.5, accuracy: 0.001)

        // 5. Project save/load persistence preserves markers
        let projFile = sandbox.workDir.appendingPathComponent("MarkerTest.lcproject")
        _ = try ProjectPersistenceService.save(project: store.project, to: projFile)
        let (loadedProject, _) = try ProjectPersistenceService.load(from: projFile)
        XCTAssertEqual(loadedProject.markers, store.project.markers)

        // 6. Delete marker
        store.deleteMarker(id: markerID)
        await store.flushPendingUndoRecords()
        XCTAssertTrue(store.project.markers.isEmpty)
        XCTAssertNil(store.selectedMarkerID)
        XCTAssertEqual(coordinator.undoEntries(for: context).count, 4)

        // 7. Full Undo sequence: Delete -> Move -> Rename -> Add
        await coordinator.undo(in: context) // Undo Delete
        XCTAssertEqual(store.project.markers.count, 1)
        XCTAssertEqual(store.project.markers.first?.name, "Verse 1")
        XCTAssertEqual(store.project.markers.first?.time ?? -1, 5.5, accuracy: 0.001)

        await coordinator.undo(in: context) // Undo Move
        XCTAssertEqual(store.project.markers.first?.time ?? -1, 2.5, accuracy: 0.001)

        await coordinator.undo(in: context) // Undo Rename
        XCTAssertEqual(store.project.markers.first?.name, "Intro")

        await coordinator.undo(in: context) // Undo Add
        XCTAssertTrue(store.project.markers.isEmpty)

        // 8. Full Redo sequence: Add -> Rename -> Move -> Delete
        await coordinator.redo(in: context)
        XCTAssertEqual(store.project.markers.count, 1)
        XCTAssertEqual(store.project.markers.first?.name, "Intro")
        await coordinator.redo(in: context)
        XCTAssertEqual(store.project.markers.first?.name, "Verse 1")
        await coordinator.redo(in: context)
        XCTAssertEqual(store.project.markers.first?.time ?? -1, 5.5, accuracy: 0.001)
        await coordinator.redo(in: context)
        XCTAssertTrue(store.project.markers.isEmpty)
    }

    // MARK: - GAP-09: Audio Toolbox Persistence, Secondary Undo & Preset Consistency

    func testGAP09_AudioToolboxStorePersistenceUndoRedoAndRememberLastUsedOptions() async throws {
        let sandbox = try makeSandbox(prefix: "P50-GAP09A")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let settings = AppSettings.shared
        let savedRememberFlag = settings.rememberLastUsedOptions
        defer {
            settings.rememberLastUsedOptions = savedRememberFlag
            settings.clearRememberedOptions()
        }
        settings.clearRememberedOptions()
        settings.rememberLastUsedOptions = true

        let (coordinator, _) = makeCoordinator(sandbox: sandbox)
        let store = AudioToolboxStore(undoCoordinator: coordinator)

        let trackA = sandbox.workDir.appendingPathComponent("trackA.wav")
        let trackB = sandbox.workDir.appendingPathComponent("trackB.mp3")
        try Data("RIFFstub".utf8).write(to: trackA)
        try Data("ID3stub".utf8).write(to: trackB)

        // Hydrate initial trim bounds once (e.g. 18.0s duration) without pushing undo
        store.hydrateTrimBoundsIfNeeded(for: trackA, duration: 18.0)
        XCTAssertEqual(store.trimStart(for: trackA), 0.0, accuracy: 0.001)
        XCTAssertEqual(store.trimEnd(for: trackA), 18.0, accuracy: 0.001)
        XCTAssertTrue(coordinator.undoEntries(for: .audioToolbox).isEmpty)

        // User edits format, trim bounds, and EQ preset on trackA
        store.setTargetFormat(.flac, for: trackA)
        store.setTrimBounds(start: 2.0, end: 14.5, for: trackA)
        store.updateConfig(
            for: trackA,
            explicitType: .audioToolboxConfig,
            explicitTitle: "Apply Vocal Clarity EQ",
            transactionGroupID: UUID()
        ) { cfg in
            cfg.activeEQPreset = .vocalClarity
            cfg.volumeGainDB = 3.5
        }
        await store.flushPendingUndoRecords()

        // Subsequent hydration (simulating tab switch back to Audio Toolbox) MUST NOT overwrite user trim bounds
        store.hydrateTrimBoundsIfNeeded(for: trackA, duration: 18.0)
        XCTAssertEqual(store.trimStart(for: trackA), 2.0, accuracy: 0.001)
        XCTAssertEqual(store.trimEnd(for: trackA), 14.5, accuracy: 0.001)
        XCTAssertEqual(store.targetFormat(for: trackA), .flac)
        XCTAssertEqual(store.config(for: trackA).activeEQPreset, .vocalClarity)
        XCTAssertEqual(store.config(for: trackA).volumeGainDB, 3.5, accuracy: 0.001)

        // Undo & Redo in .audioToolbox context
        await coordinator.undo(in: .audioToolbox) // Undo EQ & gain
        XCTAssertEqual(store.config(for: trackA).activeEQPreset, .flat)
        XCTAssertEqual(store.config(for: trackA).volumeGainDB, 0.0, accuracy: 0.001)

        await coordinator.undo(in: .audioToolbox) // Undo trim bounds
        XCTAssertEqual(store.trimStart(for: trackA), 0.0, accuracy: 0.001)
        XCTAssertEqual(store.trimEnd(for: trackA), 18.0, accuracy: 0.001)

        await coordinator.undo(in: .audioToolbox) // Undo target format
        XCTAssertEqual(store.targetFormat(for: trackA), .mp3)

        await coordinator.redo(in: .audioToolbox)
        await coordinator.redo(in: .audioToolbox)
        await coordinator.redo(in: .audioToolbox)
        XCTAssertEqual(store.targetFormat(for: trackA), .flac)
        XCTAssertEqual(store.trimStart(for: trackA), 2.0, accuracy: 0.001)
        XCTAssertEqual(store.config(for: trackA).activeEQPreset, .vocalClarity)

        // With rememberLastUsedOptions == true, a new file (trackB) inherits non-transient codec/effect settings (.flac, Vocal Clarity)
        // while keeping track-specific trim bounds clean (0..0)
        let trackBState = store.state(for: trackB)
        XCTAssertEqual(trackBState.targetFormat, .flac)
        XCTAssertEqual(trackBState.config.activeEQPreset, .vocalClarity)
        XCTAssertEqual(trackBState.trimStart, 0.0, accuracy: 0.001)
        XCTAssertFalse(trackBState.hasInitializedTrimBounds)

        // With rememberLastUsedOptions == false, an unconfigured file uses factory defaults (.mp3, Flat EQ)
        settings.rememberLastUsedOptions = false
        let trackC = sandbox.workDir.appendingPathComponent("trackC.wav")
        let trackCState = store.state(for: trackC)
        XCTAssertEqual(trackCState.targetFormat, .mp3)
        XCTAssertEqual(trackCState.config.activeEQPreset, .flat)
    }

    func testGAP09_SecondaryUndoIntegration_PresetResetSpotifyOutputAndIrreversibleTrashAudit() async throws {
        let sandbox = try makeSandbox(prefix: "P50-GAP09B")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (coordinator, artifacts) = makeCoordinator(sandbox: sandbox)

        // 1. PresetManager.resetToDefaults() Undo/Redo restores custom presets and original built-in IDs
        let presetsFile = sandbox.workDir.appendingPathComponent("presets.json")
        let presetStore = PresetStore(fileURL: presetsFile)
        let presetManager = PresetManager(store: presetStore, undoCoordinator: coordinator)

        let customPreset = SavedPreset(
            name: "Studio Master FLAC",
            description: "24-bit 96kHz FLAC",
            targetFormat: .flac,
            sourceCategoryConstraint: .audio,
            options: .default
        )
        presetManager.save(preset: customPreset)
        await presetManager.flushPendingUndoRecords()
        let beforeResetPresets = presetManager.presets
        XCTAssertTrue(beforeResetPresets.contains(where: { $0.id == customPreset.id }))

        presetManager.resetToDefaults()
        await presetManager.flushPendingUndoRecords()
        XCTAssertFalse(presetManager.presets.contains(where: { $0.id == customPreset.id }))

        await coordinator.undo(in: .presets)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(presetManager.presets, beforeResetPresets, "Undoing resetToDefaults must restore exact custom and built-in presets")

        await coordinator.redo(in: .presets)
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(presetManager.presets.contains(where: { $0.id == customPreset.id }))

        // 2. Spotify Compatibility normalized output creation Undo/Redo stages output and never touches protected source
        let sourceMP3 = sandbox.workDir.appendingPathComponent("song.mp3")
        let normalizedCopyMP3 = sandbox.workDir.appendingPathComponent("song (Spotify Ready).mp3")
        try Data("OriginalSourceMP3Bytes".utf8).write(to: sourceMP3)
        try Data("NormalizedSpotifyReadyMP3Bytes".utf8).write(to: normalizedCopyMP3)
        let sourceHashBefore = try sha256Hex(of: sourceMP3)
        let normalizedHashBefore = try sha256Hex(of: normalizedCopyMP3)

        let spotifyCmd = OutputCreationUndoCommand(
            title: "Normalize 1 Track(s) for Spotify",
            context: .audioToolbox,
            outputURLs: [normalizedCopyMP3],
            protectedSourceURLs: [sourceMP3],
            artifactManager: artifacts
        )
        await coordinator.record(spotifyCmd)

        await coordinator.undo(in: .audioToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: normalizedCopyMP3.path), "Undo must remove the created normalized copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceMP3.path), "Protected source file must remain untouched")
        XCTAssertEqual(try sha256Hex(of: sourceMP3), sourceHashBefore)

        await coordinator.redo(in: .audioToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: normalizedCopyMP3.path), "Redo must restore the normalized copy")
        XCTAssertEqual(try sha256Hex(of: normalizedCopyMP3), normalizedHashBefore)
        XCTAssertEqual(try sha256Hex(of: sourceMP3), sourceHashBefore)

        // 3. IrreversibleAuditUndoCommand archives immediately with explanation without blocking earlier reversible undo steps
        let trashAuditCmd = IrreversibleAuditUndoCommand(
            operationType: .fileTrash,
            title: "Move 1 Duplicate Image(s) to Trash",
            context: .imageToolbox,
            affectedURLs: [sandbox.workDir.appendingPathComponent("dup.png")],
            irreversibilityReason: "Files moved to the macOS Trash are managed by Finder and can be restored from Trash directly."
        )
        let store = ImageToolboxStore(undoCoordinator: coordinator)
        let imgURL = sandbox.workDir.appendingPathComponent("editable.png")
        store.setTargetFormat(.webp, for: imgURL)
        await store.flushPendingUndoRecords()

        await coordinator.record(trashAuditCmd)
        let archived = coordinator.archivedTimeline(for: .imageToolbox)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.operationType, .fileTrash)
        XCTAssertEqual(archived.first?.archiveReason, .inherentlyIrreversible)
        XCTAssertEqual(
            archived.first?.irreversibilityReason,
            "Files moved to the macOS Trash are managed by Finder and can be restored from Trash directly."
        )

        // Reversible undo step recorded before the irreversible audit entry remains undoable
        XCTAssertTrue(coordinator.canUndo(in: .imageToolbox))
        await coordinator.undo(in: .imageToolbox)
        XCTAssertEqual(store.targetFormat(for: imgURL), .jxl)
    }

    func testGAP09_OptimizationModePresetConsistencyAndEQPresetCustomTransition() throws {
        // 1. ImageOptimizationSectionView mode selection vs ConversionPreset canonical options
        let descriptors = ImageConversionEngine().optionDescriptors(from: .png, to: .webp)
        let availablePresets: [ConversionPreset] = [.web, .maximumQuality, .smallFile, .appleDevice]

        var options = ConversionOptions.default
        options.applyPreset(.web, inputFormat: .png, outputFormat: .webp)
        XCTAssertEqual(options.effectivePreset, .web)

        var captured = options
        let binding = Binding<ConversionOptions>(
            get: { captured },
            set: { captured = $0 }
        )
        let view = ImageOptimizationSectionView(
            options: binding,
            isImageTarget: true,
            availablePresets: availablePresets,
            descriptors: descriptors,
            inputFormat: .png,
            outputFormat: .webp
        )

        // Selecting .maximum in ImageOptimizationSectionView aligns with ConversionPreset.maximumQuality
        view.applyModeChange(.maximum)
        XCTAssertEqual(captured.effectivePreset, .maximumQuality)
        XCTAssertEqual(captured.effectiveImageQuality, 1.0, accuracy: 0.001)
        XCTAssertEqual(captured.webpLossless, true)
        XCTAssertEqual(captured.preserveMetadata, true)

        // Manual quality slider adjustment transitions effectivePreset to nil (Custom)
        view.applyQualitySliderChange(0.73)
        XCTAssertNil(captured.effectivePreset)
        XCTAssertEqual(captured.imageOptimizationMode, .custom)

        // Selecting .smallFile in ImageOptimizationSectionView aligns with ConversionPreset.smallFile
        view.applyModeChange(.smallFile)
        XCTAssertEqual(captured.effectivePreset, .smallFile)
        XCTAssertEqual(captured.effectiveImageQuality, 0.50, accuracy: 0.001)
        XCTAssertEqual(captured.effectiveTargetFileSizeBytes, 1_000_000)
        XCTAssertEqual(captured.preserveMetadata, false)

        // 2. AudioEQPreset transitions from named preset to .custom when any EQ band gain is adjusted
        var audioCfg = AudioToolboxConfig()
        XCTAssertEqual(audioCfg.activeEQPreset, .flat)

        audioCfg.activeEQPreset = .vocalClarity
        XCTAssertEqual(audioCfg.activeEQPreset, .vocalClarity)
        XCTAssertEqual(audioCfg.eqBands, AudioEQBand.vocalClarityBands)

        audioCfg.activeEQPreset = .bassBoost
        XCTAssertEqual(audioCfg.activeEQPreset, .bassBoost)
        XCTAssertEqual(audioCfg.eqBands, AudioEQBand.bassBoostBands)

        // Adjust a single band manually -> activeEQPreset immediately reports .custom
        audioCfg.eqBands[0].gainDB = 2.5
        XCTAssertEqual(audioCfg.activeEQPreset, .custom)
    }
}

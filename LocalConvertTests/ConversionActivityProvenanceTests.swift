import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class ConversionActivityProvenanceTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUp() async throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Provenance-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        AppSettings.shared.saveConversionHistory = true
        AppSettings.shared.historyAutoRemove = .never
    }

    override func tearDown() async throws {
        AppStoragePaths.clearTestOverrides()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Helpers

    private func ensureImageRegistryRegistered() -> ConversionRegistry {
        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: ImageConversionEngine())
            registry.register(engine: TextConversionEngine())
            registry.register(engine: PDFConversionEngine())
            registry.register(engine: MediaConversionEngine())
            registry.register(engine: SubtitleConversionEngine())
            registry.register(engine: ArchiveConversionEngine())
            registry.register(engine: OfficeConversionEngine())
            registry.register(engine: PDFToolboxEngine())
        }
        let metaRegistry = MetadataRegistry.shared
        if metaRegistry.provider(for: .png) == nil {
            metaRegistry.register(provider: ImageMetadataProvider())
        }
        return registry
    }

    @discardableResult
    private func writeSyntheticPNG(to url: URL, width: Int = 24, height: Int = 24) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 200, count: width * height * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) { pixels[idx] = 255 }
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cg = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 8.0, condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    // MARK: - 1. Manual Conversion Provenance

    func testManualConversionPresetAndMetadataProvenanceRecorded() async throws {
        let registry = ensureImageRegistryRegistered()
        let historyFile = sandbox.historyFileURL
        let history = HistoryManager(fileURL: historyFile)
        let convManager = ConversionManager(registry: registry, historyManager: history)
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let convQueue = ConversionQueue(conversionManager: convManager, undoCoordinator: undoCoord)

        let inURL = sandbox.temporaryURL.appendingPathComponent("manual_direct.png")
        try writeSyntheticPNG(to: inURL)

        // Direct manual ConversionJob
        let directJob = ConversionJob(
            inputURLs: [inURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: sandbox.outputsURL
        )
        let status: ConversionJobStatus = await withCheckedContinuation { cont in
            convManager.submit(job: directJob) { cont.resume(returning: $0) }
        }
        guard case .completed = status else {
            return XCTFail("Expected direct manual job to complete, got \(status)")
        }

        // Manual PresetExecutor run
        let presetStore = PresetStore(fileURL: sandbox.presetsFileURL)
        let presetMgr = PresetManager(store: presetStore, undoCoordinator: undoCoord)
        let preset = SavedPreset(
            name: "Manual WebP",
            targetFormat: .webp,
            sourceCategoryConstraint: .image,
            options: .default,
            outputDestinationPolicy: .customDirectory(path: sandbox.outputsURL.path),
            outputNamingPolicy: .standard
        )
        presetMgr.save(preset: preset)

        let inPresetURL = sandbox.temporaryURL.appendingPathComponent("manual_preset.png")
        try writeSyntheticPNG(to: inPresetURL)
        let report = presetMgr.executor.execute(
            preset: preset,
            inputURLs: [inPresetURL],
            conversionManager: convManager,
            conversionQueue: convQueue
        )
        XCTAssertEqual(report.enqueuedJobs.count, 1)
        let presetJobDone = await waitUntil {
            !convQueue.isProcessing && history.items.contains { $0.inputFilename == "manual_preset.png" }
        }
        XCTAssertTrue(presetJobDone)

        // Manual MetadataManager Save Copy
        let metaManager = MetadataManager(
            undoCoordinator: undoCoord,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL.appendingPathComponent("meta")),
            historyManager: history
        )
        await metaManager.load(url: inURL)
        metaManager.updateField(id: "title", value: .string("Manual Tag"))
        let taggedURL = await metaManager.saveCopy(to: sandbox.outputsURL.appendingPathComponent("manual_tagged.png"))
        XCTAssertNotNil(taggedURL)

        XCTAssertEqual(history.items.count, 3)
        for item in history.items {
            XCTAssertEqual(item.source, .manual)
            XCTAssertNil(item.watchFolderRuleID)
            XCTAssertNil(item.watchFolderRuleName)
        }
    }

    // MARK: - 2. Watch Folder Conversion Provenance

    func testWatchFolderConversionRecordsTruthfulWatchFolderProvenance() async throws {
        let registry = ensureImageRegistryRegistered()
        let inboxDir = sandbox.temporaryURL.appendingPathComponent("WFInbox", isDirectory: true)
        let wfOutDir = sandbox.outputsURL.appendingPathComponent("WFOut", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wfOutDir, withIntermediateDirectories: true)

        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let presetStore = PresetStore(fileURL: sandbox.presetsFileURL)
        let presetMgr = PresetManager(store: presetStore, undoCoordinator: undoCoord)
        let preset = SavedPreset(
            name: "WF JPEG",
            targetFormat: .jpg,
            sourceCategoryConstraint: .image,
            options: .default,
            outputDestinationPolicy: .defaultLocation,
            outputNamingPolicy: .standard
        )
        presetMgr.save(preset: preset)

        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let convManager = ConversionManager(registry: registry, historyManager: history)
        let convQueue = ConversionQueue(conversionManager: convManager, undoCoordinator: undoCoord)
        let wfStore = WatchFolderStore(fileURL: sandbox.watchFoldersFileURL)
        let wfManager = WatchFolderManager(
            store: wfStore,
            presetManager: presetMgr,
            conversionManager: convManager,
            conversionQueue: convQueue,
            defaultOutputLocationProvider: { (.sameFolder, nil) }
        )
        wfManager.monitorDebounceInterval = 0.05
        defer { wfManager.stopAll() }

        let rule = WatchFolderRule(
            name: "Inbox Auto JPG",
            inputDirectoryPath: inboxDir.path,
            presetID: preset.id,
            isEnabled: true,
            outputDestination: .customDirectory(path: wfOutDir.path, bookmarkData: nil),
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 0.8
        )
        XCTAssertTrue(wfManager.addRule(rule).isValid)

        let droppedPNG = inboxDir.appendingPathComponent("drop_from_finder.png")
        try writeSyntheticPNG(to: droppedPNG)
        wfManager.handleDetectedFiles([droppedPNG], for: rule.id)

        let finished = await waitUntil {
            history.items.contains { $0.inputFilename == "drop_from_finder.png" }
                && wfManager.records.first { $0.fileName == "drop_from_finder.png" }?.state == .completed
        }
        XCTAssertTrue(finished)

        let record = try XCTUnwrap(history.items.first { $0.inputFilename == "drop_from_finder.png" })
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.source, .watchFolder)
        XCTAssertEqual(record.watchFolderRuleID, rule.id)
        XCTAssertEqual(record.watchFolderRuleName, "Inbox Auto JPG")
        XCTAssertEqual(record.presetName, "WF JPEG")

        // Jobs Center job also carried truthful source metadata
        let sessionJob = try XCTUnwrap(convManager.activeJobs.first { $0.sourceFilename == "drop_from_finder.png" })
        XCTAssertEqual(sessionJob.source, .watchFolder)
        XCTAssertEqual(sessionJob.watchFolderRuleID, rule.id)
        XCTAssertEqual(sessionJob.watchFolderRuleName, "Inbox Auto JPG")
    }

    // MARK: - 3. Legacy Unknown Provenance & 4. Persistence Across Restart

    func testLegacyJSONDecodesUnknownWithoutFabricationAndNewProvenancePersistsAcrossRestart() throws {
        let legacyID = UUID()
        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        // Legacy JSON missing `source`, `watchFolderRuleID`, `watchFolderRuleName` AND an item with unrecognized source string
        let legacyJSON: [[String: Any]] = [
            [
                "id": legacyID.uuidString,
                "inputFilename": "watch_folder_named_but_legacy.png",
                "inputFormatName": "PNG Image",
                "outputFilename": "watch_folder_named_but_legacy.jpg",
                "outputFormatName": "JPEG Image",
                "date": legacyDate.timeIntervalSinceReferenceDate,
                "status": "completed",
                "presetName": "Old Preset"
            ],
            [
                "id": UUID().uuidString,
                "inputFilename": "future_source_value.png",
                "inputFormatName": "PNG Image",
                "outputFilename": "future_source_value.webp",
                "outputFormatName": "WebP Image",
                "date": legacyDate.timeIntervalSinceReferenceDate,
                "status": "completed",
                "source": "futurePipeline"
            ]
        ]
        let rawData = try JSONSerialization.data(withJSONObject: legacyJSON)
        try rawData.write(to: sandbox.historyFileURL, options: .atomic)

        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        XCTAssertEqual(history.items.count, 2)

        // Legacy record must NOT fabricate `.watchFolder` from filename or presetName
        XCTAssertEqual(history.items[0].id, legacyID)
        XCTAssertEqual(history.items[0].source, .unknown)
        XCTAssertEqual(history.items[0].sourceDisplayLabel, "Not Recorded")
        XCTAssertNil(history.items[0].watchFolderRuleID)
        XCTAssertNil(history.items[0].watchFolderRuleName)
        XCTAssertEqual(history.items[0].presetName, "Old Preset")

        // Unrecognized source raw value safely decodes as .unknown
        XCTAssertEqual(history.items[1].source, .unknown)

        // Add Manual and Watch Folder records, then simulate app restart by loading new HistoryManager
        let ruleID = UUID()
        history.addEntry(ConversionHistoryItem(
            inputFilename: "manual_restart.png",
            inputFormatName: "PNG",
            outputFilename: "manual_restart.jpg",
            outputFormatName: "JPG",
            status: .completed,
            source: .manual
        ))
        history.addEntry(ConversionHistoryItem(
            inputFilename: "wf_restart.png",
            inputFormatName: "PNG",
            outputFilename: "wf_restart.webp",
            outputFormatName: "WebP",
            status: .completed,
            presetName: "Watch Preset",
            source: .watchFolder,
            watchFolderRuleID: ruleID,
            watchFolderRuleName: "Desktop Drop"
        ))

        let reloaded = HistoryManager(fileURL: sandbox.historyFileURL)
        XCTAssertEqual(reloaded.items.count, 4)
        XCTAssertEqual(reloaded.items[0].source, .watchFolder)
        XCTAssertEqual(reloaded.items[0].watchFolderRuleID, ruleID)
        XCTAssertEqual(reloaded.items[0].watchFolderRuleName, "Desktop Drop")
        XCTAssertEqual(reloaded.items[1].source, .manual)
        XCTAssertEqual(reloaded.items[2].source, .unknown)
        XCTAssertEqual(reloaded.items[3].source, .unknown)
    }

    // MARK: - 5 & 6. Watch Folder Filtering, Search, Sorting & Category Compatibility

    func testFilteringSearchAndOrderPreservationNeverMutateRecords() {
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let ruleA = UUID()
        let ruleB = UUID()

        let oldestLegacy = ConversionHistoryItem(
            inputFilename: "legacy_doc.pdf",
            inputFormatName: "PDF",
            outputFilename: "legacy_doc.png",
            outputFormatName: "PNG",
            date: Date(timeIntervalSince1970: 100),
            status: .completed,
            source: .unknown
        )
        let midManual = ConversionHistoryItem(
            inputFilename: "manual_photo.png",
            inputFormatName: "PNG",
            outputFilename: "manual_photo.jpg",
            outputFormatName: "JPEG",
            date: Date(timeIntervalSince1970: 200),
            status: .completed,
            presetName: "Social Export",
            source: .manual
        )
        let watchRuleA = ConversionHistoryItem(
            inputFilename: "scan_a.png",
            inputFormatName: "PNG",
            outputFilename: "scan_a.webp",
            outputFormatName: "WebP",
            date: Date(timeIntervalSince1970: 300),
            status: .failed,
            presetName: "Inbox WebP",
            errorMessage: "Decode failed",
            source: .watchFolder,
            watchFolderRuleID: ruleA,
            watchFolderRuleName: "Inbox Rule A"
        )
        let newestWatchRuleB = ConversionHistoryItem(
            inputFilename: "scan_b.png",
            inputFormatName: "PNG",
            outputFilename: "scan_b.jpg",
            outputFormatName: "JPEG",
            date: Date(timeIntervalSince1970: 400),
            status: .completed,
            presetName: "Archive JPG",
            source: .watchFolder,
            watchFolderRuleID: ruleB,
            watchFolderRuleName: "Inbox Rule B"
        )

        // addEntry inserts newest at index 0
        history.addEntry(oldestLegacy)
        history.addEntry(midManual)
        history.addEntry(watchRuleA)
        history.addEntry(newestWatchRuleB)

        // Watch Folder source filter preserves newest-first order
        let wfOnly = HistoryFilterEngine.filter(items: history.items, source: .watchFolder)
        XCTAssertEqual(wfOnly.map(\.inputFilename), ["scan_b.png", "scan_a.png"])

        // Rule-specific filter + source filter
        let ruleAOnly = HistoryFilterEngine.filter(
            items: history.items,
            source: .watchFolder,
            watchFolderRuleID: ruleA
        )
        XCTAssertEqual(ruleAOnly.map(\.inputFilename), ["scan_a.png"])

        // Category (.failed) + Source (.watchFolder) + Search by rule name
        let failedSearch = HistoryFilterEngine.filter(
            items: history.items,
            category: .failed,
            source: .watchFolder,
            searchText: "Rule A"
        )
        XCTAssertEqual(failedSearch.map(\.inputFilename), ["scan_a.png"])

        // Search by source display label "Not Recorded"
        let legacySearch = HistoryFilterEngine.filter(items: history.items, searchText: "Not Recorded")
        XCTAssertEqual(legacySearch.map(\.inputFilename), ["legacy_doc.pdf"])

        // Filtering must never mutate or delete stored items
        XCTAssertEqual(history.items.count, 4)
        XCTAssertEqual(history.items.map(\.inputFilename), ["scan_b.png", "scan_a.png", "manual_photo.png", "legacy_doc.pdf"])
    }

    // MARK: - 7. History Retention & Clearing Semantics

    func testRetentionAndClearingSemanticsAcrossProvenances() {
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let oldDate = Date().addingTimeInterval(-10 * 86_400)
        let recentDate = Date()

        history.addEntry(ConversionHistoryItem(inputFilename: "old_wf.png", inputFormatName: "PNG", outputFilename: "old_wf.jpg", outputFormatName: "JPG", date: oldDate, status: .completed, source: .watchFolder, watchFolderRuleID: UUID(), watchFolderRuleName: "OldRule"))
        history.addEntry(ConversionHistoryItem(inputFilename: "recent_manual_fail.png", inputFormatName: "PNG", outputFilename: "recent_manual_fail.jpg", outputFormatName: "JPG", date: recentDate, status: .failed, source: .manual))
        history.addEntry(ConversionHistoryItem(inputFilename: "recent_wf_ok.png", inputFormatName: "PNG", outputFilename: "recent_wf_ok.jpg", outputFormatName: "JPG", date: recentDate, status: .completed, source: .watchFolder, watchFolderRuleID: UUID(), watchFolderRuleName: "NewRule"))
        history.addEntry(ConversionHistoryItem(inputFilename: "recent_legacy_cancel.png", inputFormatName: "PNG", outputFilename: "recent_legacy_cancel.jpg", outputFormatName: "JPG", date: recentDate, status: .cancelled, source: .unknown))

        AppSettings.shared.historyAutoRemove = .sevenDays
        history.applyAutoRemovePolicy()
        XCTAssertEqual(history.items.count, 3)
        XCTAssertFalse(history.items.contains { $0.inputFilename == "old_wf.png" })

        history.clearCompleted()
        XCTAssertEqual(history.items.map(\.inputFilename), ["recent_legacy_cancel.png", "recent_manual_fail.png"])

        history.clearFailed()
        XCTAssertTrue(history.items.isEmpty)

        // 500-entry max cap preserved
        for idx in 0..<505 {
            history.addEntry(ConversionHistoryItem(
                inputFilename: "cap_\(idx).png",
                inputFormatName: "PNG",
                outputFilename: "cap_\(idx).jpg",
                outputFormatName: "JPG",
                status: .completed,
                source: idx.isMultiple(of: 2) ? .watchFolder : .manual
            ))
        }
        XCTAssertEqual(history.items.count, 500)
        XCTAssertEqual(history.items.first?.inputFilename, "cap_504.png")

        history.clearHistory()
        XCTAssertTrue(history.items.isEmpty)
    }

    // MARK: - 8. Editing History Undo/Redo Isolation & 9. Watch Folder Activity Separation

    func testEditingHistoryUndoIsolationAndWatchFolderActivitySeparation() async throws {
        let registry = ensureImageRegistryRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let convManager = ConversionManager(registry: registry, historyManager: history)
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: artifacts
        )
        let convQueue = ConversionQueue(conversionManager: convManager, undoCoordinator: undoCoord)

        let presetStore = PresetStore(fileURL: sandbox.presetsFileURL)
        let presetMgr = PresetManager(store: presetStore, undoCoordinator: undoCoord)
        let preset = SavedPreset(
            name: "Isolated Preset",
            targetFormat: .jpg,
            sourceCategoryConstraint: .image,
            options: .default,
            outputDestinationPolicy: .defaultLocation,
            outputNamingPolicy: .standard
        )
        presetMgr.save(preset: preset)
        await presetMgr.flushPendingUndoRecords()

        let inboxDir = sandbox.temporaryURL.appendingPathComponent("IsolatedWF", isDirectory: true)
        let wfOutDir = sandbox.outputsURL.appendingPathComponent("IsolatedWFOut", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wfOutDir, withIntermediateDirectories: true)

        let wfStore = WatchFolderStore(fileURL: sandbox.watchFoldersFileURL)
        let wfManager = WatchFolderManager(
            store: wfStore,
            presetManager: presetMgr,
            conversionManager: convManager,
            conversionQueue: convQueue,
            defaultOutputLocationProvider: { (.sameFolder, nil) }
        )
        wfManager.monitorDebounceInterval = 0.05
        defer { wfManager.stopAll() }

        let rule = WatchFolderRule(
            name: "Separate Rule",
            inputDirectoryPath: inboxDir.path,
            presetID: preset.id,
            isEnabled: true,
            outputDestination: .customDirectory(path: wfOutDir.path, bookmarkData: nil),
            settleDelaySeconds: 0.05,
            maxStabilityWaitSeconds: 0.8
        )
        XCTAssertTrue(wfManager.addRule(rule).isValid)

        let img = inboxDir.appendingPathComponent("iso.png")
        try writeSyntheticPNG(to: img)
        wfManager.handleDetectedFiles([img], for: rule.id)

        let done = await waitUntil {
            history.items.count == 1 && wfManager.records.first?.state == .completed
        }
        XCTAssertTrue(done)
        await convQueue.flushPendingUndoRecords()

        // Verify undo stack only holds reversible editing operations (not ConversionHistoryItem records)
        let presetUndoCountBefore = undoCoord.undoEntries(for: .presets).count
        XCTAssertGreaterThan(presetUndoCountBefore, 0)

        // Clearing Watch Folder activity must NOT delete Conversion History records
        wfManager.clearRecords(for: rule.id)
        XCTAssertTrue(wfManager.records.isEmpty)
        XCTAssertEqual(history.items.count, 1)

        // Clearing Editing History must NOT alter Conversion History records
        await undoCoord.clearHistory(for: nil, includeArchived: true)
        XCTAssertTrue(undoCoord.allChronologicalEntries(includeArchived: true).isEmpty)
        XCTAssertEqual(history.items.count, 1)

        // Add a fresh Watch Folder record & undo preset; clearing Conversion History must NOT affect UndoRedoCoordinator
        wfManager.handleDetectedFiles([img], for: rule.id, forceReprocess: true)
        let secondDone = await waitUntil { wfManager.records.first?.state == .completed }
        XCTAssertTrue(secondDone)
        presetMgr.rename(id: preset.id, to: "Isolated Preset Renamed")
        await presetMgr.flushPendingUndoRecords()
        XCTAssertEqual(undoCoord.undoEntries(for: .presets).count, 1)

        history.clearHistory()
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertEqual(wfManager.records.count, 1)
        XCTAssertEqual(undoCoord.undoEntries(for: .presets).count, 1)
    }

    // MARK: - 10. Failure & Cancellation Lifecycle With Provenance

    func testFailedCancelledAndRetriedJobsPreserveProvenance() async throws {
        let registry = ensureImageRegistryRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let convManager = ConversionManager(registry: registry, historyManager: history)
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let convQueue = ConversionQueue(conversionManager: convManager, undoCoordinator: undoCoord)

        let ruleID = UUID()
        // 1) Watch Folder corrupt input -> fails & records Watch Folder provenance
        let corruptURL = sandbox.temporaryURL.appendingPathComponent("wf_corrupt.png")
        try Data("NOT_A_PNG".utf8).write(to: corruptURL)
        let failedJob = ConversionJob(
            inputURLs: [corruptURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: sandbox.outputsURL,
            presetName: "WF Fail Preset",
            source: .watchFolder,
            watchFolderRuleID: ruleID,
            watchFolderRuleName: "Fail Rule"
        )
        let failedStatus: ConversionJobStatus = await withCheckedContinuation { cont in
            convManager.submit(job: failedJob) { cont.resume(returning: $0) }
        }
        guard case .failed = failedStatus else {
            return XCTFail("Expected corrupt job failure, got \(failedStatus)")
        }

        // Retrying failed job must preserve Watch Folder provenance
        let retriedJob = try XCTUnwrap(convManager.retry(jobId: failedJob.id, using: convQueue))
        XCTAssertEqual(retriedJob.source, .watchFolder)
        XCTAssertEqual(retriedJob.watchFolderRuleID, ruleID)
        XCTAssertEqual(retriedJob.watchFolderRuleName, "Fail Rule")
        _ = await waitUntil { !convQueue.isProcessing }

        // 2) Cancel active job -> records `.cancelled` with truthful provenance
        let validURL = sandbox.temporaryURL.appendingPathComponent("wf_cancel.png")
        try writeSyntheticPNG(to: validURL, width: 64, height: 64)
        let cancelJob = ConversionJob(
            inputURLs: [validURL],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: sandbox.outputsURL,
            presetName: "WF Cancel Preset",
            source: .watchFolder,
            watchFolderRuleID: ruleID,
            watchFolderRuleName: "Cancel Rule"
        )
        let cancelledExpectation = expectation(description: "Cancelled job completes defer")
        convManager.submit(job: cancelJob) { status in
            if case .cancelled = status {
                cancelledExpectation.fulfill()
            }
        }
        convManager.cancel(jobId: cancelJob.id)
        await fulfillment(of: [cancelledExpectation], timeout: 5.0)

        let wfFailedRecord = try XCTUnwrap(history.items.first { $0.inputFilename == "wf_corrupt.png" && $0.status == .failed })
        XCTAssertEqual(wfFailedRecord.source, .watchFolder)
        XCTAssertEqual(wfFailedRecord.watchFolderRuleID, ruleID)
        XCTAssertEqual(wfFailedRecord.watchFolderRuleName, "Fail Rule")

        let wfCancelledRecord = try XCTUnwrap(history.items.first { $0.inputFilename == "wf_cancel.png" && $0.status == .cancelled })
        XCTAssertEqual(wfCancelledRecord.source, .watchFolder)
        XCTAssertEqual(wfCancelledRecord.watchFolderRuleID, ruleID)
        XCTAssertEqual(wfCancelledRecord.watchFolderRuleName, "Cancel Rule")
    }

    // MARK: - 11. AppState Navigation & Pending History Provenance Filter

    func testAppStateOpenConversionHistoryQueuesWatchFolderFilterAndTab() {
        let appState = AppState()
        defer { appState.watchFolderManager.stopAll() }

        let initialNonce = appState.pendingHistoryNavigationNonce
        let ruleID = UUID()

        appState.openConversionHistory(
            sourceFilter: .watchFolder,
            watchFolderRuleID: ruleID,
            watchFolderRuleName: "Inbox Rule"
        )
        XCTAssertEqual(appState.selectedTab, .history)
        XCTAssertEqual(appState.pendingHistorySourceFilter, .watchFolder)
        XCTAssertEqual(appState.pendingHistoryWatchFolderRuleID, ruleID)
        XCTAssertEqual(appState.pendingHistoryWatchFolderRuleName, "Inbox Rule")
        XCTAssertEqual(appState.pendingHistoryNavigationNonce, initialNonce + 1)

        appState.openConversionHistory(sourceFilter: .manual)
        XCTAssertEqual(appState.selectedTab, .history)
        XCTAssertEqual(appState.pendingHistorySourceFilter, .manual)
        XCTAssertNil(appState.pendingHistoryWatchFolderRuleID)
        XCTAssertNil(appState.pendingHistoryWatchFolderRuleName)
        XCTAssertEqual(appState.pendingHistoryNavigationNonce, initialNonce + 2)
    }
}

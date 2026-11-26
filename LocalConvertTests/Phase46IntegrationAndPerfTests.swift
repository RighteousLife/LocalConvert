import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
@testable import LocalConvert

@Suite("Phase 46 — Integration, Undo/Redo Persistence, .lcimg Projects & Performance", .serialized)
struct Phase46IntegrationAndPerfTests {

    private func makeSandbox(prefix: String = "Phase46Tests") throws -> (root: URL, journalDir: URL, artifactsDir: URL, workDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let journalDir = root.appendingPathComponent("journal", isDirectory: true)
        let artifactsDir = root.appendingPathComponent("artifacts", isDirectory: true)
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        return (root, journalDir, artifactsDir, workDir)
    }

    @MainActor
    private func makeCoordinator(sandbox: (root: URL, journalDir: URL, artifactsDir: URL, workDir: URL)) -> UndoRedoCoordinator {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        return UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 100 },
            storageBudgetBytesProvider: { 50_000_000 }
        )
    }

    private func writeSyntheticPNG(to url: URL, width: Int, height: Int) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Phase46Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        ctx.setFillColor(red: 0.24, green: 0.48, blue: 0.72, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.85, green: 0.55, blue: 0.20, alpha: 1.0)
        ctx.fill(CGRect(x: width / 6, y: height / 6, width: width * 2 / 3, height: height * 2 / 3))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Phase46Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Phase46Tests", code: 3, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationFinalize failed"])
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 46.6 Continuous Undo Coalescing & Rehydration

    @Test("46.6 Continuous drag coalescing across adjustments, straighten, polygon crop, and interrupted session recovery")
    @MainActor
    func continuousCoalescingAndInterruptedSessionRecovery() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let coord = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coord)

        let urlA = sandbox.workDir.appendingPathComponent("a.png")
        let urlB = sandbox.workDir.appendingPathComponent("b.png")

        // 1. Explicit exposure drag -> 1 undo step
        store.beginContinuousEdit(for: urlA)
        for ev in stride(from: 0.2, through: 1.6, by: 0.2) {
            store.updateConfig(for: urlA) { $0.colorAdjustments.exposureEV = ev }
        }
        store.endContinuousEdit(for: urlA, explicitType: .imageConfigEdit, explicitTitle: "Adjust Exposure")
        await store.flushPendingUndoRecords()

        #expect(coord.undoEntries(for: .imageToolbox).count == 1)
        #expect(abs(store.config(for: urlA).colorAdjustments.exposureEV - 1.6) < 0.001)

        // 2. Explicit straighten drag -> 1 undo step
        store.beginContinuousEdit(for: urlA)
        for deg in stride(from: 1.0, through: 7.5, by: 1.5) {
            store.updateConfig(for: urlA) { $0.cropTransform.straightenDegrees = deg }
        }
        store.endContinuousEdit(for: urlA, explicitType: .imageCrop, explicitTitle: "Straighten Image")
        await store.flushPendingUndoRecords()
        #expect(coord.undoEntries(for: .imageToolbox).count == 2)

        // 3. Interrupted continuous session on urlA when user switches to urlB
        store.beginContinuousEdit(for: urlA)
        store.updateConfig(for: urlA) { $0.cropTransform.roundedCornerRadiusPercent = 24 }
        // User switches to urlB without releasing pointer on urlA
        store.beginContinuousEdit(for: urlB)
        store.updateConfig(for: urlB) { $0.colorAdjustments.contrast = 1.25 }
        store.endContinuousEdit(for: urlB, explicitType: .imageConfigEdit, explicitTitle: "Adjust Contrast")
        await store.flushPendingUndoRecords()

        // Both urlA's interrupted drag and urlB's drag were cleanly flushed as 1 step each (total 4)
        #expect(coord.undoEntries(for: .imageToolbox).count == 4)
        #expect(abs(store.config(for: urlA).cropTransform.roundedCornerRadiusPercent - 24) < 0.001)
        #expect(abs(store.config(for: urlB).colorAdjustments.contrast - 1.25) < 0.001)

        // Step-by-step Undo back to clean state
        await coord.undo(in: .imageToolbox) // undo urlB contrast
        #expect(abs(store.config(for: urlB).colorAdjustments.contrast - 1.0) < 0.001)
        await coord.undo(in: .imageToolbox) // undo urlA corner radius
        #expect(store.config(for: urlA).cropTransform.roundedCornerRadiusPercent == 18.0)
        await coord.undo(in: .imageToolbox) // undo urlA straighten
        #expect(store.config(for: urlA).cropTransform.straightenDegrees == 0)
        await coord.undo(in: .imageToolbox) // undo urlA exposure
        #expect(store.config(for: urlA).colorAdjustments.exposureEV == 0)
        #expect(!coord.canUndo(in: .imageToolbox))

        // Redo preserves exact final state
        while coord.canRedo(in: .imageToolbox) {
            await coord.redo(in: .imageToolbox)
        }
        #expect(abs(store.config(for: urlA).colorAdjustments.exposureEV - 1.6) < 0.001)
        #expect(abs(store.config(for: urlB).colorAdjustments.contrast - 1.25) < 0.001)
    }

    @Test("46.6 Journal compactness & restart rehydration across all Phase 46 config sections")
    @MainActor
    func restartRehydrationAndCompactJournalPayload() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let imgURL = sandbox.workDir.appendingPathComponent("sunset.png")
        try writeSyntheticPNG(to: imgURL, width: 120, height: 90)

        let coord1 = makeCoordinator(sandbox: sandbox)
        let store1 = ImageToolboxStore(undoCoordinator: coord1)

        store1.updateConfig(for: imgURL) { cfg in
            cfg.colorAdjustments.exposureEV = 0.75
            cfg.colorAdjustments.curves.master = [
                ImageCurvePoint(x: 0.0, y: 0.0),
                ImageCurvePoint(x: 0.45, y: 0.60),
                ImageCurvePoint(x: 1.0, y: 1.0)
            ]
            cfg.effectStack = [
                ImageEffectSlot(kind: .vignette, intensity: 0.45, radius: 2.0, falloff: 0.5)
            ]
            cfg.cropTransform.straightenDegrees = -3.2
            cfg.rawDevelop.lumaNoiseReduction = 0.35
        }
        await store1.flushPendingUndoRecords()
        coord1.flushPersistence()

        // Verify journal file remains compact (config metadata only, zero pixel buffers)
        let journalFiles = try FileManager.default.contentsOfDirectory(at: sandbox.journalDir, includingPropertiesForKeys: [.fileSizeKey])
        #expect(!journalFiles.isEmpty)
        for jf in journalFiles where jf.pathExtension == "json" {
            let size = try jf.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            #expect(size < 24_000, "Undo journal entry unexpectedly bloated (\(size) bytes)")
        }

        // Fresh coordinator + store (simulating app relaunch)
        let coord2 = makeCoordinator(sandbox: sandbox)
        let store2 = ImageToolboxStore(undoCoordinator: coord2)
        await coord2.restorePersistedHistory()

        #expect(coord2.canUndo(in: .imageToolbox))
        await coord2.undo(in: .imageToolbox)
        #expect(store2.config(for: imgURL).colorAdjustments.exposureEV == 0.0)
        #expect(store2.config(for: imgURL).effectStack.isEmpty)

        await coord2.redo(in: .imageToolbox)
        let restored = store2.config(for: imgURL)
        #expect(abs(restored.colorAdjustments.exposureEV - 0.75) < 0.001)
        #expect(restored.colorAdjustments.curves.master.count == 3)
        #expect(restored.effectStack.first?.kind == .vignette)
        #expect(abs(restored.cropTransform.straightenDegrees + 3.2) < 0.001)
        #expect(abs(restored.rawDevelop.lumaNoiseReduction - 0.35) < 0.001)
    }

    @Test("46.6 .lcimg project persistence, source immutability, symlink/traversal guards, and missing-source relink")
    func projectPersistenceSecurityAndMissingSourceRelink() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let srcURL = sandbox.workDir.appendingPathComponent("portrait.png")
        try writeSyntheticPNG(to: srcURL, width: 160, height: 120)
        let origHash = try sha256Hex(of: srcURL)

        var cfg = ImageToolboxConfig()
        cfg.colorAdjustments.vibrance = 0.42
        cfg.colorAdjustments.saturation = 1.15
        cfg.effectStack = [ImageEffectSlot(kind: .filmGrain, intensity: 0.3, grainSize: 1.5)]
        cfg.cropTransform.straightenDegrees = 4.5
        cfg.cropTransform.autoCropOnStraighten = true

        let doc = ImageProjectDocument.create(sourceURL: srcURL, targetFormat: .webp, config: cfg)
        let projURL = sandbox.workDir.appendingPathComponent("portrait.lcimg")
        try ImagePresetCatalog.saveProject(doc, to: projURL, protectedSourceURLs: [srcURL])

        // No stray temp files remain after atomic replace/write
        let items = try FileManager.default.contentsOfDirectory(at: sandbox.workDir, includingPropertiesForKeys: nil)
        #expect(!items.contains(where: { $0.lastPathComponent.contains(".tmp-") }))
        #expect(try sha256Hex(of: srcURL) == origHash)

        // Reject saving a project directly over a protected source or symlink to source
        #expect(throws: Error.self) {
            try ImagePresetCatalog.saveProject(doc, to: srcURL, protectedSourceURLs: [srcURL])
        }
        let symlinkURL = sandbox.workDir.appendingPathComponent("sneaky_link.lcimg")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: srcURL)
        #expect(throws: Error.self) {
            try ImagePresetCatalog.saveProject(doc, to: symlinkURL, protectedSourceURLs: [srcURL])
        }
        #expect(try sha256Hex(of: srcURL) == origHash)

        // Load project with intact source
        let loadedOK = try ImagePresetCatalog.loadProject(from: projURL)
        #expect(!loadedOK.isSourceMissing)
        #expect(loadedOK.resolvedSourceURL?.standardizedFileURL.resolvingSymlinksInPath() == srcURL.standardizedFileURL.resolvingSymlinksInPath())
        #expect(loadedOK.document.targetFormat == .webp)
        #expect(abs(loadedOK.document.config.colorAdjustments.vibrance - 0.42) < 0.001)
        #expect(loadedOK.document.config.effectStack.count == 1)

        // Missing source triggers clean isSourceMissing state for UI relink
        try FileManager.default.removeItem(at: srcURL)
        // Strip bookmark so fallback can't resolve the deleted inode
        var missingDoc = doc
        missingDoc.sourceBookmarkData = nil
        try ImagePresetCatalog.saveProject(missingDoc, to: projURL)
        let loadedMissing = try ImagePresetCatalog.loadProject(from: projURL)
        #expect(loadedMissing.isSourceMissing)
        #expect(loadedMissing.resolvedSourceURL == nil)

        // Path traversal / future schema guards
        var traversalDoc = ImageProjectDocument(sourcePath: "/tmp/../../etc/passwd", targetFormat: .png, config: cfg)
        let traversalURL = sandbox.workDir.appendingPathComponent("traversal.lcimg")
        try ImagePresetCatalog.saveProject(traversalDoc, to: traversalURL)
        let loadedTraversal = try ImagePresetCatalog.loadProject(from: traversalURL)
        #expect(loadedTraversal.isSourceMissing)
        #expect(loadedTraversal.resolvedSourceURL == nil)

        traversalDoc.schemaVersion = 99
        let futureURL = sandbox.workDir.appendingPathComponent("future.lcimg")
        try ImagePresetCatalog.saveProject(traversalDoc, to: futureURL)
        #expect(throws: Error.self) {
            _ = try ImagePresetCatalog.loadProject(from: futureURL)
        }
    }

    // MARK: - 46.7 Performance, Proxy Cache Invalidation & 50 MP Memory Boundedness

    private func currentNonVolatileInternalMB() -> Double {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kVM = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard kVM == KERN_SUCCESS else { return 0.0 }
        let volatileBytes = UInt64(max(0, vmInfo.ledger_purgeable_volatile + vmInfo.ledger_purgeable_volatile_compressed)) + vmInfo.reusable
        let nonVolatileInternalBytes = (vmInfo.internal > volatileBytes) ? (vmInfo.internal - volatileBytes) : 0
        return Double(nonVolatileInternalBytes) / (1024.0 * 1024.0)
    }

    private func settleMemory() async {
        autoreleasepool {
            malloc_zone_pressure_relief(nil, 0)
        }
        try? await Task.sleep(for: .milliseconds(250))
        autoreleasepool {
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    @Test("46.7 Proxy cache detects external file modifications and prunes stale entries")
    func proxyCacheEvictionAndExternalEditInvalidation() async throws {
        let sandbox = try makeSandbox(prefix: "Phase46ProxyCache")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        await ImagePreviewProxyCache.shared.clear()

        let imgURL = sandbox.workDir.appendingPathComponent("mutable.png")
        try writeSyntheticPNG(to: imgURL, width: 800, height: 600)

        let first = try await ImageProcessingService.decodeInputImageWithRAW(
            url: imgURL,
            maxPixelDimension: 1200,
            useProxyCache: true
        )
        #expect(first.cgImage.width == 800)
        let stats1 = await ImagePreviewProxyCache.shared.stats()
        #expect(stats1.proxyCount == 1)

        // Sleep slightly & overwrite with distinctly sized dimensions + file byte length
        try await Task.sleep(for: .milliseconds(50))
        try writeSyntheticPNG(to: imgURL, width: 1024, height: 768)

        let second = try await ImageProcessingService.decodeInputImageWithRAW(
            url: imgURL,
            maxPixelDimension: 1200,
            useProxyCache: true
        )
        #expect(second.cgImage.width == 1024)
        let stats2 = await ImagePreviewProxyCache.shared.stats()
        #expect(stats2.proxyCount == 1, "Stale file-identity proxy entry must be pruned on update")

        await ImagePreviewProxyCache.shared.invalidate(url: imgURL)
        let statsAfter = await ImagePreviewProxyCache.shared.stats()
        #expect(statsAfter.proxyCount == 0)
        #expect(statsAfter.bytesUsed == 0)
    }

    @Test("46.7 Interactive proxy renders full Color + Levels + Curves + Balance + 4 Effects within budget on 24 MP image")
    func interactiveProxyLatencyWithFullAdjustmentAndEffectDAG() async throws {
        let sandbox = try makeSandbox(prefix: "Phase46ProxyLatency")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        await ImagePreviewProxyCache.shared.clear()

        let src24MP = sandbox.workDir.appendingPathComponent("photo_24mp.png")
        try writeSyntheticPNG(to: src24MP, width: 6000, height: 4000)

        var cfg = ImageToolboxConfig()
        cfg.colorAdjustments.temperatureOffset = 25
        cfg.colorAdjustments.tintOffset = -8
        cfg.colorAdjustments.exposureEV = 0.45
        cfg.colorAdjustments.contrast = 1.12
        cfg.colorAdjustments.highlights = -0.25
        cfg.colorAdjustments.shadows = 0.25
        cfg.colorAdjustments.vibrance = 0.22
        cfg.colorAdjustments.levels.master.blackPoint = 0.04
        cfg.colorAdjustments.levels.master.whitePoint = 0.96
        cfg.colorAdjustments.curves.master = [
            ImageCurvePoint(x: 0.0, y: 0.0),
            ImageCurvePoint(x: 0.5, y: 0.58),
            ImageCurvePoint(x: 1.0, y: 1.0)
        ]
        cfg.colorAdjustments.colorBalance.highlights.yellowBlue = -0.15
        cfg.effectStack = [
            ImageEffectSlot(kind: .unsharpMask, intensity: 0.5, radius: 2.0),
            ImageEffectSlot(kind: .vignette, intensity: 0.4, radius: 1.8, falloff: 0.6),
            ImageEffectSlot(kind: .photoFilter, intensity: 0.25, photoStyle: .warmAmber),
            ImageEffectSlot(kind: .filmGrain, intensity: 0.25, grainSize: 1.2)
        ]

        // Warm proxy decode (cold pass decodes 24 MP file -> <= 1200 px cached proxy)
        _ = try await ImageProcessingService.processInMemory(
            url: src24MP,
            outputFormat: .png,
            config: cfg,
            previewMaxDimension: 1200,
            encodeOutput: false
        )

        // Cached interactive scrub pass (simulated exposure slider move)
        cfg.colorAdjustments.exposureEV = 0.85
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try await ImageProcessingService.processInMemory(
            url: src24MP,
            outputFormat: .png,
            config: cfg,
            previewMaxDimension: 1200,
            encodeOutput: false
        )
        let interactiveElapsed = CFAbsoluteTimeGetCurrent() - t0
        print(String(format: "[Phase46.7] 24MP Cached Proxy Full-DAG render time (Debug arm64): %.3fs (%dx%d)",
                     interactiveElapsed, out.previewCGImage.width, out.previewCGImage.height))

        #expect(out.previewCGImage.width <= 1200)
        #expect(interactiveElapsed < 0.75, "Cached interactive proxy DAG exceeded 750ms Debug ceiling (\(interactiveElapsed)s)")
    }

    @Test("46.7 50 MP multi-stage Color + Curves + Effects + Straighten export maintains bounded memory and temp hygiene")
    func fiftyMegapixelMultiStageColorAndEffectsMemoryBoundedness() async throws {
        let sandbox = try makeSandbox(prefix: "Phase46Mem50MP")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        await ImagePreviewProxyCache.shared.clear()

        let src50 = sandbox.workDir.appendingPathComponent("canvas_50mp.png")
        try autoreleasepool {
            try writeSyntheticPNG(to: src50, width: 8192, height: 6104)
        }
        let origHash = try sha256Hex(of: src50)

        var cfg = ImageToolboxConfig()
        cfg.quality = 0.88
        cfg.colorAdjustments.exposureEV = 0.35
        cfg.colorAdjustments.contrast = 1.08
        cfg.colorAdjustments.curves.master = [
            ImageCurvePoint(x: 0.0, y: 0.02),
            ImageCurvePoint(x: 0.5, y: 0.56),
            ImageCurvePoint(x: 1.0, y: 0.98)
        ]
        cfg.effectStack = [
            ImageEffectSlot(kind: .vignette, intensity: 0.35, radius: 2.0, falloff: 0.5),
            ImageEffectSlot(kind: .unsharpMask, intensity: 0.45, radius: 1.6)
        ]
        cfg.cropTransform.straightenDegrees = 2.5
        cfg.cropTransform.autoCropOnStraighten = true

        let tmpBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("LocalConvert-") } ?? [])

        // Warm up shared CoreImage/Metal pipeline caches before sampling steady-state memory across 3 iterations.
        await settleMemory()
        let warmupOutDir = sandbox.workDir.appendingPathComponent("out_warmup", isDirectory: true)
        try FileManager.default.createDirectory(at: warmupOutDir, withIntermediateDirectories: true)
        _ = try await ImageProcessingService.processToFile(
            inputURL: src50,
            outputFormat: .jpg,
            outputDirectory: warmupOutDir,
            config: cfg
        )
        try? FileManager.default.removeItem(at: warmupOutDir)
        await settleMemory()

        var internalMBReadings: [Double] = []
        for idx in 1...3 {
            let outDir = sandbox.workDir.appendingPathComponent("out_\(idx)", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await ImageProcessingService.processToFile(
                inputURL: src50,
                outputFormat: .jpg,
                outputDirectory: outDir,
                config: cfg
            )
            #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
            if let dims = ImageProcessingService.inspectSourceDimensions(url: result.outputURL) {
                #expect(dims.width > 7000 && dims.width < 8192)
                #expect(dims.height > 5000 && dims.height < 6104)
            }
            await settleMemory()
            internalMBReadings.append(currentNonVolatileInternalMB())
        }
        await ImagePreviewProxyCache.shared.clear()

        let tmpAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("LocalConvert-") } ?? [])
        #expect(tmpAfter == tmpBefore, "Stray LocalConvert-* temp artifacts remained: \(tmpAfter.subtracting(tmpBefore))")
        #expect(try sha256Hex(of: src50) == origHash, "50 MP export must never mutate source image")

        let growth = internalMBReadings[2] - internalMBReadings[0]
        print(String(format: "[Phase46.7] 50MP Full Color+Effects+Straighten nonVolatileInternalMB: iter1=%.1fMB iter2=%.1fMB iter3=%.1fMB (growth=%.1fMB)",
                     internalMBReadings[0], internalMBReadings[1], internalMBReadings[2], growth))
        #expect(growth <= 180.0, "Non-volatile memory grew abnormally across 50 MP multi-stage exports: +\(growth) MB")
    }
}

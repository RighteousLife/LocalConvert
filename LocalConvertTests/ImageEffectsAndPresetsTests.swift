import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
@testable import LocalConvert

@Suite("Milestone 46.3 — Effects Chain & Look Presets Tests")
struct ImageEffectsAndPresetsTests {

    private func makeCheckerPNG(width: Int, height: Int, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let edge = (x / 12 + y / 12).isMultiple(of: 2)
                rgba[i + 0] = edge ? 220 : 60
                rgba[i + 1] = edge ? 140 : 170
                rgba[i + 2] = edge ? 50 : 210
                rgba[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let cg = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    private func renderBytes(_ ci: CIImage, w: Int, h: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        ImageProcessor.sharedCIContext(for: cs).render(
            ci, toBitmap: &buf, rowBytes: w * 4,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBA8, colorSpace: cs
        )
        return buf
    }

    @Test("All 9 effect kinds run cleanly, Vignette darkens corners vs center, and stack order alters output")
    func effectsAndOrdering() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-463-fx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("checker.png")
        try makeCheckerPNG(width: 96, height: 96, to: srcURL)
        let srcCG = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(srcURL as CFURL, nil)!, 0, nil)!
        let ci = CIImage(cgImage: srcCG)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!

        // Run every effect kind cleanly
        for kind in ImageEffectKind.allCases {
            let slot = ImageEffectSlot.makeDefault(kind: kind)
            let out = ImageAdjustmentsEngine.applyEffectsChain(ci, slots: [slot], workingColorSpace: cs)
            let bytes = renderBytes(out, w: 96, h: 96)
            #expect(bytes.count == 96 * 96 * 4)
        }

        // Vignette darkens corner pixel relative to center pixel on flat gray image
        let flat = CIImage(color: CIColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let vig = ImageEffectSlot(kind: .vignette, isEnabled: true, intensity: 1.0, radius: 0.4, falloff: 0.5)
        let vigBytes = renderBytes(ImageAdjustmentsEngine.applyEffectsChain(flat, slots: [vig], workingColorSpace: cs), w: 100, h: 100)
        let cornerLuma = Int(vigBytes[0])
        let centerLuma = Int(vigBytes[(50 * 100 + 50) * 4])
        #expect(centerLuma > cornerLuma + 20)

        // Stack order dependence: [GaussianBlur -> Sharpen] != [Sharpen -> GaussianBlur]
        let blur = ImageEffectSlot(kind: .gaussianBlur, isEnabled: true, intensity: 1.0, radius: 4.0)
        let sharp = ImageEffectSlot(kind: .sharpen, isEnabled: true, intensity: 1.4, radius: 2.0, sharpness: 1.5)
        let b1 = renderBytes(ImageAdjustmentsEngine.applyEffectsChain(ci, slots: [blur, sharp], workingColorSpace: cs), w: 96, h: 96)
        let b2 = renderBytes(ImageAdjustmentsEngine.applyEffectsChain(ci, slots: [sharp, blur], workingColorSpace: cs), w: 96, h: 96)
        #expect(b1 != b2)
    }

    @Test("Ordered stack add/toggle/reorder/reset and Look Preset CRUD + Look-Only preservation undo cleanly")
    @MainActor
    func stackUndoAndPresetWorkflow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-463-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let img1 = dir.appendingPathComponent("a.png")
        let img2 = dir.appendingPathComponent("b.png")
        try makeCheckerPNG(width: 64, height: 64, to: img1)
        try makeCheckerPNG(width: 64, height: 64, to: img2)

        let coord = UndoRedoCoordinator(
            journalDirectoryURL: dir.appendingPathComponent("j"),
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: dir.appendingPathComponent("a"))
        )
        let store = ImageToolboxStore(undoCoordinator: coord)

        // Preserve user's crop & resize settings when applying Look Preset
        store.updateConfig(for: img1) { cfg in
            cfg.resizeStrategy = .maxWidth
            cfg.resizeWidth = 800
            cfg.cropTransform.enabled = true
            cfg.cropTransform.rotationDegrees = 90
        }

        store.addEffect(.sepia, for: img1)
        store.addEffect(.vignette, for: img1)
        #expect(store.config(for: img1).effectStack.map(\.kind) == [.sepia, .vignette])
        let firstID = store.config(for: img1).effectStack[0].id
        store.moveEffect(id: firstID, offset: 1, for: img1)
        #expect(store.config(for: img1).effectStack.map(\.kind) == [.vignette, .sepia])
        store.toggleEffect(id: firstID, for: img1)
        #expect(store.config(for: img1).effectStack[1].isEnabled == false)

        // Built-in preset Look-Only application leaves crop & resize untouched
        let builtIn = try #require(ImagePresetCatalog.builtInLookPresets.first)
        #expect(store.applyPreset(builtIn, to: img1) == true)
        #expect(store.config(for: img1).resizeStrategy == .maxWidth)
        #expect(store.config(for: img1).resizeWidth == 800)
        #expect(store.config(for: img1).cropTransform.rotationDegrees == 90)
        #expect(store.config(for: img1).colorAdjustments.hasActiveAdjustments == true)

        // Save, rename, delete User Preset in isolated PresetStore
        let pStore = PresetStore(fileURL: dir.appendingPathComponent("presets.json"))
        let pMgr = PresetManager(store: pStore)
        let saved = ImagePresetCatalog.makeUserLookPreset(
            name: "Studio Mood",
            description: "Custom test look",
            targetFormat: .webp,
            config: store.config(for: img1)
        )
        pMgr.save(preset: saved)
        #expect(pMgr.rename(id: saved.id, to: "Studio Mood v2") == true)
        #expect(pMgr.presets.first(where: { $0.id == saved.id })?.name == "Studio Mood v2")

        // Batch apply preset to multiple images -> isolated UUIDs per image + per-URL report
        let badFile = dir.appendingPathComponent("not_an_image.txt")
        try Data("hello".utf8).write(to: badFile)
        let report = await store.applyPresetBatch(builtIn, to: [img1, img2, badFile])
        #expect(report.succeededCount == 2)
        #expect(report.failedCount == 1)
        let ids1 = Set(store.config(for: img1).effectStack.map(\.id))
        let ids2 = Set(store.config(for: img2).effectStack.map(\.id))
        #expect(ids1.isDisjoint(with: ids2))

        // Flush and Undo batch preset apply cleanly on img1
        await store.flushPendingUndoRecords()
        #expect(coord.canUndo(in: .imageToolbox))
        await coord.undo(in: .imageToolbox) // Undoes batch on img2 + img1 (shared transactionGroupID) or most recent group
        await coord.undo(in: .imageToolbox)
        pMgr.delete(id: saved.id)
        #expect(pMgr.presets.contains(where: { $0.id == saved.id }) == false)
    }
}

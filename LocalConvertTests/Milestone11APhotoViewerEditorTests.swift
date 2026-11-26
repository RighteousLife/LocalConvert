import XCTest
import Foundation
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import LocalConvert

@MainActor
final class Milestone11APhotoViewerEditorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(prefix: String = "M11APhoto") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeSolidCGImage(
        width: Int = 120,
        height: Int = 80,
        red: UInt8 = 40,
        green: UInt8 = 120,
        blue: UInt8 = 220,
        alpha: UInt8 = 255
    ) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = alpha
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ), let cg = ctx.makeImage() else {
            throw NSError(domain: "M11APhotoTests", code: 1)
        }
        return cg
    }

    private func makeCheckerboardCGImage(width: Int = 160, height: Int = 120, tileSize: Int = 8) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let isDark = ((x / tileSize) + (y / tileSize)) % 2 == 0
                let idx = (y * width + x) * 4
                pixels[idx] = isDark ? 20 : 235
                pixels[idx + 1] = isDark ? 90 : 210
                pixels[idx + 2] = isDark ? 210 : 40
                pixels[idx + 3] = 255
            }
        }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ), let cg = ctx.makeImage() else {
            throw NSError(domain: "M11APhotoTests", code: 2)
        }
        return cg
    }

    private func makeTextCGImage(text: String, width: Int = 480, height: Int = 160) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "M11APhotoTests", code: 3)
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 38, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 28, y: 56), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else {
            throw NSError(domain: "M11APhotoTests", code: 4)
        }
        return cg
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "M11APhotoTests", code: 5)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "M11APhotoTests", code: 6)
        }
    }

    private func rgbaPixel(in image: CGImage, x: Int, yTopLeft: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard x >= 0, x < image.width, yTopLeft >= 0, yTopLeft < image.height else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (yTopLeft * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    // MARK: - 1. Folder Sibling Discovery

    func testLoadSiblingsFiltersNonImagesAndSortsNaturally() throws {
        let dir = try makeTempDir(prefix: "Siblings")
        defer { try? FileManager.default.removeItem(at: dir) }

        let img2 = dir.appendingPathComponent("photo2.png")
        let img10 = dir.appendingPathComponent("photo10.JPG")
        let img1 = dir.appendingPathComponent("photo1.webp")
        let hidden = dir.appendingPathComponent(".hidden.png")
        let textFile = dir.appendingPathComponent("notes.txt")
        let pdfFile = dir.appendingPathComponent("doc.pdf")
        let subDir = dir.appendingPathComponent("nested.png", isDirectory: true)

        let tiny = try makeSolidCGImage(width: 8, height: 8)
        try writePNG(tiny, to: img2)
        try writePNG(tiny, to: img10)
        try writePNG(tiny, to: img1)
        try writePNG(tiny, to: hidden)
        try Data("not an image".utf8).write(to: textFile)
        try Data("%PDF-1.4".utf8).write(to: pdfFile)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let siblings = QuickPhotoRenderEngine.loadSiblings(for: img2)
        XCTAssertEqual(siblings.map(\.lastPathComponent), ["photo1.webp", "photo2.png", "photo10.JPG"])
    }

    func testLoadSiblingsHandlesSingleAndMissingFilesGracefully() throws {
        let dir = try makeTempDir(prefix: "SiblingsEdge")
        defer { try? FileManager.default.removeItem(at: dir) }

        let solo = dir.appendingPathComponent("solo.png")
        try writePNG(try makeSolidCGImage(width: 8, height: 8), to: solo)
        let soloList = QuickPhotoRenderEngine.loadSiblings(for: solo)
        XCTAssertEqual(soloList.map(\.lastPathComponent), ["solo.png"])

        let missingDirFile = dir.appendingPathComponent("missing-folder/absent.png")
        let missingList = QuickPhotoRenderEngine.loadSiblings(for: missingDirFile)
        XCTAssertTrue(missingList.isEmpty)
    }

    // MARK: - 2. 30-Step Undo / Redo Bounds

    func testUndoRedoStackCapsAt30StepsAndClearsRedoOnNewEdit() throws {
        let img = try makeSolidCGImage(width: 32, height: 32)
        let model = QuickPhotoEditorModel(testImage: img)
        XCTAssertEqual(model.maxHistoryCount, 30)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)

        // Push 35 sequential edits (exposure 0.01 ... 0.35)
        for step in 1...35 {
            model.applyEdit { state in
                state.adjustments.exposure = Double(step) * 0.01
            }
        }

        XCTAssertEqual(model.undoStack.count, 30)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.editState.adjustments.exposure, 0.35, accuracy: 0.0001)

        // Undo all 30 retained steps -> stops at step 5 (0.05), since steps 0..4 were evicted
        for _ in 0..<30 {
            model.undo()
        }
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.undoStack.count, 0)
        XCTAssertEqual(model.redoStack.count, 30)
        XCTAssertTrue(model.canRedo)
        XCTAssertEqual(model.editState.adjustments.exposure, 0.05, accuracy: 0.0001)

        // Redo 3 steps -> reaches 0.08
        for _ in 0..<3 {
            model.redo()
        }
        XCTAssertEqual(model.editState.adjustments.exposure, 0.08, accuracy: 0.0001)
        XCTAssertEqual(model.redoStack.count, 27)

        // Applying a new edit must clear the redo stack
        model.applyEdit { state in
            state.adjustments.brightness = 0.2
        }
        XCTAssertFalse(model.canRedo)
        XCTAssertTrue(model.redoStack.isEmpty)
        XCTAssertEqual(model.editState.adjustments.brightness, 0.2, accuracy: 0.0001)
    }

    // MARK: - 3. Markup, Redaction, Orientation, Crop & Backdrop Rendering

    func testBackdropPaddingExpandsOutputDimensionsExactly() throws {
        let base = try makeSolidCGImage(width: 200, height: 120, red: 60, green: 140, blue: 210)
        var state = QuickPhotoEditState()
        state.backdrop.isEnabled = true
        state.backdrop.style = .gradient
        state.backdrop.applyPreset(.sunset)
        state.backdrop.padding = 40
        state.backdrop.cornerRadius = 16

        let rendered = QuickPhotoRenderEngine.renderCGImage(from: base, state: state)
        XCTAssertNotNil(rendered)
        XCTAssertEqual(rendered?.width, 280)
        XCTAssertEqual(rendered?.height, 200)
    }

    func testRotationAndCropTransformOutputDimensions() throws {
        let base = try makeSolidCGImage(width: 200, height: 100)
        var state = QuickPhotoEditState()
        state.rotationQuarterTurns = 1 // 90° CW -> 100 x 200
        state.cropRect = NormalizedRect(x: 0.1, y: 0.25, width: 0.5, height: 0.5)

        let rendered = QuickPhotoRenderEngine.renderCGImage(from: base, state: state)
        XCTAssertNotNil(rendered)
        XCTAssertEqual(rendered?.width, 50)
        XCTAssertEqual(rendered?.height, 100)
    }

    func testRedactionSolidMosaicBlurAndMarkupAnnotationsRenderCleanly() throws {
        let base = try makeCheckerboardCGImage(width: 160, height: 120, tileSize: 8)
        let model = QuickPhotoEditorModel(testImage: base)

        // Solid blackout over center box [0.3, 0.3] -> [0.7, 0.7]
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .redactSolid,
            startPoint: CodableNormalizedPoint(x: 0.30, y: 0.30),
            endPoint: CodableNormalizedPoint(x: 0.70, y: 0.70)
        ))
        // Mosaic over top-right
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .redactMosaic,
            startPoint: CodableNormalizedPoint(x: 0.75, y: 0.05),
            endPoint: CodableNormalizedPoint(x: 0.95, y: 0.25)
        ))
        // Blur over bottom-left
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .redactBlur,
            startPoint: CodableNormalizedPoint(x: 0.05, y: 0.75),
            endPoint: CodableNormalizedPoint(x: 0.25, y: 0.95)
        ))
        // Step badges auto-increment 1, 2
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .stepBadge,
            startPoint: CodableNormalizedPoint(x: 0.15, y: 0.15)
        ))
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .stepBadge,
            startPoint: CodableNormalizedPoint(x: 0.25, y: 0.15)
        ))
        // Arrow + Text + Spot Heal
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .arrow,
            startPoint: CodableNormalizedPoint(x: 0.10, y: 0.45),
            endPoint: CodableNormalizedPoint(x: 0.25, y: 0.55)
        ))
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .text,
            startPoint: CodableNormalizedPoint(x: 0.50, y: 0.12),
            text: "Step",
            fontSize: 18
        ))
        model.addAnnotation(QuickPhotoAnnotation(
            kind: .spotHeal,
            startPoint: CodableNormalizedPoint(x: 0.85, y: 0.85),
            points: [
                CodableNormalizedPoint(x: 0.82, y: 0.85),
                CodableNormalizedPoint(x: 0.88, y: 0.85)
            ],
            strokeWidth: 8
        ))

        let stepNumbers = model.editState.annotations
            .filter { $0.kind == .stepBadge }
            .map(\.stepNumber)
        XCTAssertEqual(stepNumbers, [1, 2])
        XCTAssertEqual(model.nextStepNumber, 3)

        let rendered = model.renderFullResolutionCGImage()
        XCTAssertNotNil(rendered)
        if let rendered {
            // Center of solid blackout should be pure black
            let centerPixel = rgbaPixel(in: rendered, x: 80, yTopLeft: 60)
            XCTAssertNotNil(centerPixel)
            XCTAssertEqual(centerPixel?.r, 0)
            XCTAssertEqual(centerPixel?.g, 0)
            XCTAssertEqual(centerPixel?.b, 0)

            // Untouched top-left corner pixel (2, 2) should retain checkerboard dark blue color
            let cornerPixel = rgbaPixel(in: rendered, x: 2, yTopLeft: 2)
            XCTAssertNotNil(cornerPixel)
            XCTAssertGreaterThan(cornerPixel?.b ?? 0, 100)
        }
    }

    // MARK: - 4. Vision OCR Helper Safety

    func testVisionOCRSafelyHandlesBlankAndTinyImagesAndExtractsText() async throws {
        let tiny = try makeSolidCGImage(width: 1, height: 1, red: 255, green: 255, blue: 255)
        let tinyText = try await QuickPhotoRenderEngine.extractText(from: tiny)
        XCTAssertEqual(tinyText, "")

        let blank = try makeSolidCGImage(width: 120, height: 60, red: 240, green: 240, blue: 240)
        let blankText = try await QuickPhotoRenderEngine.extractText(from: blank)
        XCTAssertTrue(blankText.isEmpty)

        let textImage = try makeTextCGImage(text: "LOCALCONVERT 2026")
        let recognized = try await QuickPhotoRenderEngine.extractText(from: textImage)
        XCTAssertTrue(
            recognized.uppercased().contains("LOCALCONVERT") || recognized.contains("2026"),
            "Expected Vision OCR to detect rendered text, got: '\(recognized)'"
        )
    }

    // MARK: - 5. Atomic Save Copy & Original Preservation (LC-001)

    func testSaveCopyCreatesAtomicOutputWithoutModifyingOriginalAndHandlesCollisions() async throws {
        let dir = try makeTempDir(prefix: "AtomicSave")
        defer { try? FileManager.default.removeItem(at: dir) }

        let originalURL = dir.appendingPathComponent("original.png")
        let sourceImg = try makeSolidCGImage(width: 120, height: 80, red: 30, green: 160, blue: 90)
        try writePNG(sourceImg, to: originalURL)
        let originalHashBefore = try sha256Hex(of: originalURL)

        let model = QuickPhotoEditorModel(url: originalURL)
        await model.load(url: originalURL)
        model.rotateClockwise() // 120x80 -> 80x120

        // Refusing direct overwrite through saveCopy
        do {
            _ = try await model.saveCopy(to: originalURL)
            XCTFail("saveCopy must reject overwriting the original file directly")
        } catch {
            // Expected
        }
        XCTAssertEqual(try sha256Hex(of: originalURL), originalHashBefore)

        // Save copy to new destination
        let copyURL = model.suggestedCopyURL()
        let savedURL = try await model.saveCopy(to: copyURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(try sha256Hex(of: originalURL), originalHashBefore)

        let savedDims = ImageProcessingService.inspectSourceDimensions(url: savedURL)
        XCTAssertEqual(savedDims?.width, 80)
        XCTAssertEqual(savedDims?.height, 120)

        // Collision rejection when policy == .createUnique
        let existingHash = try sha256Hex(of: savedURL)
        do {
            _ = try await model.saveCopy(to: savedURL, policy: .createUnique)
            XCTFail("Expected outputFileAlreadyExists when policy is .createUnique")
        } catch let err as ConversionError {
            if case .outputFileAlreadyExists = err {
                // Expected
            } else {
                XCTFail("Unexpected ConversionError: \(err)")
            }
        }
        XCTAssertEqual(try sha256Hex(of: savedURL), existingHash)

        // Atomic replacement when policy == .overwrite
        model.applyEdit { $0.backdrop.isEnabled = true; $0.backdrop.padding = 20 }
        let replacedURL = try await model.saveCopy(to: savedURL, policy: .overwrite)
        XCTAssertEqual(replacedURL.standardizedFileURL, savedURL.standardizedFileURL)
        let replacedDims = ImageProcessingService.inspectSourceDimensions(url: replacedURL)
        XCTAssertEqual(replacedDims?.width, 120) // 80 + 2*20
        XCTAssertEqual(replacedDims?.height, 160) // 120 + 2*20
        XCTAssertEqual(try sha256Hex(of: originalURL), originalHashBefore)
    }

    func testOverwriteOriginalUpdatesFileAtomicallyWhenConfirmed() async throws {
        let dir = try makeTempDir(prefix: "OverwriteOriginal")
        defer { try? FileManager.default.removeItem(at: dir) }

        let targetURL = dir.appendingPathComponent("editable.png")
        try writePNG(try makeSolidCGImage(width: 100, height: 60), to: targetURL)

        let model = QuickPhotoEditorModel(url: targetURL)
        await model.load(url: targetURL)
        XCTAssertTrue(model.canOverwriteOriginal)

        model.rotateClockwise() // 100x60 -> 60x100
        let updatedURL = try await model.overwriteOriginal()
        XCTAssertEqual(updatedURL.standardizedFileURL, targetURL.standardizedFileURL)
        XCTAssertFalse(model.hasUnsavedChanges)

        let newDims = ImageProcessingService.inspectSourceDimensions(url: targetURL)
        XCTAssertEqual(newDims?.width, 60)
        XCTAssertEqual(newDims?.height, 100)
    }
}

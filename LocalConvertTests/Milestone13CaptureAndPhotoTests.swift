import XCTest
import SwiftUI
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import os
@testable import LocalConvert

@MainActor
final class Milestone13CaptureAndPhotoTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = true
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M13-CapturePhoto-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        PinnedImageWindowController.closeAll()
        AppStoragePaths.clearTestOverrides()
        AppState.shared = previousAppState
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
        previousAppState = nil
    }

    // MARK: - Helpers

    private func makeIsolatedAppState() -> AppState {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        let undo = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: artifacts
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return AppState(
            undoCoordinator: undo,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history,
            uitestingOutputDirectory: sandbox.outputsURL
        )
    }

    private func makeSolidCGImage(
        width: Int = 64,
        height: Int = 48,
        red: UInt8 = 45,
        green: UInt8 = 135,
        blue: UInt8 = 225,
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
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 1)
        }
        return cg
    }

    private func makeMultiBandCGImage(
        width: Int = 100,
        height: Int = 100,
        bands: [(rowCount: Int, r: UInt8, g: UInt8, b: UInt8)]
    ) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var currentRow = 0
        for band in bands {
            let endRow = min(height, currentRow + band.rowCount)
            for y in currentRow..<endRow {
                for x in 0..<width {
                    let idx = (y * width + x) * 4
                    pixels[idx] = band.r
                    pixels[idx + 1] = band.g
                    pixels[idx + 2] = band.b
                    pixels[idx + 3] = 255
                }
            }
            currentRow = endRow
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
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 2)
        }
        return cg
    }

    private func makeQRCodeCGImage(payload: String, pixelSize: Int = 240) throws -> CGImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 3)
        }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputCI = filter.outputImage else {
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 4)
        }

        let extent = outputCI.extent.integral
        let quietScale = max(4.0, floor(CGFloat(pixelSize - 32) / max(1.0, extent.width)))
        let scaledCI = outputCI.transformed(by: CGAffineTransform(scaleX: quietScale, y: quietScale))
        let ciContext = CIContext()
        guard let qrCG = ciContext.createCGImage(scaledCI, from: scaledCI.extent) else {
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 5)
        }

        // Composite onto a crisp white quiet-zone canvas so Vision detects reliably.
        let canvasSize = max(pixelSize, qrCG.width + 40)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: canvasSize,
            height: canvasSize,
            bitsPerComponent: 8,
            bytesPerRow: canvasSize * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 6)
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        let offset = (canvasSize - qrCG.width) / 2
        ctx.interpolationQuality = .none
        ctx.draw(qrCG, in: CGRect(x: offset, y: offset, width: qrCG.width, height: qrCG.height))
        guard let finalCG = ctx.makeImage() else {
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 7)
        }
        return finalCG
    }

    private func writePNG(_ cgImage: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone13CaptureAndPhotoTests", code: 8)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - 1. ScreenCaptureService (Headless Mock Backend)

    func testScreenCaptureInstantRoutesValidPNGIntoMediaViewer() async throws {
        let appState = makeIsolatedAppState()
        let fakeScreen = try makeSolidCGImage(width: 120, height: 80, red: 20, green: 150, blue: 240)
        let backend = MockScreenCaptureBackend(permission: true, result: .success(fakeScreen))
        let sleepRecorder = SleepRecorder()
        let stagingDir = sandbox.temporaryURL.appendingPathComponent("CaptureInstant", isDirectory: true)

        let service = ScreenCaptureService(
            backend: backend,
            sleepNanoseconds: { ns in await sleepRecorder.record(ns) },
            stagingDirectory: stagingDir
        )

        let capturedURL = try await service.captureToMediaViewer(delay: .instant, appState: appState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: capturedURL.path))
        XCTAssertEqual(capturedURL.pathExtension.lowercased(), "png")
        XCTAssertEqual(appState.activeMediaViewerURL, capturedURL)
        XCTAssertTrue(appState.isMediaViewerPresented)

        let sleeps = await sleepRecorder.values()
        XCTAssertTrue(sleeps.isEmpty)
        XCTAssertEqual(backend.captureCallCount, 1)

        let dims = ImageProcessingService.inspectSourceDimensions(url: capturedURL)
        XCTAssertEqual(dims?.width, 120)
        XCTAssertEqual(dims?.height, 80)
    }

    func testScreenCaptureThreeAndFiveSecondDelaysRecordTimerTicksWithoutRealSleep() async throws {
        let fakeScreen = try makeSolidCGImage(width: 64, height: 64, red: 90, green: 210, blue: 120)
        let backend = MockScreenCaptureBackend(permission: true, result: .success(fakeScreen))

        // 3-second delayed capture
        let recorder3s = SleepRecorder()
        let service3s = ScreenCaptureService(
            backend: backend,
            sleepNanoseconds: { ns in await recorder3s.record(ns) },
            stagingDirectory: sandbox.temporaryURL.appendingPathComponent("Capture3s", isDirectory: true)
        )
        let url3s = try await service3s.capture(delay: .threeSeconds)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url3s.path))
        let ticks3s = await recorder3s.values()
        XCTAssertEqual(ticks3s, [1_000_000_000, 1_000_000_000, 1_000_000_000])
        XCTAssertEqual(ticks3s.reduce(0, +), ScreenCaptureDelay.threeSeconds.nanoseconds)

        // 5-second delayed capture
        let recorder5s = SleepRecorder()
        let service5s = ScreenCaptureService(
            backend: backend,
            sleepNanoseconds: { ns in await recorder5s.record(ns) },
            stagingDirectory: sandbox.temporaryURL.appendingPathComponent("Capture5s", isDirectory: true)
        )
        let url5s = try await service5s.capture(delay: .fiveSeconds)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url5s.path))
        let ticks5s = await recorder5s.values()
        XCTAssertEqual(ticks5s.count, 5)
        XCTAssertEqual(ticks5s.reduce(0, +), ScreenCaptureDelay.fiveSeconds.nanoseconds)
        XCTAssertNotEqual(url3s, url5s)
        XCTAssertEqual(backend.captureCallCount, 2)
    }

    func testScreenCapturePermissionDeniedFailsActionablyBeforeSleeping() async throws {
        let fakeScreen = try makeSolidCGImage(width: 32, height: 32)
        let backend = MockScreenCaptureBackend(permission: false, result: .success(fakeScreen))
        let sleepRecorder = SleepRecorder()
        let stagingDir = sandbox.temporaryURL.appendingPathComponent("CaptureDenied", isDirectory: true)

        let service = ScreenCaptureService(
            backend: backend,
            sleepNanoseconds: { ns in await sleepRecorder.record(ns) },
            stagingDirectory: stagingDir
        )

        do {
            _ = try await service.capture(delay: .fiveSeconds)
            XCTFail("Expected ScreenCaptureError.permissionDenied")
        } catch let error as ScreenCaptureError {
            XCTAssertEqual(error, .permissionDenied)
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("permission"))
            let suggestion = try XCTUnwrap(error.recoverySuggestion)
            XCTAssertTrue(suggestion.contains("System Settings"))
            XCTAssertTrue(suggestion.contains("Screen & System Audio Recording"))
        }

        let sleeps = await sleepRecorder.values()
        XCTAssertTrue(sleeps.isEmpty, "Denied permission pre-flight must fail immediately without waiting for timer")
        XCTAssertEqual(backend.captureCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir.path))
    }

    func testScreenCaptureCancellationDuringTimerAbortsWithoutCapturing() async throws {
        let fakeScreen = try makeSolidCGImage(width: 32, height: 32)
        let backend = MockScreenCaptureBackend(permission: true, result: .success(fakeScreen))
        let stagingDir = sandbox.temporaryURL.appendingPathComponent("CaptureCancelled", isDirectory: true)

        let service = ScreenCaptureService(
            backend: backend,
            sleepNanoseconds: { _ in throw CancellationError() },
            stagingDirectory: stagingDir
        )

        do {
            _ = try await service.capture(delay: .threeSeconds)
            XCTFail("Expected ScreenCaptureError.cancelled")
        } catch let error as ScreenCaptureError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(backend.captureCallCount, 0)
        XCTAssertFalse(service.isCapturing)
        XCTAssertNil(service.remainingCountdownSeconds)
    }

    // MARK: - 2. PinnedImageWindowController

    func testPinnedImageWindowControllerConfigOpacityCopyAndZeroRetainCycleClose() throws {
        let cg = try makeSolidCGImage(width: 160, height: 120, red: 230, green: 70, blue: 90)
        let image = NSImage(cgImage: cg, size: NSSize(width: 160, height: 120))
        let pasteboardName = NSPasteboard.Name("com.localconvert.tests.pinned.\(UUID().uuidString)")
        let testPasteboard = NSPasteboard(name: pasteboardName)
        defer { testPasteboard.releaseGlobally() }

        weak var weakController: PinnedImageWindowController?

        autoreleasepool {
            var controller: PinnedImageWindowController? = PinnedImageWindowController(
                image: image,
                title: "Pinned Reference",
                pasteboard: testPasteboard
            )
            weakController = controller
            let unwrapped = try! XCTUnwrap(controller)

            // Panel configuration checks
            XCTAssertEqual(unwrapped.panel.level, .floating)
            XCTAssertTrue(unwrapped.panel.isFloatingPanel)
            XCTAssertFalse(unwrapped.panel.hidesOnDeactivate)
            XCTAssertTrue(unwrapped.panel.styleMask.contains(.resizable))
            XCTAssertTrue(unwrapped.panel.styleMask.contains(.closable))
            XCTAssertTrue(unwrapped.panel.styleMask.contains(.titled))
            XCTAssertEqual(unwrapped.panel.title, "Pinned Reference")

            // Opacity clamping (0.25...1.0)
            unwrapped.setOpacity(0.1)
            XCTAssertEqual(unwrapped.viewModel.opacity, 0.25, accuracy: 0.0001)
            XCTAssertEqual(Double(unwrapped.panel.alphaValue), 0.25, accuracy: 0.0001)

            unwrapped.setOpacity(0.62)
            XCTAssertEqual(unwrapped.viewModel.opacity, 0.62, accuracy: 0.0001)
            XCTAssertEqual(Double(unwrapped.panel.alphaValue), 0.62, accuracy: 0.0001)

            unwrapped.setOpacity(1.8)
            XCTAssertEqual(unwrapped.viewModel.opacity, 1.0, accuracy: 0.0001)
            XCTAssertEqual(Double(unwrapped.panel.alphaValue), 1.0, accuracy: 0.0001)

            // Copy action (⌘C target)
            XCTAssertTrue(unwrapped.copyImageToPasteboard())
            let copiedImages = testPasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]
            XCTAssertEqual(copiedImages?.count, 1)

            // Close and release
            unwrapped.close()
            XCTAssertNil(unwrapped.panel.contentView)
            XCTAssertNil(unwrapped.panel.delegate)
            controller = nil
        }

        XCTAssertNil(weakController, "PinnedImageWindowController must deallocate cleanly without retain cycles on close")
    }

    // MARK: - 3. Auto QR / Barcode Detector

    func testPhotoBarcodeAnalyzerDetectsGeneratedQRCodeAndHandlesBlankImage() async throws {
        let expectedPayload = "https://localconvert.app/m13-qr-test"
        let qrCG = try makeQRCodeCGImage(payload: expectedPayload, pixelSize: 260)

        let detected = try await PhotoBarcodeAnalyzer.detectBarcodes(in: qrCG)
        XCTAssertTrue(
            detected.contains(where: { $0.payload == expectedPayload }),
            "Expected QR payload '\(expectedPayload)', got: \(detected.map(\.payload))"
        )

        let blank = try makeSolidCGImage(width: 80, height: 80, red: 255, green: 255, blue: 255)
        let noneDetected = try await PhotoBarcodeAnalyzer.detectBarcodes(in: blank)
        XCTAssertTrue(noneDetected.isEmpty)

        let tiny = try makeSolidCGImage(width: 1, height: 1, red: 0, green: 0, blue: 0)
        let tinyDetected = try await PhotoBarcodeAnalyzer.detectBarcodes(in: tiny)
        XCTAssertTrue(tinyDetected.isEmpty)
    }

    // MARK: - 4. Color Eyedropper Coordinator & Formatting

    func testPhotoEyedropperCoordinatorFormatsHexAndRGBAndCopiesToClipboardWithoutRealUI() async {
        let sampler = MockScreenColorSampler(
            nextColor: NSColor(srgbRed: 1.0, green: 128.0 / 255.0, blue: 0.0, alpha: 1.0)
        )
        var copiedStrings: [String] = []
        let coordinator = PhotoEyedropperCoordinator(
            sampler: sampler,
            copyTextHandler: { copiedStrings.append($0) }
        )

        let picked = await coordinator.pickColor()
        XCTAssertEqual(picked?.hex, "#FF8000")
        XCTAssertEqual(picked?.rgbString, "RGB(255, 128, 0)")
        XCTAssertEqual(coordinator.lastSampledColor, picked)
        XCTAssertEqual(copiedStrings, ["#FF8000 · RGB(255, 128, 0)"])

        // Cancelled sample (nil) must preserve previous color and not copy
        sampler.nextColor = nil
        let cancelled = await coordinator.pickColor()
        XCTAssertNil(cancelled)
        XCTAssertEqual(coordinator.lastSampledColor, picked)
        XCTAssertEqual(copiedStrings.count, 1)
    }

    // MARK: - 5. Dominant Color Palette Extractor

    func testPhotoColorPaletteExtractorReturnsTopFiveHexSwatchesInDominanceOrder() throws {
        // 100x100 image with 6 distinct sRGB bands: 40%, 25%, 15%, 10%, 7%, 3%
        let multiColorCG = try makeMultiBandCGImage(
            width: 100,
            height: 100,
            bands: [
                (40, 230, 57, 70),   // #E63946 (40%)
                (25, 29, 53, 87),    // #1D3557 (25%)
                (15, 69, 123, 157),  // #457B9D (15%)
                (10, 168, 218, 220), // #A8DADC (10%)
                (7, 241, 250, 238),  // #F1FAEE (7%)
                (3, 255, 183, 3)     // #FFB703 (3%) — excluded from top 5
            ]
        )

        let swatches = PhotoColorPaletteExtractor.extractDominantColors(
            from: multiColorCG,
            maxColors: 5,
            maxSampleDimension: 100
        )
        XCTAssertEqual(swatches.count, 5)
        XCTAssertEqual(
            swatches.map(\.hex),
            ["#E63946", "#1D3557", "#457B9D", "#A8DADC", "#F1FAEE"]
        )
        XCTAssertEqual(swatches[0].rgbString, "RGB(230, 57, 70)")
        XCTAssertEqual(swatches[0].percentage, 40.0, accuracy: 0.5)
        XCTAssertEqual(swatches[1].percentage, 25.0, accuracy: 0.5)

        // NSImage overload parity
        let nsImage = NSImage(cgImage: multiColorCG, size: NSSize(width: 100, height: 100))
        let nsSwatches = PhotoColorPaletteExtractor.extractDominantColors(
            from: nsImage,
            maxColors: 5,
            maxSampleDimension: 100
        )
        XCTAssertEqual(nsSwatches.map(\.hex), swatches.map(\.hex))

        // Fully transparent image returns empty safely
        let transparentCG = try makeSolidCGImage(width: 32, height: 32, red: 255, green: 0, blue: 0, alpha: 0)
        XCTAssertTrue(PhotoColorPaletteExtractor.extractDominantColors(from: transparentCG).isEmpty)
    }

    // MARK: - 6. PhotoViewerEditorView LC-019 Layout Sanity

    func testPhotoViewerEditorViewFitsWithinLC019WidthWithNewTools() throws {
        let photoURL = sandbox.documentsURL.appendingPathComponent("lc019_photo.png")
        try writePNG(try makeSolidCGImage(width: 64, height: 48), to: photoURL)

        let sampler = MockScreenColorSampler(nextColor: nil)
        let view = PhotoViewerEditorView(
            url: photoURL,
            onSendToConvertQueue: { _ in },
            onDismiss: {},
            colorSampler: sampler
        )

        let size = CGSize(width: 740, height: 500)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 820)
        let controller = NSHostingController(rootView: view)
        let constrained = controller.sizeThatFits(in: size)
        XCTAssertLessThanOrEqual(constrained.width, 820)
    }
}

// MARK: - Test Doubles (Zero TCC / Zero System UI)

private final class MockScreenCaptureBackend: ScreenCaptureBackend, @unchecked Sendable {
    private struct State {
        var permission: Bool
        var result: Result<CGImage, Error>
        var callCount: Int = 0
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(permission: Bool, result: Result<CGImage, Error>) {
        self.lock = OSAllocatedUnfairLock(initialState: State(permission: permission, result: result))
    }

    var captureCallCount: Int {
        lock.withLock { $0.callCount }
    }

    func hasPermission() -> Bool {
        lock.withLock { $0.permission }
    }

    func captureMainDisplayImage() async throws -> CGImage {
        let result = lock.withLock { state -> Result<CGImage, Error> in
            state.callCount += 1
            return state.result
        }
        return try result.get()
    }
}

private actor SleepRecorder {
    private var recorded: [UInt64] = []

    func record(_ ns: UInt64) {
        recorded.append(ns)
    }

    func values() -> [UInt64] {
        recorded
    }
}

@MainActor
private final class MockScreenColorSampler: ScreenColorSampling {
    var nextColor: NSColor?

    init(nextColor: NSColor?) {
        self.nextColor = nextColor
    }

    func sampleColor() async -> NSColor? {
        nextColor
    }
}

import XCTest
import SwiftUI
import AppKit
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import LocalConvert

@MainActor
final class Milestone14AOCRRecorderViewerTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = true
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M14A-OCRRecorderViewer-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        OutputReservationCoordinator.clearReservedOutputURLs()
    }

    override func tearDown() async throws {
        OutputReservationCoordinator.clearReservedOutputURLs()
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
        width: Int = 96,
        height: Int = 64,
        red: UInt8 = 30,
        green: UInt8 = 120,
        blue: UInt8 = 210
    ) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = red
            pixels[i + 1] = green
            pixels[i + 2] = blue
            pixels[i + 3] = 255
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
            throw NSError(domain: "Milestone14AOCRRecorderViewerTests", code: 1)
        }
        return cg
    }

    private func makeTextCGImage(text: String, width: Int = 640, height: Int = 180) throws -> CGImage {
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
            throw NSError(domain: "Milestone14AOCRRecorderViewerTests", code: 2)
        }

        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        attrStr.draw(at: NSPoint(x: 36, y: 64))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else {
            throw NSError(domain: "Milestone14AOCRRecorderViewerTests", code: 3)
        }
        return cg
    }

    private func writePNG(_ cgImage: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone14AOCRRecorderViewerTests", code: 4)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    @discardableResult
    private func measureLayout<V: View>(
        _ view: V,
        size: CGSize,
        appState: AppState,
        contextName: String
    ) -> (fittingSize: CGSize, constrainedSize: CGSize) {
        var publishCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            publishCount,
            0,
            "[\(contextName)] Layout pass must not trigger synchronous AppState.objectWillChange"
        )
        let fitting = hosting.fittingSize
        XCTAssertFalse(fitting.width.isNaN || fitting.height.isNaN, "[\(contextName)] fittingSize must be finite")

        let controller = NSHostingController(rootView: view)
        let constrained = controller.sizeThatFits(in: size)
        XCTAssertFalse(
            constrained.width.isNaN || constrained.height.isNaN,
            "[\(contextName)] constrained sizeThatFits must be finite"
        )
        return (fitting, constrained)
    }

    // MARK: - 1. ScreenTextOCRService (Zero-TCC Protocol Injection & Vision OCR)

    func testScreenTextOCRServiceHappyPathCopiesTrimmedTextToClipboard() async throws {
        let image = try makeSolidCGImage(width: 120, height: 80)
        let capture = MockScreenImageCapturer(permission: true, result: .success(image))
        let recognizer = MockTextRecognizer(result: .success("  Invoice #1042\nTotal: $99.00  \n"))
        let pasteboard = MockPasteboardWriter()

        let service = ScreenTextOCRService(
            captureBackend: capture,
            textRecognizer: recognizer,
            pasteboard: pasteboard
        )

        let recognized = try await service.captureScreenTextToClipboard()
        XCTAssertEqual(recognized, "Invoice #1042\nTotal: $99.00")
        XCTAssertEqual(pasteboard.writtenStrings, ["Invoice #1042\nTotal: $99.00"])
        XCTAssertEqual(service.lastRecognizedText, "Invoice #1042\nTotal: $99.00")
        XCTAssertNotNil(service.lastStatusMessage)
        XCTAssertNil(service.lastErrorMessage)
        XCTAssertFalse(service.isCapturing)
        XCTAssertEqual(capture.callCount, 1)
        XCTAssertEqual(recognizer.callCount, 1)
    }

    func testScreenTextOCRServiceWithRealVisionRecognizerOnSyntheticImage() async throws {
        let image = try makeTextCGImage(text: "LOCALCONVERT 2026")
        let capture = MockScreenImageCapturer(permission: true, result: .success(image))
        let pasteboard = MockPasteboardWriter()

        let service = ScreenTextOCRService(
            captureBackend: capture,
            textRecognizer: VisionScreenTextRecognizer(),
            pasteboard: pasteboard
        )

        let recognized = try await service.captureScreenTextToClipboard()
        XCTAssertTrue(
            recognized.localizedCaseInsensitiveContains("LOCALCONVERT"),
            "Expected Vision OCR to recognize synthetic text, got: \(recognized)"
        )
        XCTAssertEqual(pasteboard.writtenStrings, [recognized])
        XCTAssertFalse(service.isCapturing)
    }

    func testScreenTextOCRServiceHandlesEmptyOCRTextWithoutMutatingPasteboard() async throws {
        let image = try makeSolidCGImage(width: 100, height: 100, red: 255, green: 255, blue: 255)
        let capture = MockScreenImageCapturer(permission: true, result: .success(image))
        let recognizer = MockTextRecognizer(result: .success("   \n\t  "))
        let pasteboard = MockPasteboardWriter()

        let service = ScreenTextOCRService(
            captureBackend: capture,
            textRecognizer: recognizer,
            pasteboard: pasteboard
        )

        do {
            _ = try await service.captureScreenTextToClipboard()
            XCTFail("Expected ScreenTextOCRError.noTextRecognized")
        } catch let error as ScreenTextOCRError {
            XCTAssertEqual(error, .noTextRecognized)
        }

        XCTAssertTrue(pasteboard.writtenStrings.isEmpty)
        XCTAssertNil(service.lastRecognizedText)
        XCTAssertNotNil(service.lastErrorMessage)
        XCTAssertFalse(service.isCapturing)
    }

    func testScreenTextOCRServiceHandlesCancelledAndDeniedCaptureGracefully() async throws {
        let recognizer = MockTextRecognizer(result: .success("Should not run"))
        let pasteboard = MockPasteboardWriter()

        // Nil return (user cancelled selection)
        let cancelledCapture = MockScreenImageCapturer(permission: true, result: .success(nil))
        let cancelService = ScreenTextOCRService(
            captureBackend: cancelledCapture,
            textRecognizer: recognizer,
            pasteboard: pasteboard
        )

        do {
            _ = try await cancelService.captureScreenTextToClipboard()
            XCTFail("Expected ScreenTextOCRError.cancelled")
        } catch let error as ScreenTextOCRError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(recognizer.callCount, 0)
        XCTAssertTrue(pasteboard.writtenStrings.isEmpty)
        XCTAssertFalse(cancelService.isCapturing)

        // ScreenCaptureError.cancelled mapping
        let scCancelledCapture = MockScreenImageCapturer(permission: true, result: .failure(ScreenCaptureError.cancelled))
        let scCancelService = ScreenTextOCRService(
            captureBackend: scCancelledCapture,
            textRecognizer: recognizer,
            pasteboard: pasteboard
        )
        do {
            _ = try await scCancelService.captureScreenTextToClipboard()
            XCTFail("Expected ScreenTextOCRError.cancelled")
        } catch let error as ScreenTextOCRError {
            XCTAssertEqual(error, .cancelled)
        }

        // Denied permission pre-flight
        let deniedCapture = MockScreenImageCapturer(permission: false, result: .success(nil))
        let deniedService = ScreenTextOCRService(
            captureBackend: deniedCapture,
            textRecognizer: recognizer,
            pasteboard: pasteboard
        )
        do {
            _ = try await deniedService.captureScreenTextToClipboard()
            XCTFail("Expected ScreenTextOCRError.permissionDenied")
        } catch let error as ScreenTextOCRError {
            XCTAssertEqual(error, .permissionDenied)
            XCTAssertNotNil(error.recoverySuggestion)
        }
        XCTAssertEqual(deniedCapture.callCount, 0)
        XCTAssertFalse(deniedService.isCapturing)
    }

    func testScreenTextOCRServicePropagatesOCRErrorSafely() async throws {
        let image = try makeSolidCGImage()
        let capture = MockScreenImageCapturer(permission: true, result: .success(image))
        let failingRecognizer = MockTextRecognizer(
            result: .failure(NSError(domain: "OCRTest", code: 42, userInfo: [NSLocalizedDescriptionKey: "Vision engine unavailable"]))
        )
        let pasteboard = MockPasteboardWriter()

        let service = ScreenTextOCRService(
            captureBackend: capture,
            textRecognizer: failingRecognizer,
            pasteboard: pasteboard
        )

        do {
            _ = try await service.captureScreenTextToClipboard()
            XCTFail("Expected ScreenTextOCRError.ocrFailed")
        } catch let error as ScreenTextOCRError {
            if case .ocrFailed(let message) = error {
                XCTAssertTrue(message.contains("Vision engine unavailable"))
            } else {
                XCTFail("Unexpected ScreenTextOCRError case: \(error)")
            }
        }
        XCTAssertTrue(pasteboard.writtenStrings.isEmpty)
        XCTAssertFalse(service.isCapturing)
    }

    // MARK: - 2. QuickVoiceRecorderService (Zero-TCC Mock Backend & Atomic .m4a Commit)

    func testQuickVoiceRecorderServiceStartStopCommitsAtomicallyAndQueuesToConvertTab() throws {
        let appState = makeIsolatedAppState()
        appState.selectedTab = .settings
        let recordingsDir = sandbox.documentsURL.appendingPathComponent("VoiceMemos", isDirectory: true)
        let backend = MockVoiceRecordingBackend()
        let service = QuickVoiceRecorderService(backend: backend)

        try service.startRecording(toDirectory: recordingsDir)
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(backend.startCount, 1)
        let stagedTempURL = try XCTUnwrap(backend.lastTempURL)
        XCTAssertTrue(stagedTempURL.lastPathComponent.hasPrefix(".LocalConvert-voicememo-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedTempURL.path))

        let finalURL = try service.stopRecordingAndQueue(into: appState)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(finalURL.pathExtension.lowercased(), "m4a")
        XCTAssertEqual(finalURL.deletingLastPathComponent().standardizedFileURL, recordingsDir.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedTempURL.path), "Staged hidden temp file must be moved/cleaned up")
        XCTAssertEqual(service.lastRecordedFileURL, finalURL)
        XCTAssertNil(service.lastErrorMessage)

        XCTAssertEqual(appState.selectedTab, .convert)
        XCTAssertTrue(appState.droppedFiles.contains(where: { $0.url.standardizedFileURL == finalURL.standardizedFileURL }))

        // Second recording in same directory must reserve a unique non-colliding URL
        try service.startRecording(toDirectory: recordingsDir)
        let secondURL = try service.stopRecordingAndQueue(into: appState)
        XCTAssertNotEqual(finalURL.standardizedFileURL, secondURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testQuickVoiceRecorderServiceCancelCleansUpPartialTempFile() throws {
        let recordingsDir = sandbox.documentsURL.appendingPathComponent("CancelMemos", isDirectory: true)
        let backend = MockVoiceRecordingBackend()
        let service = QuickVoiceRecorderService(backend: backend)

        try service.startRecording(toDirectory: recordingsDir)
        let stagedTempURL = try XCTUnwrap(backend.lastTempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedTempURL.path))

        service.cancelRecording()
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.elapsedSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedTempURL.path))

        let remainingFiles = try FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(remainingFiles.isEmpty, "Cancelled recording must leave no output or temp files behind")
    }

    func testQuickVoiceRecorderServiceDoubleStartNotRecordingPermissionAndEmptyGuards() throws {
        let recordingsDir = sandbox.documentsURL.appendingPathComponent("GuardMemos", isDirectory: true)

        // Stop while not recording
        let idleService = QuickVoiceRecorderService(backend: MockVoiceRecordingBackend())
        XCTAssertThrowsError(try idleService.stopRecordingAndQueue()) { error in
            XCTAssertEqual(error as? VoiceRecordingError, .notRecording)
        }

        // Permission denied
        let deniedBackend = MockVoiceRecordingBackend(permissionGranted: false)
        let deniedService = QuickVoiceRecorderService(backend: deniedBackend)
        XCTAssertThrowsError(try deniedService.startRecording(toDirectory: recordingsDir)) { error in
            XCTAssertEqual(error as? VoiceRecordingError, .permissionDenied)
        }
        XCTAssertFalse(deniedService.isRecording)
        XCTAssertEqual(deniedBackend.startCount, 0)

        // Double start guard
        let activeBackend = MockVoiceRecordingBackend()
        let activeService = QuickVoiceRecorderService(backend: activeBackend)
        try activeService.startRecording(toDirectory: recordingsDir)
        XCTAssertThrowsError(try activeService.startRecording(toDirectory: recordingsDir)) { error in
            XCTAssertEqual(error as? VoiceRecordingError, .alreadyRecording)
        }
        XCTAssertTrue(activeService.isRecording)
        XCTAssertEqual(activeBackend.startCount, 1)
        activeService.cancelRecording()

        // Empty recording on stop cleans up empty temp file
        let emptyBackend = MockVoiceRecordingBackend(writePayloadBytes: false)
        let emptyService = QuickVoiceRecorderService(backend: emptyBackend)
        try emptyService.startRecording(toDirectory: recordingsDir)
        let emptyTempURL = try XCTUnwrap(emptyBackend.lastTempURL)
        XCTAssertThrowsError(try emptyService.stopRecordingAndQueue()) { error in
            XCTAssertEqual(error as? VoiceRecordingError, .emptyRecording)
        }
        XCTAssertFalse(emptyService.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyTempURL.path))
    }

    // MARK: - 3. PhotoViewerEditorView Hold-to-Compare (\) & Undo Safety

    func testPhotoViewerHoldComparePolicyAndNonMutatingOriginalPreview() throws {
        // Key matching
        XCTAssertTrue(
            PhotoViewerHoldComparePolicy.isBackslashEvent(
                keyCode: PhotoViewerHoldComparePolicy.backslashKeyCode,
                characters: "\\",
                charactersIgnoringModifiers: "\\",
                modifierFlags: []
            )
        )
        XCTAssertFalse(
            PhotoViewerHoldComparePolicy.isBackslashEvent(
                keyCode: PhotoViewerHoldComparePolicy.backslashKeyCode,
                characters: "|",
                charactersIgnoringModifiers: "\\",
                modifierFlags: [.shift]
            )
        )
        XCTAssertFalse(
            PhotoViewerHoldComparePolicy.isBackslashEvent(
                keyCode: PhotoViewerHoldComparePolicy.backslashKeyCode,
                characters: "\\",
                charactersIgnoringModifiers: "\\",
                modifierFlags: [.command]
            )
        )
        XCTAssertTrue(
            PhotoViewerHoldComparePolicy.isBackslashEvent(
                keyCode: 50,
                characters: "\\",
                charactersIgnoringModifiers: "<",
                modifierFlags: [.option]
            ),
            "International keyboard Option-produced backslash should be accepted"
        )

        // Guard conditions
        XCTAssertTrue(
            PhotoViewerHoldComparePolicy.canActivateHoldCompare(
                isSameWindow: true,
                isKeyWindow: true,
                hasImage: true,
                isEditingText: false,
                hasActiveDragAnnotation: false,
                isConfirmationPresented: false,
                isCommandPalettePresented: false,
                isFirstResponderTextInput: false
            )
        )
        XCTAssertFalse(
            PhotoViewerHoldComparePolicy.canActivateHoldCompare(
                isSameWindow: true,
                isKeyWindow: true,
                hasImage: true,
                isEditingText: true,
                hasActiveDragAnnotation: false,
                isConfirmationPresented: false,
                isCommandPalettePresented: false,
                isFirstResponderTextInput: false
            )
        )
        XCTAssertFalse(
            PhotoViewerHoldComparePolicy.canActivateHoldCompare(
                isSameWindow: true,
                isKeyWindow: true,
                hasImage: true,
                isEditingText: false,
                hasActiveDragAnnotation: true,
                isConfirmationPresented: false,
                isCommandPalettePresented: false,
                isFirstResponderTextInput: false
            )
        )
        XCTAssertFalse(
            PhotoViewerHoldComparePolicy.canActivateHoldCompare(
                isSameWindow: true,
                isKeyWindow: true,
                hasImage: true,
                isEditingText: false,
                hasActiveDragAnnotation: false,
                isConfirmationPresented: true,
                isCommandPalettePresented: false,
                isFirstResponderTextInput: false
            )
        )
        XCTAssertFalse(
            PhotoViewerHoldComparePolicy.canActivateHoldCompare(
                isSameWindow: true,
                isKeyWindow: true,
                hasImage: true,
                isEditingText: false,
                hasActiveDragAnnotation: false,
                isConfirmationPresented: false,
                isCommandPalettePresented: true,
                isFirstResponderTextInput: false
            )
        )
        XCTAssertFalse(
            PhotoViewerHoldComparePolicy.canActivateHoldCompare(
                isSameWindow: false,
                isKeyWindow: true,
                hasImage: true,
                isEditingText: false,
                hasActiveDragAnnotation: false,
                isConfirmationPresented: false,
                isCommandPalettePresented: false,
                isFirstResponderTextInput: false
            )
        )

        // Verify QuickPhotoEditorModel preserves originalPreviewImage separately from edits & Undo stack
        let testCG = try makeSolidCGImage(width: 80, height: 60, red: 60, green: 140, blue: 220)
        let model = QuickPhotoEditorModel(
            testImage: testCG,
            url: sandbox.documentsURL.appendingPathComponent("hold_compare_test.png")
        )
        XCTAssertNotNil(model.originalPreviewImage)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.undoStack.count, 0)

        model.applyEdit { $0.adjustments.exposure = 1.25 }
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.undoStack.count, 1)
        XCTAssertEqual(model.redoStack.count, 0)
        XCTAssertNotNil(model.originalPreviewImage)
        XCTAssertEqual(model.editState.adjustments.exposure, 1.25, accuracy: 0.0001)
    }

    // MARK: - 4. Photo & Video Viewer LC-019 Layout Fit (820x580 / 740x500)

    func testPhotoAndVideoViewerEditorsFitWithinLC019BoundsWithoutReentrantPublish() async throws {
        let appState = makeIsolatedAppState()
        let photoURL = sandbox.documentsURL.appendingPathComponent("viewer_layout_photo.png")
        try writePNG(try makeSolidCGImage(width: 96, height: 72), to: photoURL)

        let videoURL = sandbox.documentsURL.appendingPathComponent("viewer_layout_clip.mp4")
        _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: videoURL)

        for size in [CGSize(width: 740, height: 500), CGSize(width: 820, height: 580)] {
            let photoMeasured = measureLayout(
                PhotoViewerEditorView(url: photoURL, onSendToConvertQueue: { _ in }, onDismiss: {}),
                size: size,
                appState: appState,
                contextName: "PhotoViewerEditorView.\(Int(size.width))x\(Int(size.height))"
            )
            XCTAssertLessThanOrEqual(photoMeasured.fittingSize.width, 820)
            XCTAssertLessThanOrEqual(photoMeasured.constrainedSize.width, 820)

            let videoMeasured = measureLayout(
                VideoViewerEditorView(url: videoURL, onSendToConvertQueue: { _ in }, onDismiss: {}),
                size: size,
                appState: appState,
                contextName: "VideoViewerEditorView.\(Int(size.width))x\(Int(size.height))"
            )
            XCTAssertLessThanOrEqual(videoMeasured.fittingSize.width, 820)
            XCTAssertLessThanOrEqual(videoMeasured.constrainedSize.width, 820)
        }
    }
}

// MARK: - Zero-TCC Test Doubles

private final class MockScreenImageCapturer: ScreenImageCapturing, @unchecked Sendable {
    private struct State {
        var permission: Bool
        var result: Result<CGImage?, Error>
        var callCount: Int = 0
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(permission: Bool, result: Result<CGImage?, Error>) {
        self.lock = OSAllocatedUnfairLock(initialState: State(permission: permission, result: result))
    }

    var callCount: Int {
        lock.withLock { $0.callCount }
    }

    func hasPermission() -> Bool {
        lock.withLock { $0.permission }
    }

    func captureImage() async throws -> CGImage? {
        let result = lock.withLock { state -> Result<CGImage?, Error> in
            state.callCount += 1
            return state.result
        }
        return try result.get()
    }
}

private final class MockTextRecognizer: TextRecognizing, @unchecked Sendable {
    private struct State {
        var result: Result<String, Error>
        var callCount: Int = 0
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(result: Result<String, Error>) {
        self.lock = OSAllocatedUnfairLock(initialState: State(result: result))
    }

    var callCount: Int {
        lock.withLock { $0.callCount }
    }

    func recognizeText(in cgImage: CGImage) async throws -> String {
        let result = lock.withLock { state -> Result<String, Error> in
            state.callCount += 1
            return state.result
        }
        return try result.get()
    }
}

@MainActor
private final class MockPasteboardWriter: PasteboardWriting {
    private(set) var writtenStrings: [String] = []

    func writeString(_ string: String) {
        writtenStrings.append(string)
    }
}

@MainActor
private final class MockVoiceRecordingBackend: VoiceRecordingBackend {
    var permissionGranted: Bool
    var writePayloadBytes: Bool
    private(set) var startCount: Int = 0
    private(set) var stopCount: Int = 0
    private(set) var cancelCount: Int = 0
    private(set) var lastTempURL: URL?

    init(permissionGranted: Bool = true, writePayloadBytes: Bool = true) {
        self.permissionGranted = permissionGranted
        self.writePayloadBytes = writePayloadBytes
    }

    func requestOrCheckPermission() -> Bool {
        permissionGranted
    }

    func startRecording(to tempURL: URL) throws {
        startCount += 1
        lastTempURL = tempURL
        if writePayloadBytes {
            // Minimal M4A/ISO-BMFF ftyp + mdat payload so FileDetector & non-empty checks succeed.
            var bytes: [UInt8] = [
                0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
                0x4D, 0x34, 0x41, 0x20, 0x00, 0x00, 0x00, 0x00,
                0x4D, 0x34, 0x41, 0x20, 0x6D, 0x70, 0x34, 0x32,
                0x00, 0x00, 0x00, 0x10, 0x6D, 0x64, 0x61, 0x74
            ]
            bytes.append(contentsOf: [UInt8](repeating: 0x11, count: 8))
            try Data(bytes).write(to: tempURL, options: [.atomic])
        } else {
            try Data().write(to: tempURL, options: [.atomic])
        }
    }

    func stopRecording() throws {
        stopCount += 1
    }

    func cancelRecording() {
        cancelCount += 1
    }
}

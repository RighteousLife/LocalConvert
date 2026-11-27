import Foundation
import AppKit
import CoreGraphics
import Vision
import os.log

// MARK: - Screen Text OCR Errors

enum ScreenTextOCRError: Error, LocalizedError, Equatable, Sendable {
    case captureAlreadyInProgress
    case permissionDenied
    case cancelled
    case noTextRecognized
    case captureFailed(String)
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureAlreadyInProgress:
            return String(localized: "Screen text capture is already in progress.")
        case .permissionDenied:
            return String(localized: "Screen Recording permission is required to capture screen text.")
        case .cancelled:
            return String(localized: "Screen text capture was cancelled.")
        case .noTextRecognized:
            return String(localized: "No recognizable text was found in the captured screen.")
        case .captureFailed(let message):
            return String(localized: "Screen text capture failed: \(message)")
        case .ocrFailed(let message):
            return String(localized: "Text recognition failed: \(message)")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Open System Settings > Privacy & Security > Screen & System Audio Recording, allow LocalConvert, then try again.")
        case .captureAlreadyInProgress, .cancelled, .noTextRecognized, .captureFailed, .ocrFailed:
            return nil
        }
    }
}

// MARK: - Protocol-Injectable Backends (Zero-TCC Testability)

protocol ScreenImageCapturing: Sendable {
    func hasPermission() -> Bool
    func captureImage() async throws -> CGImage?
}

struct ScreenCaptureBackendAdapter: ScreenImageCapturing, Sendable {
    private let backend: any ScreenCaptureBackend

    init(backend: any ScreenCaptureBackend = SystemScreenCaptureBackend()) {
        self.backend = backend
    }

    func hasPermission() -> Bool {
        backend.hasPermission()
    }

    func captureImage() async throws -> CGImage? {
        try await backend.captureMainDisplayImage()
    }
}

protocol TextRecognizing: Sendable {
    func recognizeText(in cgImage: CGImage) async throws -> String
}

struct VisionScreenTextRecognizer: TextRecognizing, Sendable {
    init() {}

    func recognizeText(in cgImage: CGImage) async throws -> String {
        guard cgImage.width >= 2, cgImage.height >= 2 else {
            return ""
        }

        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()

            let observations = request.results ?? []
            let lines = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return lines.joined(separator: "\n")
        }.value
    }
}

@MainActor
protocol PasteboardWriting: AnyObject {
    func writeString(_ string: String)
}

typealias ClipboardWriting = PasteboardWriting

@MainActor
final class SystemPasteboardWriter: PasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func writeString(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

// MARK: - Screen Text OCR Service (TextSniper-Style 1-Click Capture -> Clipboard)

@MainActor
final class ScreenTextOCRService: ObservableObject {

    static let shared = ScreenTextOCRService()

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "ScreenTextOCRService")

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var lastRecognizedText: String?
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var lastErrorMessage: String?

    private let captureBackend: any ScreenImageCapturing
    private let textRecognizer: any TextRecognizing
    private let pasteboard: any PasteboardWriting

    init(
        captureBackend: any ScreenImageCapturing = ScreenCaptureBackendAdapter(),
        textRecognizer: any TextRecognizing = VisionScreenTextRecognizer(),
        pasteboard: any PasteboardWriting = SystemPasteboardWriter()
    ) {
        self.captureBackend = captureBackend
        self.textRecognizer = textRecognizer
        self.pasteboard = pasteboard
    }

    convenience init(
        screenCaptureBackend: any ScreenCaptureBackend,
        textRecognizer: any TextRecognizing = VisionScreenTextRecognizer(),
        pasteboard: any PasteboardWriting = SystemPasteboardWriter()
    ) {
        self.init(
            captureBackend: ScreenCaptureBackendAdapter(backend: screenCaptureBackend),
            textRecognizer: textRecognizer,
            pasteboard: pasteboard
        )
    }

    @discardableResult
    func captureScreenTextToClipboard() async throws -> String {
        guard !isCapturing else {
            let error = ScreenTextOCRError.captureAlreadyInProgress
            lastErrorMessage = error.localizedDescription
            throw error
        }

        guard captureBackend.hasPermission() else {
            let error = ScreenTextOCRError.permissionDenied
            lastStatusMessage = nil
            lastErrorMessage = error.localizedDescription
            throw error
        }

        isCapturing = true
        lastStatusMessage = nil
        lastErrorMessage = nil
        defer { isCapturing = false }

        let capturedCGImage: CGImage?
        do {
            try Task.checkCancellation()
            capturedCGImage = try await captureBackend.captureImage()
        } catch is CancellationError {
            let error = ScreenTextOCRError.cancelled
            lastErrorMessage = error.localizedDescription
            throw error
        } catch let captureError as ScreenCaptureError {
            let mapped: ScreenTextOCRError = {
                switch captureError {
                case .permissionDenied:
                    return .permissionDenied
                case .cancelled:
                    return .cancelled
                default:
                    return .captureFailed(captureError.localizedDescription)
                }
            }()
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        } catch let ocrError as ScreenTextOCRError {
            lastErrorMessage = ocrError.localizedDescription
            throw ocrError
        } catch {
            let mapped = ScreenTextOCRError.captureFailed(error.localizedDescription)
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        }

        guard let cgImage = capturedCGImage else {
            let error = ScreenTextOCRError.cancelled
            lastErrorMessage = error.localizedDescription
            throw error
        }

        let recognizedRaw: String
        do {
            try Task.checkCancellation()
            recognizedRaw = try await textRecognizer.recognizeText(in: cgImage)
        } catch is CancellationError {
            let error = ScreenTextOCRError.cancelled
            lastErrorMessage = error.localizedDescription
            throw error
        } catch let ocrError as ScreenTextOCRError {
            lastErrorMessage = ocrError.localizedDescription
            throw ocrError
        } catch {
            let mapped = ScreenTextOCRError.ocrFailed(error.localizedDescription)
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        }

        let recognized = recognizedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognized.isEmpty else {
            let error = ScreenTextOCRError.noTextRecognized
            lastErrorMessage = error.localizedDescription
            throw error
        }

        pasteboard.writeString(recognized)
        lastRecognizedText = recognized
        let status = String(localized: "Copied \(recognized.count) characters to clipboard.")
        lastStatusMessage = status
        lastErrorMessage = nil
        Self.logger.info("Recognized and copied \(recognized.count, privacy: .public) characters via screen OCR")
        return recognized
    }

    func triggerCaptureFromUI(appState: AppState? = nil) {
        guard !isCapturing else { return }
        Task { @MainActor [weak self, weak appState] in
            guard let self else { return }
            do {
                let text = try await self.captureScreenTextToClipboard()
                let feedback = String(localized: "Copied \(text.count) characters to clipboard.")
                appState?.dropFeedbackText = feedback
                AccessibilityAnnouncer.announce(feedback)
            } catch ScreenTextOCRError.cancelled {
                // User cancelled capture; do not present a modal alert.
            } catch {
                appState?.showError(
                    title: String(localized: "Screen Text OCR Failed"),
                    message: error.localizedDescription,
                    suggestion: (error as? LocalizedError)?.recoverySuggestion
                )
            }
        }
    }
}

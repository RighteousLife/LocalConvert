import Foundation
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import os.log

// MARK: - Screen Capture Delay

enum ScreenCaptureDelay: Int, CaseIterable, Identifiable, Sendable {
    case instant = 0
    case threeSeconds = 3
    case fiveSeconds = 5

    var id: Int { rawValue }

    var nanoseconds: UInt64 {
        UInt64(max(0, rawValue)) * 1_000_000_000
    }

    var displayTitle: String {
        switch self {
        case .instant:
            return String(localized: "Instant")
        case .threeSeconds:
            return String(localized: "3s Timer")
        case .fiveSeconds:
            return String(localized: "5s Timer")
        }
    }

    var menuItemTitle: String {
        switch self {
        case .instant:
            return String(localized: "Capture Screen (Instant)")
        case .threeSeconds:
            return String(localized: "Capture Screen (3s Timer)")
        case .fiveSeconds:
            return String(localized: "Capture Screen (5s Timer)")
        }
    }
}

// MARK: - Screen Capture Error

enum ScreenCaptureError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied
    case noDisplayAvailable
    case encodingFailed
    case writeFailed(String)
    case captureFailed(String)
    case cancelled
    case captureAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Screen Recording permission is required to capture screenshots.")
        case .noDisplayAvailable:
            return String(localized: "No active display is available to capture.")
        case .encodingFailed:
            return String(localized: "Failed to encode the captured screenshot as PNG.")
        case .writeFailed(let message):
            return String(localized: "Failed to save the captured screenshot: \(message)")
        case .captureFailed(let message):
            return String(localized: "Screen capture failed: \(message)")
        case .cancelled:
            return String(localized: "Screen capture was cancelled.")
        case .captureAlreadyInProgress:
            return String(localized: "A screen capture is already in progress.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Open System Settings > Privacy & Security > Screen & System Audio Recording, allow LocalConvert, then try capturing again.")
        case .noDisplayAvailable:
            return String(localized: "Connect or wake a display and try capturing again.")
        case .encodingFailed, .writeFailed, .captureFailed, .cancelled, .captureAlreadyInProgress:
            return nil
        }
    }
}

// MARK: - Screen Capture Backend Protocol

protocol ScreenCaptureBackend: Sendable {
    func hasPermission() -> Bool
    func captureMainDisplayImage() async throws -> CGImage
}

struct SystemScreenCaptureBackend: ScreenCaptureBackend, Sendable {
    init() {}

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func captureMainDisplayImage() async throws -> CGImage {
        guard hasPermission() else {
            throw ScreenCaptureError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch let scError as SCStreamError {
            if scError.code == .userDeclined || scError.code == .missingEntitlements {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.captureFailed(scError.localizedDescription)
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == SCStreamErrorDomain && nsErr.code == SCStreamError.userDeclined.rawValue {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }

        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw ScreenCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.pixelWidth > 0, mode.pixelHeight > 0 {
            config.width = mode.pixelWidth
            config.height = mode.pixelHeight
        } else {
            config.width = max(1, display.width * 2)
            config.height = max(1, display.height * 2)
        }
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch let scError as SCStreamError {
            if scError.code == .userDeclined || scError.code == .missingEntitlements {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.captureFailed(scError.localizedDescription)
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == SCStreamErrorDomain && nsErr.code == SCStreamError.userDeclined.rawValue {
                throw ScreenCaptureError.permissionDenied
            }
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
    }
}

// MARK: - Screen Capture Service

@MainActor
final class ScreenCaptureService: ObservableObject {

    static let shared = ScreenCaptureService()

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "ScreenCaptureService")

    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var remainingCountdownSeconds: Int? = nil
    @Published private(set) var lastCapturedURL: URL? = nil

    static var defaultStagingDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-ScreenCapture", isDirectory: true)
    }

    private let backend: any ScreenCaptureBackend
    private let sleepNanoseconds: @Sendable (UInt64) async throws -> Void
    private let stagingDirectory: URL

    init(
        backend: any ScreenCaptureBackend = SystemScreenCaptureBackend(),
        sleepNanoseconds: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        stagingDirectory: URL? = nil
    ) {
        self.backend = backend
        self.sleepNanoseconds = sleepNanoseconds
        self.stagingDirectory = (stagingDirectory ?? Self.defaultStagingDirectory).standardizedFileURL
    }

    func capture(delay: ScreenCaptureDelay = .instant) async throws -> URL {
        guard !isCapturing else {
            throw ScreenCaptureError.captureAlreadyInProgress
        }

        // Pre-flight permission before waiting on any countdown timer.
        guard backend.hasPermission() else {
            throw ScreenCaptureError.permissionDenied
        }

        isCapturing = true
        remainingCountdownSeconds = nil
        defer {
            isCapturing = false
            remainingCountdownSeconds = nil
        }

        if delay.rawValue > 0 {
            for remaining in stride(from: delay.rawValue, through: 1, by: -1) {
                if Task.isCancelled {
                    throw ScreenCaptureError.cancelled
                }
                remainingCountdownSeconds = remaining
                do {
                    try await sleepNanoseconds(1_000_000_000)
                } catch is CancellationError {
                    throw ScreenCaptureError.cancelled
                } catch {
                    throw ScreenCaptureError.cancelled
                }
            }
            if Task.isCancelled {
                throw ScreenCaptureError.cancelled
            }
            remainingCountdownSeconds = nil
        }

        let capturedCGImage: CGImage
        do {
            capturedCGImage = try await backend.captureMainDisplayImage()
        } catch is CancellationError {
            throw ScreenCaptureError.cancelled
        }

        let targetDirectory = stagingDirectory
        let committedURL = try await Task.detached(priority: .userInitiated) {
            try Self.encodeAndWriteAtomicPNG(cgImage: capturedCGImage, in: targetDirectory)
        }.value

        lastCapturedURL = committedURL
        Self.logger.info("Captured screenshot to \(committedURL.lastPathComponent, privacy: .public)")
        return committedURL
    }

    @discardableResult
    func captureToMediaViewer(delay: ScreenCaptureDelay = .instant, appState: AppState) async throws -> URL {
        let capturedURL = try await capture(delay: delay)
        appState.openInMediaViewer(capturedURL)
        NSApp?.activate(ignoringOtherApps: true)
        return capturedURL
    }

    static func openScreenRecordingPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Off-MainActor Atomic PNG Encoding & Staging

    private nonisolated static func encodeAndWriteAtomicPNG(cgImage: CGImage, in directory: URL) throws -> URL {
        let pngData = try encodePNGData(from: cgImage)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ScreenCaptureError.writeFailed(error.localizedDescription)
        }

        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let stamp = timestampToken()
        let uniqueSuffix = String(UUID().uuidString.prefix(8))
        let finalURL: URL
        do {
            finalURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: resolvedDirectory,
                baseName: "ScreenCapture-\(stamp)-\(uniqueSuffix)",
                extension: "png",
                policy: .createUnique
            )
        } catch {
            throw ScreenCaptureError.writeFailed(error.localizedDescription)
        }
        defer { OutputReservationCoordinator.releaseReservedOutputURL(finalURL) }

        let stageURL = resolvedDirectory.appendingPathComponent(
            ".LocalConvert-capture-\(UUID().uuidString).png",
            isDirectory: false
        )
        defer { try? fm.removeItem(at: stageURL) }

        do {
            try pngData.write(to: stageURL, options: [.atomic])
            let committed = try OutputReservationCoordinator.moveOrReplaceTempFile(
                stageURL,
                to: finalURL,
                policy: .createUnique
            )
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: committed.path)
            return committed.standardizedFileURL.resolvingSymlinksInPath()
        } catch {
            throw ScreenCaptureError.writeFailed(error.localizedDescription)
        }
    }

    private nonisolated static func encodePNGData(from cgImage: CGImage) throws -> Data {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenCaptureError.encodingFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest), mutableData.length > 0 else {
            throw ScreenCaptureError.encodingFailed
        }
        return mutableData as Data
    }

    private nonisolated static func timestampToken() -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1,
            comps.hour ?? 0,
            comps.minute ?? 0,
            comps.second ?? 0
        )
    }
}

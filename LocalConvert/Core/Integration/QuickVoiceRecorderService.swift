import Foundation
import AppKit
@preconcurrency import AVFoundation
import os.log

// MARK: - Voice Recording Errors

enum VoiceRecordingError: Error, LocalizedError, Equatable, Sendable {
    case alreadyRecording
    case notRecording
    case permissionDenied
    case invalidDestinationDirectory(String)
    case failedToStart(String)
    case failedToStop(String)
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return String(localized: "A voice recording is already in progress.")
        case .notRecording:
            return String(localized: "No active voice recording to stop.")
        case .permissionDenied:
            return String(localized: "Microphone permission is required to record a voice memo.")
        case .invalidDestinationDirectory(let message):
            return String(localized: "Cannot save voice memo to destination folder: \(message)")
        case .failedToStart(let message):
            return String(localized: "Failed to start voice recording: \(message)")
        case .failedToStop(let message):
            return String(localized: "Failed to finish voice recording: \(message)")
        case .emptyRecording:
            return String(localized: "Recorded voice memo was empty.")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Open System Settings > Privacy & Security > Microphone, allow LocalConvert, then try recording again.")
        case .alreadyRecording, .notRecording, .invalidDestinationDirectory, .failedToStart, .failedToStop, .emptyRecording:
            return nil
        }
    }
}

// MARK: - Voice Recording Backend Protocol (Zero-TCC Testability)

@MainActor
protocol VoiceRecordingBackend: AnyObject {
    func requestOrCheckPermission() -> Bool
    func requestOrCheckPermissionAsync() async -> Bool
    func startRecording(to tempURL: URL) throws
    func stopRecording() throws
    func cancelRecording()
}

extension VoiceRecordingBackend {
    func requestOrCheckPermissionAsync() async -> Bool {
        requestOrCheckPermission()
    }
}

@MainActor
final class SystemVoiceRecordingBackend: VoiceRecordingBackend {
    private var recorder: AVAudioRecorder?
    private let authorizationStatusProvider: @Sendable () -> AVAuthorizationStatus
    private let requestAccessHandler: @Sendable () async -> Bool

    init(
        authorizationStatusProvider: @escaping @Sendable () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        requestAccessHandler: @escaping @Sendable () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.authorizationStatusProvider = authorizationStatusProvider
        self.requestAccessHandler = requestAccessHandler
    }

    func requestOrCheckPermission() -> Bool {
        authorizationStatusProvider() == .authorized
    }

    func requestOrCheckPermissionAsync() async -> Bool {
        switch authorizationStatusProvider() {
        case .authorized:
            return true
        case .notDetermined:
            return await requestAccessHandler()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startRecording(to tempURL: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000
        ]

        let audioRecorder: AVAudioRecorder
        do {
            audioRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
        } catch {
            throw VoiceRecordingError.failedToStart(error.localizedDescription)
        }

        guard audioRecorder.prepareToRecord(), audioRecorder.record() else {
            throw VoiceRecordingError.failedToStart(String(localized: "Unable to initialize microphone audio input."))
        }

        recorder = audioRecorder
    }

    func stopRecording() throws {
        guard let audioRecorder = recorder else {
            throw VoiceRecordingError.notRecording
        }
        audioRecorder.stop()
        recorder = nil
    }

    func cancelRecording() {
        if let audioRecorder = recorder {
            audioRecorder.stop()
            audioRecorder.deleteRecording()
        }
        recorder = nil
    }
}

// MARK: - Quick Voice Recorder Service

@MainActor
final class QuickVoiceRecorderService: ObservableObject {

    static let shared = QuickVoiceRecorderService()

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "QuickVoiceRecorderService")

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var lastRecordedFileURL: URL?
    @Published private(set) var lastErrorMessage: String?

    static var defaultRecordingsDirectory: URL {
        if let sandboxRoot = AppStoragePaths.activeTestSandboxRoot {
            return sandboxRoot
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("VoiceMemos", isDirectory: true)
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return docs.appendingPathComponent("LocalConvert Voice Memos", isDirectory: true)
        }
        return AppStoragePaths.applicationSupportDirectory.appendingPathComponent("VoiceMemos", isDirectory: true)
    }

    private let backend: any VoiceRecordingBackend
    private var activeTempFileURL: URL?
    private var activeDestinationDirectory: URL?
    private var recordingStartDate: Date?
    private var elapsedTimerTask: Task<Void, Never>?

    init(backend: any VoiceRecordingBackend = SystemVoiceRecordingBackend()) {
        self.backend = backend
    }

    deinit {
        elapsedTimerTask?.cancel()
    }

    var formattedElapsedTime: String {
        let total = max(0, Int(elapsedSeconds.rounded(.down)))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func startRecording(toDirectory directory: URL? = nil) throws {
        guard !isRecording else {
            let error = VoiceRecordingError.alreadyRecording
            lastErrorMessage = error.localizedDescription
            throw error
        }

        guard backend.requestOrCheckPermission() else {
            let error = VoiceRecordingError.permissionDenied
            lastErrorMessage = error.localizedDescription
            throw error
        }

        try beginRecordingAfterPermissionCheck(toDirectory: directory)
    }

    func startRecordingAsync(toDirectory directory: URL? = nil) async throws {
        guard !isRecording else {
            let error = VoiceRecordingError.alreadyRecording
            lastErrorMessage = error.localizedDescription
            throw error
        }

        let granted = await backend.requestOrCheckPermissionAsync()
        guard granted else {
            let error = VoiceRecordingError.permissionDenied
            lastErrorMessage = error.localizedDescription
            throw error
        }

        try Task.checkCancellation()

        guard !isRecording else {
            let error = VoiceRecordingError.alreadyRecording
            lastErrorMessage = error.localizedDescription
            throw error
        }

        try beginRecordingAfterPermissionCheck(toDirectory: directory)
    }

    private func beginRecordingAfterPermissionCheck(toDirectory directory: URL?) throws {
        let targetDirectory = (directory ?? Self.defaultRecordingsDirectory).standardizedFileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            try OutputReservationCoordinator.validateWritableDirectory(targetDirectory)
        } catch {
            let mapped = VoiceRecordingError.invalidDestinationDirectory(error.localizedDescription)
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        }

        let resolvedDirectory = targetDirectory.resolvingSymlinksInPath()
        let stageURL = resolvedDirectory.appendingPathComponent(
            ".LocalConvert-voicememo-\(UUID().uuidString).m4a",
            isDirectory: false
        )

        do {
            try backend.startRecording(to: stageURL)
        } catch let recordingError as VoiceRecordingError {
            try? fm.removeItem(at: stageURL)
            lastErrorMessage = recordingError.localizedDescription
            throw recordingError
        } catch {
            try? fm.removeItem(at: stageURL)
            let mapped = VoiceRecordingError.failedToStart(error.localizedDescription)
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        }

        activeDestinationDirectory = resolvedDirectory
        activeTempFileURL = stageURL
        recordingStartDate = Date()
        elapsedSeconds = 0
        lastErrorMessage = nil
        isRecording = true

        startElapsedTimer()
        Self.logger.info("Started quick voice recording in \(resolvedDirectory.lastPathComponent, privacy: .public)")
    }

    @discardableResult
    func stopRecordingAndQueue(into appState: AppState? = nil) throws -> URL {
        guard isRecording,
              let tempURL = activeTempFileURL,
              let destinationDir = activeDestinationDirectory else {
            let error = VoiceRecordingError.notRecording
            lastErrorMessage = error.localizedDescription
            throw error
        }

        stopElapsedTimer()
        if let start = recordingStartDate {
            elapsedSeconds = max(elapsedSeconds, Date().timeIntervalSince(start))
        }

        let fm = FileManager.default
        defer {
            isRecording = false
            activeTempFileURL = nil
            activeDestinationDirectory = nil
            recordingStartDate = nil
            try? fm.removeItem(at: tempURL)
        }

        do {
            try backend.stopRecording()
        } catch let recordingError as VoiceRecordingError {
            lastErrorMessage = recordingError.localizedDescription
            throw recordingError
        } catch {
            let mapped = VoiceRecordingError.failedToStop(error.localizedDescription)
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        }

        let attributes = try? fm.attributesOfItem(atPath: tempURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard fm.fileExists(atPath: tempURL.path), fileSize > 0 else {
            let error = VoiceRecordingError.emptyRecording
            lastErrorMessage = error.localizedDescription
            throw error
        }

        let baseName = "VoiceMemo-\(Self.timestampToken())"
        let reservedURL: URL
        do {
            reservedURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
                directory: destinationDir,
                baseName: baseName,
                extension: "m4a",
                policy: .createUnique
            )
        } catch {
            let mapped = VoiceRecordingError.failedToStop(error.localizedDescription)
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        }
        defer { OutputReservationCoordinator.releaseReservedOutputURL(reservedURL) }

        let finalURL: URL
        do {
            finalURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempURL,
                to: reservedURL,
                policy: .createUnique
            )
        } catch {
            let mapped = VoiceRecordingError.failedToStop(error.localizedDescription)
            lastErrorMessage = mapped.localizedDescription
            throw mapped
        }

        lastRecordedFileURL = finalURL
        lastErrorMessage = nil

        if let appState {
            appState.addFiles(urls: [finalURL])
            appState.selectedTab = .convert
            let feedback = String(localized: "Recorded voice memo: \(finalURL.lastPathComponent)")
            appState.dropFeedbackText = feedback
            AccessibilityAnnouncer.announce(feedback)
        }

        Self.logger.info("Saved quick voice memo \(finalURL.lastPathComponent, privacy: .public)")
        return finalURL
    }

    func toggleRecording(into appState: AppState? = nil) {
        if isRecording {
            do {
                _ = try stopRecordingAndQueue(into: appState)
            } catch {
                appState?.showError(
                    title: String(localized: "Voice Recording Failed"),
                    message: error.localizedDescription,
                    suggestion: (error as? LocalizedError)?.recoverySuggestion
                )
            }
        } else {
            Task { @MainActor [weak self, weak appState] in
                guard let self else { return }
                do {
                    try await self.startRecordingAsync()
                } catch is CancellationError {
                    return
                } catch {
                    appState?.showError(
                        title: String(localized: "Voice Recording Failed"),
                        message: error.localizedDescription,
                        suggestion: (error as? LocalizedError)?.recoverySuggestion
                    )
                }
            }
        }
    }

    func cancelRecording() {
        stopElapsedTimer()
        if isRecording {
            backend.cancelRecording()
        }
        if let tempURL = activeTempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        isRecording = false
        elapsedSeconds = 0
        activeTempFileURL = nil
        activeDestinationDirectory = nil
        recordingStartDate = nil
    }

    // MARK: - Private Helpers

    private func startElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.isRecording,
                      let start = self.recordingStartDate else {
                    break
                }
                self.elapsedSeconds = max(0, Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
    }

    private static func timestampToken() -> String {
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

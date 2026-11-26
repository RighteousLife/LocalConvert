import Foundation
import Speech
import os.log

// MARK: - Transcription Models

enum TranscriptionExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case srt = "srt"
    case txt = "txt"

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var fileFormat: FileFormat {
        switch self {
        case .srt: return .srt
        case .txt: return .txt
        }
    }

    var displayName: String {
        switch self {
        case .srt: return "SubRip Subtitles (.srt)"
        case .txt: return "Plain Text (.txt)"
        }
    }

    var shortLabel: String {
        switch self {
        case .srt: return ".srt"
        case .txt: return ".txt"
        }
    }
}

struct TranscriptionSegment: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let confidence: Float

    var endTime: TimeInterval {
        max(0, timestamp) + max(0, duration)
    }

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: TimeInterval,
        duration: TimeInterval,
        confidence: Float = 1.0
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.confidence = confidence
    }
}

struct TranscriptionCue: Equatable, Sendable {
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct TranscriptionResult: Equatable, Sendable {
    let outputURL: URL
    let exportFormat: TranscriptionExportFormat
    let localeIdentifier: String
    let segments: [TranscriptionSegment]
    let transcriptText: String
    let durationSeconds: TimeInterval
    let usedAudioExtraction: Bool
}

enum SpeechAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized

    init(rawStatus: Int) {
        switch rawStatus {
        case SFSpeechRecognizerAuthorizationStatus.authorized.rawValue:
            self = .authorized
        case SFSpeechRecognizerAuthorizationStatus.denied.rawValue:
            self = .denied
        case SFSpeechRecognizerAuthorizationStatus.restricted.rawValue:
            self = .restricted
        default:
            self = .notDetermined
        }
    }
}

struct SpeechRecognizerCapability: Equatable, Sendable {
    let localeIdentifier: String
    let exists: Bool
    let isAvailable: Bool
    let supportsOnDeviceRecognition: Bool
}

struct SpeechLocaleChoice: Identifiable, Equatable, Hashable, Sendable {
    let identifier: String
    let displayName: String
    let supportsOnDeviceRecognition: Bool

    var id: String { identifier }
}

// MARK: - Backends (Testable Abstractions)

protocol OfflineSpeechRecognitionBackend: Sendable {
    func hasUsageDescription() -> Bool
    func currentAuthorizationStatus() -> SpeechAuthorizationState
    func requestAuthorization() async -> SpeechAuthorizationState
    func supportedLocaleIdentifiers() -> [String]
    func recognizerCapability(for localeIdentifier: String) -> SpeechRecognizerCapability
    func transcribeAudioFile(
        at audioURL: URL,
        localeIdentifier: String,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> [TranscriptionSegment]
}

protocol SpeechAudioPreparationBackend: Sendable {
    func probe(url: URL) async throws -> MediaInfo
    func extractSpeechWAV(
        from inputURL: URL,
        to wavURL: URL,
        timeout: TimeInterval
    ) async throws
}

// MARK: - Live Apple Speech Backend (Strictly Offline / On-Device Only)

final class LiveOfflineSpeechRecognitionBackend: OfflineSpeechRecognitionBackend, Sendable {

    private final class LiveRecognitionSession: @unchecked Sendable {
        private let lock = NSLock()
        private var task: SFSpeechRecognitionTask?
        private var continuation: CheckedContinuation<[TranscriptionSegment], Error>?
        private var isFinished = false
        private var isCancelled = false

        func install(
            continuation: CheckedContinuation<[TranscriptionSegment], Error>,
            task: SFSpeechRecognitionTask
        ) {
            var shouldCancelTask = false
            var continuationToFail: CheckedContinuation<[TranscriptionSegment], Error>?

            lock.lock()
            if isFinished {
                shouldCancelTask = true
                continuationToFail = continuation
            } else {
                self.continuation = continuation
                self.task = task
                if isCancelled {
                    isFinished = true
                    shouldCancelTask = true
                    continuationToFail = self.continuation
                    self.continuation = nil
                }
            }
            lock.unlock()

            if shouldCancelTask {
                task.cancel()
            }
            if let continuationToFail {
                continuationToFail.resume(throwing: ConversionError.cancelled)
            }
        }

        func finish(with result: Result<[TranscriptionSegment], Error>) {
            let cont: CheckedContinuation<[TranscriptionSegment], Error>?
            let taskToCleanup: SFSpeechRecognitionTask?

            lock.lock()
            if isFinished {
                cont = nil
                taskToCleanup = nil
            } else {
                isFinished = true
                cont = continuation
                continuation = nil
                taskToCleanup = task
                task = nil
            }
            lock.unlock()

            _ = taskToCleanup
            if let cont {
                switch result {
                case .success(let segments):
                    cont.resume(returning: segments)
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }

        func cancel() {
            let cont: CheckedContinuation<[TranscriptionSegment], Error>?
            let taskToCancel: SFSpeechRecognitionTask?

            lock.lock()
            isCancelled = true
            if isFinished {
                cont = nil
                taskToCancel = nil
            } else {
                isFinished = true
                cont = continuation
                continuation = nil
                taskToCancel = task
                task = nil
            }
            lock.unlock()

            taskToCancel?.cancel()
            cont?.resume(throwing: ConversionError.cancelled)
        }
    }

    static func makeURLRecognitionRequest(for audioURL: URL) -> SFSpeechURLRecognitionRequest {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return request
    }

    func hasUsageDescription() -> Bool {
        let raw = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        return !(raw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func currentAuthorizationStatus() -> SpeechAuthorizationState {
        SpeechAuthorizationState(rawStatus: SFSpeechRecognizer.authorizationStatus().rawValue)
    }

    func requestAuthorization() async -> SpeechAuthorizationState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: SpeechAuthorizationState(rawStatus: status.rawValue))
            }
        }
    }

    func supportedLocaleIdentifiers() -> [String] {
        SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted()
    }

    func recognizerCapability(for localeIdentifier: String) -> SpeechRecognizerCapability {
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return SpeechRecognizerCapability(
                localeIdentifier: localeIdentifier,
                exists: false,
                isAvailable: false,
                supportsOnDeviceRecognition: false
            )
        }
        return SpeechRecognizerCapability(
            localeIdentifier: localeIdentifier,
            exists: true,
            isAvailable: recognizer.isAvailable,
            supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition
        )
    }

    func transcribeAudioFile(
        at audioURL: URL,
        localeIdentifier: String,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> [TranscriptionSegment] {
        try Task.checkCancellation()

        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw ConversionError.invalidInput(
                "The speech recognition locale '\(localeIdentifier)' is not supported on this Mac."
            )
        }

        // Strict offline-only policy: never fall back to Apple cloud servers.
        guard recognizer.supportsOnDeviceRecognition else {
            throw ConversionError.engineNotAvailable(
                "Offline on-device speech recognition is not available for locale '\(localeIdentifier)'. LocalConvert never sends audio over the network."
            )
        }

        guard recognizer.isAvailable else {
            throw ConversionError.engineNotAvailable(
                "On-device speech recognizer for '\(localeIdentifier)' is currently unavailable."
            )
        }

        let request = Self.makeURLRecognitionRequest(for: audioURL)
        guard request.requiresOnDeviceRecognition else {
            throw ConversionError.engineExecutionFailed(
                "On-device speech recognition invariant failed.",
                underlyingError: "SFSpeechURLRecognitionRequest.requiresOnDeviceRecognition must be true."
            )
        }

        progress(.determinate(0.45, message: "Transcribing speech on-device..."))

        let session = LiveRecognitionSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        let nsError = error as NSError
                        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                            session.finish(with: .failure(ConversionError.cancelled))
                        } else if Task.isCancelled {
                            session.finish(with: .failure(ConversionError.cancelled))
                        } else {
                            session.finish(with: .failure(
                                ConversionError.engineExecutionFailed(
                                    "Offline speech recognition failed: \(error.localizedDescription)",
                                    underlyingError: "\(nsError.domain) (\(nsError.code)): \(error.localizedDescription)"
                                )
                            ))
                        }
                        return
                    }

                    guard let result else { return }
                    guard result.isFinal else { return }

                    let mappedSegments = result.bestTranscription.segments.map { seg in
                        TranscriptionSegment(
                            text: seg.substring,
                            timestamp: max(0, seg.timestamp),
                            duration: max(0, seg.duration),
                            confidence: seg.confidence
                        )
                    }
                    if mappedSegments.isEmpty {
                        let fallback = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !fallback.isEmpty {
                            session.finish(with: .success([
                                TranscriptionSegment(text: fallback, timestamp: 0, duration: 1.0, confidence: 1.0)
                            ]))
                            return
                        }
                    }
                    session.finish(with: .success(mappedSegments))
                }
                session.install(continuation: continuation, task: task)
            }
        } onCancel: {
            session.cancel()
        }
    }
}

// MARK: - Live FFmpeg Audio Preparation Backend

final class FFmpegSpeechAudioPreparationBackend: SpeechAudioPreparationBackend, Sendable {

    private let ffmpegProvider: BundledFFmpegProvider

    init(
        ffmpegProvider: BundledFFmpegProvider = BundledFFmpegProvider(
            fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback
        )
    ) {
        self.ffmpegProvider = ffmpegProvider
    }

    func probe(url: URL) async throws -> MediaInfo {
        try await ffmpegProvider.probe(url: url)
    }

    func extractSpeechWAV(
        from inputURL: URL,
        to wavURL: URL,
        timeout: TimeInterval
    ) async throws {
        guard let ffmpegPath = await ffmpegProvider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("Bundled FFmpeg is required to extract audio for speech transcription.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y",
            "-i", inputURL.path,
            "-vn",
            "-sn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            wavURL.path
        ]

        let output: ProcessExecutionOutput
        do {
            output = try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: timeout)
        } catch let timeoutErr as ProcessTimeoutError {
            throw ConversionError.engineExecutionFailed(
                "Audio extraction timed out after \(Int(timeoutErr.timeoutSeconds)) seconds.",
                underlyingError: timeoutErr.localizedDescription
            )
        } catch is CancellationError {
            throw ConversionError.cancelled
        }

        guard output.terminationStatus == 0 else {
            let stderrText = String(data: output.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConversionError.engineExecutionFailed(
                "Failed to extract audio track from '\(inputURL.lastPathComponent)' for transcription.",
                underlyingError: stderrText
            )
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int64) ?? 0
        guard FileManager.default.fileExists(atPath: wavURL.path), fileSize > 44 else {
            throw ConversionError.engineExecutionFailed(
                "Audio extraction produced an empty WAV file.",
                underlyingError: nil
            )
        }
    }
}

// MARK: - Offline Speech Transcription Engine

final class OfflineSpeechTranscriptionEngine: Sendable {

    static let shared = OfflineSpeechTranscriptionEngine()
    static let defaultFFmpegExtractionTimeoutSeconds: TimeInterval = 600.0

    private static let nativeSpeechAudioFormats: Set<FileFormat> = [
        .wav, .m4a, .mp3, .aiff, .caf, .aac, .alac
    ]

    private let logger = Logger(subsystem: "com.localconvert.app", category: "OfflineSpeechTranscription")
    private let speechBackend: any OfflineSpeechRecognitionBackend
    private let audioBackend: any SpeechAudioPreparationBackend
    private let ffmpegTimeoutSeconds: TimeInterval

    init(
        speechBackend: any OfflineSpeechRecognitionBackend = LiveOfflineSpeechRecognitionBackend(),
        audioBackend: any SpeechAudioPreparationBackend = FFmpegSpeechAudioPreparationBackend(),
        ffmpegTimeoutSeconds: TimeInterval = defaultFFmpegExtractionTimeoutSeconds
    ) {
        self.speechBackend = speechBackend
        self.audioBackend = audioBackend
        self.ffmpegTimeoutSeconds = max(1.0, ffmpegTimeoutSeconds)
    }

    // MARK: - Locale Discovery & Pre-Flight Validation

    func supportedLocaleChoices(preferredLocaleIdentifier: String = Locale.current.identifier) -> [SpeechLocaleChoice] {
        let identifiers = speechBackend.supportedLocaleIdentifiers()
        let currentBase = Locale(identifier: preferredLocaleIdentifier).language.languageCode?.identifier

        return identifiers
            .map { id in
                let capability = speechBackend.recognizerCapability(for: id)
                let localized = Locale.current.localizedString(forIdentifier: id)
                    ?? Locale(identifier: "en").localizedString(forIdentifier: id)
                    ?? id
                return SpeechLocaleChoice(
                    identifier: id,
                    displayName: "\(localized) (\(id))",
                    supportsOnDeviceRecognition: capability.supportsOnDeviceRecognition
                )
            }
            .sorted { lhs, rhs in
                if lhs.supportsOnDeviceRecognition != rhs.supportsOnDeviceRecognition {
                    return lhs.supportsOnDeviceRecognition && !rhs.supportsOnDeviceRecognition
                }
                let lhsMatchesPreferred = (lhs.identifier == preferredLocaleIdentifier)
                let rhsMatchesPreferred = (rhs.identifier == preferredLocaleIdentifier)
                if lhsMatchesPreferred != rhsMatchesPreferred {
                    return lhsMatchesPreferred
                }
                if let currentBase {
                    let lhsBase = Locale(identifier: lhs.identifier).language.languageCode?.identifier == currentBase
                    let rhsBase = Locale(identifier: rhs.identifier).language.languageCode?.identifier == currentBase
                    if lhsBase != rhsBase {
                        return lhsBase
                    }
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func validateEnvironmentAndLocale(_ localeIdentifier: String) async throws {
        let authStatus = speechBackend.currentAuthorizationStatus()
        switch authStatus {
        case .authorized:
            break
        case .denied:
            throw ConversionError.engineNotAvailable(
                "Speech Recognition access is denied. Enable LocalConvert under System Settings → Privacy & Security → Speech Recognition."
            )
        case .restricted:
            throw ConversionError.engineNotAvailable(
                "Speech Recognition is restricted on this Mac by system policy."
            )
        case .notDetermined:
            guard speechBackend.hasUsageDescription() else {
                throw ConversionError.engineNotAvailable(
                    "Speech Recognition permission cannot be requested because NSSpeechRecognitionUsageDescription is missing from the app bundle."
                )
            }
            let updatedStatus = await speechBackend.requestAuthorization()
            guard updatedStatus == .authorized else {
                switch updatedStatus {
                case .denied:
                    throw ConversionError.engineNotAvailable(
                        "Speech Recognition permission was denied. Enable LocalConvert in System Settings → Privacy & Security → Speech Recognition."
                    )
                case .restricted:
                    throw ConversionError.engineNotAvailable(
                        "Speech Recognition is restricted on this Mac."
                    )
                default:
                    throw ConversionError.engineNotAvailable(
                        "Speech Recognition authorization was not granted."
                    )
                }
            }
        }

        let trimmedLocale = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            throw ConversionError.invalidInput("Speech recognition language locale must not be empty.")
        }

        let capability = speechBackend.recognizerCapability(for: trimmedLocale)
        guard capability.exists else {
            throw ConversionError.invalidInput(
                "The speech recognition locale '\(trimmedLocale)' is not supported on this Mac."
            )
        }
        guard capability.supportsOnDeviceRecognition else {
            throw ConversionError.engineNotAvailable(
                "Offline on-device speech recognition is not available for '\(trimmedLocale)'. Network/cloud recognition is strictly disabled."
            )
        }
        guard capability.isAvailable else {
            throw ConversionError.engineNotAvailable(
                "The on-device speech recognizer for '\(trimmedLocale)' is currently unavailable."
            )
        }
    }

    // MARK: - Transcription & Atomic Export

    func transcribe(
        inputURL: URL,
        to exportFormat: TranscriptionExportFormat,
        outputDirectory: URL,
        localeIdentifier: String = Locale.current.identifier,
        existingFileHandling: ExistingFileHandling = .createUnique,
        progress: @escaping @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }

        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)
        try await validateEnvironmentAndLocale(localeIdentifier)

        let detectedFormat = FileDetector.detectFormat(url: inputURL)
        if let detectedFormat,
           detectedFormat.category != .audio && detectedFormat.category != .video {
            throw ConversionError.invalidInput(
                "Only audio and video files can be transcribed (received \(detectedFormat.displayName))."
            )
        }

        progress(.determinate(0.10, message: "Inspecting media stream..."))
        let mediaInfo = try? await audioBackend.probe(url: inputURL)
        if let mediaInfo, !mediaInfo.hasAudio {
            throw ConversionError.invalidInput(
                "The file '\(inputURL.lastPathComponent)' does not contain an audio stream to transcribe."
            )
        }

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: scratchDir)
        }

        let needsExtraction = Self.shouldExtractAudioToWAV(
            inputURL: inputURL,
            detectedFormat: detectedFormat,
            mediaInfo: mediaInfo
        )

        let speechInputURL: URL
        if needsExtraction {
            progress(.determinate(0.22, message: "Extracting audio track..."))
            let extractedWAV = scratchDir.appendingPathComponent("extracted_speech.wav")
            try await audioBackend.extractSpeechWAV(
                from: inputURL,
                to: extractedWAV,
                timeout: ffmpegTimeoutSeconds
            )
            speechInputURL = extractedWAV
        } else {
            speechInputURL = inputURL
        }

        try Task.checkCancellation()

        let segments = try await speechBackend.transcribeAudioFile(
            at: speechInputURL,
            localeIdentifier: localeIdentifier,
            progress: progress
        )

        try Task.checkCancellation()
        progress(.determinate(0.88, message: "Formatting \(exportFormat.shortLabel) output..."))

        let plainText = Self.formatPlainText(segments: segments)
        let formattedContent: String
        switch exportFormat {
        case .srt:
            formattedContent = Self.formatSRT(segments: segments)
        case .txt:
            formattedContent = plainText
        }

        guard !formattedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.invalidInput(
                "No recognizable speech was detected in '\(inputURL.lastPathComponent)'."
            )
        }

        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL)
        let reservedOutputURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: outputDirectory,
            baseName: baseName,
            extension: exportFormat.fileExtension,
            sourceURL: inputURL,
            policy: existingFileHandling
        )
        defer {
            OutputReservationCoordinator.releaseReservedOutputURL(reservedOutputURL)
        }

        let tempExportURL = scratchDir.appendingPathComponent("transcript.\(exportFormat.fileExtension)")
        guard let data = formattedContent.data(using: .utf8) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to encode transcript as UTF-8.",
                underlyingError: nil
            )
        }
        try data.write(to: tempExportURL, options: .atomic)

        try Task.checkCancellation()
        let finalOutputURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempExportURL,
            to: reservedOutputURL,
            policy: existingFileHandling
        )

        let durationSeconds = mediaInfo?.duration ?? segments.map(\.endTime).max() ?? 0
        progress(.determinate(1.0, message: "Transcription Complete"))
        logger.info("Offline transcription succeeded: \(inputURL.lastPathComponent) -> \(finalOutputURL.lastPathComponent) (\(segments.count) segments)")

        return TranscriptionResult(
            outputURL: finalOutputURL,
            exportFormat: exportFormat,
            localeIdentifier: localeIdentifier,
            segments: segments,
            transcriptText: plainText,
            durationSeconds: durationSeconds,
            usedAudioExtraction: needsExtraction
        )
    }

    // MARK: - Media Routing Helpers

    static func shouldExtractAudioToWAV(
        inputURL: URL,
        detectedFormat: FileFormat?,
        mediaInfo: MediaInfo?
    ) -> Bool {
        if let mediaInfo, mediaInfo.hasRealVideo {
            return true
        }
        if let detectedFormat {
            if detectedFormat.category == .video {
                return true
            }
            if detectedFormat.category == .audio {
                return !nativeSpeechAudioFormats.contains(detectedFormat)
            }
        }
        let ext = inputURL.pathExtension.lowercased()
        if let byExt = FileFormat.from(extension: ext) {
            if byExt.category == .video { return true }
            if byExt.category == .audio { return !nativeSpeechAudioFormats.contains(byExt) }
        }
        return false
    }

    // MARK: - Formatting Helpers (Deterministic, Pure)

    /// Formats seconds as SubRip timestamp `HH:MM:SS,mmm`.
    static func formatSRTTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = (seconds.isFinite && seconds > 0) ? seconds : 0
        let totalMillis = Int64((clamped * 1000.0).rounded())
        let millis = totalMillis % 1000
        let totalSecs = totalMillis / 1000
        let secs = totalSecs % 60
        let mins = (totalSecs / 60) % 60
        let hours = totalSecs / 3600
        return String(format: "%02lld:%02lld:%02lld,%03lld", hours, mins, secs, millis)
    }

    /// Groups timestamped speech segments into clean, non-overlapping SubRip cues.
    static func buildSubRipCues(
        from segments: [TranscriptionSegment],
        maxCharactersPerCue: Int = 84,
        maxCueDuration: TimeInterval = 5.0,
        pauseGapThreshold: TimeInterval = 0.75
    ) -> [TranscriptionCue] {
        let normalized: [TranscriptionSegment] = segments
            .enumerated()
            .sorted {
                if abs($0.element.timestamp - $1.element.timestamp) > 0.0001 {
                    return $0.element.timestamp < $1.element.timestamp
                }
                return $0.offset < $1.offset
            }
            .compactMap { _, seg in
                let cleaned = sanitizeCueInlineText(seg.text)
                guard !cleaned.isEmpty else { return nil }
                return TranscriptionSegment(
                    id: seg.id,
                    text: cleaned,
                    timestamp: max(0, seg.timestamp.isFinite ? seg.timestamp : 0),
                    duration: max(0, seg.duration.isFinite ? seg.duration : 0),
                    confidence: seg.confidence
                )
            }

        guard !normalized.isEmpty else { return [] }

        struct PendingCue {
            var startTime: TimeInterval
            var endTime: TimeInterval
            var tokens: [String]
        }

        var pendingCues: [PendingCue] = []
        var current = PendingCue(
            startTime: normalized[0].timestamp,
            endTime: max(normalized[0].timestamp, normalized[0].endTime),
            tokens: [normalized[0].text]
        )

        for seg in normalized.dropFirst() {
            let segStart = seg.timestamp
            let segEnd = max(segStart, seg.endTime)
            let gap = segStart - current.endTime
            let currentJoined = joinTokens(current.tokens)
            let candidateJoined = joinTokens(current.tokens + [seg.text])
            let projectedDuration = max(current.endTime, segEnd) - current.startTime
            let previousEndedSentence = endsWithSentencePunctuation(current.tokens.last ?? "")

            let shouldSplit = gap >= pauseGapThreshold
                || (candidateJoined.count > maxCharactersPerCue && !currentJoined.isEmpty)
                || (projectedDuration > maxCueDuration && !currentJoined.isEmpty)
                || previousEndedSentence
                || currentJoined.contains("\n")
                || seg.text.contains("\n")

            if shouldSplit {
                pendingCues.append(current)
                current = PendingCue(
                    startTime: segStart,
                    endTime: segEnd,
                    tokens: [seg.text]
                )
            } else {
                current.tokens.append(seg.text)
                current.endTime = max(current.endTime, segEnd)
            }
        }
        pendingCues.append(current)

        var cues: [TranscriptionCue] = []
        cues.reserveCapacity(pendingCues.count)

        for idx in pendingCues.indices {
            let item = pendingCues[idx]
            let start = max(0, item.startTime)
            var end = item.endTime > start + 0.05 ? item.endTime : (start + 0.5)
            if idx + 1 < pendingCues.count {
                let nextStart = max(0, pendingCues[idx + 1].startTime)
                if nextStart > start && end > nextStart {
                    end = nextStart
                }
            }
            let joined = joinTokens(item.tokens)
            let wrapped = wrapCueLines(joined, maxLineLength: max(20, maxCharactersPerCue / 2))
            cues.append(TranscriptionCue(
                index: idx + 1,
                startTime: start,
                endTime: end,
                text: wrapped
            ))
        }

        return cues
    }

    static func formatSRT(
        segments: [TranscriptionSegment],
        maxCharactersPerCue: Int = 84,
        maxCueDuration: TimeInterval = 5.0,
        pauseGapThreshold: TimeInterval = 0.75
    ) -> String {
        let cues = buildSubRipCues(
            from: segments,
            maxCharactersPerCue: maxCharactersPerCue,
            maxCueDuration: maxCueDuration,
            pauseGapThreshold: pauseGapThreshold
        )
        guard !cues.isEmpty else { return "" }

        let blocks = cues.map { cue in
            """
            \(cue.index)
            \(formatSRTTimestamp(cue.startTime)) --> \(formatSRTTimestamp(cue.endTime))
            \(cue.text)
            """
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func formatPlainText(
        segments: [TranscriptionSegment],
        fallbackText: String? = nil,
        paragraphPauseThreshold: TimeInterval = 1.5
    ) -> String {
        let sorted = segments
            .enumerated()
            .sorted {
                if abs($0.element.timestamp - $1.element.timestamp) > 0.0001 {
                    return $0.element.timestamp < $1.element.timestamp
                }
                return $0.offset < $1.offset
            }
            .compactMap { _, seg -> TranscriptionSegment? in
                let trimmed = seg.text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return TranscriptionSegment(
                    id: seg.id,
                    text: trimmed,
                    timestamp: max(0, seg.timestamp.isFinite ? seg.timestamp : 0),
                    duration: max(0, seg.duration.isFinite ? seg.duration : 0),
                    confidence: seg.confidence
                )
            }

        guard !sorted.isEmpty else {
            return fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var paragraphs: [[String]] = [[]]
        var prevEnd = sorted[0].endTime
        var prevText = sorted[0].text
        paragraphs[0].append(prevText)

        for seg in sorted.dropFirst() {
            let gap = seg.timestamp - prevEnd
            if gap >= paragraphPauseThreshold && endsWithSentencePunctuation(prevText) {
                paragraphs.append([seg.text])
            } else {
                paragraphs[paragraphs.count - 1].append(seg.text)
            }
            prevEnd = max(prevEnd, seg.endTime)
            prevText = seg.text
        }

        return paragraphs
            .map { joinTokens($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Private Text Helpers

    private static func sanitizeCueInlineText(_ raw: String) -> String {
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedNewlines
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static func joinTokens(_ tokens: [String]) -> String {
        var result = ""
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
            } else if shouldAttachWithoutSpace(trimmed) {
                result += trimmed
            } else if result.hasSuffix("\n") {
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }

    private static func shouldAttachWithoutSpace(_ token: String) -> Bool {
        let noLeadingSpacePrefixes = [".", ",", "!", "?", ";", ":", "…", ")", "]", "}", "”", "’"]
        if noLeadingSpacePrefixes.contains(where: { token.hasPrefix($0) }) {
            return true
        }
        let contractions = ["'s", "'t", "'re", "'ve", "'m", "'ll", "'d", "n't", "’s", "’t", "’re", "’ve", "’m", "’ll", "’d", "n’t"]
        let lower = token.lowercased()
        return contractions.contains(lower)
    }

    private static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return last == "." || last == "!" || last == "?" || last == "…"
    }

    private static func wrapCueLines(_ text: String, maxLineLength: Int) -> String {
        if text.contains("\n") || text.count <= maxLineLength {
            return text
        }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else {
            return text
        }

        let targetMid = text.count / 2
        var bestSplitIndex = 1
        var bestDelta = Int.max
        var runningLength = 0

        for i in 0..<(words.count - 1) {
            runningLength += words[i].count + (i > 0 ? 1 : 0)
            let delta = abs(runningLength - targetMid)
            if delta < bestDelta {
                bestDelta = delta
                bestSplitIndex = i + 1
            }
        }

        let firstLine = words[0..<bestSplitIndex].joined(separator: " ")
        let secondLine = words[bestSplitIndex...].joined(separator: " ")
        guard !firstLine.isEmpty && !secondLine.isEmpty else {
            return text
        }
        return "\(firstLine)\n\(secondLine)"
    }
}

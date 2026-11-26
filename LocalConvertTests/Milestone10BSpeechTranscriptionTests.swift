import XCTest
import SwiftUI
import Speech
import os
@testable import LocalConvert

// MARK: - Deterministic Test Doubles

private final class MockSpeechRecognitionBackend: OfflineSpeechRecognitionBackend, @unchecked Sendable {
    struct Config: Sendable {
        var usageDescriptionPresent: Bool = true
        var initialAuthStatus: SpeechAuthorizationState = .authorized
        var requestedAuthResult: SpeechAuthorizationState = .authorized
        var supportedLocales: [String] = ["en-US", "tr-TR"]
        var capabilitiesByLocale: [String: SpeechRecognizerCapability] = [
            "en-US": SpeechRecognizerCapability(
                localeIdentifier: "en-US",
                exists: true,
                isAvailable: true,
                supportsOnDeviceRecognition: true
            ),
            "tr-TR": SpeechRecognizerCapability(
                localeIdentifier: "tr-TR",
                exists: true,
                isAvailable: true,
                supportsOnDeviceRecognition: false
            )
        ]
        var segmentsToReturn: [TranscriptionSegment] = [
            TranscriptionSegment(text: "Hello", timestamp: 0.0, duration: 0.45, confidence: 0.98),
            TranscriptionSegment(text: "world.", timestamp: 0.50, duration: 0.55, confidence: 0.97),
            TranscriptionSegment(text: "Offline", timestamp: 1.40, duration: 0.40, confidence: 0.99),
            TranscriptionSegment(text: "subtitles!", timestamp: 1.85, duration: 0.65, confidence: 0.96)
        ]
        var errorToThrow: Error? = nil
    }

    private let lock = NSLock()
    private var config: Config
    private(set) var requestAuthorizationCallCount = 0
    private(set) var transcribedAudioURLs: [URL] = []

    init(config: Config = Config()) {
        self.config = config
    }

    func hasUsageDescription() -> Bool {
        lock.withLock { config.usageDescriptionPresent }
    }

    func currentAuthorizationStatus() -> SpeechAuthorizationState {
        lock.withLock { config.initialAuthStatus }
    }

    func requestAuthorization() async -> SpeechAuthorizationState {
        lock.withLock {
            requestAuthorizationCallCount += 1
            return config.requestedAuthResult
        }
    }

    func supportedLocaleIdentifiers() -> [String] {
        lock.withLock { config.supportedLocales }
    }

    func recognizerCapability(for localeIdentifier: String) -> SpeechRecognizerCapability {
        lock.withLock {
            config.capabilitiesByLocale[localeIdentifier] ?? SpeechRecognizerCapability(
                localeIdentifier: localeIdentifier,
                exists: false,
                isAvailable: false,
                supportsOnDeviceRecognition: false
            )
        }
    }

    func transcribeAudioFile(
        at audioURL: URL,
        localeIdentifier: String,
        progress: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws -> [TranscriptionSegment] {
        let snapshot = lock.withLock { () -> (Config) in
            transcribedAudioURLs.append(audioURL)
            return config
        }
        progress(.determinate(0.6, message: "Transcribing speech on-device..."))
        if let err = snapshot.errorToThrow {
            throw err
        }
        return snapshot.segmentsToReturn
    }
}

private final class MockSpeechAudioPreparationBackend: SpeechAudioPreparationBackend, @unchecked Sendable {
    private let lock = NSLock()
    var probeMediaInfo: MediaInfo
    var extractError: Error?
    private(set) var extractedPairs: [(input: URL, outputWAV: URL)] = []

    init(probeMediaInfo: MediaInfo, extractError: Error? = nil) {
        self.probeMediaInfo = probeMediaInfo
        self.extractError = extractError
    }

    func probe(url: URL) async throws -> MediaInfo {
        probeMediaInfo
    }

    func extractSpeechWAV(
        from inputURL: URL,
        to wavURL: URL,
        timeout: TimeInterval
    ) async throws {
        let err = lock.withLock { () -> Error? in
            extractedPairs.append((inputURL, wavURL))
            return extractError
        }
        if let err {
            throw err
        }
        // Write valid minimal WAV header + PCM payload so downstream checks see a non-empty file.
        let headerAndPayload = Data(repeating: 0x01, count: 128)
        try headerAndPayload.write(to: wavURL)
    }
}

// MARK: - Milestone 10B Tests

@MainActor
final class Milestone10BSpeechTranscriptionTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M10BSpeech-\(UUID().uuidString)")
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

    private func makeAudioMediaInfo(url: URL, duration: Double = 0.2) -> MediaInfo {
        MediaInfo(
            url: url,
            formatName: "wav",
            duration: duration,
            fileSize: nil,
            bitRate: nil,
            streams: [
                MediaStreamInfo(
                    index: 0,
                    streamType: .audio,
                    codecName: "pcm_s16le",
                    codecLongName: nil,
                    bitRate: nil,
                    width: nil,
                    height: nil,
                    frameRate: nil,
                    sampleRate: 16_000,
                    channels: 1,
                    duration: duration
                )
            ]
        )
    }

    private func makeVideoMediaInfo(url: URL, duration: Double = 3.0, includeAudio: Bool) -> MediaInfo {
        var streams: [MediaStreamInfo] = [
            MediaStreamInfo(
                index: 0,
                streamType: .video,
                codecName: "h264",
                codecLongName: nil,
                bitRate: nil,
                width: 1280,
                height: 720,
                frameRate: 30,
                sampleRate: nil,
                channels: nil,
                duration: duration
            )
        ]
        if includeAudio {
            streams.append(
                MediaStreamInfo(
                    index: 1,
                    streamType: .audio,
                    codecName: "aac",
                    codecLongName: nil,
                    bitRate: nil,
                    width: nil,
                    height: nil,
                    frameRate: nil,
                    sampleRate: 48_000,
                    channels: 2,
                    duration: duration
                )
            )
        }
        return MediaInfo(
            url: url,
            formatName: "mov,mp4,m4a,3gp,3g2,mj2",
            duration: duration,
            fileSize: nil,
            bitRate: nil,
            streams: streams
        )
    }

    // MARK: - 1. SRT Timestamp Formatting

    func testSRTTimestampFormattingAndBoundaryClamping() {
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(0.0), "00:00:00,000")
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(0.005), "00:00:00,005")
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(0.9999), "00:00:01,000")
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(65.432), "00:01:05,432")
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(3661.045), "01:01:01,045")
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(-4.2), "00:00:00,000")
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(.nan), "00:00:00,000")
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRTTimestamp(.infinity), "00:00:00,000")
    }

    // MARK: - 2. SRT Cue Assembly & Edge Cases

    func testFormatSRTGroupsWordsSplitsPausesAndNumbersCuesSequentially() {
        let segments: [TranscriptionSegment] = [
            TranscriptionSegment(text: "Hello", timestamp: 0.0, duration: 0.4),
            TranscriptionSegment(text: "world.", timestamp: 0.45, duration: 0.55),
            TranscriptionSegment(text: "Welcome", timestamp: 1.5, duration: 0.4),
            TranscriptionSegment(text: "to", timestamp: 1.95, duration: 0.2),
            TranscriptionSegment(text: "LocalConvert!", timestamp: 2.2, duration: 0.8),
            TranscriptionSegment(text: "Line\r\n\r\nbreak", timestamp: 4.0, duration: 0.0)
        ]

        let srt = OfflineSpeechTranscriptionEngine.formatSRT(segments: segments)
        let blocks = srt.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")

        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks[0].hasPrefix("1\n00:00:00,000 --> 00:00:01,000\nHello world."))
        XCTAssertTrue(blocks[1].hasPrefix("2\n00:00:01,500 --> 00:00:03,000\nWelcome to LocalConvert!"))
        // Zero duration gets minimum non-zero cue duration (0.5s) and internal blank lines collapse
        XCTAssertTrue(blocks[2].hasPrefix("3\n00:00:04,000 --> 00:00:04,500\nLine\nbreak"))
    }

    func testFormatSRTEmptySegmentsReturnsEmptyString() {
        XCTAssertEqual(OfflineSpeechTranscriptionEngine.formatSRT(segments: []), "")
        XCTAssertEqual(
            OfflineSpeechTranscriptionEngine.formatSRT(segments: [
                TranscriptionSegment(text: "   \n ", timestamp: 0, duration: 1)
            ]),
            ""
        )
    }

    func testFormatSRTPreventsOverlappingCues() {
        let segments = [
            TranscriptionSegment(text: "First sentence.", timestamp: 0.0, duration: 2.5),
            TranscriptionSegment(text: "Second sentence.", timestamp: 1.8, duration: 1.0)
        ]
        let cues = OfflineSpeechTranscriptionEngine.buildSubRipCues(from: segments)
        XCTAssertEqual(cues.count, 2)
        XCTAssertLessThanOrEqual(cues[0].endTime, cues[1].startTime)
        XCTAssertGreaterThan(cues[0].endTime, cues[0].startTime)
    }

    // MARK: - 3. Plain Text (.txt) Assembly

    func testFormatPlainTextHandlesPunctuationContractionsAndParagraphPauses() {
        let segments = [
            TranscriptionSegment(text: "It", timestamp: 0.0, duration: 0.2),
            TranscriptionSegment(text: "'s", timestamp: 0.2, duration: 0.2),
            TranscriptionSegment(text: "working", timestamp: 0.45, duration: 0.4),
            TranscriptionSegment(text: "!", timestamp: 0.85, duration: 0.1),
            // Pause >= 1.5s after sentence punctuation triggers paragraph break
            TranscriptionSegment(text: "Next", timestamp: 3.0, duration: 0.3),
            TranscriptionSegment(text: "paragraph.", timestamp: 3.35, duration: 0.5)
        ]

        let txt = OfflineSpeechTranscriptionEngine.formatPlainText(segments: segments)
        XCTAssertEqual(txt, "It's working!\n\nNext paragraph.")
    }

    // MARK: - 4. Strict Offline / On-Device Configuration

    func testLiveRecognitionRequestStrictlyEnforcesOnDeviceRecognition() {
        let sampleURL = sandbox.documentsURL.appendingPathComponent("sample.wav")
        let request = LiveOfflineSpeechRecognitionBackend.makeURLRecognitionRequest(for: sampleURL)
        XCTAssertTrue(request.requiresOnDeviceRecognition, "Offline policy requires requiresOnDeviceRecognition = true")
        XCTAssertFalse(request.shouldReportPartialResults)
    }

    func testEngineRejectsLocaleWithoutOnDeviceRecognitionSupport() async throws {
        let wavURL = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: sandbox.documentsURL.appendingPathComponent("voice_tr.wav"),
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 16_000, channelCount: 1, frameCount: 3_200)
        )
        let speech = MockSpeechRecognitionBackend()
        let audio = MockSpeechAudioPreparationBackend(probeMediaInfo: makeAudioMediaInfo(url: wavURL))
        let engine = OfflineSpeechTranscriptionEngine(speechBackend: speech, audioBackend: audio)

        do {
            _ = try await engine.transcribe(
                inputURL: wavURL,
                to: .srt,
                outputDirectory: sandbox.outputsURL,
                localeIdentifier: "tr-TR"
            )
            XCTFail("Expected engineNotAvailable when on-device recognition is unsupported")
        } catch let error as ConversionError {
            guard case .engineNotAvailable(let message) = error else {
                return XCTFail("Expected engineNotAvailable, got \(error)")
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("on-device"))
            XCTAssertTrue(speech.transcribedAudioURLs.isEmpty)
        }
    }

    // MARK: - 5. Authorization & Error Diagnostics

    func testEngineFailsCleanlyWhenPermissionDeniedOrRestricted() async throws {
        let wavURL = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: sandbox.documentsURL.appendingPathComponent("denied.wav"),
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 16_000, channelCount: 1, frameCount: 3_200)
        )
        let audio = MockSpeechAudioPreparationBackend(probeMediaInfo: makeAudioMediaInfo(url: wavURL))

        for state in [SpeechAuthorizationState.denied, .restricted] {
            var cfg = MockSpeechRecognitionBackend.Config()
            cfg.initialAuthStatus = state
            let speech = MockSpeechRecognitionBackend(config: cfg)
            let engine = OfflineSpeechTranscriptionEngine(speechBackend: speech, audioBackend: audio)

            do {
                _ = try await engine.transcribe(
                    inputURL: wavURL,
                    to: .txt,
                    outputDirectory: sandbox.outputsURL,
                    localeIdentifier: "en-US"
                )
                XCTFail("Expected error for authorization state \(state)")
            } catch let error as ConversionError {
                guard case .engineNotAvailable = error else {
                    return XCTFail("Expected engineNotAvailable, got \(error)")
                }
            }
        }
    }

    func testEngineAvoidsTCCPromptCrashWhenUsageDescriptionMissing() async throws {
        let wavURL = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: sandbox.documentsURL.appendingPathComponent("not_determined.wav"),
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 16_000, channelCount: 1, frameCount: 3_200)
        )
        var cfg = MockSpeechRecognitionBackend.Config()
        cfg.usageDescriptionPresent = false
        cfg.initialAuthStatus = .notDetermined
        let speech = MockSpeechRecognitionBackend(config: cfg)
        let audio = MockSpeechAudioPreparationBackend(probeMediaInfo: makeAudioMediaInfo(url: wavURL))
        let engine = OfflineSpeechTranscriptionEngine(speechBackend: speech, audioBackend: audio)

        do {
            _ = try await engine.transcribe(
                inputURL: wavURL,
                to: .srt,
                outputDirectory: sandbox.outputsURL,
                localeIdentifier: "en-US"
            )
            XCTFail("Expected engineNotAvailable when NSSpeechRecognitionUsageDescription is absent")
        } catch let error as ConversionError {
            guard case .engineNotAvailable(let msg) = error else {
                return XCTFail("Expected engineNotAvailable, got \(error)")
            }
            XCTAssertTrue(msg.contains("NSSpeechRecognitionUsageDescription"))
            XCTAssertEqual(speech.requestAuthorizationCallCount, 0, "Must never call SFSpeechRecognizer.requestAuthorization without usage description")
        }
    }

    func testEngineRejectsUnsupportedLocaleUnavailableRecognizerMissingFileAndEmptySpeech() async throws {
        let wavURL = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: sandbox.documentsURL.appendingPathComponent("valid.wav"),
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 16_000, channelCount: 1, frameCount: 3_200)
        )
        let audio = MockSpeechAudioPreparationBackend(probeMediaInfo: makeAudioMediaInfo(url: wavURL))

        // Missing file
        do {
            let engine = OfflineSpeechTranscriptionEngine(speechBackend: MockSpeechRecognitionBackend(), audioBackend: audio)
            _ = try await engine.transcribe(
                inputURL: sandbox.documentsURL.appendingPathComponent("does_not_exist.wav"),
                to: .srt,
                outputDirectory: sandbox.outputsURL,
                localeIdentifier: "en-US"
            )
            XCTFail("Expected inputFileNotFound")
        } catch let error as ConversionError {
            guard case .inputFileNotFound = error else {
                return XCTFail("Expected inputFileNotFound, got \(error)")
            }
        }

        // Unsupported locale
        do {
            let engine = OfflineSpeechTranscriptionEngine(speechBackend: MockSpeechRecognitionBackend(), audioBackend: audio)
            _ = try await engine.transcribe(
                inputURL: wavURL,
                to: .srt,
                outputDirectory: sandbox.outputsURL,
                localeIdentifier: "xx-INVALID"
            )
            XCTFail("Expected invalidInput for unsupported locale")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }

        // Unavailable recognizer
        do {
            var cfg = MockSpeechRecognitionBackend.Config()
            cfg.capabilitiesByLocale["en-US"] = SpeechRecognizerCapability(
                localeIdentifier: "en-US",
                exists: true,
                isAvailable: false,
                supportsOnDeviceRecognition: true
            )
            let engine = OfflineSpeechTranscriptionEngine(speechBackend: MockSpeechRecognitionBackend(config: cfg), audioBackend: audio)
            _ = try await engine.transcribe(
                inputURL: wavURL,
                to: .srt,
                outputDirectory: sandbox.outputsURL,
                localeIdentifier: "en-US"
            )
            XCTFail("Expected engineNotAvailable for unavailable recognizer")
        } catch let error as ConversionError {
            guard case .engineNotAvailable = error else {
                return XCTFail("Expected engineNotAvailable, got \(error)")
            }
        }

        // Empty speech segments
        do {
            var cfg = MockSpeechRecognitionBackend.Config()
            cfg.segmentsToReturn = []
            let engine = OfflineSpeechTranscriptionEngine(speechBackend: MockSpeechRecognitionBackend(config: cfg), audioBackend: audio)
            _ = try await engine.transcribe(
                inputURL: wavURL,
                to: .txt,
                outputDirectory: sandbox.outputsURL,
                localeIdentifier: "en-US"
            )
            XCTFail("Expected invalidInput for empty speech transcription")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    // MARK: - 6. Video Audio Extraction & Atomic Commit

    func testShouldExtractAudioToWAVRoutingRules() {
        XCTAssertTrue(OfflineSpeechTranscriptionEngine.shouldExtractAudioToWAV(
            inputURL: URL(fileURLWithPath: "/tmp/clip.mp4"),
            detectedFormat: .mp4,
            mediaInfo: nil
        ))
        XCTAssertTrue(OfflineSpeechTranscriptionEngine.shouldExtractAudioToWAV(
            inputURL: URL(fileURLWithPath: "/tmp/voice.opus"),
            detectedFormat: .opus,
            mediaInfo: nil
        ))
        XCTAssertFalse(OfflineSpeechTranscriptionEngine.shouldExtractAudioToWAV(
            inputURL: URL(fileURLWithPath: "/tmp/voice.wav"),
            detectedFormat: .wav,
            mediaInfo: nil
        ))
        XCTAssertFalse(OfflineSpeechTranscriptionEngine.shouldExtractAudioToWAV(
            inputURL: URL(fileURLWithPath: "/tmp/voice.m4a"),
            detectedFormat: .m4a,
            mediaInfo: nil
        ))
    }

    func testEndToEndAtomicSRTAndTXTExportAndCollisionSafeNaming() async throws {
        let wavURL = try await SyntheticAudioFixtureWriter.writeAudioFixture(
            to: sandbox.documentsURL.appendingPathComponent("meeting.wav"),
            spec: SyntheticAudioFixtureWriter.Spec(format: .wav, sampleRate: 16_000, channelCount: 1, frameCount: 3_200)
        )
        let originalData = try Data(contentsOf: wavURL)
        let speech = MockSpeechRecognitionBackend()
        let audio = MockSpeechAudioPreparationBackend(probeMediaInfo: makeAudioMediaInfo(url: wavURL, duration: 2.5))
        let engine = OfflineSpeechTranscriptionEngine(speechBackend: speech, audioBackend: audio)

        // First SRT export
        let srt1 = try await engine.transcribe(
            inputURL: wavURL,
            to: .srt,
            outputDirectory: sandbox.outputsURL,
            localeIdentifier: "en-US"
        )
        XCTAssertEqual(srt1.outputURL.lastPathComponent, "meeting.srt")
        XCTAssertFalse(srt1.usedAudioExtraction)
        let srtContent = try String(contentsOf: srt1.outputURL, encoding: .utf8)
        XCTAssertTrue(srtContent.contains("00:00:00,000 --> 00:00:01,050"))
        XCTAssertTrue(srtContent.contains("Hello world."))
        XCTAssertTrue(srtContent.contains("Offline subtitles!"))

        // Second SRT export must create collision-safe unique file instead of overwriting
        let srt2 = try await engine.transcribe(
            inputURL: wavURL,
            to: .srt,
            outputDirectory: sandbox.outputsURL,
            localeIdentifier: "en-US"
        )
        XCTAssertNotEqual(srt1.outputURL, srt2.outputURL)
        XCTAssertEqual(srt2.outputURL.lastPathComponent, "meeting (1).srt")

        // TXT export
        let txtResult = try await engine.transcribe(
            inputURL: wavURL,
            to: .txt,
            outputDirectory: sandbox.outputsURL,
            localeIdentifier: "en-US"
        )
        XCTAssertEqual(txtResult.outputURL.lastPathComponent, "meeting.txt")
        let txtContent = try String(contentsOf: txtResult.outputURL, encoding: .utf8)
        XCTAssertEqual(txtContent, "Hello world. Offline subtitles!")

        // Source audio bytes untouched
        XCTAssertEqual(try Data(contentsOf: wavURL), originalData)
    }

    func testVideoInputExtractsTempWAVAndCleansUpTempDirectory() async throws {
        let mp4URL = sandbox.documentsURL.appendingPathComponent("lecture.mp4")
        try Data("synthetic-mp4-bytes".utf8).write(to: mp4URL)

        let speech = MockSpeechRecognitionBackend()
        let audio = MockSpeechAudioPreparationBackend(probeMediaInfo: makeVideoMediaInfo(url: mp4URL, duration: 3.0, includeAudio: true))
        let engine = OfflineSpeechTranscriptionEngine(speechBackend: speech, audioBackend: audio)

        let result = try await engine.transcribe(
            inputURL: mp4URL,
            to: .srt,
            outputDirectory: sandbox.outputsURL,
            localeIdentifier: "en-US"
        )

        XCTAssertTrue(result.usedAudioExtraction)
        XCTAssertEqual(audio.extractedPairs.count, 1)
        let extractedWAV = audio.extractedPairs[0].outputWAV
        XCTAssertEqual(speech.transcribedAudioURLs, [extractedWAV])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: extractedWAV.deletingLastPathComponent().path),
            "Isolated temporary LocalConvert-Speech directory must be removed after completion"
        )
    }

    func testVideoWithoutAudioStreamThrowsInvalidInput() async throws {
        let silentVideoURL = sandbox.documentsURL.appendingPathComponent("silent.mp4")
        try Data("synthetic-video-no-audio".utf8).write(to: silentVideoURL)

        let speech = MockSpeechRecognitionBackend()
        let audio = MockSpeechAudioPreparationBackend(probeMediaInfo: makeVideoMediaInfo(url: silentVideoURL, duration: 2.0, includeAudio: false))
        let engine = OfflineSpeechTranscriptionEngine(speechBackend: speech, audioBackend: audio)

        do {
            _ = try await engine.transcribe(
                inputURL: silentVideoURL,
                to: .srt,
                outputDirectory: sandbox.outputsURL,
                localeIdentifier: "en-US"
            )
            XCTFail("Expected invalidInput when video has no audio stream")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    // MARK: - 7. Smart Bar & Audio Workspace UI Integration

    func testSmartSuggestionEngineIncludesTranscribeSRTForStagedAudioVideoFiles() {
        let wavURL = sandbox.documentsURL.appendingPathComponent("voice.wav")
        let movURL = sandbox.documentsURL.appendingPathComponent("clip.mov")
        let wavFile = DroppedFile(
            url: wavURL,
            detectionResult: FileDetectionResult(
                url: wavURL,
                detectedFormat: .wav,
                extensionFormat: .wav,
                utTypeFormat: .wav,
                magicBytesFormat: .wav,
                confidence: .high
            )
        )
        let movFile = DroppedFile(
            url: movURL,
            detectionResult: FileDetectionResult(
                url: movURL,
                detectedFormat: .mov,
                extensionFormat: .mov,
                utTypeFormat: .mov,
                magicBytesFormat: .mov,
                confidence: .high
            )
        )

        let plan = SmartSuggestionEngine.suggest(for: [movFile, wavFile])
        XCTAssertEqual(plan.category, .audioVideo)
        XCTAssertTrue(plan.actions.contains(where: { $0.id == .transcribeSRT && $0.title == "Transcribe (.srt)" && $0.isEnabled }))
    }

    func testAudioWorkspaceRootViewAudioToolsLayoutsAtMinimumSizeWithoutMutatingState() throws {
        let coordinator = AudioWorkspaceCoordinator(
            databaseURL: sandbox.applicationSupportURL.appendingPathComponent("library.sqlite"),
            artworkDirectoryURL: sandbox.cachesURL.appendingPathComponent("artwork", isDirectory: true),
            playerStateURL: sandbox.applicationSupportURL.appendingPathComponent("player_state.json")
        )
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let editorStore = AudioEditorStore(undoCoordinator: undoCoord)
        coordinator.activeMode = .audioTools

        var coordPublishes = 0
        let c1 = coordinator.objectWillChange.sink { _ in coordPublishes += 1 }
        var editorPublishes = 0
        let c2 = editorStore.objectWillChange.sink { _ in editorPublishes += 1 }
        defer { c1.cancel(); c2.cancel() }

        let view = AudioWorkspaceRootView(coordinator: coordinator, editorStore: editorStore) {
            Text("Audio Tools Placeholder")
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(coordPublishes, 0)
        XCTAssertEqual(editorPublishes, 0)
    }
}

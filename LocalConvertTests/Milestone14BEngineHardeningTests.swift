import XCTest
import AVFoundation
import os
@testable import LocalConvert

final class Milestone14BEngineHardeningTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUp() async throws {
        continueAfterFailure = true
        sandbox = try TestSandbox(runID: "M14B-EngineHardening-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        OutputReservationCoordinator.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - 1. TargetSizeCompressionCoordinator Hardware Fallback Guard

    func testResolveHardwareFallbackEncoderChecksAvailabilityAndRejectsWebM() async {
        let mp4Available = await LiveTargetSizeVideoRunner.resolveHardwareFallbackEncoder(
            outputFormat: .mp4,
            isEncoderAvailable: { encoder in encoder == "libx264" }
        )
        XCTAssertEqual(mp4Available, "libx264")

        let mp4Unavailable = await LiveTargetSizeVideoRunner.resolveHardwareFallbackEncoder(
            outputFormat: .mp4,
            isEncoderAvailable: { _ in false }
        )
        XCTAssertNil(mp4Unavailable)

        let probeCalledForWebM = OSAllocatedUnfairLock(initialState: false)
        let webmResult = await LiveTargetSizeVideoRunner.resolveHardwareFallbackEncoder(
            outputFormat: .webm,
            isEncoderAvailable: { _ in
                probeCalledForWebM.withLock { $0 = true }
                return true
            }
        )
        XCTAssertNil(webmResult)
        XCTAssertFalse(probeCalledForWebM.withLock { $0 }, "WebM must not probe libx264 fallback")
    }

    func testLiveTargetSizeVideoRunnerDoesNotRetryLibx264WhenUnavailable() async throws {
        let binDir = sandbox.temporaryURL.appendingPathComponent("mock-ffmpeg-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let invocationLog = sandbox.temporaryURL.appendingPathComponent("ffmpeg-invocations.log")
        let fakeFFmpeg = binDir.appendingPathComponent("ffmpeg")
        let fakeFFprobe = binDir.appendingPathComponent("ffprobe")

        let ffmpegScript = """
        #!/bin/sh
        echo "$@" >> "\(invocationLog.path)"
        echo "Error initializing output stream 0:0 -- h264_videotoolbox: VTCompressionSessionCreate failed" 1>&2
        exit 1
        """
        let ffprobeScript = """
        #!/bin/sh
        exit 0
        """
        try ffmpegScript.write(to: fakeFFmpeg, atomically: true, encoding: .utf8)
        try ffprobeScript.write(to: fakeFFprobe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpeg.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFprobe.path)

        let inputFile = sandbox.temporaryURL.appendingPathComponent("input.mp4")
        let tempOut = sandbox.temporaryURL.appendingPathComponent("out.mp4")
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: inputFile)

        let provider = BundledFFmpegProvider(
            fallbackToSystem: false,
            enforceBundledOnly: false,
            environment: [
                "LOCALCONVERT_FFMPEG_PATH": fakeFFmpeg.path,
                "LOCALCONVERT_FFPROBE_PATH": fakeFFprobe.path
            ]
        )

        let checkedEncoders = OSAllocatedUnfairLock(initialState: [String]())
        let runner = LiveTargetSizeVideoRunner(
            provider: provider,
            encoderAvailabilityCheck: { encoder in
                checkedEncoders.withLock { $0.append(encoder) }
                return false
            }
        )

        do {
            try await runner.transcode(
                inputURL: inputFile,
                tempOutputURL: tempOut,
                outputFormat: .mp4,
                videoBitrateBps: 500_000,
                audioBitrateBps: 96_000,
                scaleMaxWidth: nil,
                progress: { _ in }
            )
            XCTFail("Expected ConversionError.engineExecutionFailed when libx264 is unavailable")
        } catch let error as ConversionError {
            guard case .engineExecutionFailed(let message, let underlying) = error else {
                XCTFail("Unexpected ConversionError case: \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("no software H.264 encoder is available"),
                "Unexpected error message: \(message)"
            )
            XCTAssertNotNil(underlying)
            XCTAssertTrue(underlying?.contains("h264_videotoolbox") == true || underlying?.contains("VTCompressionSessionCreate") == true)
        }

        XCTAssertEqual(checkedEncoders.withLock { $0 }, ["libx264"])
        let logged = try String(contentsOf: invocationLog, encoding: .utf8)
        let lines = logged.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 1, "Must not invoke ffmpeg a second time with libx264 when unavailable")
        XCTAssertFalse(logged.contains("libx264"))
    }

    // MARK: - 2. DuplicateFileScannerEngine Cancellation Propagation

    func testDuplicateScannerPropagatesTaskCancellation() async throws {
        let scanDir = sandbox.temporaryURL.appendingPathComponent("dup-cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)

        // Create two identical 512 KiB files so hashing phase runs
        let payload = Data(repeating: 0xAB, count: 512 * 1024)
        for idx in 0..<4 {
            let fileURL = scanDir.appendingPathComponent("file_\(idx).bin")
            try payload.write(to: fileURL)
        }

        let startedHashing = AsyncStream<Void>.makeStream()
        let task = Task {
            try await DuplicateFileScannerEngine.scan(
                directoryURL: scanDir,
                options: DuplicateScanOptions(chunkSize: 4096),
                progress: { prog in
                    if prog.candidateFilesToHash > 0 {
                        startedHashing.continuation.yield()
                    }
                }
            )
        }

        for await _ in startedHashing.stream {
            task.cancel()
            break
        }

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError when parent task is cancelled")
        } catch is CancellationError {
            // Expected
        }
    }

    func testDuplicateScannerSynchronouslyDoesNotSwallowCancellationError() async throws {
        let scanDir = sandbox.temporaryURL.appendingPathComponent("dup-sync-cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)

        let payload = Data(repeating: 0xCD, count: 64 * 1024)
        try payload.write(to: scanDir.appendingPathComponent("a.bin"))
        try payload.write(to: scanDir.appendingPathComponent("b.bin"))

        let task = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try DuplicateFileScannerEngine.scanSynchronously(directoryURL: scanDir)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError to propagate from scanSynchronously")
        } catch is CancellationError {
            // Expected
        }
    }

    // MARK: - 3. BatchFileRenamerEngine Overflow & Int.min Safety

    func testComputeSequentialNumberBoundsAndOverflowGuards() {
        XCTAssertEqual(
            BatchFileRenamerEngine.computeSequentialNumber(startIndex: 1, index: 4, step: 3),
            13
        )
        XCTAssertEqual(
            BatchFileRenamerEngine.computeSequentialNumber(startIndex: -10, index: 3, step: -5),
            -25
        )
        XCTAssertNil(
            BatchFileRenamerEngine.computeSequentialNumber(
                startIndex: BatchFileRenamerEngine.maxAbsoluteStartIndex + 1,
                index: 0,
                step: 1
            )
        )
        XCTAssertNil(
            BatchFileRenamerEngine.computeSequentialNumber(
                startIndex: -BatchFileRenamerEngine.maxAbsoluteStartIndex - 1,
                index: 0,
                step: 1
            )
        )
        XCTAssertNil(
            BatchFileRenamerEngine.computeSequentialNumber(
                startIndex: 1,
                index: 1,
                step: BatchFileRenamerEngine.maxAbsoluteStep + 1
            )
        )
        XCTAssertNil(
            BatchFileRenamerEngine.computeSequentialNumber(
                startIndex: 1,
                index: Int.max,
                step: 2
            )
        )
    }

    func testBatchRenamerPreviewMarksNumberingOverflowConflictWithoutTrapping() throws {
        let dir = sandbox.temporaryURL.appendingPathComponent("batch-overflow", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileA = dir.appendingPathComponent("photo_a.png")
        let fileB = dir.appendingPathComponent("photo_b.png")
        try Data([1, 2, 3]).write(to: fileA)
        try Data([4, 5, 6]).write(to: fileB)

        var rules = BatchRenameRules.default
        rules.includeNumbering = true
        rules.startIndex = BatchFileRenamerEngine.maxAbsoluteStartIndex + 1
        rules.step = 1

        let plan = BatchFileRenamerEngine.preview(urls: [fileA, fileB], rules: rules)
        XCTAssertTrue(plan.hasConflicts)
        XCTAssertEqual(plan.conflictCount, 2)
        for row in plan.rows {
            XCTAssertEqual(row.status, .conflict(.numberingOverflow))
        }
        XCTAssertEqual(
            BatchRenameConflictReason.numberingOverflow.localizedDescription,
            String(localized: "Sequential numbering value is out of range")
        )
        XCTAssertNil(BatchFileRenamerEngine.makeTransformedFilename(for: fileA, index: 0, rules: rules))
    }

    func testFormatSequentialNumberHandlesIntMinWithoutTrapOrPrecisionLoss() {
        XCTAssertEqual(
            BatchFileRenamerEngine.formatSequentialNumber(Int.min, paddingDigits: 3),
            "-\(Int.min.magnitude)"
        )
        XCTAssertEqual(BatchFileRenamerEngine.formatSequentialNumber(7, paddingDigits: 3), "007")
        XCTAssertEqual(BatchFileRenamerEngine.formatSequentialNumber(-7, paddingDigits: 3), "-007")
    }

    // MARK: - 4. ArchiveInspectorEngine Bounded Listing & Recursive Symlink Rejection

    func testArchiveInspectorListingEnforcesMaxListingBytesAndMaxEntries() async throws {
        let srcDir = sandbox.temporaryURL.appendingPathComponent("archive-src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        for idx in 0..<5 {
            let fileURL = srcDir.appendingPathComponent("sample_entry_\(idx).txt")
            try Data("hello \(idx)\n".utf8).write(to: fileURL)
        }

        let archiveURL = sandbox.temporaryURL.appendingPathComponent("sample.zip")
        let tarProc = Process()
        tarProc.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        tarProc.arguments = ["--format=zip", "-cf", archiveURL.path, "-C", srcDir.path] + (0..<5).map { "sample_entry_\($0).txt" }
        let out = try await AsyncProcessRunner.run(tarProc, stdin: .nullDevice, timeout: 15)
        XCTAssertEqual(out.terminationStatus, 0)

        // Normal listing succeeds
        let normalResult = try await ArchiveInspectorEngine.listEntries(in: archiveURL)
        XCTAssertGreaterThanOrEqual(normalResult.entries.count, 5)

        // Small maxListingBytes aborts immediately with invalidInput
        do {
            _ = try await ArchiveInspectorEngine.listEntries(
                in: archiveURL,
                maxListingBytes: 32
            )
            XCTFail("Expected ConversionError.invalidInput when listing exceeds maxListingBytes")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
        }

        // Small maxEntries aborts immediately with invalidInput
        do {
            _ = try await ArchiveInspectorEngine.listEntries(
                in: archiveURL,
                maxEntries: 2
            )
            XCTFail("Expected ConversionError.invalidInput when listing exceeds maxEntries")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
        }
    }

    func testValidateNoSymlinksRecursivelyRejectsNestedSymlinksAndCreateEncryptedZipBlocksThem() async throws {
        let rootDir = sandbox.temporaryURL.appendingPathComponent("enc-root", isDirectory: true)
        let nestedDir = rootDir.appendingPathComponent("level1/level2", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        let secretTarget = sandbox.temporaryURL.appendingPathComponent("outside-secret.txt")
        try Data("secret".utf8).write(to: secretTarget)

        let regularFile = nestedDir.appendingPathComponent("ok.txt")
        try Data("ok".utf8).write(to: regularFile)

        // Clean directory passes
        XCTAssertNoThrow(try ArchiveInspectorEngine.validateNoSymlinksRecursively(at: rootDir))

        // Add nested symlink at depth 2
        let nestedSymlink = nestedDir.appendingPathComponent("leak.txt")
        try FileManager.default.createSymbolicLink(at: nestedSymlink, withDestinationURL: secretTarget)

        XCTAssertThrowsError(try ArchiveInspectorEngine.validateNoSymlinksRecursively(at: rootDir)) { error in
            guard case ConversionError.invalidInput(let msg) = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("leak.txt"))
        }

        do {
            _ = try await ArchiveInspectorEngine.createEncryptedZip(
                inputs: [rootDir],
                outputDirectory: sandbox.outputsURL,
                archiveBaseName: "ShouldFail",
                password: "Password123!"
            )
            XCTFail("createEncryptedZip must reject directory containing nested symlink")
        } catch let error as ConversionError {
            guard case .invalidInput(let msg) = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("leak.txt"))
        }
    }

    // MARK: - 5. DiagnosticBundleExporter Concurrent Pipe Drain & Zip Export

    func testDiagnosticBundleExporterHandlesLargeLogsWithoutPipeDeadlock() async throws {
        let logsDir = sandbox.logsURL
        let bigLog = (0..<2500).map { idx in
            "2026-11-27T17:00:00Z [INFO] /Users/alice/Movies/clip_\(idx).mov token=secret_\(idx)"
        }.joined(separator: "\n")
        try bigLog.write(to: logsDir.appendingPathComponent("session.log"), atomically: true, encoding: .utf8)

        let exporter = DiagnosticBundleExporter(
            logsDirectoryOverride: logsDir,
            stagingParentDirectory: sandbox.temporaryURL,
            currentUsernameOverride: "alice"
        )
        let destURL = sandbox.outputsURL.appendingPathComponent("Diagnostics.zip")
        let result = try exporter.exportBundle(
            to: destURL,
            policy: .createUnique,
            additionalLogContents: "Extra /Users/alice/Desktop/notes.txt"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertGreaterThan(result.fileSizeBytes, 0)
        XCTAssertTrue(result.includedFiles.contains("system-summary.txt"))
        XCTAssertTrue(result.includedFiles.contains("logs-session.log"))
        XCTAssertTrue(result.includedFiles.contains("additional-notes.log"))

        let inspection = try await ArchiveInspectorEngine.listEntries(in: result.outputURL)
        XCTAssertTrue(inspection.entries.contains(where: { $0.path.hasSuffix("system-summary.txt") }))
        XCTAssertTrue(inspection.entries.contains(where: { $0.path.hasSuffix("logs-session.log") }))
    }

    // MARK: - 6. QuickVoiceRecorderService Async Permission & Toggle Flow

    @MainActor
    func testSystemVoiceRecordingBackendPermissionStates() async {
        let requestedCount = OSAllocatedUnfairLock(initialState: 0)

        let notDeterminedGrant = SystemVoiceRecordingBackend(
            authorizationStatusProvider: { .notDetermined },
            requestAccessHandler: {
                requestedCount.withLock { $0 += 1 }
                return true
            }
        )
        XCTAssertFalse(notDeterminedGrant.requestOrCheckPermission(), "Synchronous check must not treat .notDetermined as authorized")
        let asyncGranted = await notDeterminedGrant.requestOrCheckPermissionAsync()
        XCTAssertTrue(asyncGranted)
        XCTAssertEqual(requestedCount.withLock { $0 }, 1)

        let notDeterminedDeny = SystemVoiceRecordingBackend(
            authorizationStatusProvider: { .notDetermined },
            requestAccessHandler: { false }
        )
        let asyncDenied = await notDeterminedDeny.requestOrCheckPermissionAsync()
        XCTAssertFalse(asyncDenied)

        let deniedBackend = SystemVoiceRecordingBackend(
            authorizationStatusProvider: { .denied },
            requestAccessHandler: {
                XCTFail("requestAccessHandler must not be called when already denied")
                return true
            }
        )
        XCTAssertFalse(deniedBackend.requestOrCheckPermission())
        let deniedAsync = await deniedBackend.requestOrCheckPermissionAsync()
        XCTAssertFalse(deniedAsync)

        let authorizedBackend = SystemVoiceRecordingBackend(
            authorizationStatusProvider: { .authorized },
            requestAccessHandler: {
                XCTFail("requestAccessHandler must not be called when already authorized")
                return false
            }
        )
        XCTAssertTrue(authorizedBackend.requestOrCheckPermission())
        let authorizedAsync = await authorizedBackend.requestOrCheckPermissionAsync()
        XCTAssertTrue(authorizedAsync)
    }

    @MainActor
    func testQuickVoiceRecorderServiceStartRecordingAsyncAndLegacyBackendCompatibility() async throws {
        let dir = sandbox.documentsURL.appendingPathComponent("VoiceAsync", isDirectory: true)
        let legacyBackend = LegacySyncOnlyVoiceBackend(permissionGranted: true)
        let service = QuickVoiceRecorderService(backend: legacyBackend)

        try await service.startRecordingAsync(toDirectory: dir)
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(legacyBackend.startCount, 1)

        let recordedURL = try service.stopRecordingAndQueue()
        XCTAssertFalse(service.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordedURL.path))

        let deniedService = QuickVoiceRecorderService(backend: LegacySyncOnlyVoiceBackend(permissionGranted: false))
        do {
            try await deniedService.startRecordingAsync(toDirectory: dir)
            XCTFail("Expected VoiceRecordingError.permissionDenied")
        } catch let error as VoiceRecordingError {
            XCTAssertEqual(error, .permissionDenied)
        }
        XCTAssertFalse(deniedService.isRecording)

        let toggleBackend = LegacySyncOnlyVoiceBackend(permissionGranted: true)
        let toggleService = QuickVoiceRecorderService(backend: toggleBackend)
        toggleService.toggleRecording()
        for _ in 0..<50 where !toggleService.isRecording {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(toggleService.isRecording)
        toggleService.toggleRecording()
        XCTAssertFalse(toggleService.isRecording)
        XCTAssertNotNil(toggleService.lastRecordedFileURL)
    }
}

@MainActor
private final class LegacySyncOnlyVoiceBackend: VoiceRecordingBackend {
    let permissionGranted: Bool
    private(set) var startCount: Int = 0

    init(permissionGranted: Bool) {
        self.permissionGranted = permissionGranted
    }

    func requestOrCheckPermission() -> Bool {
        permissionGranted
    }

    func startRecording(to tempURL: URL) throws {
        startCount += 1
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20]).write(to: tempURL)
    }

    func stopRecording() throws {}

    func cancelRecording() {}
}

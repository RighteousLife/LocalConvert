import XCTest
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin
@testable import LocalConvert

final class Milestone1ACoreInfrastructureTests: XCTestCase {

    private struct MockVolumeCapacityProvider: VolumeCapacityProviding {
        let capacitiesByPathPrefix: [(prefix: String, bytes: Int64?)]

        func availableCapacityBytes(for url: URL) -> Int64? {
            let stdPath = url.standardizedFileURL.path
            for entry in capacitiesByPathPrefix where stdPath == entry.prefix || stdPath.hasPrefix(entry.prefix + "/") {
                return entry.bytes
            }
            return nil
        }
    }

    private func makeTempDir(prefix: String = "M1A") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeTinyPNG(to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 200, count: 16 * 16 * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "M1ATests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: - LC-001: Atomic Commit & Late-Cancellation Overwrite Protection

    func testAtomicReplaceSameVolumeOverwritesAndPreservesNewPayload() throws {
        let dir = try makeTempDir(prefix: "LC001-SameVol")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tempFile = dir.appendingPathComponent("staged.txt")
        let destFile = dir.appendingPathComponent("output.txt")
        try Data("original-content".utf8).write(to: destFile)
        try Data("replacement-content".utf8).write(to: tempFile)

        let resultURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempFile,
            to: destFile,
            policy: .overwrite
        )
        XCTAssertEqual(resultURL.standardizedFileURL, destFile.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: destFile, encoding: .utf8), "replacement-content")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(siblings.contains { $0.contains(".stage-") || $0.contains(".bak-") })
    }

    func testAtomicReplaceSimulatedCrossVolumeFailurePerformsBackupRollbackWithoutDataLoss() throws {
        let srcDir = try makeTempDir(prefix: "LC001-Src")
        let dstDir = try makeTempDir(prefix: "LC001-Dst")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dstDir)
        }

        let tempFile = srcDir.appendingPathComponent("temp_out.dat")
        let destFile = dstDir.appendingPathComponent("existing.dat")
        let originalBytes = Data("CRITICAL-USER-DATA-MUST-SURVIVE".utf8)
        let newBytes = Data("new-replacement-payload".utf8)
        try originalBytes.write(to: destFile)
        try newBytes.write(to: tempFile)
        let originalSHA = try sha256Hex(of: destFile)

        // Case 1: Simulated cross-volume where replaceItemAt fails -> falls back to backup-then-move cleanly
        let crossVolSuccessOps = OutputReservationCoordinator.AtomicPublishFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            isSameVolume: { _, _ in false },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            replaceItemAt: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )

        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempFile,
            to: destFile,
            policy: .overwrite,
            operations: crossVolSuccessOps
        )
        XCTAssertEqual(try Data(contentsOf: destFile), newBytes)

        // Restore original bytes & new temp file to test double failure rollback
        try originalBytes.write(to: destFile)
        try newBytes.write(to: tempFile)

        let simulatedWriteError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        let rollbackOps = OutputReservationCoordinator.AtomicPublishFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            isSameVolume: { _, _ in false },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { src, dst in
                // Allow moving dest -> .bak and restoring .bak -> dest, but fail moving .stage -> dest
                if src.lastPathComponent.contains(".stage-") {
                    throw simulatedWriteError
                }
                try FileManager.default.moveItem(at: src, to: dst)
            },
            replaceItemAt: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )

        XCTAssertThrowsError(
            try OutputReservationCoordinator.moveOrReplaceTempFile(
                tempFile,
                to: destFile,
                policy: .overwrite,
                operations: rollbackOps
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destFile.path))
        XCTAssertEqual(try sha256Hex(of: destFile), originalSHA, "Existing destination file must be restored byte-for-byte on write failure")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dstDir.path)
        XCTAssertEqual(leftovers, ["existing.dat"], "No hidden .stage- or .bak- files may remain after rollback")
    }

    func testAtomicReplaceThrowsOutputExistsUnderCreateUniqueOrSkip() throws {
        let dir = try makeTempDir(prefix: "LC001-Policy")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tempFile = dir.appendingPathComponent("temp.txt")
        let destFile = dir.appendingPathComponent("existing.txt")
        try Data("keep-me".utf8).write(to: destFile)
        try Data("new".utf8).write(to: tempFile)

        for policy in [ExistingFileHandling.createUnique, .skip] {
            XCTAssertThrowsError(
                try OutputReservationCoordinator.moveOrReplaceTempFile(tempFile, to: destFile, policy: policy)
            ) { error in
                XCTAssertEqual(error as? ConversionError, .outputFileAlreadyExists(destFile))
            }
            XCTAssertEqual(try String(contentsOf: destFile, encoding: .utf8), "keep-me")
        }
    }

    @MainActor
    func testLateCancellationUnderOverwriteDoesNotDeleteCommittedDestination() async throws {
        let sandbox = try TestSandbox(runID: "M1A-LateCancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox.rootURL) }

        let src = sandbox.documentsURL.appendingPathComponent("source.png")
        let committedOut = sandbox.outputsURL.appendingPathComponent("source.jpg")
        try Data("src".utf8).write(to: src)
        try Data("committed-overwrite-output".utf8).write(to: committedOut)

        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let manager = ConversionManager(registry: .shared, historyManager: history)

        let overwriteJob = ConversionJob(
            inputURLs: [src],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: sandbox.outputsURL,
            options: ConversionOptions(overwriteExisting: true)
        )
        manager.cleanupLateCancelledOutputs(for: overwriteJob, urls: [committedOut])
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedOut.path), ".overwrite committed file must not be deleted on late cancellation")

        let uniqueOut = sandbox.outputsURL.appendingPathComponent("source (1).jpg")
        try Data("new-unique".utf8).write(to: uniqueOut)
        let uniqueJob = ConversionJob(
            inputURLs: [src],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: sandbox.outputsURL,
            options: ConversionOptions(overwriteExisting: false)
        )
        manager.cleanupLateCancelledOutputs(for: uniqueJob, urls: [uniqueOut])
        XCTAssertFalse(FileManager.default.fileExists(atPath: uniqueOut.path), "Non-overwrite unique output should be cleaned on late cancellation")
    }

    // MARK: - LC-005: Shared Disk Space Guard

    @MainActor
    func testDiskSpaceGuardRejectsInsufficientSpacePreFlightWithoutStrayTempFiles() async throws {
        let sandbox = try TestSandbox(runID: "M1A-DiskSpace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox.rootURL) }

        if ConversionRegistry.shared.registeredEngines.isEmpty {
            ConversionRegistry.shared.register(engine: ImageConversionEngine())
        }

        let inputURL = sandbox.documentsURL.appendingPathComponent("tiny.png")
        try writeTinyPNG(to: inputURL)

        let tempStaging = sandbox.temporaryURL
        let outDir = sandbox.outputsURL

        // Mock tiny available space on output volume while staging is large
        let mockProvider = MockVolumeCapacityProvider(capacitiesByPathPrefix: [
            (prefix: outDir.standardizedFileURL.path, bytes: 1_024),
            (prefix: tempStaging.standardizedFileURL.path, bytes: 100_000_000_000)
        ])
        let guardUnderTest = DiskSpaceGuard(
            capacityProvider: mockProvider,
            minimumFreeBufferBytes: 64 * 1024 * 1024
        )

        XCTAssertThrowsError(
            try guardUnderTest.validateSufficientSpace(
                stagingDirectory: tempStaging,
                outputDirectory: outDir,
                inputURLs: [inputURL],
                outputFormat: .jpg
            )
        ) { error in
            XCTAssertEqual(error as? ConversionError, .insufficientDiskSpace)
        }

        // Verify sufficient space passes cleanly
        let okProvider = MockVolumeCapacityProvider(capacitiesByPathPrefix: [
            (prefix: outDir.standardizedFileURL.path, bytes: 100_000_000_000),
            (prefix: tempStaging.standardizedFileURL.path, bytes: 100_000_000_000)
        ])
        let passingGuard = DiskSpaceGuard(capacityProvider: okProvider)
        try passingGuard.validateSufficientSpace(
            stagingDirectory: tempStaging,
            outputDirectory: outDir,
            inputURLs: [inputURL],
            outputFormat: .jpg
        )

        // Wire into ConversionManager and confirm pre-flight failure + zero output/temp artifacts
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let manager = ConversionManager(
            registry: .shared,
            historyManager: history,
            diskSpaceGuard: guardUnderTest
        )
        let job = ConversionJob(
            inputURLs: [inputURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: outDir
        )

        let tempBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])

        let done = expectation(description: "DiskSpace insufficient completion")
        var observedStatus: ConversionJobStatus?
        manager.submit(job: job) { status in
            observedStatus = status
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5.0)

        XCTAssertEqual(observedStatus, .failed(.insufficientDiskSpace))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outDir.path), [])
        let tempAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        let newLocalConvertTempItems = tempAfter.subtracting(tempBefore).filter { $0.hasPrefix("LocalConvert-") }
        XCTAssertTrue(newLocalConvertTempItems.isEmpty, "Zero stray LocalConvert temp items allowed after pre-flight rejection")
    }

    // MARK: - LC-006: AsyncProcessRunner Timeout, Cancellation & SIGKILL Tree Escalation

    func testAsyncProcessRunnerTimeoutThrowsProcessTimeoutError() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]

        do {
            _ = try await AsyncProcessRunner.run(
                proc,
                stdin: .nullDevice,
                timeout: 0.25,
                terminationGraceSeconds: 0.2
            )
            XCTFail("Expected ProcessTimeoutError")
        } catch let err as ProcessTimeoutError {
            XCTAssertEqual(err.timeoutSeconds, 0.25, accuracy: 0.001)
        }
    }

    func testAsyncProcessRunnerCancellationTerminatesProcessPromptly() async throws {
        let task = Task {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
            proc.arguments = ["30"]
            return try await AsyncProcessRunner.run(
                proc,
                stdin: .nullDevice,
                timeout: 30,
                terminationGraceSeconds: 0.2
            )
        }

        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    func testAsyncProcessRunnerEscalatesToSIGKILLForSigTermIgnoringParentAndChild() async throws {
        let dir = try makeTempDir(prefix: "LC006-KillTree")
        defer { try? FileManager.default.removeItem(at: dir) }

        let parentPIDFile = dir.appendingPathComponent("parent.pid")
        let childPIDFile = dir.appendingPathComponent("child.pid")
        let scriptFile = dir.appendingPathComponent("stubborn.sh")

        // Trap and ignore SIGTERM; spawn a background child sleep that also ignores SIGTERM
        let script = """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(parentPIDFile.path)"
        /bin/sh -c "trap '' TERM; exec /bin/sleep 30" &
        CHILD_PID=$!
        echo "$CHILD_PID" > "\(childPIDFile.path)"
        wait "$CHILD_PID"
        """
        try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scriptFile.path]

        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await AsyncProcessRunner.run(
                proc,
                stdin: .nullDevice,
                timeout: 0.65,
                terminationGraceSeconds: 0.25
            )
            XCTFail("Expected ProcessTimeoutError after escalation")
        } catch is ProcessTimeoutError {
            // Expected
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 4.0, "SIGKILL escalation should terminate stubborn process tree quickly")

        let parentPIDStr = try String(contentsOf: parentPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let childPIDStr = try String(contentsOf: childPIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let parentPID = try XCTUnwrap(pid_t(parentPIDStr))
        let childPID = try XCTUnwrap(pid_t(childPIDStr))

        // Give kernel brief scheduling beat to reap exited child PIDs
        for _ in 0..<20 {
            let pAlive = kill(parentPID, 0) == 0 || errno != ESRCH
            let cAlive = kill(childPID, 0) == 0 || errno != ESRCH
            if !pAlive && !cAlive { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(kill(parentPID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Parent PID \(parentPID) must be completely terminated (no orphan)")
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Child PID \(childPID) must be completely terminated (no orphan)")
    }

    func testMediaProbeHonorsCustomTimeoutOnHungExecutable() async throws {
        let dir = try makeTempDir(prefix: "LC006-ProbeTimeout")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dummyMedia = dir.appendingPathComponent("dummy.wav")
        try Data("RIFF".utf8).write(to: dummyMedia)

        let fakeFFprobe = dir.appendingPathComponent("fake_ffprobe.sh")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: fakeFFprobe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFprobe.path)

        do {
            _ = try await MediaProbe.probe(url: dummyMedia, ffprobePath: fakeFFprobe.path, timeout: 0.25)
            XCTFail("Expected ConversionError wrapping timeout")
        } catch let err as ConversionError {
            guard case .engineExecutionFailed(let message, _) = err else {
                XCTFail("Unexpected ConversionError case: \(err)")
                return
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("timed out"))
        }
    }
}

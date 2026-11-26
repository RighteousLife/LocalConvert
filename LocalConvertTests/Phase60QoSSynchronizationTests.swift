import XCTest
import AVFoundation
import CryptoKit
@testable import LocalConvert

final class Phase60QoSSynchronizationTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "Phase60-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    @MainActor
    func testValidSyntheticMP4CreationAndPlayability() async throws {
        let outputURL = sandbox.temporaryURL.appendingPathComponent("valid_fixture.mp4")
        let producedURL = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: outputURL, timeout: .seconds(15))
        XCTAssertEqual(producedURL.standardizedFileURL, outputURL.standardizedFileURL)

        let dataBefore = try Data(contentsOf: producedURL)
        XCTAssertGreaterThan(dataBefore.count, 0, "Generated MP4 must be non-empty")

        let asset = AVURLAsset(url: producedURL)
        let isPlayable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        XCTAssertTrue(isPlayable, "Generated MP4 must be playable by AVURLAsset")
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.5, "15 frames @ 15fps should have ~1.0s duration")
        XCTAssertEqual(tracks.count, 1, "Generated MP4 must contain 1 video track")

        // Verify file remains stable and unmodified after completion (no delayed writer touches)
        try await Task.sleep(for: .milliseconds(100))
        let dataAfter = try Data(contentsOf: producedURL)
        XCTAssertEqual(SHA256.hash(data: dataBefore), SHA256.hash(data: dataAfter), "Finalized MP4 must remain stable after completion")
    }

    func testInvalidDestinationPropagatesClearError() async {
        let invalidURL = sandbox.temporaryURL
            .appendingPathComponent("nonexistent_dir_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("bad_fixture.mp4")

        do {
            _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: invalidURL, timeout: .seconds(5))
            XCTFail("Expected writeSyntheticMP4 to fail for missing parent directory")
        } catch is CancellationError {
            XCTFail("Expected explicit writer error rather than CancellationError")
        } catch let error as SyntheticMP4FixtureError {
            if case .timedOut = error {
                XCTFail("Expected immediate failure rather than timeout for missing directory")
            }
            // Expected explicit error case
        } catch {
            // AVAssetWriter/Cocoa error for invalid destination is also acceptable and explicit
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testInvalidConfigurationThrowsError() async {
        let url = sandbox.temporaryURL.appendingPathComponent("invalid_config.mp4")
        do {
            _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(
                to: url,
                width: 0,
                height: 64,
                frameCount: 15,
                fps: 15
            )
            XCTFail("Expected invalidConfiguration error")
        } catch let error as SyntheticMP4FixtureError {
            if case .invalidConfiguration = error {
                // expected
            } else {
                XCTFail("Unexpected SyntheticMP4FixtureError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testTimeoutCancelsWorkAndThrowsTimedOut() async {
        let url = sandbox.temporaryURL.appendingPathComponent("timed_out_fixture.mp4")
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(
                to: url,
                width: 128,
                height: 128,
                frameCount: 3000,
                fps: 30,
                timeout: .milliseconds(10)
            )
            XCTFail("Expected timeout error for 10ms limit with 3000 frames")
        } catch let error as SyntheticMP4FixtureError {
            guard case .timedOut = error else {
                XCTFail("Expected .timedOut, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected SyntheticMP4FixtureError.timedOut, got \(error)")
        }

        let elapsed = start.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(5), "Timeout must abort promptly without waiting for 3000 frames")
    }

    func testCancellationStopsBackgroundWorkCleanly() async throws {
        let url = sandbox.temporaryURL.appendingPathComponent("cancelled_fixture.mp4")
        let task = Task {
            try await SyntheticMP4FixtureWriter.writeSyntheticMP4(
                to: url,
                width: 128,
                height: 128,
                frameCount: 3000,
                fps: 30,
                timeout: .seconds(15)
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("Cancelled synthetic MP4 task must not succeed")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }

        // Allow serial writerQueue cleanup block to remove any partial artifact
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Cancelled write must clean up partial output file")
    }

    func testOnceContinuationGateProcessesDuplicateCompletionsOnlyOnce() async throws {
        let gate = OnceContinuationGate<Int>()
        var firstAccepted = false
        var secondAccepted = true
        var thirdAccepted = true

        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            gate.attach(continuation)
            firstAccepted = gate.complete(with: .success(42))
            secondAccepted = gate.complete(with: .success(99))
            thirdAccepted = gate.complete(with: .failure(SyntheticMP4FixtureError.notPlayable))
        }

        XCTAssertEqual(value, 42)
        XCTAssertTrue(firstAccepted)
        XCTAssertFalse(secondAccepted)
        XCTAssertFalse(thirdAccepted)
        XCTAssertTrue(gate.isCompleted)
        XCTAssertEqual(gate.attemptCount, 3)

        // Pre-completion before attach (early cancellation / race) must also resolve once on attach
        let preGate = OnceContinuationGate<String>()
        XCTAssertTrue(preGate.complete(with: .success("first")))
        XCTAssertFalse(preGate.complete(with: .success("duplicate")))
        let resolved = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            preGate.attach(continuation)
        }
        XCTAssertEqual(resolved, "first")
        XCTAssertEqual(preGate.attemptCount, 2)
    }
}

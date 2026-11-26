import Foundation
import AVFoundation
import CoreVideo
import os

enum SyntheticMP4FixtureError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case cannotAddInput
    case startWritingFailed(String)
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed(Int32)
    case appendFailed(frame: Int, reason: String)
    case writerFailed(status: Int, reason: String)
    case emptyOutputFile
    case notPlayable
    case timedOut(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg): return "Invalid synthetic MP4 configuration: \(msg)"
        case .cannotAddInput: return "Cannot add AVAssetWriterInput"
        case .startWritingFailed(let msg): return "AVAssetWriter.startWriting failed: \(msg)"
        case .pixelBufferPoolUnavailable: return "AVAssetWriterInputPixelBufferAdaptor pixelBufferPool unavailable"
        case .pixelBufferCreationFailed(let status): return "CVPixelBufferPoolCreatePixelBuffer failed with status \(status)"
        case .appendFailed(let frame, let reason): return "Failed to append video frame \(frame): \(reason)"
        case .writerFailed(let status, let reason): return "AVAssetWriter finished with status \(status): \(reason)"
        case .emptyOutputFile: return "Synthetic MP4 fixture is empty"
        case .notPlayable: return "Synthetic MP4 fixture is not playable"
        case .timedOut(let seconds): return "Synthetic MP4 fixture generation timed out after \(seconds)s"
        }
    }
}

/// Thread-safe once-only completion gate ensuring a checked continuation is resumed at most once
/// even under concurrent completion, cancellation, or timeout races.
final class OnceContinuationGate<T: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var pendingResult: Result<T, Error>?
        var isCompleted: Bool = false
        var attemptCount: Int = 0
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    var attemptCount: Int {
        lock.withLock { $0.attemptCount }
    }

    var isCompleted: Bool {
        lock.withLock { $0.isCompleted }
    }

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        let immediate: Result<T, Error>? = lock.withLock { state in
            if let pending = state.pendingResult {
                state.pendingResult = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let immediate {
            continuation.resume(with: immediate)
        }
    }

    @discardableResult
    func complete(with result: Result<T, Error>) -> Bool {
        let outcome: (accepted: Bool, continuation: CheckedContinuation<T, Error>?) = lock.withLock { state in
            state.attemptCount += 1
            guard !state.isCompleted else {
                return (false, nil)
            }
            state.isCompleted = true
            if let cont = state.continuation {
                state.continuation = nil
                return (true, cont)
            } else {
                state.pendingResult = result
                return (true, nil)
            }
        }
        outcome.continuation?.resume(with: result)
        return outcome.accepted
    }
}

/// Async, QoS-safe synthetic H.264 MP4 fixture generator for tests.
/// Eliminates `DispatchSemaphore.wait()` and `Task.detached` priority inversions while preserving
/// strict timeouts, cancellation cleanup, once-only completion, and `AVURLAsset.load(.isPlayable)` verification.
enum SyntheticMP4FixtureWriter {

    private final class WriteSession: @unchecked Sendable {
        private let url: URL
        private let width: Int
        private let height: Int
        private let frameCount: Int
        private let fps: Int32
        private let writerQueue: DispatchQueue
        private let gate = OnceContinuationGate<Void>()
        private let cancelLock = OSAllocatedUnfairLock<Bool>(initialState: false)

        // Confined strictly to serial `writerQueue`:
        private var isFinishing: Bool = false
        private var nextFrameIndex: Int = 0
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

        init(url: URL, width: Int, height: Int, frameCount: Int, fps: Int32) {
            self.url = url
            self.width = width
            self.height = height
            self.frameCount = frameCount
            self.fps = fps
            self.writerQueue = DispatchQueue(
                label: "com.localconvert.test.mp4writer.\(UUID().uuidString.prefix(8))",
                qos: .userInitiated
            )
        }

        func run() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    gate.attach(continuation)
                    writerQueue.async { [self] in
                        startWritingOnQueue()
                    }
                }
            } onCancel: { [self] in
                cancel()
            }
        }

        func cancel() {
            let shouldCancel = cancelLock.withLock { cancelled -> Bool in
                guard !cancelled else { return false }
                cancelled = true
                return true
            }
            if shouldCancel {
                gate.complete(with: .failure(CancellationError()))
                writerQueue.async { [self] in
                    abortOnQueue(with: CancellationError())
                }
            }
        }

        private func startWritingOnQueue() {
            guard !isCancelled else {
                finish(with: .failure(CancellationError()))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }

                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let settings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = false

                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height
                    ]
                )

                guard writer.canAdd(input) else {
                    throw SyntheticMP4FixtureError.cannotAddInput
                }
                writer.add(input)

                guard writer.startWriting() else {
                    let msg = writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)"
                    throw SyntheticMP4FixtureError.startWritingFailed(msg)
                }
                writer.startSession(atSourceTime: .zero)

                self.writer = writer
                self.input = input
                self.adaptor = adaptor

                input.requestMediaDataWhenReady(on: writerQueue) { [self] in
                    pumpFramesOnQueue()
                }
            } catch {
                finish(with: .failure(error))
            }
        }

        private func pumpFramesOnQueue() {
            if isCancelled {
                abortOnQueue(with: CancellationError())
                return
            }

            guard !isFinishing, let writer, let input, let adaptor else {
                return
            }

            while input.isReadyForMoreMediaData {
                if isCancelled {
                    abortOnQueue(with: CancellationError())
                    return
                }

                if nextFrameIndex >= frameCount {
                    beginFinishOnQueue(writer: writer, input: input)
                    return
                }

                guard let pool = adaptor.pixelBufferPool else {
                    abortOnQueue(with: SyntheticMP4FixtureError.pixelBufferPoolUnavailable)
                    return
                }

                var pbOpt: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt)
                guard status == kCVReturnSuccess, let pb = pbOpt else {
                    abortOnQueue(with: SyntheticMP4FixtureError.pixelBufferCreationFailed(status))
                    return
                }

                CVPixelBufferLockBaseAddress(pb, [])
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    memset(base, 128, CVPixelBufferGetDataSize(pb))
                }
                CVPixelBufferUnlockBaseAddress(pb, [])

                let pts = CMTime(value: Int64(nextFrameIndex), timescale: fps)
                guard adaptor.append(pb, withPresentationTime: pts) else {
                    let reason = writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
                    abortOnQueue(with: SyntheticMP4FixtureError.appendFailed(frame: nextFrameIndex, reason: reason))
                    return
                }

                nextFrameIndex += 1
            }
        }

        private func beginFinishOnQueue(writer: AVAssetWriter, input: AVAssetWriterInput) {
            guard !isFinishing else { return }
            isFinishing = true

            input.markAsFinished()
            writer.finishWriting { [self] in
                writerQueue.async { [self] in
                    handleFinishWritingCompletion()
                }
            }
        }

        private func handleFinishWritingCompletion() {
            let activeWriter = self.writer
            self.writer = nil
            self.input = nil
            self.adaptor = nil

            if isCancelled {
                try? FileManager.default.removeItem(at: url)
                finish(with: .failure(CancellationError()))
                return
            }

            guard let activeWriter else {
                finish(with: .failure(CancellationError()))
                return
            }

            if activeWriter.status == .completed {
                finish(with: .success(()))
            } else {
                try? FileManager.default.removeItem(at: url)
                let reason = activeWriter.error?.localizedDescription ?? "unknown error"
                finish(with: .failure(SyntheticMP4FixtureError.writerFailed(status: activeWriter.status.rawValue, reason: reason)))
            }
        }

        private func abortOnQueue(with error: Error) {
            isFinishing = true
            let activeWriter = self.writer
            let activeInput = self.input
            self.writer = nil
            self.input = nil
            self.adaptor = nil

            if let activeInput, activeWriter?.status == .writing {
                activeInput.markAsFinished()
            }
            if let activeWriter, activeWriter.status == .writing {
                activeWriter.cancelWriting()
            }
            try? FileManager.default.removeItem(at: url)
            finish(with: .failure(error))
        }

        private var isCancelled: Bool {
            cancelLock.withLock { $0 }
        }

        private func finish(with result: Result<Void, Error>) {
            gate.complete(with: result)
        }
    }

    static func writeSyntheticMP4(
        to url: URL,
        width: Int = 64,
        height: Int = 64,
        frameCount: Int = 15,
        fps: Int32 = 15,
        timeout: Duration = .seconds(15),
        verifyPlayability: Bool = true
    ) async throws -> URL {
        guard width > 0, height > 0, frameCount > 0, fps > 0 else {
            throw SyntheticMP4FixtureError.invalidConfiguration("Dimensions, frameCount, and fps must be positive")
        }
        guard timeout > .zero else {
            throw SyntheticMP4FixtureError.timedOut(seconds: 0)
        }

        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                let session = WriteSession(url: url, width: width, height: height, frameCount: frameCount, fps: fps)
                try await session.run()
                try Task.checkCancellation()

                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                guard fileSize > 0 else {
                    throw SyntheticMP4FixtureError.emptyOutputFile
                }

                if verifyPlayability {
                    let asset = AVURLAsset(url: url)
                    let isPlayable = try await asset.load(.isPlayable)
                    try Task.checkCancellation()
                    guard isPlayable else {
                        throw SyntheticMP4FixtureError.notPlayable
                    }
                }

                return url
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw SyntheticMP4FixtureError.timedOut(seconds: timeoutSeconds)
            }

            do {
                guard let firstResult = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return firstResult
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

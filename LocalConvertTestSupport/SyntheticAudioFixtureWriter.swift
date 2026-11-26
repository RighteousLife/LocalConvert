import Foundation
import AVFoundation
import os

enum SyntheticAudioFixtureFormat: String, Sendable, CaseIterable {
    case wav
    case aiff
    case alac
    case flac
    case ape // Intentionally unsupported for encode verification
}

enum SyntheticAudioFixtureError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case unsupportedFormat(String)
    case encoderUnavailable(String)
    case encodingFailed(String)
    case emptyOutputFile
    case timedOut(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg): return "Invalid synthetic audio fixture configuration: \(msg)"
        case .unsupportedFormat(let fmt): return "Unsupported synthetic audio fixture format: \(fmt)"
        case .encoderUnavailable(let name): return "Required encoder binary unavailable: \(name)"
        case .encodingFailed(let msg): return "Synthetic audio fixture encoding failed: \(msg)"
        case .emptyOutputFile: return "Generated synthetic audio fixture file is empty"
        case .timedOut(let seconds): return "Synthetic audio fixture generation timed out after \(seconds)s"
        }
    }
}

/// Async, QoS-safe, deterministic synthetic audio fixture generator for `LocalConvertTests` and
/// `LocalConvertUITests`. Never uses `DispatchSemaphore.wait()`, `Thread.sleep()`, or `Task.detached`.
enum SyntheticAudioFixtureWriter {

    struct Spec: Sendable, Equatable {
        var format: SyntheticAudioFixtureFormat
        var sampleRate: Int
        var channelCount: Int
        var bitDepth: Int
        var frameCount: Int64
        var frequencyHz: Double
        var amplitude: Double

        init(
            format: SyntheticAudioFixtureFormat,
            sampleRate: Int = 48_000,
            channelCount: Int = 2,
            bitDepth: Int = 16,
            frameCount: Int64 = 4_800,
            frequencyHz: Double = 440.0,
            amplitude: Double = 0.25
        ) {
            self.format = format
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitDepth = bitDepth
            self.frameCount = frameCount
            self.frequencyHz = frequencyHz
            self.amplitude = amplitude
        }
    }

    static func writeAudioFixture(
        to url: URL,
        spec: Spec,
        timeout: Duration = .seconds(20)
    ) async throws -> URL {
        try validateSpec(spec)
        guard timeout > .zero else {
            throw SyntheticAudioFixtureError.timedOut(seconds: 0)
        }

        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await performWrite(to: url, spec: spec)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SyntheticAudioFixtureError.timedOut(seconds: timeoutSeconds)
            }

            do {
                guard let produced = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return produced
            } catch {
                group.cancelAll()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    // MARK: - Validation & Generation

    private static func validateSpec(_ spec: Spec) throws {
        guard spec.format != .ape else {
            throw SyntheticAudioFixtureError.unsupportedFormat(spec.format.rawValue)
        }
        guard (1...768_000).contains(spec.sampleRate) else {
            throw SyntheticAudioFixtureError.invalidConfiguration("Sample rate \(spec.sampleRate) outside 1...768000 Hz")
        }
        guard (1...8).contains(spec.channelCount) else {
            throw SyntheticAudioFixtureError.invalidConfiguration("Channel count \(spec.channelCount) outside 1...8")
        }
        guard spec.frameCount > 0 else {
            throw SyntheticAudioFixtureError.invalidConfiguration("Frame count must be positive")
        }
        guard spec.amplitude.isFinite && spec.amplitude >= 0.0 && spec.amplitude <= 1.0 else {
            throw SyntheticAudioFixtureError.invalidConfiguration("Amplitude must be within 0.0...1.0")
        }
        guard spec.frequencyHz.isFinite && spec.frequencyHz >= 0.0 else {
            throw SyntheticAudioFixtureError.invalidConfiguration("Frequency must be non-negative")
        }
        switch spec.format {
        case .wav:
            guard [16, 24, 32].contains(spec.bitDepth) else {
                throw SyntheticAudioFixtureError.invalidConfiguration("WAV bit depth must be 16, 24, or 32 (float)")
            }
        case .aiff:
            guard [16, 24].contains(spec.bitDepth) else {
                throw SyntheticAudioFixtureError.invalidConfiguration("AIFF bit depth must be 16 or 24")
            }
        case .alac, .flac:
            guard [16, 24].contains(spec.bitDepth) else {
                throw SyntheticAudioFixtureError.invalidConfiguration("\(spec.format.rawValue.uppercased()) bit depth must be 16 or 24")
            }
        case .ape:
            throw SyntheticAudioFixtureError.unsupportedFormat(spec.format.rawValue)
        }
    }

    private static func performWrite(to url: URL, spec: Spec) async throws -> URL {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let stagingURL = parent.appendingPathComponent(".\(url.lastPathComponent).stage-\(UUID().uuidString).\(url.pathExtension.isEmpty ? spec.format.rawValue : url.pathExtension)")
        let intermediateWAV = parent.appendingPathComponent(".\(url.lastPathComponent).pcm-\(UUID().uuidString).wav")

        defer {
            try? fm.removeItem(at: stagingURL)
            try? fm.removeItem(at: intermediateWAV)
        }

        try Task.checkCancellation()

        switch spec.format {
        case .wav, .aiff:
            try writePCMFile(to: stagingURL, format: spec.format, spec: spec)
        case .alac:
            let pcmSpec = Spec(
                format: .wav,
                sampleRate: spec.sampleRate,
                channelCount: spec.channelCount,
                bitDepth: spec.bitDepth,
                frameCount: spec.frameCount,
                frequencyHz: spec.frequencyHz,
                amplitude: spec.amplitude
            )
            try writePCMFile(to: intermediateWAV, format: .wav, spec: pcmSpec)
            try await encodeWithBundledFFmpeg(
                inputWAV: intermediateWAV,
                outputURL: stagingURL,
                codecArgs: ["-c:a", "alac", "-map_metadata", "-1", "-fflags", "+bitexact"]
            )
        case .flac:
            let pcmSpec = Spec(
                format: .wav,
                sampleRate: spec.sampleRate,
                channelCount: spec.channelCount,
                bitDepth: spec.bitDepth,
                frameCount: spec.frameCount,
                frequencyHz: spec.frequencyHz,
                amplitude: spec.amplitude
            )
            try writePCMFile(to: intermediateWAV, format: .wav, spec: pcmSpec)
            let sampleFmt = spec.bitDepth == 16 ? "s16" : "s32"
            try await encodeWithBundledFFmpeg(
                inputWAV: intermediateWAV,
                outputURL: stagingURL,
                codecArgs: ["-c:a", "flac", "-sample_fmt", sampleFmt, "-map_metadata", "-1", "-fflags", "+bitexact"]
            )
        case .ape:
            throw SyntheticAudioFixtureError.unsupportedFormat(spec.format.rawValue)
        }

        try Task.checkCancellation()

        let attrs = try fm.attributesOfItem(atPath: stagingURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw SyntheticAudioFixtureError.emptyOutputFile
        }

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: url)
        }
        return url
    }

    private static func writePCMFile(
        to destination: URL,
        format: SyntheticAudioFixtureFormat,
        spec: Spec
    ) throws {
        let isFloat = (format == .wav && spec.bitDepth == 32)
        let isBigEndian = (format == .aiff)
        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(spec.sampleRate),
            channels: AVAudioChannelCount(spec.channelCount),
            interleaved: false
        ) else {
            throw SyntheticAudioFixtureError.invalidConfiguration("Unsupported AVAudioFormat for \(spec.sampleRate) Hz / \(spec.channelCount) ch")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(spec.sampleRate),
            AVNumberOfChannelsKey: spec.channelCount,
            AVLinearPCMBitDepthKey: spec.bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: isBigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outFile = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let chunkSize: Int64 = 8_192
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: AVAudioFrameCount(chunkSize)
        ), let channelData = buffer.floatChannelData else {
            throw SyntheticAudioFixtureError.encodingFailed("Unable to allocate PCM buffer")
        }

        let twoPiOverSR = (2.0 * Double.pi * spec.frequencyHz) / Double(spec.sampleRate)
        var written: Int64 = 0

        while written < spec.frameCount {
            try Task.checkCancellation()
            let remaining = spec.frameCount - written
            let count = Int(min(chunkSize, remaining))
            buffer.frameLength = AVAudioFrameCount(count)

            for i in 0..<count {
                let sampleIndex = Double(written + Int64(i))
                let val = Float(sin(twoPiOverSR * sampleIndex) * spec.amplitude)
                for ch in 0..<spec.channelCount {
                    channelData[ch][i] = val
                }
            }

            try outFile.write(from: buffer)
            written += Int64(count)
        }
    }

    private static func encodeWithBundledFFmpeg(
        inputWAV: URL,
        outputURL: URL,
        codecArgs: [String]
    ) async throws {
        guard let ffmpegPath = findBundledFFmpegExecutable() else {
            throw SyntheticAudioFixtureError.encoderUnavailable("ffmpeg")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-hide_banner", "-nostats", "-y", "-i", inputWAV.path] + codecArgs + [outputURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let gate = OnceContinuationGate<Int32>()

        try await withTaskCancellationHandler {
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                gate.attach(continuation)
                process.terminationHandler = { finished in
                    gate.complete(with: .success(finished.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    gate.complete(with: .failure(error))
                }
            }

            if status != 0 {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "exit status \(status)"
                throw SyntheticAudioFixtureError.encodingFailed(errMsg)
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
            gate.complete(with: .failure(CancellationError()))
        }
    }

    private static func findBundledFFmpegExecutable() -> String? {
        if let env = ProcessInfo.processInfo.environment["LOCALCONVERT_FFMPEG_PATH"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("ffmpeg/ffmpeg"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ffmpeg/ffmpeg"))
        if let testHost = ProcessInfo.processInfo.environment["TEST_HOST"] {
            let hostApp = URL(fileURLWithPath: testHost).deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(hostApp.appendingPathComponent("Resources/ffmpeg/ffmpeg"))
        }
        if let srcroot = ProcessInfo.processInfo.environment["SRCROOT"] {
            candidates.append(URL(fileURLWithPath: srcroot).appendingPathComponent("LocalConvert/Resources/ffmpeg/ffmpeg"))
        }
        let repoFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LocalConvertTestSupport
            .deletingLastPathComponent() // Repo root
            .appendingPathComponent("LocalConvert/Resources/ffmpeg/ffmpeg")
        candidates.append(repoFallback)

        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}

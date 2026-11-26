import Foundation
import AVFoundation
import CoreAudioTypes
import os

// MARK: - Decoder Models & Abstraction

enum AudioDecoderBackend: String, Sendable, Equatable {
    case nativeAVAudioFile
    case bundledFFmpeg
}

/// Explicit speaker arrangement metadata used for multichannel playback formatting
/// and gapless transition compatibility checks.
struct AudioChannelLayoutInfo: Sendable, Equatable, Hashable {
    let channelCount: Int
    let coreAudioTag: AudioChannelLayoutTag?
    let normalizedName: String

    init?(channelCount: Int, coreAudioTag: AudioChannelLayoutTag? = nil, normalizedName: String) {
        let trimmed = normalizedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard channelCount > 0, !trimmed.isEmpty else { return nil }
        guard trimmed != "unknown", trimmed != "unk", trimmed != "unspecified" else { return nil }
        self.channelCount = channelCount
        self.coreAudioTag = coreAudioTag
        self.normalizedName = trimmed
    }

    /// Gapless playback is eligible only when both streams carry an explicit non-unknown
    /// channel layout with matching channel count and matching speaker arrangement.
    func isGaplessCompatible(with other: AudioChannelLayoutInfo) -> Bool {
        guard channelCount > 0, channelCount == other.channelCount else {
            return false
        }
        return normalizedName == other.normalizedName
    }

    func makeAVAudioFormat(sampleRate: Double) -> AVAudioFormat? {
        if let tag = coreAudioTag,
           tag != kAudioChannelLayoutTag_Unknown,
           tag != kAudioChannelLayoutTag_UseChannelDescriptions,
           tag != kAudioChannelLayoutTag_UseChannelBitmap,
           let caLayout = AVAudioChannelLayout(layoutTag: tag),
           Int(caLayout.channelCount) == channelCount {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: caLayout
            )
        }

        if let mappedTag = Self.coreAudioTag(forNormalizedName: normalizedName, channelCount: channelCount),
           let caLayout = AVAudioChannelLayout(layoutTag: mappedTag),
           Int(caLayout.channelCount) == channelCount {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                interleaved: false,
                channelLayout: caLayout
            )
        }

        return Self.makeFallbackPlaybackFormat(sampleRate: sampleRate, channelCount: channelCount)
    }

    static func makePlaybackFormat(
        sampleRate: Double,
        channelCount: Int,
        channelLayout: AudioChannelLayoutInfo?
    ) -> AVAudioFormat? {
        let safeChannels = max(1, channelCount)
        if let channelLayout,
           channelLayout.channelCount == safeChannels,
           let format = channelLayout.makeAVAudioFormat(sampleRate: sampleRate) {
            return format
        }
        return makeFallbackPlaybackFormat(sampleRate: sampleRate, channelCount: safeChannels)
    }

    private static func makeFallbackPlaybackFormat(sampleRate: Double, channelCount: Int) -> AVAudioFormat? {
        guard sampleRate > 0, channelCount > 0 else { return nil }
        if channelCount <= 2 {
            return AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount)
            )
        }
        let discreteTag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channelCount)
        guard let discreteLayout = AVAudioChannelLayout(layoutTag: discreteTag) else {
            return nil
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: discreteLayout
        )
    }

    static func fromAVAudioChannelLayout(_ layout: AVAudioChannelLayout?, channelCount: Int) -> AudioChannelLayoutInfo? {
        guard let layout, channelCount > 0 else { return nil }
        let tag = layout.layoutTag

        if tag == kAudioChannelLayoutTag_Unknown || tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            return nil
        }

        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            let bitmap = layout.layout.pointee.mChannelBitmap
            switch (bitmap.rawValue, channelCount) {
            case (AudioChannelBitmap.bit_Left.rawValue | AudioChannelBitmap.bit_Right.rawValue, 2):
                return AudioChannelLayoutInfo(channelCount: 2, coreAudioTag: kAudioChannelLayoutTag_Stereo, normalizedName: "stereo")
            case (AudioChannelBitmap.bit_Center.rawValue, 1):
                return AudioChannelLayoutInfo(channelCount: 1, coreAudioTag: kAudioChannelLayoutTag_Mono, normalizedName: "mono")
            case (0x3F, 6):
                return AudioChannelLayoutInfo(channelCount: 6, coreAudioTag: kAudioChannelLayoutTag_WAVE_5_1_B, normalizedName: "5.1")
            case (0x60F, 6):
                return AudioChannelLayoutInfo(channelCount: 6, coreAudioTag: kAudioChannelLayoutTag_MPEG_5_1_A, normalizedName: "5.1(side)")
            case (0x33, 4):
                return AudioChannelLayoutInfo(channelCount: 4, coreAudioTag: kAudioChannelLayoutTag_WAVE_4_0_B, normalizedName: "quad")
            default:
                return nil
            }
        }

        let tagChannelCount = Int(tag & 0xFFFF)
        guard tagChannelCount == channelCount else { return nil }

        if let canonical = canonicalName(forCoreAudioTag: tag, channelCount: channelCount) {
            return AudioChannelLayoutInfo(channelCount: channelCount, coreAudioTag: tag, normalizedName: canonical)
        }

        let highBits = tag >> 16
        if highBits == 147 /* kAudioChannelLayoutTag_DiscreteInOrder */ {
            return nil
        }

        return AudioChannelLayoutInfo(
            channelCount: channelCount,
            coreAudioTag: tag,
            normalizedName: "coreaudio_tag_\(tag)"
        )
    }

    static func fromFFmpegLayoutName(_ rawName: String?, channelCount: Int) -> AudioChannelLayoutInfo? {
        guard channelCount > 0, let rawName else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "unknown" || trimmed == "unk" || trimmed == "unspecified"
            || trimmed.hasSuffix(" channels") || trimmed.hasSuffix(" channel") {
            return nil
        }

        switch (trimmed, channelCount) {
        case ("mono", 1), ("1.0", 1), ("fc", 1):
            return AudioChannelLayoutInfo(channelCount: 1, coreAudioTag: kAudioChannelLayoutTag_Mono, normalizedName: "mono")
        case ("stereo", 2), ("2.0", 2), ("downmix", 2):
            return AudioChannelLayoutInfo(channelCount: 2, coreAudioTag: kAudioChannelLayoutTag_Stereo, normalizedName: "stereo")
        case ("2.1", 3):
            return AudioChannelLayoutInfo(channelCount: 3, coreAudioTag: kAudioChannelLayoutTag_DVD_4, normalizedName: "2.1")
        case ("3.0", 3):
            return AudioChannelLayoutInfo(channelCount: 3, coreAudioTag: kAudioChannelLayoutTag_MPEG_3_0_A, normalizedName: "3.0")
        case ("3.0(back)", 3):
            return AudioChannelLayoutInfo(channelCount: 3, coreAudioTag: nil, normalizedName: "3.0(back)")
        case ("4.0", 4):
            return AudioChannelLayoutInfo(channelCount: 4, coreAudioTag: kAudioChannelLayoutTag_MPEG_4_0_A, normalizedName: "4.0")
        case ("quad", 4):
            return AudioChannelLayoutInfo(channelCount: 4, coreAudioTag: kAudioChannelLayoutTag_WAVE_4_0_B, normalizedName: "quad")
        case ("quad(side)", 4):
            return AudioChannelLayoutInfo(channelCount: 4, coreAudioTag: kAudioChannelLayoutTag_Quadraphonic, normalizedName: "quadraphonic")
        case ("5.0", 5):
            return AudioChannelLayoutInfo(channelCount: 5, coreAudioTag: kAudioChannelLayoutTag_MPEG_5_0_D, normalizedName: "5.0")
        case ("5.0(side)", 5):
            return AudioChannelLayoutInfo(channelCount: 5, coreAudioTag: kAudioChannelLayoutTag_MPEG_5_0_A, normalizedName: "5.0(side)")
        case ("5.1", 6):
            return AudioChannelLayoutInfo(channelCount: 6, coreAudioTag: kAudioChannelLayoutTag_WAVE_5_1_B, normalizedName: "5.1")
        case ("5.1(side)", 6):
            return AudioChannelLayoutInfo(channelCount: 6, coreAudioTag: kAudioChannelLayoutTag_MPEG_5_1_A, normalizedName: "5.1(side)")
        case ("6.1", 7):
            return AudioChannelLayoutInfo(channelCount: 7, coreAudioTag: kAudioChannelLayoutTag_MPEG_6_1_A, normalizedName: "6.1")
        case ("7.1", 8):
            return AudioChannelLayoutInfo(channelCount: 8, coreAudioTag: kAudioChannelLayoutTag_MPEG_7_1_C, normalizedName: "7.1")
        case ("7.1(wide)", 8):
            return AudioChannelLayoutInfo(channelCount: 8, coreAudioTag: kAudioChannelLayoutTag_MPEG_7_1_A, normalizedName: "7.1(wide)")
        default:
            // Preserve unambiguous explicit FFmpeg custom mask only if it doesn't indicate missing layout
            if trimmed.contains("ambiguous") || trimmed.contains("none") {
                return nil
            }
            return AudioChannelLayoutInfo(
                channelCount: channelCount,
                coreAudioTag: nil,
                normalizedName: "ffmpeg:\(trimmed)"
            )
        }
    }

    private static func canonicalName(forCoreAudioTag tag: AudioChannelLayoutTag, channelCount: Int) -> String? {
        switch (tag, channelCount) {
        case (kAudioChannelLayoutTag_Mono, 1): return "mono"
        case (kAudioChannelLayoutTag_Stereo, 2): return "stereo"
        case (kAudioChannelLayoutTag_StereoHeadphones, 2): return "stereo_headphones"
        case (kAudioChannelLayoutTag_Binaural, 2): return "binaural"
        case (kAudioChannelLayoutTag_MidSide, 2): return "mid_side"
        case (kAudioChannelLayoutTag_XY, 2): return "xy"
        case (kAudioChannelLayoutTag_DVD_4, 3): return "2.1"
        case (kAudioChannelLayoutTag_MPEG_3_0_A, 3): return "3.0"
        case (kAudioChannelLayoutTag_MPEG_3_0_B, 3): return "3.0(c_first)"
        case (kAudioChannelLayoutTag_MPEG_4_0_A, 4), (kAudioChannelLayoutTag_WAVE_4_0_A, 4): return "4.0"
        case (kAudioChannelLayoutTag_MPEG_4_0_B, 4): return "4.0(c_first)"
        case (kAudioChannelLayoutTag_WAVE_4_0_B, 4): return "quad"
        case (kAudioChannelLayoutTag_Quadraphonic, 4): return "quadraphonic"
        case (kAudioChannelLayoutTag_MPEG_5_0_A, 5): return "5.0(side)"
        case (kAudioChannelLayoutTag_MPEG_5_0_D, 5): return "5.0"
        case (kAudioChannelLayoutTag_WAVE_5_1_B, 6): return "5.1"
        case (kAudioChannelLayoutTag_MPEG_5_1_A, 6): return "5.1(side)"
        case (kAudioChannelLayoutTag_MPEG_5_1_D, 6): return "5.1(mpeg_d)"
        case (kAudioChannelLayoutTag_MPEG_6_1_A, 7): return "6.1"
        case (kAudioChannelLayoutTag_MPEG_7_1_C, 8): return "7.1"
        case (kAudioChannelLayoutTag_MPEG_7_1_A, 8): return "7.1(wide)"
        default: return nil
        }
    }

    private static func coreAudioTag(forNormalizedName name: String, channelCount: Int) -> AudioChannelLayoutTag? {
        switch (name, channelCount) {
        case ("mono", 1): return kAudioChannelLayoutTag_Mono
        case ("stereo", 2): return kAudioChannelLayoutTag_Stereo
        case ("2.1", 3): return kAudioChannelLayoutTag_DVD_4
        case ("3.0", 3): return kAudioChannelLayoutTag_MPEG_3_0_A
        case ("4.0", 4): return kAudioChannelLayoutTag_MPEG_4_0_A
        case ("quad", 4): return kAudioChannelLayoutTag_WAVE_4_0_B
        case ("quadraphonic", 4): return kAudioChannelLayoutTag_Quadraphonic
        case ("5.0(side)", 5): return kAudioChannelLayoutTag_MPEG_5_0_A
        case ("5.0", 5): return kAudioChannelLayoutTag_MPEG_5_0_D
        case ("5.1", 6): return kAudioChannelLayoutTag_WAVE_5_1_B
        case ("5.1(side)", 6): return kAudioChannelLayoutTag_MPEG_5_1_A
        case ("6.1", 7): return kAudioChannelLayoutTag_MPEG_6_1_A
        case ("7.1", 8): return kAudioChannelLayoutTag_MPEG_7_1_C
        case ("7.1(wide)", 8): return kAudioChannelLayoutTag_MPEG_7_1_A
        default: return nil
        }
    }
}

struct DecodedAudioStreamInfo: Sendable, Equatable {
    let sampleRate: SampleRate
    let channelCount: Int
    let channelLayout: AudioChannelLayoutInfo?
    let totalFrames: Int64
    let isExactFrameSeekSupported: Bool
    let codecName: String
    let backend: AudioDecoderBackend

    init(
        sampleRate: SampleRate,
        channelCount: Int,
        channelLayout: AudioChannelLayoutInfo? = nil,
        totalFrames: Int64,
        isExactFrameSeekSupported: Bool,
        codecName: String,
        backend: AudioDecoderBackend
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.channelLayout = channelLayout
        self.totalFrames = totalFrames
        self.isExactFrameSeekSupported = isExactFrameSeekSupported
        self.codecName = codecName
        self.backend = backend
    }
}

struct DecodedPCMChunk: Sendable {
    let sampleRate: Double
    let channelCount: Int
    let channelLayout: AudioChannelLayoutInfo?
    let frameCount: Int
    /// Non-interleaved Float32 planes (`channels.count == channelCount`).
    let channels: [[Float]]

    init(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        channels: [[Float]],
        channelLayout: AudioChannelLayoutInfo? = nil
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.channelLayout = channelLayout
        self.frameCount = frameCount
        self.channels = channels
    }

    func makeAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard frameCount > 0, channelCount > 0, channels.count == channelCount,
              let format = AudioChannelLayoutInfo.makePlaybackFormat(
                  sampleRate: sampleRate,
                  channelCount: channelCount,
                  channelLayout: channelLayout
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let dst = buffer.floatChannelData {
            for ch in 0..<channelCount {
                let count = min(frameCount, channels[ch].count)
                channels[ch].withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        dst[ch].update(from: base, count: count)
                    }
                }
            }
        }
        return buffer
    }
}

enum AudioPlaybackError: Error, LocalizedError, Equatable, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case decoderUnavailable(String)
    case openFailed(String)
    case seekFailed(String)
    case decodeFailed(String)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name): return "Audio file not found: \(name)"
        case .unsupportedFormat(let fmt): return "Unsupported audio playback format: \(fmt)"
        case .decoderUnavailable(let detail): return "Required audio decoder unavailable: \(detail)"
        case .openFailed(let detail): return "Unable to open audio file: \(detail)"
        case .seekFailed(let detail): return "Unable to seek audio stream: \(detail)"
        case .decodeFailed(let detail): return "Audio decode failed: \(detail)"
        case .engineStartFailed(let detail): return "Audio output engine failed to start: \(detail)"
        }
    }
}

protocol AudioPlaybackDecoderProtocol: Sendable {
    var streamInfo: DecodedAudioStreamInfo { get }
    func seek(toFrame frame: Int64) async throws
    func readNextChunk(maxFrames: Int) async throws -> DecodedPCMChunk?
    func close() async
}

// MARK: - Native AVAudioFile Streaming Decoder

actor NativeAVAudioPlaybackDecoder: AudioPlaybackDecoderProtocol {
    nonisolated let streamInfo: DecodedAudioStreamInfo
    private var file: AVAudioFile?
    private let processingFormat: AVAudioFormat
    private var scratchBuffer: AVAudioPCMBuffer

    init(url: URL, format: FileFormat) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlaybackError.fileNotFound(url.lastPathComponent)
        }
        let opened: AVAudioFile
        do {
            opened = try AVAudioFile(forReading: url)
        } catch {
            throw AudioPlaybackError.openFailed(error.localizedDescription)
        }

        let fmt = opened.processingFormat
        let sr = Int32(fmt.sampleRate.rounded())
        guard let validatedRate = try? SampleRate(sr) else {
            throw AudioPlaybackError.openFailed("Invalid audio sample rate \(sr)")
        }
        let channels = max(1, Int(fmt.channelCount))
        let frames = max(0, opened.length)
        let rawChannelLayout = fmt.channelLayout ?? (
            Int(opened.fileFormat.channelCount) == channels ? opened.fileFormat.channelLayout : nil
        )
        let layoutInfo = AudioChannelLayoutInfo.fromAVAudioChannelLayout(rawChannelLayout, channelCount: channels)

        guard let scratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8_192) else {
            throw AudioPlaybackError.openFailed("Unable to allocate PCM read buffer")
        }

        self.file = opened
        self.processingFormat = fmt
        self.scratchBuffer = scratch
        self.streamInfo = DecodedAudioStreamInfo(
            sampleRate: validatedRate,
            channelCount: channels,
            channelLayout: layoutInfo,
            totalFrames: frames,
            isExactFrameSeekSupported: true,
            codecName: format.rawValue.lowercased(),
            backend: .nativeAVAudioFile
        )
    }

    func seek(toFrame frame: Int64) async throws {
        guard let file else {
            throw AudioPlaybackError.seekFailed("Decoder has been closed")
        }
        let maxFrame = max(0, streamInfo.totalFrames)
        let clamped = max(0, min(frame, maxFrame))
        file.framePosition = clamped
    }

    func readNextChunk(maxFrames: Int) async throws -> DecodedPCMChunk? {
        try Task.checkCancellation()
        guard let file else { return nil }
        guard maxFrames > 0 else { return nil }

        let total = file.length
        let currentPos = file.framePosition
        if total > 0 && currentPos >= total {
            return nil
        }

        let framesToRequest: Int
        if total > 0 {
            framesToRequest = min(maxFrames, Int(total - currentPos))
        } else {
            framesToRequest = maxFrames
        }
        guard framesToRequest > 0 else { return nil }

        let desired = AVAudioFrameCount(framesToRequest)
        if scratchBuffer.frameCapacity < desired {
            guard let resized = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: desired) else {
                throw AudioPlaybackError.decodeFailed("Unable to allocate scratch buffer")
            }
            scratchBuffer = resized
        }
        scratchBuffer.frameLength = 0

        do {
            try file.read(into: scratchBuffer, frameCount: desired)
        } catch let nsError as NSError {
            // CoreAudio returns eofErr (-39) at end-of-stream on some formats/seeks.
            if nsError.domain == NSOSStatusErrorDomain && nsError.code == -39 {
                return nil
            }
            throw AudioPlaybackError.decodeFailed(nsError.localizedDescription)
        }

        let readCount = Int(scratchBuffer.frameLength)
        guard readCount > 0 else {
            return nil
        }

        let channelCount = streamInfo.channelCount
        var planes: [[Float]] = []
        planes.reserveCapacity(channelCount)
        if let floatData = scratchBuffer.floatChannelData {
            for ch in 0..<channelCount {
                let ptr = floatData[ch]
                planes.append(Array(UnsafeBufferPointer(start: ptr, count: readCount)))
            }
        } else {
            planes = Array(repeating: [Float](repeating: 0, count: readCount), count: channelCount)
        }

        return DecodedPCMChunk(
            sampleRate: Double(streamInfo.sampleRate.hz),
            channelCount: channelCount,
            frameCount: readCount,
            channels: planes,
            channelLayout: streamInfo.channelLayout
        )
    }

    func close() async {
        file = nil
    }
}

// MARK: - Bounded FFmpeg Streaming PCM Decoder (Non-Native Formats)

actor FFmpegStreamingPlaybackDecoder: AudioPlaybackDecoderProtocol {
    nonisolated let streamInfo: DecodedAudioStreamInfo

    private final class ProcessStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stdoutHandle: FileHandle?
        private var stderrHandle: FileHandle?
        private var stderrTail = Data()
        private var intentionallyStopped = false
        private var hasExited = false
        private var exitWaiters: [@Sendable (Int32) -> Void] = []

        func prepareLaunch() {
            lock.lock()
            hasExited = false
            intentionallyStopped = false
            stderrTail.removeAll(keepingCapacity: false)
            lock.unlock()
        }

        func attach(process: Process, stdout: FileHandle, stderr: FileHandle) {
            lock.lock()
            self.process = process
            self.stdoutHandle = stdout
            self.stderrHandle = stderr
            lock.unlock()
        }

        func markExited(status: Int32) {
            let waiters: [@Sendable (Int32) -> Void]
            lock.lock()
            hasExited = true
            waiters = exitWaiters
            exitWaiters.removeAll()
            lock.unlock()
            for w in waiters {
                w(status)
            }
        }

        func appendStderr(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            stderrTail.append(chunk)
            if stderrTail.count > 8_192 {
                stderrTail.removeFirst(stderrTail.count - 8_192)
            }
            lock.unlock()
        }

        func currentStderrString() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        func wasIntentionallyStopped() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return intentionallyStopped
        }

        func awaitProcessExit(timeoutMilliseconds: Int = 500) async -> Int32? {
            enum WaitState {
                case alreadyDone(Int32?)
                case pending
            }

            let immediate: WaitState = lock.withLock {
                guard let proc = process else { return .alreadyDone(nil) }
                if hasExited || !proc.isRunning {
                    hasExited = true
                    return .alreadyDone(proc.terminationStatus)
                }
                return .pending
            }
            if case .alreadyDone(let status) = immediate {
                return status
            }

            return await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let box = self

                // Timeout fallback so an unresponsive child cannot freeze caller or actor
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) {
                    guard resumed.withLock({ r in let first = !r; r = true; return first }) else { return }
                    let proc = box.lock.withLock { box.process }
                    if let proc, proc.isRunning {
                        let pid = proc.processIdentifier
                        if pid > 0 { kill(pid, SIGKILL) }
                    }
                    cont.resume(returning: nil)
                }

                // Wait on process terminationHandler
                let (doneNow, statusNow): (Bool, Int32) = lock.withLock {
                    guard let proc = process, !hasExited, proc.isRunning else {
                        hasExited = true
                        return (true, process?.terminationStatus ?? 0)
                    }
                    exitWaiters.append { code in
                        guard resumed.withLock({ r in let first = !r; r = true; return first }) else { return }
                        cont.resume(returning: code)
                    }
                    return (false, 0)
                }
                if doneNow {
                    guard resumed.withLock({ r in let first = !r; r = true; return first }) else { return }
                    cont.resume(returning: statusNow)
                }
            }
        }

        func terminateAndDetach() {
            lock.lock()
            intentionallyStopped = true
            let proc = process
            let errH = stderrHandle
            let outH = stdoutHandle
            let alreadyExited = hasExited
            let waiters = exitWaiters
            exitWaiters.removeAll()
            process = nil
            stderrHandle = nil
            stdoutHandle = nil
            lock.unlock()

            for w in waiters {
                w(-1)
            }

            // Close read-side pipes first so any blocked FFmpeg write unblocks immediately via EPIPE.
            try? outH?.close()
            try? errH?.close()

            if let proc, !alreadyExited, proc.isRunning {
                let pid = proc.processIdentifier
                proc.terminate()
                if pid > 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(150)) {
                        if proc.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                }
            }
        }

        deinit {
            terminateAndDetach()
        }
    }

    private let url: URL
    private let ffmpegPath: String
    private let ioQueue = DispatchQueue(label: "com.localconvert.audioworkspace.ffmpegdecoder", qos: .userInitiated)
    private let processBox = ProcessStateBox()

    private var activeStdout: FileHandle?
    private var activeProcess: Process?
    private var pendingSeekFrame: Int64 = 0
    private var framesProducedInCurrentProcess: Int64 = 0
    private var isClosed = false

    private init(url: URL, ffmpegPath: String, streamInfo: DecodedAudioStreamInfo) {
        self.url = url
        self.ffmpegPath = ffmpegPath
        self.streamInfo = streamInfo
    }

    static func open(url: URL, format: FileFormat) async throws -> FFmpegStreamingPlaybackDecoder {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlaybackError.fileNotFound(url.lastPathComponent)
        }
        let provider = BundledFFmpegProvider(fallbackToSystem: false)
        guard let ffmpegPath = await provider.findFFmpegPath(),
              let ffprobePath = await provider.findFFprobePath() else {
            throw AudioPlaybackError.decoderUnavailable("Bundled FFmpeg/FFprobe binary unavailable.")
        }

        let probeProc = Process()
        probeProc.executableURL = URL(fileURLWithPath: ffprobePath)
        probeProc.arguments = [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "format=duration:stream=codec_name,sample_rate,channels,channel_layout,duration",
            "-of", "json",
            url.path
        ]
        let probeOut = try await AsyncProcessRunner.run(probeProc, stdin: .nullDevice, timeout: 15)
        guard probeOut.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: probeOut.stdout) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first else {
            let errText = String(data: probeOut.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AudioPlaybackError.openFailed(errText.isEmpty ? "Unreadable audio stream" : errText)
        }

        let srNum = (stream["sample_rate"] as? String).flatMap { Int32($0) } ?? (stream["sample_rate"] as? Int).map { Int32($0) }
        guard let rawSR = srNum, let sampleRate = try? SampleRate(rawSR) else {
            throw AudioPlaybackError.openFailed("Invalid or missing sample rate in stream.")
        }

        let channels = max(1, (stream["channels"] as? Int) ?? 2)
        let rawChannelLayout = stream["channel_layout"] as? String
        let layoutInfo = AudioChannelLayoutInfo.fromFFmpegLayoutName(rawChannelLayout, channelCount: channels)
        let formatDict = json["format"] as? [String: Any]
        let streamDur = (stream["duration"] as? String).flatMap { Double($0) } ?? (stream["duration"] as? Double)
        let formatDur = (formatDict?["duration"] as? String).flatMap { Double($0) } ?? (formatDict?["duration"] as? Double)
        let duration = max(0.0, streamDur ?? formatDur ?? 0.0)
        let totalFrames = duration.isFinite ? Int64((duration * Double(sampleRate.hz)).rounded()) : 0
        let codecName = (stream["codec_name"] as? String)?.lowercased() ?? format.rawValue.lowercased()

        let info = DecodedAudioStreamInfo(
            sampleRate: sampleRate,
            channelCount: channels,
            channelLayout: layoutInfo,
            totalFrames: max(0, totalFrames),
            isExactFrameSeekSupported: false, // Container packet/demuxer seek via FFmpeg -ss
            codecName: codecName,
            backend: .bundledFFmpeg
        )
        return FFmpegStreamingPlaybackDecoder(url: url, ffmpegPath: ffmpegPath, streamInfo: info)
    }

    func seek(toFrame frame: Int64) async throws {
        guard !isClosed else {
            throw AudioPlaybackError.seekFailed("Decoder has been closed")
        }
        let maxFrame = max(0, streamInfo.totalFrames)
        pendingSeekFrame = max(0, min(frame, maxFrame))
        stopCurrentChildProcess()
    }

    func readNextChunk(maxFrames: Int) async throws -> DecodedPCMChunk? {
        try Task.checkCancellation()
        guard !isClosed, maxFrames > 0 else { return nil }

        if activeStdout == nil {
            try launchChildProcess(startingAtFrame: pendingSeekFrame)
        }

        guard let stdout = activeStdout else { return nil }
        let bytesPerFrame = streamInfo.channelCount * MemoryLayout<Float>.size
        let targetByteCount = maxFrames * bytesPerFrame

        let rawData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ioQueue.async {
                    do {
                        var accumulated = Data()
                        accumulated.reserveCapacity(targetByteCount)
                        while accumulated.count < targetByteCount {
                            let needed = targetByteCount - accumulated.count
                            guard let part = try stdout.read(upToCount: needed), !part.isEmpty else {
                                break
                            }
                            accumulated.append(part)
                        }
                        continuation.resume(returning: accumulated)
                    } catch {
                        continuation.resume(throwing: AudioPlaybackError.decodeFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: { [processBox] in
            processBox.terminateAndDetach()
        }

        try Task.checkCancellation()

        let usableFrames = rawData.count / bytesPerFrame
        if usableFrames == 0 {
            let hadProducedFrames = framesProducedInCurrentProcess > 0
            let stderrSummary = processBox.currentStderrString()
            let stoppedIntentionally = processBox.wasIntentionallyStopped()

            let exitCode = await processBox.awaitProcessExit(timeoutMilliseconds: 500) ?? 0
            stopCurrentChildProcess()

            if !stoppedIntentionally && exitCode != 0 && !hadProducedFrames {
                let msg = stderrSummary.isEmpty ? "FFmpeg exited with code \(exitCode)" : stderrSummary
                throw AudioPlaybackError.decodeFailed(msg)
            }
            return nil
        }

        framesProducedInCurrentProcess += Int64(usableFrames)
        let channels = Self.deinterleaveFloat32(
            data: rawData,
            frameCount: usableFrames,
            channelCount: streamInfo.channelCount
        )
        return DecodedPCMChunk(
            sampleRate: Double(streamInfo.sampleRate.hz),
            channelCount: streamInfo.channelCount,
            frameCount: usableFrames,
            channels: channels,
            channelLayout: streamInfo.channelLayout
        )
    }

    func close() async {
        isClosed = true
        stopCurrentChildProcess()
    }

    // MARK: - Child Process Helpers

    private func launchChildProcess(startingAtFrame frame: Int64) throws {
        stopCurrentChildProcess()

        let seconds = Double(max(0, frame)) / Double(streamInfo.sampleRate.hz)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        var args = ["-v", "error", "-nostdin"]
        if seconds > 0.0001 {
            args.append(contentsOf: ["-ss", String(format: "%.6f", seconds)])
        }
        args.append(contentsOf: [
            "-i", url.path,
            "-vn", "-sn", "-dn",
            "-f", "f32le",
            "-ac", "\(streamInfo.channelCount)",
            "-ar", "\(streamInfo.sampleRate.hz)",
            "pipe:1"
        ])
        proc.arguments = args

        processBox.prepareLaunch()
        let box = processBox
        proc.terminationHandler = { finishedProc in
            box.markExited(status: finishedProc.terminationStatus)
        }

        do {
            try proc.run()
        } catch {
            proc.terminationHandler = nil
            throw AudioPlaybackError.openFailed(error.localizedDescription)
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        box.attach(process: proc, stdout: outHandle, stderr: errHandle)

        // Drain stderr continuously on utility queue until write side closes cleanly (zero readabilityHandler races).
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? errHandle.read(upToCount: 4_096), !chunk.isEmpty {
                box.appendStderr(chunk)
            }
        }

        activeProcess = proc
        activeStdout = outHandle
        framesProducedInCurrentProcess = 0
    }

    private func stopCurrentChildProcess() {
        processBox.terminateAndDetach()
        activeProcess = nil
        activeStdout = nil
    }

    private static func deinterleaveFloat32(data: Data, frameCount: Int, channelCount: Int) -> [[Float]] {
        var planes = Array(repeating: [Float](repeating: 0, count: frameCount), count: channelCount)
        let sampleCount = frameCount * channelCount
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            guard floats.count >= sampleCount else { return }
            for frameIdx in 0..<frameCount {
                let base = frameIdx * channelCount
                for ch in 0..<channelCount {
                    planes[ch][frameIdx] = floats[base + ch]
                }
            }
        }
        return planes
    }
}

// MARK: - Decoder Factory

enum AudioPlaybackDecoderFactory {
    static func openDecoder(url: URL, format: FileFormat? = nil) async throws -> any AudioPlaybackDecoderProtocol {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioPlaybackError.fileNotFound(url.lastPathComponent)
        }
        guard let resolvedFormat = format ?? AudioLibraryFormatSupport.resolveAudioFormat(for: url) else {
            throw AudioPlaybackError.unsupportedFormat(url.pathExtension)
        }

        if AudioLibraryFormatSupport.nativePlaybackFormats.contains(resolvedFormat) {
            return try NativeAVAudioPlaybackDecoder(url: url, format: resolvedFormat)
        }
        if AudioLibraryFormatSupport.ffmpegPlaybackFormats.contains(resolvedFormat) {
            return try await FFmpegStreamingPlaybackDecoder.open(url: url, format: resolvedFormat)
        }
        throw AudioPlaybackError.unsupportedFormat(resolvedFormat.rawValue)
    }
}

import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Target Size Quick Presets

enum TargetSizeQuickPreset: String, CaseIterable, Identifiable, Sendable {
    case mb5 = "5 MB"
    case discord10MB = "10 MB Discord"
    case email25MB = "25 MB Email"

    var id: String { rawValue }

    var megabytes: Double {
        switch self {
        case .mb5: return 5.0
        case .discord10MB: return 10.0
        case .email25MB: return 25.0
        }
    }

    var targetBytes: Int64 {
        Int64(megabytes * 1_000_000.0)
    }

    var localizedTitle: String {
        switch self {
        case .mb5: return String(localized: "5 MB")
        case .discord10MB: return String(localized: "10 MB Discord")
        case .email25MB: return String(localized: "25 MB Email")
        }
    }
}

// MARK: - Target Size Compression Models

struct TargetSizeCompressionResult: Sendable, Equatable {
    let outputURL: URL
    let outputFormat: FileFormat
    let originalBytes: Int64
    let finalBytes: Int64
    let targetBytes: Int64
    let targetReached: Bool
    let iterationsUsed: Int
    let finalQuality: Double?
    let finalScaleFactor: Double?
    let finalVideoBitrateBps: Int?
    let finalAudioBitrateBps: Int?
    let note: String?
}

struct TargetSizeVideoBudget: Sendable, Equatable {
    let targetBytes: Int64
    let durationSeconds: Double
    let videoBitrateBps: Int
    let audioBitrateBps: Int
    let scaleMaxWidth: Int?

    var totalBitrateBps: Int {
        videoBitrateBps + audioBitrateBps
    }
}

protocol TargetSizeVideoCompressionRunner: Sendable {
    func probeDurationSeconds(url: URL) async throws -> Double
    func transcode(
        inputURL: URL,
        tempOutputURL: URL,
        outputFormat: FileFormat,
        videoBitrateBps: Int,
        audioBitrateBps: Int,
        scaleMaxWidth: Int?,
        progress: @Sendable (Double) -> Void
    ) async throws
}

struct LiveTargetSizeVideoRunner: TargetSizeVideoCompressionRunner {
    let provider: BundledFFmpegProvider

    init(provider: BundledFFmpegProvider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)) {
        self.provider = provider
    }

    func probeDurationSeconds(url: URL) async throws -> Double {
        guard let ffprobePath = await provider.findFFprobePath() else {
            throw ConversionError.engineNotAvailable("ffprobe is required to inspect video duration.")
        }
        let info = try await MediaProbe.probe(url: url, ffprobePath: ffprobePath)
        guard info.hasRealVideo else {
            throw ConversionError.invalidInput("The source file does not contain a video stream.")
        }
        return max(0.1, info.duration)
    }

    func transcode(
        inputURL: URL,
        tempOutputURL: URL,
        outputFormat: FileFormat,
        videoBitrateBps: Int,
        audioBitrateBps: Int,
        scaleMaxWidth: Int?,
        progress: @Sendable (Double) -> Void
    ) async throws {
        guard let ffmpegPath = await provider.findFFmpegPath(),
              let ffprobePath = await provider.findFFprobePath() else {
            throw ConversionError.engineNotAvailable("FFmpeg is required for video target-size compression.")
        }

        let scaleFilter: String
        if let maxW = scaleMaxWidth, maxW >= 160 {
            let evenW = (maxW / 2) * 2
            scaleFilter = "scale='min(\(evenW),iw)':-2:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2"
        } else {
            scaleFilter = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        }

        let useWebM = (outputFormat == .webm)
        let videoCodec = useWebM ? "libvpx-vp9" : "h264_videotoolbox"
        let audioCodec = useWebM ? "libopus" : "aac"
        let bufsize = max(videoBitrateBps * 2, 120_000)

        var args: [String] = [
            "-y",
            "-i", inputURL.path,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-sn",
            "-c:v", videoCodec,
            "-pix_fmt", "yuv420p",
            "-vf", scaleFilter,
            "-b:v", "\(videoBitrateBps)",
            "-maxrate", "\(videoBitrateBps)",
            "-bufsize", "\(bufsize)",
            "-c:a", audioCodec,
            "-b:a", "\(audioBitrateBps)"
        ]
        if [.mp4, .mov, .m4v].contains(outputFormat) {
            args += ["-movflags", "+faststart"]
        }
        args.append(tempOutputURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = args
        let output = try await AsyncProcessRunner.run(
            proc,
            stdin: .nullDevice,
            timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds
        )

        if output.terminationStatus != 0 {
            let stderrText = String(data: output.stderr, encoding: .utf8) ?? ""
            if !useWebM && BaseFFmpegProvider.isVideoToolboxHardwareFailure(stderr: stderrText, arguments: args) {
                try? FileManager.default.removeItem(at: tempOutputURL)
                var swArgs = args
                if let idx = swArgs.firstIndex(of: "h264_videotoolbox") {
                    swArgs[idx] = "libx264"
                }
                let swProc = Process()
                swProc.executableURL = URL(fileURLWithPath: ffmpegPath)
                swProc.arguments = swArgs
                let swOut = try await AsyncProcessRunner.run(
                    swProc,
                    stdin: .nullDevice,
                    timeout: BaseFFmpegProvider.defaultConversionTimeoutSeconds
                )
                guard swOut.terminationStatus == 0 else {
                    let swErr = String(data: swOut.stderr, encoding: .utf8)
                    throw ConversionError.engineExecutionFailed(
                        "Target-size video compression failed.",
                        underlyingError: swErr
                    )
                }
            } else {
                throw ConversionError.engineExecutionFailed(
                    "Target-size video compression failed.",
                    underlyingError: stderrText
                )
            }
        }

        _ = try await MediaProbe.validate(outputURL: tempOutputURL, expectedFormat: outputFormat, ffprobePath: ffprobePath)
        progress(1.0)
    }
}

// MARK: - Target File-Size Auto-Compression Coordinator

/// Bounded max-4-iteration adaptive compression coordinator for Images, PDFs, and Videos.
/// Never overwrites source media by default and commits outputs atomically via `OutputReservationCoordinator`.
enum TargetSizeCompressionCoordinator {

    static let maxIterations = 4
    static let minimumVideoBitrateBps = 64_000
    static let minimumAudioBitrateBps = 48_000

    // MARK: - Public Entry Points

    static func compress(
        inputURL: URL,
        targetBytes: Int64,
        outputDirectory: URL,
        preferredOutputFormat: FileFormat? = nil,
        existingFileHandling: ExistingFileHandling = .createUnique,
        videoRunner: any TargetSizeVideoCompressionRunner = LiveTargetSizeVideoRunner(),
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> TargetSizeCompressionResult {
        try Task.checkCancellation()

        guard targetBytes > 0 else {
            throw ConversionError.invalidInput("Target file size must be greater than zero bytes.")
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        guard let detectedFormat = FileDetector.detectFormat(url: inputURL) else {
            throw ConversionError.invalidInput("Could not detect format for '\(inputURL.lastPathComponent)'.")
        }

        if detectedFormat == .pdf {
            return try await compressPDF(
                inputURL: inputURL,
                targetBytes: targetBytes,
                outputDirectory: outputDirectory,
                existingFileHandling: existingFileHandling,
                progress: progress
            )
        }

        switch detectedFormat.category {
        case .image:
            let resolvedOutFormat: FileFormat = {
                if let preferredOutputFormat,
                   [.jpg, .heic, .webp, .png, .avif, .jxl].contains(preferredOutputFormat) {
                    return preferredOutputFormat
                }
                if [.jpg, .heic, .webp, .png].contains(detectedFormat) {
                    return detectedFormat
                }
                return .jpg
            }()
            return try await compressImage(
                inputURL: inputURL,
                targetFormat: resolvedOutFormat,
                targetBytes: targetBytes,
                outputDirectory: outputDirectory,
                existingFileHandling: existingFileHandling,
                progress: progress
            )

        case .video:
            let resolvedOutFormat: FileFormat = {
                if let preferredOutputFormat, preferredOutputFormat.category == .video {
                    return preferredOutputFormat
                }
                return detectedFormat == .webm ? .webm : .mp4
            }()
            return try await compressVideo(
                inputURL: inputURL,
                outputFormat: resolvedOutFormat,
                targetBytes: targetBytes,
                outputDirectory: outputDirectory,
                existingFileHandling: existingFileHandling,
                runner: videoRunner,
                progress: progress
            )

        default:
            throw ConversionError.invalidInput("Target file-size auto-compression supports images, PDFs, and videos.")
        }
    }

    // MARK: - Image Target-Size Compression (Max 4 Bounded Iterations)

    static func compressImage(
        inputURL: URL,
        targetFormat: FileFormat = .jpg,
        targetBytes: Int64,
        outputDirectory: URL,
        existingFileHandling: ExistingFileHandling = .createUnique,
        preserveMetadata: Bool = false,
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> TargetSizeCompressionResult {
        try Task.checkCancellation()
        guard targetBytes > 0 else {
            throw ConversionError.invalidInput("Target file size must be greater than zero bytes.")
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        let originalBytes = fileSizeBytes(at: inputURL)
        progress(.determinate(0.1, message: String(localized: "Decoding image...")))

        let decoded = try await ImageProcessingService.decodeInputImage(url: inputURL)
        let sourceImage = decoded.cgImage

        let outputURL = try reserveTargetSizeOutputURL(
            inputURL: inputURL,
            format: targetFormat,
            directory: outputDirectory,
            policy: existingFileHandling
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(outputURL) }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-TargetImg-\(UUID().uuidString).\(targetFormat.fileExtension)")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let isLosslessFormat = (targetFormat == .png || targetFormat == .tiff || targetFormat == .bmp || targetFormat == .tga)
        var currentQuality = isLosslessFormat ? 1.0 : 0.85
        var currentScale = 1.0
        var iterationsUsed = 0

        var bestUnderTarget: (data: Data, quality: Double, scale: Double)? = nil
        var smallestOverall: (data: Data, quality: Double, scale: Double)? = nil

        for iteration in 1...maxIterations {
            try Task.checkCancellation()
            iterationsUsed = iteration
            progress(.determinate(
                0.15 + (Double(iteration - 1) / Double(maxIterations)) * 0.75,
                message: String(localized: "Compressing image (pass \(iteration)/\(maxIterations))...")
            ))

            let candidateImage: CGImage
            if currentScale < 0.999 {
                let targetW = max(16, Int((Double(sourceImage.width) * currentScale).rounded()))
                let targetH = max(16, Int((Double(sourceImage.height) * currentScale).rounded()))
                candidateImage = try ImageProcessor.resampleCGImage(
                    sourceImage,
                    width: targetW,
                    height: targetH,
                    method: .lanczos
                )
            } else {
                candidateImage = sourceImage
            }

            let encoded = try ImageProcessor.encodeToMemory(
                cgImage: candidateImage,
                format: targetFormat,
                quality: currentQuality,
                lossless: isLosslessFormat,
                sourceProperties: preserveMetadata ? decoded.properties : nil,
                preserveMetadata: preserveMetadata
            )

            let candidateSize = Int64(encoded.count)
            if smallestOverall == nil || candidateSize < Int64(smallestOverall!.data.count) {
                smallestOverall = (encoded, currentQuality, currentScale)
            }

            if candidateSize <= targetBytes {
                if bestUnderTarget == nil || candidateSize > Int64(bestUnderTarget!.data.count) {
                    bestUnderTarget = (encoded, currentQuality, currentScale)
                }
                break
            }

            // Adapt quality and/or scale for next bounded iteration
            let ratio = Double(targetBytes) / Double(max(1, candidateSize))
            if isLosslessFormat {
                let nextScale = max(0.15, min(currentScale * 0.85, currentScale * sqrt(ratio) * 0.88))
                if abs(nextScale - currentScale) < 0.01 && currentScale <= 0.16 {
                    break
                }
                currentScale = nextScale
            } else {
                if currentQuality > 0.35 && ratio > 0.25 {
                    currentQuality = max(0.18, min(currentQuality - 0.15, currentQuality * pow(ratio, 0.75)))
                } else {
                    currentQuality = max(0.15, currentQuality * 0.72)
                    let scaleStep = max(0.20, min(0.85, sqrt(ratio) * 0.90))
                    currentScale = max(0.20, currentScale * scaleStep)
                }
            }
        }

        guard let chosen = bestUnderTarget ?? smallestOverall else {
            throw ConversionError.engineExecutionFailed("Image target-size compression produced no output.", underlyingError: nil)
        }

        try chosen.data.write(to: tempOut, options: .atomic)
        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: existingFileHandling)
        let finalBytes = fileSizeBytes(at: committedURL)
        let reached = finalBytes <= targetBytes

        progress(.determinate(1.0, message: String(localized: "Complete")))

        return TargetSizeCompressionResult(
            outputURL: committedURL,
            outputFormat: targetFormat,
            originalBytes: originalBytes,
            finalBytes: finalBytes,
            targetBytes: targetBytes,
            targetReached: reached,
            iterationsUsed: iterationsUsed,
            finalQuality: isLosslessFormat ? nil : chosen.quality,
            finalScaleFactor: chosen.scale,
            finalVideoBitrateBps: nil,
            finalAudioBitrateBps: nil,
            note: reached ? nil : String(localized: "Reached minimum practical quality/scale after \(iterationsUsed) pass(es).")
        )
    }

    // MARK: - PDF Target-Size Compression (Max 4 Bounded Iterations)

    static func compressPDF(
        inputURL: URL,
        targetBytes: Int64,
        outputDirectory: URL,
        existingFileHandling: ExistingFileHandling = .createUnique,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> TargetSizeCompressionResult {
        try Task.checkCancellation()
        guard targetBytes > 0 else {
            throw ConversionError.invalidInput("Target file size must be greater than zero bytes.")
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        let originalBytes = fileSizeBytes(at: inputURL)
        let outputURL = try reserveTargetSizeOutputURL(
            inputURL: inputURL,
            format: .pdf,
            directory: outputDirectory,
            policy: existingFileHandling
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(outputURL) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-TargetPDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 4 progressive compression passes from vector-preserving Quartz down to aggressive rasterization
        let tiers: [(strategy: PDFCompressionStrategy, dpi: Double, quality: Double, grayscale: Bool)] = [
            (.quartzOptimized, 150.0, 0.78, false),
            (.rasterizePages, 110.0, 0.58, false),
            (.rasterizePages, 84.0, 0.38, false),
            (.rasterizePages, 72.0, 0.22, false)
        ]

        var iterationsUsed = 0
        var bestUnderTargetURL: URL? = nil
        var bestUnderTargetBytes: Int64 = 0
        var bestUnderTargetQuality: Double = 0.78

        var smallestURL: URL? = nil
        var smallestBytes: Int64 = .max
        var smallestQuality: Double = 0.78

        for (index, tier) in tiers.enumerated() {
            try Task.checkCancellation()
            let passNumber = index + 1
            iterationsUsed = passNumber

            progress(.determinate(
                0.1 + (Double(index) / Double(maxIterations)) * 0.8,
                message: String(localized: "Optimizing PDF (pass \(passNumber)/\(maxIterations))...")
            ))

            let candidateURL = tempDir.appendingPathComponent("pass_\(passNumber).pdf")
            var opts = PDFCompressionOptions(
                profile: .custom,
                strategy: tier.strategy,
                targetDPI: tier.dpi,
                imageQuality: tier.quality,
                imageCodec: .jpeg,
                stripMetadata: true,
                grayscale: tier.grayscale,
                password: password
            )
            // Keep first pass non-lossy-destructive if possible unless size exceeds target
            if passNumber == 1 {
                opts.stripMetadata = false
            }

            let info = try await PDFCompressionService.compress(
                inputURL: inputURL,
                outputURL: candidateURL,
                options: opts,
                progress: { _ in }
            )

            let size = info.compressedBytes
            if size < smallestBytes {
                smallestBytes = size
                smallestURL = candidateURL
                smallestQuality = tier.quality
            }

            if size <= targetBytes {
                if bestUnderTargetURL == nil || size > bestUnderTargetBytes {
                    bestUnderTargetBytes = size
                    bestUnderTargetURL = candidateURL
                    bestUnderTargetQuality = tier.quality
                }
                break
            }
        }

        guard let winningTemp = bestUnderTargetURL ?? smallestURL else {
            throw ConversionError.engineExecutionFailed("PDF target-size compression produced no output.", underlyingError: nil)
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(winningTemp, to: outputURL, policy: existingFileHandling)
        let finalBytes = fileSizeBytes(at: committedURL)
        let reached = finalBytes <= targetBytes

        progress(.determinate(1.0, message: String(localized: "Complete")))

        return TargetSizeCompressionResult(
            outputURL: committedURL,
            outputFormat: .pdf,
            originalBytes: originalBytes,
            finalBytes: finalBytes,
            targetBytes: targetBytes,
            targetReached: reached,
            iterationsUsed: iterationsUsed,
            finalQuality: bestUnderTargetURL != nil ? bestUnderTargetQuality : smallestQuality,
            finalScaleFactor: nil,
            finalVideoBitrateBps: nil,
            finalAudioBitrateBps: nil,
            note: reached ? nil : String(localized: "Reached minimum PDF rasterization floor after \(iterationsUsed) pass(es).")
        )
    }

    // MARK: - Video Bitrate Budget & Compression (Max 4 Bounded Iterations)

    static func computeVideoBitrateBudget(
        targetBytes: Int64,
        durationSeconds: Double,
        containerOverheadRatio: Double = 0.92,
        scaleMaxWidth: Int? = nil
    ) -> TargetSizeVideoBudget {
        let safeDuration = max(0.25, durationSeconds.isFinite ? durationSeconds : 1.0)
        let safeTarget = max(16_384, targetBytes)
        let clampedOverhead = max(0.70, min(0.98, containerOverheadRatio))

        let totalBits = Double(safeTarget) * 8.0 * clampedOverhead
        let totalBps = totalBits / safeDuration

        let audioBps: Int
        if totalBps < 180_000 {
            audioBps = minimumAudioBitrateBps
        } else if totalBps < 400_000 {
            audioBps = 64_000
        } else if totalBps < 1_000_000 {
            audioBps = 96_000
        } else {
            audioBps = 128_000
        }

        let videoBps = max(minimumVideoBitrateBps, Int(totalBps) - audioBps)
        return TargetSizeVideoBudget(
            targetBytes: safeTarget,
            durationSeconds: safeDuration,
            videoBitrateBps: videoBps,
            audioBitrateBps: audioBps,
            scaleMaxWidth: scaleMaxWidth
        )
    }

    static func compressVideo(
        inputURL: URL,
        outputFormat: FileFormat = .mp4,
        targetBytes: Int64,
        outputDirectory: URL,
        existingFileHandling: ExistingFileHandling = .createUnique,
        runner: any TargetSizeVideoCompressionRunner = LiveTargetSizeVideoRunner(),
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> TargetSizeCompressionResult {
        try Task.checkCancellation()
        guard targetBytes > 0 else {
            throw ConversionError.invalidInput("Target file size must be greater than zero bytes.")
        }
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        let originalBytes = fileSizeBytes(at: inputURL)
        progress(.determinate(0.05, message: String(localized: "Analyzing video duration...")))
        let durationSeconds = try await runner.probeDurationSeconds(url: inputURL)

        let outputURL = try reserveTargetSizeOutputURL(
            inputURL: inputURL,
            format: outputFormat,
            directory: outputDirectory,
            policy: existingFileHandling
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(outputURL) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-TargetVideo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var effectiveTargetBytes = targetBytes
        var scaleMaxWidth: Int? = nil
        var iterationsUsed = 0

        var bestUnderURL: URL? = nil
        var bestUnderBytes: Int64 = 0
        var bestUnderBudget: TargetSizeVideoBudget? = nil

        var smallestURL: URL? = nil
        var smallestBytes: Int64 = .max
        var smallestBudget: TargetSizeVideoBudget? = nil

        for iteration in 1...maxIterations {
            try Task.checkCancellation()
            iterationsUsed = iteration

            let budget = computeVideoBitrateBudget(
                targetBytes: effectiveTargetBytes,
                durationSeconds: durationSeconds,
                containerOverheadRatio: 0.92,
                scaleMaxWidth: scaleMaxWidth
            )

            progress(.determinate(
                0.1 + (Double(iteration - 1) / Double(maxIterations)) * 0.8,
                message: String(localized: "Encoding video at \(budget.videoBitrateBps / 1000) kbps (pass \(iteration)/\(maxIterations))...")
            ))

            let candidateURL = tempDir.appendingPathComponent("pass_\(iteration).\(outputFormat.fileExtension)")
            try await runner.transcode(
                inputURL: inputURL,
                tempOutputURL: candidateURL,
                outputFormat: outputFormat,
                videoBitrateBps: budget.videoBitrateBps,
                audioBitrateBps: budget.audioBitrateBps,
                scaleMaxWidth: budget.scaleMaxWidth,
                progress: { _ in }
            )

            let producedBytes = fileSizeBytes(at: candidateURL)
            if producedBytes > 0 && producedBytes < smallestBytes {
                smallestBytes = producedBytes
                smallestURL = candidateURL
                smallestBudget = budget
            }

            if producedBytes > 0 && producedBytes <= targetBytes {
                if bestUnderURL == nil || producedBytes > bestUnderBytes {
                    bestUnderBytes = producedBytes
                    bestUnderURL = candidateURL
                    bestUnderBudget = budget
                }
                break
            }

            // Tighten bitrate budget proportionally and downscale resolution if needed on later retries
            let overshootRatio = Double(targetBytes) / Double(max(1, producedBytes))
            effectiveTargetBytes = max(16_384, Int64(Double(effectiveTargetBytes) * min(0.88, overshootRatio * 0.90)))
            if iteration >= 2 && budget.videoBitrateBps < 700_000 {
                scaleMaxWidth = (iteration == 2) ? 1280 : 854
            }
        }

        guard let winningTemp = bestUnderURL ?? smallestURL,
              let winningBudget = bestUnderBudget ?? smallestBudget else {
            throw ConversionError.engineExecutionFailed("Video target-size compression produced no output.", underlyingError: nil)
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(winningTemp, to: outputURL, policy: existingFileHandling)
        let finalBytes = fileSizeBytes(at: committedURL)
        let reached = finalBytes <= targetBytes

        progress(.determinate(1.0, message: String(localized: "Complete")))

        return TargetSizeCompressionResult(
            outputURL: committedURL,
            outputFormat: outputFormat,
            originalBytes: originalBytes,
            finalBytes: finalBytes,
            targetBytes: targetBytes,
            targetReached: reached,
            iterationsUsed: iterationsUsed,
            finalQuality: nil,
            finalScaleFactor: nil,
            finalVideoBitrateBps: winningBudget.videoBitrateBps,
            finalAudioBitrateBps: winningBudget.audioBitrateBps,
            note: reached ? nil : String(localized: "Reached minimum video bitrate floor after \(iterationsUsed) pass(es).")
        )
    }

    // MARK: - Helpers

    private static func reserveTargetSizeOutputURL(
        inputURL: URL,
        format: FileFormat,
        directory: URL,
        policy: ExistingFileHandling
    ) throws -> URL {
        let baseName = FileFormat.baseNameByStrippingExtension(from: inputURL) + "_compressed"
        return try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: directory,
            baseName: baseName,
            extension: format.fileExtension,
            sourceURL: inputURL,
            policy: policy == .overwrite ? .createUnique : policy
        )
    }

    private static func fileSizeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

import Foundation
import os.log

// MARK: - BaseFFmpegProvider Audio Toolbox Execution

extension BaseFFmpegProvider {

    func convertBatch(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        if Self.shouldRouteToAudioToolbox(inputs: inputs, outputFormat: outputFormat, options: options) {
            return try await convertBatchWithAudioToolbox(
                inputs: inputs,
                to: outputFormat,
                outputDirectory: outputDirectory,
                options: options,
                progress: progress
            )
        }
        guard let input = inputs.first else {
            throw ConversionError.invalidInput("No inputs provided")
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        let url = try await convert(
            input: input,
            to: outputFormat,
            outputDirectory: outputDirectory,
            options: options,
            progress: progress
        )
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ConversionResult(
            outputURL: url,
            outputFormat: outputFormat,
            fileSize: fileSize,
            duration: duration,
            engineName: "MediaConversionEngine"
        )
    }

    static func shouldRouteToAudioToolbox(
        inputs: [URL],
        outputFormat: FileFormat,
        options: ConversionOptions
    ) -> Bool {
        guard outputFormat.category == .audio else { return false }
        if inputs.count > 1 { return true }
        let custom = options.customOptions
        if custom["audio_operation"] != nil || custom[AudioToolboxConfig.customOptionConfigKey] != nil {
            return true
        }
        let audioKeys = [
            "audio_codec", "audio_bitrate_kbps", "audio_bitrate_mode",
            "audio_vbr_quality", "audio_sample_rate", "audio_bit_depth",
            "audio_channels", "audio_stream_copy"
        ]
        if audioKeys.contains(where: { custom[$0] != nil }) {
            return true
        }
        let config = AudioToolboxConfig.from(options: options, outputFormat: outputFormat)
        return config.requiresAudioFilterProcessing || config.hasTrimWindow || config.operation != .convert
    }

    func convertBatchWithAudioToolbox(
        inputs: [URL],
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> ConversionResult {
        guard let ffmpegPath = await findFFmpegPath(),
              let ffprobePath = await findFFprobePath() else {
            throw ConversionError.engineNotAvailable("FFmpeg is required for audio processing and conversion.")
        }

        guard let primaryInput = inputs.first else {
            throw ConversionError.invalidInput("No input files provided.")
        }

        for url in inputs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConversionError.inputFileNotFound(url)
            }
        }

        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw ConversionError.outputDirectoryNotWritable(outputDirectory)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let config = AudioToolboxConfig.from(options: options, outputFormat: outputFormat)
        let legacyLosslessM4A = (options.customOptions["m4a_lossless"] == "true")

        progress(.determinate(0.05, message: "Analyzing audio streams..."))

        // Probe all inputs
        var inputInfos: [MediaInfo] = []
        for url in inputs {
            try Task.checkCancellation()
            let info = try await MediaProbe.probe(url: url, ffprobePath: ffprobePath)
            guard info.hasAudio else {
                throw ConversionError.invalidInput("'\(url.lastPathComponent)' does not contain an audio stream.")
            }
            inputInfos.append(info)
        }

        guard let primaryInfo = inputInfos.first else {
            throw ConversionError.invalidInput("Unable to inspect audio input.")
        }

        // Pre-flight validation
        let validation = AudioConversionValidator.validate(
            config: config,
            outputFormat: outputFormat,
            sourceInfo: primaryInfo,
            legacyLosslessM4A: legacyLosslessM4A
        )
        if !validation.isValid {
            throw ConversionError.invalidInput(validation.errors.joined(separator: " "))
        }

        if config.operation == .merge && inputs.count < 2 {
            throw ConversionError.invalidInput("At least 2 audio files are required to merge.")
        }

        // Temporary workspace
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvertAudio_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try Task.checkCancellation()

        // Measure peak / EBU R128 parameters before encoding when Peak or Two-Pass EBU R128 normalization is requested
        var loudnessMeasurement: AudioLoudnessMeasurement? = nil
        if config.normalizationMode == .peak || config.normalizationMode == .ebuR128 {
            progress(.determinate(0.12, message: config.normalizationMode == .ebuR128 ? "Analyzing EBU R128 two-pass loudness..." : "Measuring audio peak levels..."))
            let analysis: AudioAnalysisService
            if let bundledSelf = self as? BundledFFmpegProvider {
                analysis = AudioAnalysisService(provider: bundledSelf)
            } else {
                analysis = AudioAnalysisService(provider: BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback))
            }
            loudnessMeasurement = try? await analysis.measureLoudness(
                url: primaryInput,
                targetLUFS: config.targetLUFS,
                targetTruePeakDB: config.targetTruePeakDB,
                includeTwoPassLoudnorm: (config.normalizationMode == .ebuR128)
            )
        }
        let measuredPeakDB = loudnessMeasurement?.maxVolumeDB

        try Task.checkCancellation()

        let effectiveCodec = config.resolvedCodec(for: outputFormat, legacyLosslessM4A: legacyLosslessM4A)
        let metadataArgs = audioMetadataArguments(preserveMetadata: options.preserveMetadata, outputFormat: outputFormat)

        // Dispatch by operation
        switch config.operation {
        case .merge:
            let mergedURL = try await executeAudioMerge(
                inputs: inputs,
                inputInfos: inputInfos,
                config: config,
                outputFormat: outputFormat,
                outputDirectory: outputDirectory,
                tempRoot: tempRoot,
                ffmpegPath: ffmpegPath,
                ffprobePath: ffprobePath,
                options: options,
                metadataArgs: metadataArgs,
                measuredPeakDB: measuredPeakDB,
                loudnessMeasurement: loudnessMeasurement,
                progress: progress
            )
            let size = (try? FileManager.default.attributesOfItem(atPath: mergedURL.path)[.size] as? Int64) ?? 0
            return ConversionResult(
                outputURL: mergedURL,
                outputFormat: outputFormat,
                fileSize: size,
                duration: CFAbsoluteTimeGetCurrent() - startTime,
                engineName: "MediaEngine"
            )

        case .extractSegments:
            let segmentURLs = try await executeMultiSegmentExtraction(
                input: primaryInput,
                inputInfo: primaryInfo,
                config: config,
                effectiveCodec: effectiveCodec,
                outputFormat: outputFormat,
                outputDirectory: outputDirectory,
                tempRoot: tempRoot,
                ffmpegPath: ffmpegPath,
                ffprobePath: ffprobePath,
                options: options,
                metadataArgs: metadataArgs,
                measuredPeakDB: measuredPeakDB,
                loudnessMeasurement: loudnessMeasurement,
                progress: progress
            )
            guard let primaryOut = segmentURLs.first else {
                throw ConversionError.engineExecutionFailed("No segments were produced.", underlyingError: nil)
            }
            let totalSize: Int64 = segmentURLs.reduce(0) { sum, url in
                sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
            }
            return ConversionResult(
                outputURL: primaryOut,
                additionalOutputURLs: Array(segmentURLs.dropFirst()),
                outputFormat: outputFormat,
                fileSize: totalSize,
                duration: CFAbsoluteTimeGetCurrent() - startTime,
                engineName: "MediaEngine"
            )

        case .convert, .trim, .removeSilence:
            let finalURL = try await executeSingleAudioOutput(
                input: primaryInput,
                inputInfo: primaryInfo,
                config: config,
                effectiveCodec: effectiveCodec,
                outputFormat: outputFormat,
                outputDirectory: outputDirectory,
                tempRoot: tempRoot,
                ffmpegPath: ffmpegPath,
                ffprobePath: ffprobePath,
                options: options,
                metadataArgs: metadataArgs,
                measuredPeakDB: measuredPeakDB,
                loudnessMeasurement: loudnessMeasurement,
                progress: progress
            )
            let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
            return ConversionResult(
                outputURL: finalURL,
                outputFormat: outputFormat,
                fileSize: size,
                duration: CFAbsoluteTimeGetCurrent() - startTime,
                engineName: "MediaEngine"
            )
        }
    }

    // MARK: - Single Output Execution

    private func executeSingleAudioOutput(
        input: URL,
        inputInfo: MediaInfo,
        config: AudioToolboxConfig,
        effectiveCodec: AudioCodecID,
        outputFormat: FileFormat,
        outputDirectory: URL,
        tempRoot: URL,
        ffmpegPath: String,
        ffprobePath: String,
        options: ConversionOptions,
        metadataArgs: [String],
        measuredPeakDB: Double?,
        loudnessMeasurement: AudioLoudnessMeasurement?,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL {
        let tempOutput = tempRoot.appendingPathComponent("output.\(outputFormat.fileExtension)")
        var args: [String] = ["-y", "-hide_banner", "-progress", "pipe:1", "-nostats"]
        let keepCoverArt = !inputInfo.hasRealVideo
            && inputInfo.hasAttachedArtwork
            && options.preserveMetadata
            && AudioCodecRegistry.supportsCoverArt(for: outputFormat)
        let streamMappingArgs = keepCoverArt
            ? ["-map", "0:a", "-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic", "-sn", "-dn"]
            : ["-vn", "-sn", "-dn"]

        if effectiveCodec == .streamCopy {
            if let start = config.trimStartSeconds, start > 0 {
                args += ["-ss", String(format: "%.4f", start)]
            }
            args += ["-i", input.path]
            if let end = config.trimEndSeconds, end > 0 {
                let start = max(0, config.trimStartSeconds ?? 0)
                if end > start {
                    args += ["-t", String(format: "%.4f", end - start)]
                }
            }
            args += streamMappingArgs
            args += metadataArgs
            args += AudioFilterGraphBuilder.codecArguments(config: config, outputFormat: outputFormat, options: options)
            args.append(tempOutput.path)
        } else {
            args += ["-i", input.path]
            args += streamMappingArgs
            args += metadataArgs
            let filters = AudioFilterGraphBuilder.buildFilterChain(
                config: config,
                sourceInfo: inputInfo,
                measuredPeakDB: measuredPeakDB,
                loudnessMeasurement: loudnessMeasurement
            )
            if !filters.isEmpty {
                args += ["-af", filters.joined(separator: ",")]
            }
            args += AudioFilterGraphBuilder.codecArguments(config: config, outputFormat: outputFormat, options: options)
            args.append(tempOutput.path)
        }

        let estimatedDuration = max(0.1, inputInfo.duration / max(0.25, config.speedMultiplier))
        let stderrLog = try await runAudioFFmpegProcess(
            executablePath: ffmpegPath,
            arguments: args,
            expectedDuration: estimatedDuration,
            progressRange: 0.15...0.95,
            statusMessage: "Processing audio...",
            progress: progress
        )

        guard FileManager.default.fileExists(atPath: tempOutput.path) else {
            throw ConversionError.engineExecutionFailed("FFmpeg finished, but output audio was not created.", underlyingError: nil)
        }

        _ = try await MediaProbe.validate(outputURL: tempOutput, expectedFormat: outputFormat, ffprobePath: ffprobePath)
        let finalURL = try ConversionManager.finalizeOutputFile(
            from: tempOutput,
            for: input,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )
        if config.normalizationMode == .ebuR128,
           let normType = AudioAnalysisService.parseLoudnessMeasurement(from: stderrLog).normalizationTypeUsed {
            await AudioAnalysisService.shared.recordNormalizationMode(normType, for: finalURL)
        } else if config.normalizationMode == .peak {
            await AudioAnalysisService.shared.recordNormalizationMode("peak", for: finalURL)
        }
        progress(.determinate(1.0, message: "Complete"))
        return finalURL
    }

    // MARK: - Multi-Segment Extraction

    private func executeMultiSegmentExtraction(
        input: URL,
        inputInfo: MediaInfo,
        config: AudioToolboxConfig,
        effectiveCodec: AudioCodecID,
        outputFormat: FileFormat,
        outputDirectory: URL,
        tempRoot: URL,
        ffmpegPath: String,
        ffprobePath: String,
        options: ConversionOptions,
        metadataArgs: [String],
        measuredPeakDB: Double?,
        loudnessMeasurement: AudioLoudnessMeasurement?,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> [URL] {
        var finalURLs: [URL] = []
        var reservedURLs: [URL] = []
        defer {
            for reserved in reservedURLs {
                ConversionManager.releaseReservedOutputURL(reserved)
            }
        }
        let total = config.segments.count
        let keepCoverArt = !inputInfo.hasRealVideo
            && inputInfo.hasAttachedArtwork
            && options.preserveMetadata
            && AudioCodecRegistry.supportsCoverArt(for: outputFormat)
        let streamMappingArgs = keepCoverArt
            ? ["-map", "0:a", "-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic", "-sn", "-dn"]
            : ["-vn", "-sn", "-dn"]

        do {
            for (index, segment) in config.segments.enumerated() {
                try Task.checkCancellation()

                let tempOutput = tempRoot.appendingPathComponent("segment_\(index + 1).\(outputFormat.fileExtension)")
                var args: [String] = ["-y", "-hide_banner", "-progress", "pipe:1", "-nostats"]

                if effectiveCodec == .streamCopy {
                    args += ["-ss", String(format: "%.4f", segment.startTime)]
                    args += ["-i", input.path]
                    args += ["-t", String(format: "%.4f", segment.duration)]
                    args += streamMappingArgs
                    args += metadataArgs
                    args += AudioFilterGraphBuilder.codecArguments(config: config, outputFormat: outputFormat, options: options)
                    args.append(tempOutput.path)
                } else {
                    args += ["-i", input.path]
                    args += streamMappingArgs
                    args += metadataArgs
                    let filters = AudioFilterGraphBuilder.buildFilterChain(
                        config: config,
                        sourceInfo: inputInfo,
                        measuredPeakDB: measuredPeakDB,
                        loudnessMeasurement: loudnessMeasurement,
                        trimStartOverride: segment.startTime,
                        trimEndOverride: segment.endTime
                    )
                    if !filters.isEmpty {
                        args += ["-af", filters.joined(separator: ",")]
                    }
                    args += AudioFilterGraphBuilder.codecArguments(config: config, outputFormat: outputFormat, options: options)
                    args.append(tempOutput.path)
                }

                let stepStart = 0.15 + (0.80 * Double(index) / Double(max(1, total)))
                let stepEnd = 0.15 + (0.80 * Double(index + 1) / Double(max(1, total)))
                try await runAudioFFmpegProcess(
                    executablePath: ffmpegPath,
                    arguments: args,
                    expectedDuration: max(0.1, segment.duration),
                    progressRange: stepStart...stepEnd,
                    statusMessage: "Extracting segment \(index + 1) of \(total)...",
                    progress: progress
                )

                _ = try await MediaProbe.validate(outputURL: tempOutput, expectedFormat: outputFormat, ffprobePath: ffprobePath)
                let baseName = segmentBaseName(
                    baseInput: input,
                    segment: segment,
                    index: index + 1
                )
                let destURL = try ConversionManager.reserveUniqueOutputURL(
                    directory: outputDirectory,
                    baseName: baseName,
                    extension: outputFormat.fileExtension,
                    sourceURL: input,
                    policy: options.resolvedExistingFileHandling
                )
                reservedURLs.append(destURL)
                if options.resolvedExistingFileHandling == .overwrite,
                   FileManager.default.fileExists(atPath: destURL.path) {
                    _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tempOutput)
                } else {
                    try FileManager.default.moveItem(at: tempOutput, to: destURL)
                }
                finalURLs.append(destURL)
            }
        } catch {
            for url in finalURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        progress(.determinate(1.0, message: "Complete"))
        return finalURLs
    }

    // MARK: - Multi-File Audio Merge

    private func executeAudioMerge(
        inputs: [URL],
        inputInfos: [MediaInfo],
        config: AudioToolboxConfig,
        outputFormat: FileFormat,
        outputDirectory: URL,
        tempRoot: URL,
        ffmpegPath: String,
        ffprobePath: String,
        options: ConversionOptions,
        metadataArgs: [String],
        measuredPeakDB: Double?,
        loudnessMeasurement: AudioLoudnessMeasurement?,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL {
        let tempOutput = tempRoot.appendingPathComponent("merged.\(outputFormat.fileExtension)")
        var args: [String] = ["-y", "-hide_banner", "-progress", "pipe:1", "-nostats"]

        for url in inputs {
            args += ["-i", url.path]
        }

        let targetSR = config.sampleRateHz ?? (inputInfos.first?.primaryAudioStream?.sampleRate ?? 44100)
        let targetCh = config.channelMode.channelCount ?? (inputInfos.first?.primaryAudioStream?.channels ?? 2)
        let layout: String
        switch targetCh {
        case 1: layout = "mono"
        case 3: layout = "2.1"
        case 6: layout = "5.1"
        case 8: layout = "7.1"
        default: layout = "stereo"
        }

        var graphParts: [String] = []
        var concatInputs = ""
        let resampler = config.resamplerEngine == .kaiserSinc ? ":filter_type=kaiser:filter_size=32:exact_rational=1" : ""
        for idx in 0..<inputs.count {
            graphParts.append("[\(idx):a]aresample=\(targetSR):async=1\(resampler),aformat=channel_layouts=\(layout):sample_fmts=fltp[a\(idx)]")
            concatInputs += "[a\(idx)]"
        }

        let minSegDur = inputInfos.map(\.duration).filter { $0 > 0 }.min() ?? 0
        let rawCrossfade = config.mergeCrossfadeSeconds
        let effectiveCrossfade = (inputs.count >= 2 && rawCrossfade > 0.05 && minSegDur > rawCrossfade * 1.1) ? rawCrossfade : 0.0
        let totalMergedDuration = max(0.1, inputInfos.reduce(0.0) { $0 + $1.duration } - effectiveCrossfade * Double(max(0, inputs.count - 1)))

        var postConfig = config
        postConfig.trimStartSeconds = nil
        postConfig.trimEndSeconds = nil

        let syntheticMergedInfo = MediaInfo(
            url: inputs[0],
            formatName: outputFormat.fileExtension,
            duration: totalMergedDuration,
            fileSize: nil,
            bitRate: inputInfos.first?.bitRate,
            streams: [
                MediaStreamInfo(
                    index: 0,
                    streamType: .audio,
                    codecName: outputFormat.fileExtension,
                    codecLongName: nil,
                    bitRate: nil,
                    width: nil,
                    height: nil,
                    frameRate: nil,
                    sampleRate: targetSR,
                    channels: targetCh,
                    duration: totalMergedDuration
                )
            ]
        )

        let postFilters = AudioFilterGraphBuilder.buildFilterChain(
            config: postConfig,
            sourceInfo: syntheticMergedInfo,
            measuredPeakDB: measuredPeakDB,
            loudnessMeasurement: loudnessMeasurement
        )

        let combinedLabel = postFilters.isEmpty ? "[outa]" : "[merged]"
        if effectiveCrossfade > 0.05 {
            var currentLabel = "[a0]"
            let cfStr = String(format: "%.3f", effectiveCrossfade)
            for idx in 1..<inputs.count {
                let isLast = (idx == inputs.count - 1)
                let outLabel = isLast ? combinedLabel : "[cf\(idx)]"
                graphParts.append("\(currentLabel)[a\(idx)]acrossfade=d=\(cfStr):c1=qsin:c2=qsin\(outLabel)")
                currentLabel = outLabel
            }
        } else {
            graphParts.append("\(concatInputs)concat=n=\(inputs.count):v=0:a=1\(combinedLabel)")
        }

        if !postFilters.isEmpty {
            graphParts.append("[merged]\(postFilters.joined(separator: ","))[outa]")
        }

        args += ["-filter_complex", graphParts.joined(separator: ";")]
        args += ["-map", "[outa]"]
        args += metadataArgs
        args += AudioFilterGraphBuilder.codecArguments(config: config, outputFormat: outputFormat, options: options)
        args.append(tempOutput.path)

        try await runAudioFFmpegProcess(
            executablePath: ffmpegPath,
            arguments: args,
            expectedDuration: totalMergedDuration,
            progressRange: 0.15...0.95,
            statusMessage: "Merging \(inputs.count) audio files...",
            progress: progress
        )

        _ = try await MediaProbe.validate(outputURL: tempOutput, expectedFormat: outputFormat, ffprobePath: ffprobePath)

        let baseName = inputs[0].deletingPathExtension().lastPathComponent + "_merged"
        let syntheticInput = inputs[0].deletingLastPathComponent().appendingPathComponent("\(baseName).\(inputs[0].pathExtension)")
        let finalURL = try ConversionManager.finalizeOutputFile(
            from: tempOutput,
            for: syntheticInput,
            format: outputFormat,
            in: outputDirectory,
            options: options
        )

        progress(.determinate(1.0, message: "Complete"))
        return finalURL
    }

    // MARK: - Helpers

    private func audioMetadataArguments(preserveMetadata: Bool, outputFormat: FileFormat) -> [String] {
        if preserveMetadata {
            var args = ["-map_metadata", "0"]
            if outputFormat == .mp3 {
                args += ["-id3v2_version", "3"]
            }
            return args
        } else {
            return ["-map_metadata", "-1"]
        }
    }

    private func segmentBaseName(
        baseInput: URL,
        segment: AudioTrimSegment,
        index: Int
    ) -> String {
        let baseName = baseInput.deletingPathExtension().lastPathComponent
        let cleanLabel = segment.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let suffix = cleanLabel.isEmpty ? "part\(index)" : cleanLabel
        return "\(baseName)_\(suffix)"
    }

    @discardableResult
    private func runAudioFFmpegProcess(
        executablePath: String,
        arguments: [String],
        expectedDuration: Double,
        progressRange: ClosedRange<Double>,
        statusMessage: String,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> String {
        let processHolder = AudioProcessHolder()

        return try await withoutActuallyEscaping(progress) { escapingProgress in
            let progressRelay = AudioProgressRelay(escapingProgress)
            defer { progressRelay.clear() }

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe

                    processHolder.set(process)

                    let stderrBuffer = LockedDataBuffer()

                    errPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            stderrBuffer.append(data)
                        }
                    }

                    outPipe.fileHandleForReading.readabilityHandler = { handle in
                        guard !processHolder.isFinished else { return }
                        let data = handle.availableData
                        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                        for line in chunk.components(separatedBy: .newlines) {
                            if line.hasPrefix("out_time_us="),
                               let us = Double(line.replacingOccurrences(of: "out_time_us=", with: "").trimmingCharacters(in: .whitespaces)) {
                                let seconds = max(0, us / 1_000_000.0)
                                let fraction = min(1.0, seconds / max(0.1, expectedDuration))
                                let mapped = progressRange.lowerBound + fraction * (progressRange.upperBound - progressRange.lowerBound)
                                progressRelay.send(.determinate(mapped, message: statusMessage))
                            }
                        }
                    }

                    process.terminationHandler = { proc in
                        processHolder.markFinished()
                        progressRelay.clear()
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        let remErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                        if !remErr.isEmpty {
                            stderrBuffer.append(remErr)
                        }
                        let stderrText = String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? ""

                        if processHolder.isCancelled || proc.terminationReason == .uncaughtSignal {
                            continuation.resume(throwing: ConversionError.cancelled)
                        } else if proc.terminationStatus == 0 {
                            continuation.resume(returning: stderrText)
                        } else {
                            let lastLine = stderrText.components(separatedBy: .newlines).reversed().first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? stderrText
                            continuation.resume(throwing: ConversionError.engineExecutionFailed(lastLine, underlyingError: stderrText))
                        }
                    }

                    do {
                        try process.run()
                        if processHolder.isCancelled && process.isRunning {
                            process.terminate()
                        }
                    } catch {
                        processHolder.markFinished()
                        progressRelay.clear()
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: ConversionError.engineExecutionFailed("Failed to launch FFmpeg: \(error.localizedDescription)", underlyingError: nil))
                    }
                }
            } onCancel: {
                processHolder.cancelAndTerminate()
            }
        }
    }
}

private final class AudioProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ConversionProgress) -> Void)?

    init(_ handler: @escaping @Sendable (ConversionProgress) -> Void) {
        self.handler = handler
    }

    func send(_ progress: ConversionProgress) {
        let fn = lock.withLock { handler }
        fn?(progress)
    }

    func clear() {
        lock.withLock { handler = nil }
    }
}

final class AudioProcessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func markFinished() {
        lock.withLock { finished = true }
    }

    func set(_ p: Process) {
        lock.withLock {
            process = p
            if cancelled && p.isRunning {
                p.terminate()
            }
        }
    }

    func cancelAndTerminate() {
        lock.withLock {
            cancelled = true
            if let p = process, p.isRunning {
                p.terminate()
            }
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    func snapshot() -> Data {
        lock.withLock { data }
    }
}

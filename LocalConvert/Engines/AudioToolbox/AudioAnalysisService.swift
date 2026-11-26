import Foundation

// MARK: - Audio Analysis Service (Waveform, Silence Detection, Loudness Inspection)

actor AudioAnalysisService {

    static let shared = AudioAnalysisService()

    private let provider: BundledFFmpegProvider
    private var waveformCache: [String: AudioWaveformData] = [:]
    private var waveformCacheOrder: [String] = []
    private var waveformCacheBytesByKey: [String: Int] = [:]
    private var waveformCacheTotalBytes: Int = 0
    private var waveformCacheHitCount: Int = 0
    private var waveformCacheMissCount: Int = 0
    private var waveformCacheEvictionCount: Int = 0
    private let maxWaveformCacheEntries = 32
    private let maxWaveformCacheBytes = 8 * 1024 * 1024

    init(provider: BundledFFmpegProvider = BundledFFmpegProvider()) {
        self.provider = provider
    }

    // MARK: - Real PCM Waveform Extraction

    /// Decodes mono 8 kHz float32 PCM via bundled FFmpeg using streaming O(bins) accumulation into `[0.0...1.0]` peak & RMS bins.
    func extractWaveform(url: URL, bins: Int = 220, startTime: Double? = nil, endTime: Double? = nil) async throws -> AudioWaveformData {
        guard let ffmpegPath = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("Bundled FFmpeg")
        }

        let targetBins = max(32, min(1000, bins))
        let cacheKey = makeWaveformCacheKey(url: url, bins: targetBins, startTime: startTime, endTime: endTime)
        if let cached = waveformCache[cacheKey] {
            waveformCacheHitCount += 1
            if let idx = waveformCacheOrder.firstIndex(of: cacheKey) {
                waveformCacheOrder.remove(at: idx)
                waveformCacheOrder.append(cacheKey)
            }
            return cached
        }
        waveformCacheMissCount += 1

        let info = try await provider.probe(url: url)

        var ffArgs: [String] = ["-v", "error"]
        let windowStart = max(0, startTime ?? 0)
        let effectiveEnd = (endTime ?? info.duration) > windowStart ? (endTime ?? info.duration) : info.duration
        if windowStart > 0.01 {
            ffArgs += ["-ss", String(format: "%.3f", windowStart)]
        }
        ffArgs += ["-i", url.path]
        if let e = endTime, e > windowStart + 0.02 {
            ffArgs += ["-t", String(format: "%.3f", e - windowStart)]
        }
        let targetSampleRate = (effectiveEnd - windowStart) > 0 && (effectiveEnd - windowStart) < 30 ? 16000 : 8000
        ffArgs += ["-vn", "-ac", "1", "-ar", "\(targetSampleRate)", "-f", "f32le", "pipe:1"]

        let windowDuration = max(0, effectiveEnd - windowStart)
        let expectedSamples = windowDuration > 0 ? Int(windowDuration * Double(targetSampleRate)) : 0

        if expectedSamples > 0 {
            let result = try await streamWaveformBins(
                executablePath: ffmpegPath,
                arguments: ffArgs,
                targetBins: targetBins,
                expectedSamples: expectedSamples
            )
            let actualDur = info.duration > 0 ? info.duration : (Double(result.totalSamples) / Double(targetSampleRate))
            let waveform = AudioWaveformData(
                peaks: result.peaks,
                rms: result.rms,
                duration: actualDur,
                sampleRate: info.primaryAudioStream?.sampleRate ?? 44100,
                channels: info.primaryAudioStream?.channels ?? 1
            )
            cacheWaveform(waveform, forKey: cacheKey)
            return waveform
        }

        let pcmData = try await runFFmpegStdoutData(executablePath: ffmpegPath, arguments: ffArgs)
        try Task.checkCancellation()

        let sampleCount = pcmData.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else {
            return AudioWaveformData(
                peaks: Array(repeating: 0, count: targetBins),
                rms: Array(repeating: 0, count: targetBins),
                duration: info.duration,
                sampleRate: info.primaryAudioStream?.sampleRate ?? 44100,
                channels: info.primaryAudioStream?.channels ?? 1
            )
        }

        var peaks = [Float](repeating: 0, count: targetBins)
        var rmsValues = [Float](repeating: 0, count: targetBins)

        pcmData.withUnsafeBytes { rawBuffer in
            let floats = rawBuffer.bindMemory(to: Float.self)
            let samplesPerBin = max(1, sampleCount / targetBins)

            for bin in 0..<targetBins {
                let start = bin * samplesPerBin
                let end = (bin == targetBins - 1) ? sampleCount : min(sampleCount, start + samplesPerBin)
                guard start < end else { continue }

                var maxAbs: Float = 0
                var sumSquares: Double = 0
                var count = 0

                for idx in start..<end {
                    let s = floats[idx]
                    guard s.isFinite else { continue }
                    let absVal = abs(s)
                    if absVal > maxAbs { maxAbs = absVal }
                    sumSquares += Double(s * s)
                    count += 1
                }

                peaks[bin] = min(1.0, maxAbs)
                rmsValues[bin] = count > 0 ? min(1.0, Float(sqrt(sumSquares / Double(count)))) : 0
            }
        }

        let detectedDuration = info.duration > 0 ? info.duration : (Double(sampleCount) / Double(targetSampleRate))
        let waveform = AudioWaveformData(
            peaks: peaks,
            rms: rmsValues,
            duration: detectedDuration,
            sampleRate: info.primaryAudioStream?.sampleRate ?? 44100,
            channels: info.primaryAudioStream?.channels ?? 1
        )
        cacheWaveform(waveform, forKey: cacheKey)
        return waveform
    }

    private func makeWaveformCacheKey(
        url: URL,
        bins: Int,
        startTime: Double?,
        endTime: Double?
    ) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let sKey = startTime.map { String(format: "%.3f", $0) } ?? "nil"
        let eKey = endTime.map { String(format: "%.3f", $0) } ?? "nil"
        return "\(url.standardizedFileURL.path)|\(size)|\(String(format: "%.6f", mtime))|\(bins)|\(sKey)|\(eKey)"
    }

    private func estimatedBytes(for waveform: AudioWaveformData, key: String) -> Int {
        (waveform.peaks.count + waveform.rms.count) * MemoryLayout<Float>.size + key.utf8.count + 64
    }

    private func cacheWaveform(_ waveform: AudioWaveformData, forKey key: String) {
        let entryBytes = estimatedBytes(for: waveform, key: key)
        if let prevBytes = waveformCacheBytesByKey[key] {
            waveformCacheTotalBytes = max(0, waveformCacheTotalBytes - prevBytes)
        } else {
            waveformCacheOrder.append(key)
        }
        waveformCache[key] = waveform
        waveformCacheBytesByKey[key] = entryBytes
        waveformCacheTotalBytes += entryBytes
        while waveformCacheOrder.count > maxWaveformCacheEntries || waveformCacheTotalBytes > maxWaveformCacheBytes {
            guard !waveformCacheOrder.isEmpty else { break }
            let evicted = waveformCacheOrder.removeFirst()
            waveformCache.removeValue(forKey: evicted)
            if let removedBytes = waveformCacheBytesByKey.removeValue(forKey: evicted) {
                waveformCacheTotalBytes = max(0, waveformCacheTotalBytes - removedBytes)
            }
            waveformCacheEvictionCount += 1
        }
    }

    struct WaveformCacheDiagnostics: Sendable, Equatable {
        let entryCount: Int
        let totalBytes: Int
        let maxEntries: Int
        let maxBytes: Int
        let hits: Int
        let misses: Int
        let evictions: Int
    }

    func cacheDiagnostics() -> WaveformCacheDiagnostics {
        WaveformCacheDiagnostics(
            entryCount: waveformCache.count,
            totalBytes: waveformCacheTotalBytes,
            maxEntries: maxWaveformCacheEntries,
            maxBytes: maxWaveformCacheBytes,
            hits: waveformCacheHitCount,
            misses: waveformCacheMissCount,
            evictions: waveformCacheEvictionCount
        )
    }

    func resetCacheForTesting() {
        waveformCache.removeAll()
        waveformCacheOrder.removeAll()
        waveformCacheBytesByKey.removeAll()
        waveformCacheTotalBytes = 0
        waveformCacheHitCount = 0
        waveformCacheMissCount = 0
        waveformCacheEvictionCount = 0
    }

    private func streamWaveformBins(
        executablePath: String,
        arguments: [String],
        targetBins: Int,
        expectedSamples: Int
    ) async throws -> (peaks: [Float], rms: [Float], totalSamples: Int) {
        let holder = AudioProcessHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                holder.set(process)

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        if holder.isCancelled {
                            continuation.resume(throwing: ConversionError.cancelled)
                            return
                        }
                        try process.run()
                        if holder.isCancelled {
                            holder.cancelAndTerminate()
                        }
                        var peaks = [Float](repeating: 0, count: targetBins)
                        var sumSquares = [Double](repeating: 0, count: targetBins)
                        var counts = [Int](repeating: 0, count: targetBins)
                        var leftover = Data()
                        var sampleIdx = 0
                        let safeTotal = max(1, expectedSamples)

                        while true {
                            if holder.isCancelled {
                                holder.cancelAndTerminate()
                                try? outPipe.fileHandleForReading.close()
                                break
                            }
                            let chunk = outPipe.fileHandleForReading.readData(ofLength: 65536)
                            if chunk.isEmpty { break }
                            let combined = leftover.isEmpty ? chunk : (leftover + chunk)
                            let usableBytes = (combined.count / 4) * 4
                            if usableBytes < combined.count {
                                leftover = Data(combined.suffix(combined.count - usableBytes))
                            } else {
                                leftover.removeAll(keepingCapacity: true)
                            }
                            if usableBytes > 0 {
                                combined.prefix(usableBytes).withUnsafeBytes { raw in
                                    let floats = raw.bindMemory(to: Float.self)
                                    for i in 0..<floats.count {
                                        let s = floats[i]
                                        if s.isFinite {
                                            let bin = min(targetBins - 1, (sampleIdx * targetBins) / safeTotal)
                                            let absS = abs(s)
                                            if absS > peaks[bin] { peaks[bin] = min(1.0, absS) }
                                            sumSquares[bin] += Double(s * s)
                                            counts[bin] += 1
                                        }
                                        sampleIdx += 1
                                    }
                                }
                            }
                        }

                        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()

                        if holder.isCancelled {
                            continuation.resume(throwing: ConversionError.cancelled)
                            return
                        }
                        guard process.terminationStatus == 0 else {
                            let rawErr = String(data: stderrData, encoding: .utf8) ?? "FFmpeg exited with code \(process.terminationStatus)"
                            continuation.resume(throwing: ConversionError.engineExecutionFailed(
                                "Audio waveform analysis could not read the stream (FFmpeg exit code \(process.terminationStatus)).",
                                underlyingError: rawErr
                            ))
                            return
                        }
                        var rms = [Float](repeating: 0, count: targetBins)
                        for b in 0..<targetBins where counts[b] > 0 {
                            rms[b] = min(1.0, Float(sqrt(sumSquares[b] / Double(counts[b]))))
                        }
                        continuation.resume(returning: (peaks, rms, sampleIdx))
                    } catch {
                        holder.cancelAndTerminate()
                        continuation.resume(throwing: ConversionError.engineExecutionFailed(error.localizedDescription, underlyingError: nil))
                    }
                }
            }
        } onCancel: {
            holder.cancelAndTerminate()
        }
    }

    // MARK: - Silence Detection

    func detectSilence(
        url: URL,
        noiseThresholdDB: Double = -45.0,
        minDuration: Double = 0.5
    ) async throws -> [AudioSilenceInterval] {
        guard let ffmpegPath = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("Bundled FFmpeg")
        }

        let filter = String(format: "silencedetect=noise=%.1fdB:d=%.2f", noiseThresholdDB, max(0.05, minDuration))
        let stderr = try await runFFmpegStderr(
            executablePath: ffmpegPath,
            arguments: [
                "-hide_banner",
                "-i", url.path,
                "-vn",
                "-af", filter,
                "-f", "null",
                "-"
            ]
        )

        return Self.parseSilenceIntervals(from: stderr)
    }

    // MARK: - Peak & Loudness Measurement

    private var lastNormalizationModes: [String: String] = [:]
    private var lastNormalizationModeOrder: [String] = []
    private let maxNormalizationModeEntries = 256

    func recordNormalizationMode(_ mode: String, for outputURL: URL) {
        let key = outputURL.standardizedFileURL.path
        if lastNormalizationModes[key] == nil {
            lastNormalizationModeOrder.append(key)
        }
        lastNormalizationModes[key] = mode
        while lastNormalizationModeOrder.count > maxNormalizationModeEntries {
            let evicted = lastNormalizationModeOrder.removeFirst()
            lastNormalizationModes.removeValue(forKey: evicted)
        }
    }

    func lastRecordedNormalizationMode(for outputURL: URL) -> String? {
        lastNormalizationModes[outputURL.standardizedFileURL.path]
    }

    func normalizationModeCacheDiagnostics() -> (entryCount: Int, maxEntries: Int) {
        (lastNormalizationModes.count, maxNormalizationModeEntries)
    }

    func resetNormalizationModeCacheForTesting() {
        lastNormalizationModes.removeAll()
        lastNormalizationModeOrder.removeAll()
    }

    func measureLoudness(
        url: URL,
        targetLUFS: Double = -14.0,
        targetTruePeakDB: Double = -1.0,
        includeTwoPassLoudnorm: Bool = false
    ) async throws -> AudioLoudnessMeasurement {
        guard let ffmpegPath = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("Bundled FFmpeg")
        }

        var filters = "volumedetect,ebur128=peak=true+sample"
        if includeTwoPassLoudnorm {
            let iVal = min(-5.0, max(-36.0, targetLUFS))
            let tpVal = min(0.0, max(-9.0, targetTruePeakDB))
            filters = String(format: "volumedetect,ebur128=peak=true+sample,loudnorm=I=%.1f:TP=%.1f:LRA=11:print_format=json", iVal, tpVal)
        }

        let stderr = try await runFFmpegStderr(
            executablePath: ffmpegPath,
            arguments: [
                "-hide_banner",
                "-nostats",
                "-i", url.path,
                "-vn",
                "-af", filters,
                "-f", "null",
                "-"
            ]
        )

        return Self.parseLoudnessMeasurement(from: stderr)
    }

    // MARK: - Parsing Helpers

    nonisolated static func parseSilenceIntervals(from stderr: String) -> [AudioSilenceInterval] {
        var intervals: [AudioSilenceInterval] = []
        var pendingStart: Double?

        for line in stderr.components(separatedBy: .newlines) {
            if let range = line.range(of: "silence_start:") {
                let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if let firstToken = tail.split(separator: " ").first, let startVal = Double(firstToken) {
                    pendingStart = startVal
                }
            } else if let endRange = line.range(of: "silence_end:") {
                let tail = line[endRange.upperBound...]
                let parts = tail.components(separatedBy: "|")
                let endStr = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let endVal = Double(endStr)
                var durVal: Double?
                if parts.count > 1, let dRange = parts[1].range(of: "silence_duration:") {
                    let durStr = parts[1][dRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    durVal = Double(durStr)
                }
                if let endVal {
                    let startVal = pendingStart ?? max(0, endVal - (durVal ?? 0))
                    let duration = durVal ?? max(0, endVal - startVal)
                    intervals.append(AudioSilenceInterval(start: startVal, end: endVal, duration: duration))
                    pendingStart = nil
                }
            }
        }
        return intervals
    }

    nonisolated static func parseLoudnessMeasurement(from stderr: String) -> AudioLoudnessMeasurement {
        var maxVol: Double?
        var meanVol: Double?
        var integratedLUFS: Double?
        var truePeakDBTP: Double?
        var lraLU: Double?
        var threshLUFS: Double?

        var lnI: Double?
        var lnTP: Double?
        var lnLRA: Double?
        var lnThresh: Double?
        var lnOffset: Double?
        var normType: String?
        var predOutI: Double?
        var predOutTP: Double?
        var peakSection = ""

        for line in stderr.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "Sample peak:" {
                peakSection = "sample"
                continue
            } else if trimmedLine == "True peak:" {
                peakSection = "true"
                continue
            }

            if let r = line.range(of: "max_volume:") {
                let token = line[r.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first
                if let token, let val = Double(token) { maxVol = val }
            } else if let r = line.range(of: "mean_volume:") {
                let token = line[r.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first
                if let token, let val = Double(token) { meanVol = val }
            } else if line.contains("I:") && line.contains("LUFS") {
                let tokens = trimmedLine.split(whereSeparator: { $0.isWhitespace })
                if let idx = tokens.firstIndex(of: "I:"), idx + 1 < tokens.count,
                   let val = Double(tokens[idx + 1]) {
                    integratedLUFS = val
                }
            } else if line.contains("LRA:") && line.contains("LU") {
                let tokens = trimmedLine.split(whereSeparator: { $0.isWhitespace })
                if let idx = tokens.firstIndex(of: "LRA:"), idx + 1 < tokens.count,
                   let val = Double(tokens[idx + 1]) {
                    lraLU = val
                }
            } else if line.contains("Threshold:") && line.contains("LUFS") {
                let tokens = trimmedLine.split(whereSeparator: { $0.isWhitespace })
                if let idx = tokens.firstIndex(of: "Threshold:"), idx + 1 < tokens.count,
                   let val = Double(tokens[idx + 1]) {
                    if threshLUFS == nil { threshLUFS = val }
                }
            } else if line.contains("Peak:") && line.contains("dBFS") {
                let tokens = trimmedLine.split(whereSeparator: { $0.isWhitespace })
                if let idx = tokens.firstIndex(of: "Peak:"), idx + 1 < tokens.count,
                   let val = Double(tokens[idx + 1]) {
                    if peakSection == "sample" {
                        if maxVol == nil { maxVol = val }
                    } else {
                        truePeakDBTP = val
                    }
                }
            }
        }

        // Parse JSON block emitted by `loudnorm=...:print_format=json`
        if let startBrace = stderr.range(of: "{\n\t\"input_i\"", options: .backwards) ?? stderr.range(of: "\"input_i\"", options: .backwards).flatMap({ r in stderr[..<r.lowerBound].range(of: "{", options: .backwards) }),
           let endBrace = stderr[startBrace.lowerBound...].range(of: "}") {
            let jsonSlice = String(stderr[startBrace.lowerBound...endBrace.upperBound])
            if let jsonData = jsonSlice.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                lnI = (dict["input_i"] as? String).flatMap(Double.init)
                lnTP = (dict["input_tp"] as? String).flatMap(Double.init)
                lnLRA = (dict["input_lra"] as? String).flatMap(Double.init)
                lnThresh = (dict["input_thresh"] as? String).flatMap(Double.init)
                lnOffset = (dict["target_offset"] as? String).flatMap(Double.init)
                normType = dict["normalization_type"] as? String
                predOutI = (dict["output_i"] as? String).flatMap(Double.init)
                predOutTP = (dict["output_tp"] as? String).flatMap(Double.init)
                if integratedLUFS == nil, let lnI, lnI.isFinite { integratedLUFS = lnI }
                if truePeakDBTP == nil, let lnTP, lnTP.isFinite { truePeakDBTP = lnTP }
                if lraLU == nil, let lnLRA, lnLRA.isFinite { lraLU = lnLRA }
                if threshLUFS == nil, let lnThresh, lnThresh.isFinite { threshLUFS = lnThresh }
            }
        }

        return AudioLoudnessMeasurement(
            integratedLUFS: integratedLUFS,
            maxVolumeDB: maxVol,
            meanVolumeDB: meanVol,
            truePeakDBTP: truePeakDBTP,
            loudnessRangeLU: lraLU,
            thresholdLUFS: threshLUFS,
            loudnormMeasuredInputI: lnI,
            loudnormMeasuredInputTP: lnTP,
            loudnormMeasuredInputLRA: lnLRA,
            loudnormMeasuredInputThresh: lnThresh,
            loudnormTargetOffset: lnOffset,
            normalizationTypeUsed: normType,
            predictedOutputI: predOutI,
            predictedOutputTP: predOutTP
        )
    }

    // MARK: - Subprocess Runners

    private func runFFmpegStdoutData(executablePath: String, arguments: [String]) async throws -> Data {
        let (stdoutData, _) = try await runFFmpegProcess(executablePath: executablePath, arguments: arguments, captureStdout: true)
        return stdoutData
    }

    private func runFFmpegStderr(executablePath: String, arguments: [String]) async throws -> String {
        let (_, stderrData) = try await runFFmpegProcess(executablePath: executablePath, arguments: arguments, captureStdout: false)
        return String(data: stderrData, encoding: .utf8) ?? ""
    }

    private func runFFmpegProcess(
        executablePath: String,
        arguments: [String],
        captureStdout: Bool
    ) async throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        do {
            let output = try await AsyncProcessRunner.run(process, stdin: .nullDevice)
            guard output.terminationStatus == 0 else {
                let rawErr = String(data: output.stderr, encoding: .utf8) ?? "FFmpeg exited with code \(output.terminationStatus)"
                throw ConversionError.engineExecutionFailed(
                    "Audio analysis could not complete (FFmpeg exit code \(output.terminationStatus)).",
                    underlyingError: rawErr
                )
            }
            return (captureStdout ? output.stdout : Data(), output.stderr)
        } catch is CancellationError {
            throw ConversionError.cancelled
        } catch let err as ConversionError {
            throw err
        } catch {
            throw ConversionError.engineExecutionFailed(error.localizedDescription, underlyingError: nil)
        }
    }
}

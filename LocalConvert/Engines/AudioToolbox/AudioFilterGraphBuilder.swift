import Foundation

// MARK: - Audio Filter Graph & Argument Builder

enum AudioFilterGraphBuilder {

    /// Builds ordered FFmpeg `-af` filter elements using only filters verified against bundled FFmpeg 9.0.2.
    /// (NOTE: `anlmdn` segfaults in bundled FFmpeg 9.0.2; use `afftdn` + `adeclick` instead.)
    static func buildFilterChain(
        config: AudioToolboxConfig,
        sourceInfo: MediaInfo?,
        measuredPeakDB: Double? = nil,
        loudnessMeasurement: AudioLoudnessMeasurement? = nil,
        trimStartOverride: Double? = nil,
        trimEndOverride: Double? = nil
    ) -> [String] {
        var filters: [String] = []

        let sourceSampleRate = sourceInfo?.primaryAudioStream?.sampleRate ?? 44100
        let sourceChannels = sourceInfo?.primaryAudioStream?.channels ?? 2
        let sourceDuration = sourceInfo?.duration ?? 0

        let startSec = trimStartOverride ?? config.trimStartSeconds
        let endSec = trimEndOverride ?? config.trimEndSeconds

        // 1. In-graph trim only if requested alongside filter processing (otherwise -ss/-to on input/output is faster).
        // Keeping trim inside filter_complex/af is exact sample-accurate even when combined with speed/fades/reverse.
        if startSec != nil || endSec != nil {
            var trimParts: [String] = []
            if let s = startSec, s > 0 {
                trimParts.append(String(format: "start=%.4f", s))
            }
            if let e = endSec, e > 0 {
                trimParts.append(String(format: "end=%.4f", e))
            }
            if !trimParts.isEmpty {
                filters.append("atrim=\(trimParts.joined(separator: ":"))")
                filters.append("asetpts=PTS-STARTPTS")
            }
        }

        // 2. Noise reduction (FFT denoiser + optional declick)
        if config.declickEnabled {
            filters.append("adeclick")
        }
        if config.noiseReduction != .off {
            let nr = String(format: "%.1f", config.noiseReduction.nrAmountDB)
            let nf = String(format: "%.1f", config.noiseReduction.noiseFloorDB)
            filters.append("afftdn=nr=\(nr):nf=\(nf)")
        }

        // 3. High-pass / Low-pass filters
        if let hp = config.highPassHz, hp > 10 {
            filters.append(String(format: "highpass=f=%.1f", hp))
        }
        if let lp = config.lowPassHz, lp > 100 {
            filters.append(String(format: "lowpass=f=%.1f", lp))
        }

        // 4. Parametric Equalizer
        for band in config.eqBands where abs(band.gainDB) > 0.05 {
            let f = String(format: "%.1f", band.frequencyHz)
            let q = String(format: "%.2f", max(0.3, band.qFactor))
            let g = String(format: "%.2f", band.gainDB)
            filters.append("equalizer=f=\(f):t=q:w=\(q):g=\(g)")
        }

        // 5. Pitch Shift & Tempo Scaling
        let semitones = config.pitchSemitones
        let targetSpeed = min(4.0, max(0.25, config.speedMultiplier))
        var remainingTempo = targetSpeed

        if abs(semitones) > 0.05 {
            let pitchFactor = pow(2.0, semitones / 12.0)
            let shiftedRate = max(8000, Int((Double(sourceSampleRate) * pitchFactor).rounded()))
            filters.append("asetrate=\(shiftedRate)")
            filters.append("aresample=\(sourceSampleRate)")
            // asetrate shifted speed by `pitchFactor`, so divide desired tempo by pitchFactor
            remainingTempo = targetSpeed / pitchFactor
        }

        if abs(remainingTempo - 1.0) > 0.005 {
            filters.append(contentsOf: chainedAtempoFilters(factor: remainingTempo))
        }

        // 6. Silence removal
        if config.operation == .removeSilence || config.removeSilence {
            let thresh = String(format: "%.1fdB", config.silenceThresholdDB)
            let minDur = String(format: "%.2f", max(0.05, config.silenceMinDurationSeconds))
            switch config.silenceTrimScope {
            case .all:
                filters.append("silenceremove=start_periods=1:start_duration=0.02:start_threshold=\(thresh):stop_periods=-1:stop_duration=\(minDur):stop_threshold=\(thresh)")
            case .edgesOnly:
                // Remove leading silence (keeping 20ms onset), reverse, remove trailing silence cleanly, reverse back
                filters.append("silenceremove=start_periods=1:start_duration=0.02:start_threshold=\(thresh)")
                filters.append("areverse")
                filters.append("silenceremove=start_periods=1:start_duration=0.02:start_threshold=\(thresh)")
                filters.append("areverse")
            }
        }

        // 7. Reverse
        if config.reverseAudio {
            filters.append("areverse")
        }

        // 8. Dynamics (Compressor + Limiter)
        if config.compressorEnabled {
            let thresh = String(format: "%.1fdB", config.compressorThresholdDB)
            let ratio = String(format: "%.2f", max(1.0, config.compressorRatio))
            filters.append("acompressor=threshold=\(thresh):ratio=\(ratio):attack=15:release=180")
        }
        if config.limiterEnabled {
            let limitLinear = pow(10.0, config.limiterCeilingDB / 20.0)
            let clamped = min(1.0, max(0.0625, limitLinear))
            filters.append(String(format: "alimiter=limit=%.4f:attack=5:release=50", clamped))
        }

        // 9. Channel routing / balance / stereo widening
        if config.swapChannels && sourceChannels >= 2 && config.channelMode != .mono {
            filters.append("pan=stereo|c0=c1|c1=c0")
        }

        let targetChannels = config.channelMode.channelCount ?? sourceChannels
        if abs(config.channelBalance) > 0.01 || abs(config.stereoWidth - 1.0) > 0.01 {
            if targetChannels >= 2 {
                let slev = String(format: "%.2f", min(2.0, max(0.0, config.stereoWidth)))
                let bal = String(format: "%.2f", min(1.0, max(-1.0, config.channelBalance)))
                filters.append("stereotools=mlev=1.0:slev=\(slev):balance_in=\(bal)")
            }
        }

        // 10. Volume gain
        if abs(config.volumeGainDB) > 0.05 {
            filters.append(String(format: "volume=%.2fdB", config.volumeGainDB))
        }

        // 11. Fade In / Fade Out
        if config.fadeInSeconds > 0.01 {
            filters.append(String(format: "afade=t=in:st=0:d=%.3f", config.fadeInSeconds))
        }
        if config.fadeOutSeconds > 0.01 {
            let effectiveBaseDuration: Double
            if let s = startSec, let e = endSec, e > s {
                effectiveBaseDuration = min(e, sourceDuration > 0 ? sourceDuration : e) - max(0, s)
            } else if let e = endSec, e > 0 {
                effectiveBaseDuration = sourceDuration > 0 ? min(e, sourceDuration) : e
            } else if let s = startSec, s > 0, sourceDuration > s {
                effectiveBaseDuration = sourceDuration - s
            } else {
                effectiveBaseDuration = sourceDuration
            }
            let effectiveDuration = effectiveBaseDuration / targetSpeed
            if effectiveDuration > 0.05 {
                let fadeDur = min(config.fadeOutSeconds, effectiveDuration)
                let fadeStart = max(0, effectiveDuration - fadeDur)
                filters.append(String(format: "afade=t=out:st=%.3f:d=%.3f", fadeStart, fadeDur))
            }
        }

        // 12. Loudness / Peak Normalization & Resampling / Dithering
        switch config.normalizationMode {
        case .none:
            break
        case .ebuR128:
            let lufs = min(-5.0, max(-36.0, config.targetLUFS))
            let tp = min(0.0, max(-9.0, config.targetTruePeakDB))
            let restoreRate = config.sampleRateHz ?? (sourceSampleRate > 0 ? sourceSampleRate : 44100)
            if let lm = loudnessMeasurement,
               let mI = lm.loudnormMeasuredInputI, mI.isFinite, mI > -70,
               let mTP = lm.loudnormMeasuredInputTP, mTP.isFinite,
               let mLRA = lm.loudnormMeasuredInputLRA, mLRA.isFinite,
               let mThresh = lm.loudnormMeasuredInputThresh, mThresh.isFinite,
               let mOffset = lm.loudnormTargetOffset, mOffset.isFinite {
                // Genuine two-pass EBU R128 loudness normalization (reports actual linear vs dynamic fallback in JSON)
                filters.append(String(
                    format: "loudnorm=I=%.1f:TP=%.1f:LRA=11:measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true:print_format=json",
                    lufs, tp, mI, mTP, mLRA, mThresh, mOffset
                ))
            } else {
                filters.append(String(format: "loudnorm=I=%.1f:TP=%.1f:LRA=11:print_format=json", lufs, tp))
            }
            filters.append(resampleFilterString(rate: restoreRate, config: config))
            filters.append("asetnsamples=n=4096:p=0")
        case .peak:
            let effectivePeak = measuredPeakDB ?? loudnessMeasurement?.maxVolumeDB
            if let peakDB = effectivePeak {
                let neededGain = config.peakNormalizeTargetDB - peakDB
                if abs(neededGain) > 0.05 && neededGain.isFinite {
                    let clampedGain = min(60.0, max(-60.0, neededGain))
                    filters.append(String(format: "volume=%.2fdB", clampedGain))
                }
            } else {
                filters.append(String(format: "loudnorm=I=-16.0:TP=%.1f:LRA=11", config.peakNormalizeTargetDB))
                let restoreRate = config.sampleRateHz ?? (sourceSampleRate > 0 ? sourceSampleRate : 44100)
                filters.append(resampleFilterString(rate: restoreRate, config: config))
                filters.append("asetnsamples=n=4096:p=0")
            }
        }

        // Apply high-precision SoX resampling / TPDF dithering when sample rate or 16-bit depth conversion is requested outside loudnorm
        if config.normalizationMode != .ebuR128 {
            let needsExplicitResample = (config.sampleRateHz != nil && config.sampleRateHz != sourceSampleRate)
            let isLoweringTo16Bit = (config.bitDepth == 16) || (config.codec == .pcmS16LE || config.codec == .pcmS16BE)
            if needsExplicitResample || (isLoweringTo16Bit && config.ditherMethod != .auto) {
                let targetRate = config.sampleRateHz ?? (sourceSampleRate > 0 ? sourceSampleRate : 44100)
                filters.append(resampleFilterString(rate: targetRate, config: config))
            }
        }

        // Ensure exact channel layout mask when converting to Mono, Stereo, 2.1, 5.1, or 7.1
        if config.operation != .merge, let layoutName = config.channelMode.ffmpegLayoutName {
            filters.append("aformat=channel_layouts=\(layoutName)")
        }

        return filters
    }

    static func resampleFilterString(rate: Int, config: AudioToolboxConfig) -> String {
        var parts = ["aresample=\(rate)"]
        if config.resamplerEngine == .kaiserSinc {
            parts.append("filter_type=kaiser")
            parts.append("filter_size=32")
            parts.append("exact_rational=1")
        }
        if let dither = config.ditherMethod.ffmpegValue {
            parts.append("dither_method=\(dither)")
        }
        return parts.joined(separator: ":")
    }

    /// FFmpeg `atempo` supports `0.5...2.0` per stage; chain multiple stages cleanly for wider ranges.
    static func chainedAtempoFilters(factor: Double) -> [String] {
        var remaining = min(16.0, max(0.0625, factor))
        var stages: [String] = []
        while remaining > 2.0 {
            stages.append("atempo=2.0")
            remaining /= 2.0
        }
        while remaining < 0.5 {
            stages.append("atempo=0.5")
            remaining /= 0.5
        }
        if abs(remaining - 1.0) > 0.002 {
            stages.append(String(format: "atempo=%.4f", remaining))
        }
        return stages
    }

    // MARK: - Codec Encoding CLI Arguments

    static func codecArguments(
        config: AudioToolboxConfig,
        outputFormat: FileFormat,
        options: ConversionOptions
    ) -> [String] {
        let legacyLosslessM4A = (options.customOptions["m4a_lossless"] == "true")
        let codec = config.resolvedCodec(for: outputFormat, legacyLosslessM4A: legacyLosslessM4A)
        let quality = options.effectiveMediaQuality
        let spec = AudioCodecRegistry.spec(for: codec)

        if codec == .streamCopy {
            return ["-c:a", "copy"] + containerMuxerArguments(for: outputFormat)
        }

        var args: [String] = ["-c:a", codec.ffmpegEncoderName]
        if codec.requiresExperimentalFlag {
            args += ["-strict", "-2"]
        }

        // Bitrate or VBR
        if config.bitrateMode == .vbr && spec.supportsVBR {
            switch codec {
            case .mp3:
                let q = config.vbrQuality ?? defaultVBRQuality(for: codec, mediaQuality: quality)
                args += ["-q:a", "\(q)"]
            case .aacAT:
                let q = config.vbrQuality ?? defaultVBRQuality(for: codec, mediaQuality: quality)
                args += ["-q:a", "\(q)"]
            case .vorbis:
                let q = config.vbrQuality ?? defaultVBRQuality(for: codec, mediaQuality: quality)
                args += ["-q:a", "\(q)"]
            case .opus:
                let kbps = config.bitrateKbps ?? defaultBitrateKbps(for: codec, outputFormat: outputFormat, mediaQuality: quality)
                args += ["-vbr", "on", "-b:a", "\(kbps)k"]
            default:
                break
            }
        } else if spec.supportsCBR {
            let kbps = config.bitrateKbps ?? defaultBitrateKbps(for: codec, outputFormat: outputFormat, mediaQuality: quality)
            if codec == .opus {
                args += ["-vbr", "off", "-b:a", "\(kbps)k"]
            } else {
                args += ["-b:a", "\(kbps)k"]
            }
        }

        // Lossless compression level (FLAC, WavPack)
        if spec.supportsCompressionLevel, let level = config.compressionLevel {
            args += ["-compression_level", "\(level)"]
        }

        // Bit depth / sample format
        if let bitDepth = config.bitDepth {
            switch (codec, bitDepth) {
            case (.flac, 16):
                args += ["-sample_fmt", "s16"]
            case (.flac, 24):
                args += ["-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
            case (.alac, 16):
                args += ["-sample_fmt", "s16p"]
            case (.alac, 24):
                args += ["-sample_fmt", "s32p"]
            case (.wavpack, 16):
                args += ["-sample_fmt", "s16p"]
            case (.wavpack, 24):
                args += ["-sample_fmt", "s32p", "-bits_per_raw_sample", "24"]
            case (.wavpack, 32):
                args += ["-sample_fmt", "fltp"]
            default:
                break
            }
        } else if codec == .flac {
            // Filter chains emit float/double samples; force standard 16-bit PCM for FLAC unless 24-bit is requested
            // so FFmpeg does not try experimental 32-bit FLAC encoding.
            args += ["-sample_fmt", "s16"]
        }

        // Explicit sample rate
        if let sr = config.sampleRateHz {
            args += ["-ar", "\(sr)"]
        } else if outputFormat == .mp3 && !spec.supportedSampleRates.isEmpty {
            // Do not force if source is already standard, FFmpeg chooses valid rate safely
        }

        // Channels
        if let ch = config.channelMode.channelCount {
            args += ["-ac", "\(ch)"]
        }

        args += containerMuxerArguments(for: outputFormat)
        return args
    }

    static func containerMuxerArguments(for outputFormat: FileFormat) -> [String] {
        switch outputFormat {
        case .m4a, .alac:
            return ["-f", "ipod"]
        case .m4b:
            return ["-f", "mp4"]
        case .aac:
            return ["-f", "adts"]
        case .wma:
            return ["-f", "asf"]
        case .wv:
            return ["-f", "wv"]
        case .mka:
            return ["-f", "matroska"]
        case .aiff:
            return ["-f", "aiff", "-write_id3v2", "1"]
        case .au:
            return ["-f", "au"]
        case .caf:
            return ["-f", "caf"]
        case .ogg:
            return ["-f", "ogg"]
        case .opus:
            return ["-f", "opus"]
        default:
            return []
        }
    }

    private static func defaultBitrateKbps(for codec: AudioCodecID, outputFormat: FileFormat, mediaQuality: QualityPreset) -> Int {
        if outputFormat == .m4b && (codec == .aac || codec == .aacAT) {
            switch mediaQuality {
            case .low: return 96
            case .medium: return 128
            case .high: return 192
            case .maximum: return 256
            }
        }
        switch codec {
        case .aac, .aacAT, .mp3, .vorbis:
            switch mediaQuality {
            case .low: return 128
            case .medium: return 192
            case .high: return 256
            case .maximum: return 320
            }
        case .wmav2:
            switch mediaQuality {
            case .low: return 128
            case .medium: return 192
            case .high, .maximum: return 256
            }
        case .opus:
            switch mediaQuality {
            case .low: return 96
            case .medium: return 128
            case .high: return 192
            case .maximum: return 256
            }
        case .ac3, .eac3:
            switch mediaQuality {
            case .low: return 192
            case .medium: return 384
            case .high: return 448
            case .maximum: return 640
            }
        case .dts:
            return 768
        default:
            return 192
        }
    }

    private static func defaultVBRQuality(for codec: AudioCodecID, mediaQuality: QualityPreset) -> Int {
        switch codec {
        case .mp3:
            switch mediaQuality {
            case .low: return 5
            case .medium: return 3
            case .high: return 2
            case .maximum: return 0
            }
        case .aacAT:
            // FFmpeg `aac_at` -q:a is lower-is-better (0 = highest quality, 14 = smallest file)
            switch mediaQuality {
            case .low: return 8
            case .medium: return 4
            case .high: return 2
            case .maximum: return 0
            }
        case .vorbis:
            switch mediaQuality {
            case .low: return 3
            case .medium: return 5
            case .high: return 7
            case .maximum: return 9
            }
        default:
            return 5
        }
    }
}
